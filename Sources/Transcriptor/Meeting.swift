import Foundation

// A live meeting: the microphone plus everything the Mac plays, transcribed
// until End. Each stretch between Pause and Continue is its own Soniox session,
// so a pause sends no audio at all and the socket never idles out. The
// finished transcript lands in history under its name, with start and end time.
@MainActor @Observable
final class Meeting {
    enum Status { case idle, recording, paused, finishing, done }

    private(set) var status = Status.idle
    var title = ""
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private var savedID: String?
    private(set) var problem: String?
    private(set) var text = ""          // closed segments
    private(set) var live = ""          // the open segment, partial words included
    private var elapsedBefore = 0.0     // seconds recorded in closed segments
    private(set) var segmentStart: Date?

    private let store: Store
    private var session: Session?
    private var open = 0                // sessions still waiting for their final words

    init(store: Store) { self.store = store }

    var transcript: String { Self.join(text, live) }
    var isActive: Bool { status == .recording || status == .paused || status == .finishing }

    func elapsed(at now: Date) -> TimeInterval {
        elapsedBefore + (segmentStart.map { now.timeIntervalSince($0) } ?? 0)
    }

    func start() {
        guard !isActive else { return }
        text = ""
        live = ""
        problem = nil
        elapsedBefore = 0
        savedID = nil
        startedAt = .now
        begin()
    }

    func togglePause() {
        switch status {
        case .recording:
            close()
            status = .paused
        case .paused:
            begin()
        default: break
        }
    }

    func end() {
        guard status == .recording || status == .paused else { return }
        close()
        status = .finishing
        if open == 0 { complete() }
    }

    func reset() {
        guard !isActive else { return }
        status = .idle
        title = ""
        text = ""
        live = ""
    }

    /// Renaming after the end updates the saved entry too.
    func commitTitle() {
        guard let savedID else { return }
        store.retitle(savedID, displayTitle)
    }

    private var displayTitle: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled meeting" : name
    }

    private func begin() {
        guard let apiKey = Keychain.get(Keychain.Account.soniox), !apiKey.isEmpty else {
            problem = "Add your Soniox API key in Settings first."
            status = .paused
            return
        }
        var config = store.config
        config.silenceStopMs = 0 // meetings have long silences; only End stops them
        // A fresh capture per segment: the previous one may still be finishing,
        // and its teardown must not stop this one's microphone.
        let session = Session(mic: MicCapture(systemAudio: SystemAudio()))
        session.onTranscript = { [weak self] final, partial in
            self?.live = Session.collapse(final + " " + partial)
        }
        session.onResult = { [weak self, weak session] text, _ in self?.closed(session, text: text) }
        session.onError = { [weak self, weak session] message, text, _ in
            self?.closed(session, text: text, error: message)
        }
        do {
            try session.start(config: config, apiKey: apiKey)
        } catch {
            problem = error.localizedDescription
            status = .paused
            return
        }
        self.session = session
        open += 1
        problem = nil
        segmentStart = .now
        status = .recording
    }

    /// Stops listening now; the segment's last words arrive in `closed`.
    private func close() {
        if let segmentStart { elapsedBefore += Date.now.timeIntervalSince(segmentStart) }
        segmentStart = nil
        session?.stop()
    }

    private func closed(_ finished: Session?, text segment: String, error: String? = nil) {
        open -= 1
        text = Self.join(text, segment)
        let current = finished === session
        if current {
            session = nil
            live = ""
        }
        if status == .finishing, open == 0 { return complete() }
        // A dropped connection mid-meeting reconnects on its own; a dead one waits for the user.
        guard current, status == .recording, let error else { return }
        if let segmentStart { elapsedBefore += Date.now.timeIntervalSince(segmentStart) }
        segmentStart = nil
        if segment.isEmpty {
            problem = error
            status = .paused
        } else {
            begin()
        }
    }

    private func complete() {
        status = .done
        endedAt = .now
        let final = transcript
        guard !final.isEmpty else { return }
        savedID = try? store.recordTranscript(final, durationMs: (elapsedBefore * 1000).rounded(),
                                              title: displayTitle, startedAt: startedAt)
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}
