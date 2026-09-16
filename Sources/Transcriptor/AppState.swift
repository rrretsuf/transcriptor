import AppKit
import AVFoundation
import Foundation

// Global so other types (NotchSurface, tests) can use them without inheriting
// the AppState actor isolation.
enum Phase { case idle, recording, finishing, polishing }
enum SessionMode { case dictate, email }

@MainActor @Observable
final class AppState {
    static let emailHotkey = "Command+Shift+E"

    private(set) var state = Phase.idle
    private(set) var sessionMode = SessionMode.dictate
    private(set) var sessionId = 0

    let store = Store()
    let hotkeys = Hotkeys()
    let surface = NotchSurface()
    let tapWatcher = TapWatcher()
    private let mic = MicCapture()
    private var session: Session?
    private var starting = false
    private var apiKey: String? // lazily read from Keychain on first dictation

    var config: Config { store.config }

    func forgetKey() { apiKey = nil }

    /// Lent by the tray label view; agent apps must activate before a window can come forward.
    var openSettings: (() -> Void)?

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
    }

    /// Island click: show the running transcript feed under the notch, remembered.
    func toggleNotchExpanded() {
        var next = config
        next.notchExpanded.toggle()
        store.stage(next)
        surface.setExpanded(next.notchExpanded)
    }

    /* ---------------------------------- hotkeys --------------------------------- */

    func registerHotkey() {
        hotkeys.unregisterAll()
        if state != .idle { registerEscape() }
        if config.emailEnabled && config.hotkey != Self.emailHotkey
            && !hotkeys.register(Self.emailHotkey, handler: { [weak self] in self?.startEmail() }) {
            notify("Email hotkey unavailable", "\(Self.emailHotkey) is already taken by another app.")
        }
        applyTapWatcher()
        if Hotkeys.parseTap(config.hotkey) != nil { return }
        if !hotkeys.register(config.hotkey, handler: { [weak self] in self?.toggle() }) {
            notify("Hotkey unavailable", "\(config.hotkey) is already taken by another app.")
        }
    }

    // tap:<modifier>:<count> needs a CGEvent watcher; Carbon cannot express it.
    private func applyTapWatcher() {
        guard let wanted = Hotkeys.parseTap(config.hotkey) else { return tapWatcher.stop() }
        tapWatcher.onTap = { [weak self] modifier, count in
            guard modifier == wanted.modifier, count >= wanted.count else { return false }
            self?.toggle()
            return true
        }
        tapWatcher.start()
    }

    private func registerEscape() {
        _ = hotkeys.register("Escape") { [weak self] in self?.cancel() }
    }

    /* --------------------------------- sessions --------------------------------- */

    func toggle() {
        if state == .recording { return stop() }
        guard state == .idle, !starting else { return }
        sessionMode = .dictate
        beginSession()
    }

    func startEmail() {
        if state == .recording { return stop() }
        guard state == .idle, !starting else { return }
        guard config.emailEnabled else {
            notify("Email dictation is off", "Turn it on in Settings to dictate emails with ⌘⇧E.")
            return
        }
        sessionMode = .email
        beginSession()
    }

    /// Warm everything a session needs so the hotkey only has to flip a switch.
    func prepare() {
        Task.detached(priority: .utility) { [weak self] in
            let key = Keychain.get(Keychain.Account.soniox)
            await MainActor.run { self?.apiKey = key }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { try? mic.warm() }
        SonioxClient.warm()
    }

    private func beginSession() {
        if apiKey?.isEmpty ?? true { apiKey = Keychain.get(Keychain.Account.soniox) }
        guard let apiKey, !apiKey.isEmpty else {
            notify("Transcriptor", "Add your Soniox API key in Settings first.")
            showSettings()
            return
        }
        // The island opens on this very frame; mic and socket catch up behind it.
        starting = true
        sessionId += 1
        setState(.recording)
        surface.show(expanded: config.notchExpanded)
        Task {
            defer { starting = false }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    setState(.idle)
                    surface.fail("Microphone access is off")
                    notify("Microphone blocked", "Allow microphone access in System Settings › Privacy.")
                    return
                }
            }
            guard state == .recording else { return } // cancelled while asking
            let session = Session(mic: mic)
            session.onTranscript = { [weak self] final, partial in
                self?.surface.update(final: final, partial: partial)
            }
            session.onLevel = { [weak self] rms in self?.surface.level(rms) }
            session.onAutostop = { [weak self] in self?.stop() }
            session.onResult = { [weak self] text, ms in self?.handleResult(text: text, durationMs: ms) }
            session.onError = { [weak self] message, text, ms in
                self?.handleError(message: message, text: text, durationMs: ms)
            }
            do {
                try session.start(config: config, apiKey: apiKey)
                self.session = session
                registerEscape()
            } catch {
                setState(.idle)
                surface.fail("Microphone unavailable")
                notify("Could not start dictation", error.localizedDescription)
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        guard let session else { return cancel() } // stopped before the mic was up
        setState(.finishing)
        surface.finishing()
        session.stop()
    }

    func cancel() {
        guard state != .idle else { return }
        hotkeys.unregister("Escape")
        session?.cancel()
        session = nil
        setState(.idle)
        surface.idle()
    }

    /* --------------------------------- results ---------------------------------- */

    func handleResult(text: String, durationMs: Double) {
        guard state != .idle else { return }
        hotkeys.unregister("Escape")
        session = nil
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            setState(.idle)
            surface.fail("No speech detected")
            return
        }
        let mode = sessionMode
        let openrouterKey = Keychain.get(Keychain.Account.openrouter) ?? ""
        let wanted = mode == .email
            ? Polish.emailWanted(clean, config: config, openrouterKey: openrouterKey)
            : Polish.cleanupWanted(clean, config: config, openrouterKey: openrouterKey)
        guard wanted else {
            surface.idle()
            setState(.idle)
            recordAndPaste(clean, durationMs: durationMs)
            // "exp" tier: raw text pastes instantly while models clean in the background.
            if mode != .email, Polish.experimentWanted(clean, config: config, openrouterKey: openrouterKey) {
                Task { await Polish.experiment(clean, config: config, openrouterKey: openrouterKey) }
            }
            return
        }
        // AI path: the notch stays visible in a loading state until the
        // polished text (or the original, on failure) is pasted.
        setState(.polishing)
        surface.polishing()
        let polishingId = sessionId
        Task { [config] in
            let outcome = mode == .email
                ? await Polish.email(clean, config: config, openrouterKey: openrouterKey)
                : await Polish.cleanup(clean, config: config, openrouterKey: openrouterKey)
            guard self.sessionId == polishingId, self.state == .polishing else { return }
            if outcome.ok, let usage = outcome.usage { self.recordUsage(usage, mode: mode) }
            if !outcome.ok {
                switch outcome.reason {
                case "HTTP 401", "HTTP 402", "HTTP 403":
                    notify(mode == .email ? "Email skipped" : "Cleanup skipped",
                           "Your OpenRouter key was rejected. The original transcription was pasted.")
                default:
                    if mode == .email {
                        notify("Email not structured",
                               "The email model failed (\(outcome.reason)). The original transcription was pasted.")
                    }
                }
            }
            surface.idle()
            setState(.idle)
            let final = outcome.ok && !outcome.text.isEmpty ? outcome.text : clean
            self.recordAndPaste(final, durationMs: durationMs)
        }
    }

    private func recordAndPaste(_ text: String, durationMs: Double) {
        do {
            try store.recordTranscript(text, durationMs: durationMs)
        } catch {
            notify("History could not be saved", "Your transcription is still available on the clipboard.")
        }
        Paste.pasteAtCursor(text, autoPaste: config.autoPaste, restoreClipboard: config.restoreClipboard)
    }

    private func recordUsage(_ usage: Polish.Usage, mode: SessionMode) {
        store.recordCleanup { stats in
            if mode == .email {
                stats.emailCount += 1
                stats.emailCostUsd += usage.costUsd ?? 0
            } else {
                stats.count += 1
                stats.promptTokens += usage.promptTokens ?? 0
                stats.completionTokens += usage.completionTokens ?? 0
                stats.costUsd += usage.costUsd ?? 0
            }
        }
    }

    /// Network or Soniox failure. Whatever was already transcribed is not lost:
    /// it is pasted like a normal result. The island carries the message; a
    /// banner only appears when there is nothing to paste.
    func handleError(message: String, text: String, durationMs: Double) {
        guard state != .idle else { return }
        hotkeys.unregister("Escape")
        session = nil
        setState(.idle)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            surface.fail(message)
            notify("Transcription failed", message)
        } else {
            surface.fail("Connection lost — partial text pasted")
            recordAndPaste(clean, durationMs: durationMs)
        }
    }

    private func setState(_ next: Phase) {
        state = next
        if next == .idle { sessionMode = .dictate }
    }
}
