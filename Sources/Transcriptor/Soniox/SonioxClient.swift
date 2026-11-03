import Foundation

// 1:1 port of the socket half of pill.js: config on open, audio queued while
// connecting, "" terminator + finish timer, bufferedAmount guard via an
// in-flight send counter (URLSessionWebSocketTask has no bufferedAmount).
@MainActor
final class SonioxClient {
    enum Event {
        case `final`(String)
        case partial(String)
        case finished
        case failed(String)
    }

    private enum State { case connecting, open, done }

    nonisolated static let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let maxBufferBytes = 16000 * 2 * 15
    static let chunkBytes = 1280 // 40 ms of s16le mono at 16 kHz

    let events: AsyncStream<Event>
    private var continuation: AsyncStream<Event>.Continuation?

    private var task: URLSessionWebSocketTask?
    private var state = State.connecting
    private var queue: [Data] = []
    private var inFlight = 0
    private var finalized = false
    private var translateTo = ""
    private var lastSpeaker: String?
    private let decoder = JSONDecoder()

    private var openTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var finishTimeout: Task<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    var isOpen: Bool { state == .open }

    func connect(apiKey: String, config: Config, translateTo: String? = nil) {
        self.translateTo = translateTo ?? config.translateTo
        let task = URLSession.shared.webSocketTask(with: Self.url)
        self.task = task
        task.resume()

        // A successful send means the handshake completed; config goes first,
        // then everything that was queued while connecting.
        let configJSON = String(decoding: try! JSONEncoder().encode(Self.configMessage(apiKey: apiKey, config: config)), as: UTF8.self)
        openTask = Task { [weak self] in
            do { try await task.send(.string(configJSON)) } catch {
                self?.fail("Soniox unreachable")
                return
            }
            guard let self, self.state == .connecting else { return }
            self.connectTimeout?.cancel()
            self.state = .open
            let queued = self.queue
            self.queue = []
            for pcm in queued { self.sendNow(pcm) }
            if self.finalized { self.sendTerminator() }
        }

        receiveTask = Task { [weak self] in
            while let self, self.state != .done, let task = self.task {
                do {
                    guard case .string(let text) = try await task.receive() else { continue }
                    self.handle(Data(text.utf8))
                } catch {
                    if self.state == .connecting { self.fail("Soniox unreachable") }
                    else if self.state == .open { self.fail("Connection closed before transcription completed") }
                    return
                }
            }
        }

        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.fail("Connection timed out")
        }
    }

    func send(pcm: Data) {
        switch state {
        case .connecting:
            if queue.count * Self.chunkBytes >= Self.maxBufferBytes {
                return fail("Connection is too slow")
            }
            queue.append(pcm)
        case .open:
            if inFlight * Self.chunkBytes > Self.maxBufferBytes {
                return fail("Connection is too slow")
            }
            sendNow(pcm)
        case .done:
            break
        }
    }

    /// Sends the "" terminator once audio has stopped; if the socket is still
    /// connecting it is sent right after the queued audio on open (pill.js
    /// `stopping && captureStopped → finalizeStream()` in onopen).
    func finalize() {
        guard !finalized, state != .done else { return }
        finalized = true
        if state == .open { sendTerminator() }
    }

    func cancel() {
        guard state != .done else { return }
        state = .done
        teardown()
    }

    private func sendNow(_ pcm: Data) {
        guard let task else { return }
        inFlight += 1
        Task { [weak self] in
            _ = try? await task.send(.data(pcm))
            self?.inFlight -= 1
        }
    }

    private func sendTerminator() {
        guard let task else { return }
        Task { _ = try? await task.send(.string("")) }
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.fail("Final transcription timed out")
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? decoder.decode(Incoming.self, from: data) else { return }
        if let code = message.error_code {
            fail(message.error_message ?? "Soniox error \(code.value)")
            return
        }
        if let tokens = message.tokens {
            var final = "", pending = ""
            var speaker = lastSpeaker
            for token in tokens where Self.keepToken(token, translateTo: translateTo) {
                let text = Self.speakerMark(token.speaker, after: &speaker) + token.text
                if token.is_final {
                    final += text
                    lastSpeaker = speaker
                } else {
                    pending += text
                }
            }
            if !final.isEmpty { continuation?.yield(.final(final)) }
            continuation?.yield(.partial(pending))
        }
        if message.finished == true {
            state = .done
            continuation?.yield(.finished)
            teardown()
        }
    }

    private func fail(_ message: String) {
        guard state != .done else { return }
        state = .done
        continuation?.yield(.failed(message))
        teardown()
    }

    private func teardown() {
        connectTimeout?.cancel()
        finishTimeout?.cancel()
        openTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        queue = []
        continuation?.finish()
        continuation = nil
    }

    // A throwaway connection caches DNS + TLS so the next real one resumes
    // instead of paying a full handshake (pill.js warmSocket).
    nonisolated static func warm() {
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let close: @Sendable () -> Void = { task.cancel(with: .normalClosure, reason: nil) }
        // Any receive result (a frame or an error) means the handshake is done.
        task.receive { _ in close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: close)
    }

    /* -------------------------------- protocol -------------------------------- */

    struct ConfigMessage: Encodable {
        var api_key: String
        var model: String
        var audio_format = "s16le"
        var sample_rate = 16000
        var num_channels = 1
        var enable_endpoint_detection = true
        var enable_speaker_diarization: Bool?
        var language_hints: [String]?
        var context: Context?
        var translation: Translation?

        struct Context: Encodable {
            var terms: [String]?
            var text: String?

            /// nil when there is nothing to tell Soniox.
            init?(terms: [String], text: String = "") {
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !terms.isEmpty || !text.isEmpty else { return nil }
                self.terms = terms.isEmpty ? nil : terms
                self.text = text.isEmpty ? nil : text
            }
        }
        struct Translation: Encodable { var type = "one_way"; var target_language: String }
    }

    nonisolated static func configMessage(apiKey: String, config: Config) -> ConfigMessage {
        var message = ConfigMessage(api_key: apiKey, model: config.model)
        if !config.languageHints.isEmpty { message.language_hints = config.languageHints }
        if config.labelSpeakers { message.enable_speaker_diarization = true }
        message.context = .init(terms: config.terms, text: config.precedingText)
        if !config.translateTo.isEmpty {
            message.translation = .init(target_language: config.translateTo)
        }
        return message
    }

    /// Soniox error_code arrives as a string or a number depending on the error.
    struct FlexibleCode: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { value = string }
            else if let int = try? container.decode(Int.self) { value = String(int) }
            else { value = "unknown" }
        }
    }

    struct Incoming: Decodable {
        struct Token: Decodable {
            var text = ""
            var is_final = false
            var translation_status: String?
            var speaker: String?
        }
        var tokens: [Token]?
        var finished: Bool?
        var error_code: FlexibleCode?
        var error_message: String?
    }

    /// A new paragraph with "Speaker N:" wherever the voice changes. Soniox only
    /// sends speakers when diarization is on, so dictation never gets a label.
    nonisolated static func speakerMark(_ speaker: String?, after last: inout String?) -> String {
        guard let speaker, speaker != last else { return "" }
        last = speaker
        return "\n\nSpeaker \(speaker): "
    }

    /// pill.js keepToken: drop "<end>"-style specials; when translating, only
    /// translated tokens are kept.
    nonisolated static func keepToken(_ token: Incoming.Token, translateTo: String) -> Bool {
        let text = token.text
        if text.count > 2, text.first == "<", text.last == ">", !text.dropFirst().dropLast().contains(">") { return false }
        if translateTo.isEmpty { return true }
        return token.translation_status == "translation"
    }
}
