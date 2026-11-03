import AppKit
import AVFoundation
import Foundation

// Global so other types (NotchSurface, tests) can use them without inheriting
// the AppState actor isolation.
enum Phase { case idle, recording, finishing }

@MainActor @Observable
final class AppState {
    static let cancelHotkey = "Option+X"

    private(set) var state = Phase.idle

    let store = Store()
    let hotkeys = Hotkeys()
    let surface = NotchSurface()
    let tapWatcher = TapWatcher()
    let files: FileTranscription
    let meeting: Meeting
    private let mic = MicCapture()
    private var session: Session?
    private var starting = false
    private var apiKey: String? // lazily read from Keychain on first dictation

    var config: Config { store.config }

    init() {
        files = FileTranscription(store: store)
        meeting = Meeting(store: store)
    }

    func forgetKey() { apiKey = nil }

    /// Lent by the tray label view; agent apps must activate before a window can come forward.
    var openSettings: (() -> Void)?

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
    }

    /// Island minus / plus: fold the island down to the notch's height, remembered.
    func setNotchMinimized(_ minimized: Bool) {
        var next = config
        next.notchMinimized = minimized
        store.stage(next)
        surface.setMinimized(minimized)
    }

    /* ---------------------------------- hotkeys --------------------------------- */

    func registerHotkey() {
        hotkeys.unregisterAll()
        if state != .idle { registerCancelKeys() }
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

    /// Escape cancels any phase; Option+X only while recording, so it never swallows typing otherwise.
    private func registerCancelKeys() {
        _ = hotkeys.register("Escape") { [weak self] in self?.cancel() }
        if state == .recording { _ = hotkeys.register(Self.cancelHotkey) { [weak self] in self?.cancel() } }
    }

    private func unregisterCancelKeys() {
        hotkeys.unregister("Escape")
        hotkeys.unregister(Self.cancelHotkey)
    }

    /* --------------------------------- sessions --------------------------------- */

    func toggle() {
        if state == .recording { return stop() }
        guard state == .idle, !starting else { return }
        beginSession()
    }

    /// Warm everything a session needs so the hotkey only has to flip a switch.
    func prepare() {
        Task.detached(priority: .utility) { [weak self] in
            let key = Keychain.get(Keychain.Account.soniox)
            await MainActor.run { self?.apiKey = key }
        }
        // Mic capture is deliberately not warmed here: the engine only runs
        // during a dictation, so the audio device stays free while idle.
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
        state = .recording
        surface.show(minimized: config.notchMinimized)
        Task {
            defer { starting = false }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    state = .idle
                    surface.fail("Microphone access is off")
                    notify("Microphone blocked", "Allow microphone access in System Settings › Privacy.")
                    return
                }
            }
            var config = self.config
            if config.cursorContext { config.precedingText = await Cursor.precedingText() }
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
                registerCancelKeys()
            } catch {
                state = .idle
                surface.fail("Microphone unavailable")
                notify("Could not start dictation", error.localizedDescription)
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        guard let session else { return cancel() } // stopped before the mic was up
        hotkeys.unregister(Self.cancelHotkey)
        state = .finishing
        surface.finishing()
        session.stop()
    }

    func cancel() {
        guard state != .idle else { return }
        unregisterCancelKeys()
        session?.cancel()
        session = nil
        state = .idle
        surface.idle()
    }

    /* --------------------------------- results ---------------------------------- */

    func handleResult(text: String, durationMs: Double) {
        guard state != .idle else { return }
        unregisterCancelKeys()
        session = nil
        state = .idle
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return surface.fail("No speech detected") }
        surface.idle()
        recordAndPaste(clean, durationMs: durationMs)
    }

    /// Paste first: the history write is disk I/O the user shouldn't wait on.
    private func recordAndPaste(_ text: String, durationMs: Double) {
        Paste.pasteAtCursor(text, autoPaste: config.autoPaste, restoreClipboard: config.restoreClipboard)
        do {
            try store.recordTranscript(text, durationMs: durationMs)
        } catch {
            notify("History could not be saved", "Your transcription is still available on the clipboard.")
        }
    }

    /// Network or Soniox failure. Whatever was already transcribed is not lost:
    /// it is pasted like a normal result. The island carries the message; a
    /// banner only appears when there is nothing to paste.
    func handleError(message: String, text: String, durationMs: Double) {
        guard state != .idle else { return }
        unregisterCancelKeys()
        session = nil
        state = .idle
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            surface.fail(message)
            notify("Transcription failed", message)
        } else {
            surface.fail("Connection lost — partial text pasted")
            recordAndPaste(clean, durationMs: durationMs)
        }
    }
}
