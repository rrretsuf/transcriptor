import Foundation

// One dictation: mic + socket, port of pill.js start/stop/cancel/finish/fail.
@MainActor
final class Session {
    private let mic: MicCapture
    private var client: SonioxClient?
    private var audioChunks = 0

    init(mic: MicCapture) { self.mic = mic }
    private var detector: SilenceDetector?

    private var finalText = ""
    private var partialText = ""
    private var startedAt = 0.0       // systemUptime seconds, like performance.now()
    private var capturedDuration = 0.0 // ms
    private var stopping = false
    private var generation = 0

    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    var onTranscript: ((_ final: String, _ partial: String) -> Void)?
    var onLevel: ((_ rms: Float) -> Void)?
    var onAutostop: (() -> Void)?
    var onResult: ((_ text: String, _ durationMs: Double) -> Void)?
    var onError: ((_ message: String, _ text: String, _ durationMs: Double) -> Void)?

    func start(config: Config, apiKey: String) throws {
        generation += 1
        let generation = self.generation
        finalText = ""
        partialText = ""
        stopping = false
        capturedDuration = 0
        audioChunks = 0
        detector = config.silenceStopMs > 0 ? SilenceDetector(thresholdMs: config.silenceStopMs) : nil

        let client = SonioxClient()
        self.client = client
        client.connect(apiKey: apiKey, config: config)

        eventTask = Task { [weak self] in
            for await event in client.events {
                guard let self, self.generation == generation else { return }
                switch event {
                case .final(let text):
                    self.finalText += text
                    self.onTranscript?(self.finalText, self.partialText)
                case .partial(let text):
                    self.partialText = text
                    self.onTranscript?(self.finalText, self.partialText)
                case .finished:
                    let result = (self.resultText(), self.durationMs())
                    self.teardown()
                    self.onResult?(result.0, result.1)
                case .failed(let message):
                    let result = (self.resultText(), self.durationMs())
                    self.teardown()
                    self.onError?(message, result.0, result.1)
                }
            }
        }

        let chunks: AsyncStream<MicCapture.Chunk>
        do { chunks = try mic.start() } catch {
            client.cancel()
            throw error
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        audioTask = Task { [weak self] in
            for await chunk in chunks {
                guard let self, self.generation == generation else { return }
                self.audioChunks += 1
                self.onLevel?(chunk.rms)
                client.send(pcm: chunk.pcm)
                if !self.stopping,
                   self.detector?.feed(rms: Double(chunk.rms),
                                       now: ProcessInfo.processInfo.systemUptime * 1000) == true {
                    self.onAutostop?()
                }
            }
            // The flushed tail is the stream's last element: every chunk has now
            // reached the socket, so the terminator can go out behind them.
            guard let self, self.generation == generation else { return }
            // Nothing captured (hotkey tapped twice, dead input): there is nothing
            // for Soniox to finish, so end quietly instead of waiting for a timeout.
            guard self.audioChunks > 0 else {
                let duration = self.durationMs()
                self.teardown()
                self.onResult?("", duration)
                return
            }
            self.client?.finalize()
        }
    }

    func stop() {
        guard !stopping else { return }
        capturedDuration = startedAt > 0
            ? ((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded() : 0
        stopping = true
        mic.stop() // flushes the tail chunk; the audio task finalizes the socket
    }

    func cancel() {
        teardown()
    }

    private func durationMs() -> Double {
        if stopping { return capturedDuration }
        guard startedAt > 0 else { return 0 }
        return ((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()
    }

    private func resultText() -> String {
        Self.collapse(finalText + partialText)
    }

    /// (finalText + partialText).replace(/\s+/g, " ").trim()
    nonisolated static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func teardown() {
        generation += 1
        audioTask?.cancel()
        audioTask = nil
        eventTask?.cancel()
        eventTask = nil
        mic.stop()
        client?.cancel()
        client = nil
        finalText = ""
        partialText = ""
        stopping = true
        // The TLS cache from this session goes stale; refresh it for the next one.
        Task { try? await Task.sleep(for: .seconds(30)); SonioxClient.warm() }
    }
}
