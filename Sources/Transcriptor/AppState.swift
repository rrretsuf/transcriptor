import AppKit
import Combine
import AVFoundation
import Foundation
import ServiceManagement

// Global so other types (NotchSurface, tests) can use them without inheriting
// the AppState actor isolation.
enum Phase { case idle, recording, finishing }

@MainActor
final class AppState: ObservableObject {
    static let cancelHotkey = "Option+X"

    @Published private(set) var state = Phase.idle
    @Published private(set) var detectedMeeting: DetectedMeeting?

    let store = Store()
    let hotkeys = Hotkeys()
    let surface = NotchSurface()
    let tapWatcher = TapWatcher()
    let files: FileTranscription
    let meeting: Meeting
    let meetingDetector = MeetingDetector()
    let meetingBanner = MeetingBanner()
    private let mic = MicCapture()
    private var session: Session?
    private var target: String?         // the app being dictated into, kept with the entry
    private var starting = false
    private var apiKey: String? // lazily read from Keychain on first dictation

    var config: Config { store.config }

    private var forwards: [AnyCancellable] = []

    init() {
        files = FileTranscription(store: store)
        meeting = Meeting(store: store)
        // Views read settings, history and the meeting's status through AppState.
        forwards = [
            store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            meeting.$status.sink { [weak self] status in
                guard let self else { return }
                if status == .recording || status == .paused || status == .finishing {
                    self.detectedMeeting = nil
                    self.meetingDetector.suppressNow()
                    self.meetingBanner.hide()
                }
                self.objectWillChange.send()
            },
        ]
        wireMeetingDetection()
    }

    func forgetKey() { apiKey = nil }

    /// Lent by the tray label view; agent apps must activate before a window can come forward.
    var openSettings: (() -> Void)?
    var openWindow: ((String) -> Void)?
    var statusItemFrame: (() -> NSRect?)? {
        didSet { meetingBanner.anchorRect = statusItemFrame }
    }

    private func wireMeetingDetection() {
        meetingDetector.isSuppressed = { [weak self] in
            self?.meeting.isActive ?? false
        }
        meetingDetector.onShow = { [weak self] detected in
            guard let self else { return }
            self.detectedMeeting = detected
            self.meetingBanner.show(detected)
        }
        meetingDetector.onUpdate = { [weak self] detected in
            guard let self else { return }
            self.detectedMeeting = detected
            self.meetingBanner.update(detected)
        }
        meetingDetector.onHide = { [weak self] in
            guard let self else { return }
            self.detectedMeeting = nil
            self.meetingBanner.hide()
        }
        meetingBanner.onStart = { [weak self] detected in
            self?.startDetectedMeeting(detected)
        }
        meetingBanner.onDismiss = { [weak self] in
            guard let self else { return }
            self.detectedMeeting = nil
            self.meetingDetector.dismissCurrent()
        }
    }

    func applyMeetingDetection() {
        if config.detectMeetings {
            meetingBanner.install()
            meetingDetector.start()
        } else {
            meetingDetector.stop()
            detectedMeeting = nil
            meetingBanner.hide()
        }
    }

    /// Starts meeting transcription with the detected meeting's title pre-filled
    /// (and still editable in the Meeting window).
    func startDetectedMeeting(_ detected: DetectedMeeting) {
        detectedMeeting = nil
        meetingDetector.suppressNow()
        meetingBanner.hide()
        if !meeting.isActive {
            meeting.reset()
            meeting.start(title: detected.title)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow?("meeting")
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let openSettings { openSettings() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }

    func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?("onboarding")
    }

    func finishOnboarding() {
        var next = config
        next.onboarded = true
        store.stage(next)
        store.flushConfig()
    }

    /// Island minus / plus: fold the island down to the notch's height, remembered.
    func setNotchMinimized(_ minimized: Bool) {
        var next = config
        next.notchMinimized = minimized
        store.stage(next)
        surface.setMinimized(minimized)
    }

    // Reapplied on every launch: a reinstall by build.sh can drop the login item.
    func applyLaunchAtLogin() {
        let app = SMAppService.mainApp
        if config.launchAtLogin, app.status != .enabled { try? app.register() }
        if !config.launchAtLogin, app.status == .enabled { try? app.unregister() }
    }

    /* ---------------------------------- hotkeys --------------------------------- */

    /// False when another app already owns the combination.
    @discardableResult
    func registerHotkey() -> Bool {
        hotkeys.unregisterAll()
        if state != .idle { registerCancelKeys() }
        applyTapWatcher()
        if Hotkeys.parseTap(config.hotkey) != nil { return true }
        return hotkeys.register(config.hotkey) { [weak self] in self?.toggle() }
    }

    /// Launch and Settings have no place to show a taken hotkey; the welcome window does.
    func registerHotkeyOrNotify() {
        if !registerHotkey() {
            notify("Hotkey unavailable", "\(config.hotkey) is already taken by another app.")
        }
    }

    /// While a new hotkey is being recorded; registerHotkey() resumes.
    func suspendHotkey() {
        hotkeys.unregisterAll()
        tapWatcher.stop()
    }

    // tap:<modifier>:<count> needs a CGEvent watcher; Carbon cannot express it.
    private func applyTapWatcher() {
        guard let wanted = Hotkeys.parseTap(config.hotkey) else { return tapWatcher.stop() }
        // An event tap opened without Accessibility makes macOS ask for Input
        // Monitoring instead. The welcome window registers again once it is granted.
        guard Permission.accessibility.granted else {
            if config.onboarded {
                notify("Hotkey needs Accessibility",
                       "Allow Transcriptor under Privacy › Accessibility, then start it again.")
            }
            return tapWatcher.stop()
        }
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
            if config.onboarded {
                notify("Transcriptor", "Add your Soniox API key in Settings first.")
                showSettings()
            } else {
                showOnboarding()
            }
            return
        }
        // The island opens on this very frame; mic and socket catch up behind it.
        starting = true
        state = .recording
        target = NSWorkspace.shared.frontmostApplication?.localizedName
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
            try store.recordTranscript(text, durationMs: durationMs, app: target)
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
