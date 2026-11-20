import AppKit
import SwiftUI

@main @MainActor
enum Entry {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "mcp" { return MCP.serve() }
        TranscriptorApp.main()
    }
}

struct TranscriptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.appState)
        } label: {
            TrayLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(state: delegate.appState)
        }

        Window("Transcriptions", id: "history") {
            HistoryView(state: delegate.appState)
        }
        .defaultSize(width: 560, height: 640)

        Window("Transcribe File", id: "file") {
            FileView(files: delegate.appState.files)
        }
        .defaultSize(width: 520, height: 460)

        Window("Meeting", id: "meeting") {
            MeetingView(meeting: delegate.appState.meeting)
        }
        .defaultSize(width: 520, height: 560)

        Window("Welcome to Transcriptor", id: "onboarding") {
            OnboardingView(state: delegate.appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

}

// The tray label is the one view alive from launch, so it lends AppState the
// scene's window actions.
private struct TrayLabel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.trayImage(active: state.state != .idle || state.meeting.status == .recording))
            .background {
                TrayAnchor(state: state)
                if #available(macOS 14, *) { SettingsLender(state: state) }
            }
            .onAppear { state.openWindow = { openWindow(id: $0) } }
    }

    // Drawn as a vector so it stays crisp at any scale: five rounded bars, nothing else.
    // Idle bars are short and even; active bars rise into the full waveform.
    private static func trayImage(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let heights: [CGFloat] = active ? [7, 12, 16, 12, 7] : [4, 8, 12, 8, 4]
        let width: CGFloat = 2, gap: CGFloat = 1.5
        let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
        let image = NSImage(size: size, flipped: false) { rect in
            var x = (rect.width - total) / 2
            for h in heights {
                let bar = NSRect(x: x, y: (rect.height - h) / 2, width: width, height: h)
                NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Transcriptor"
        return image
    }
}

private struct MenuContent: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("\(firstItemLabel)  \(Hotkeys.display(state.config.hotkey))") { state.toggle() }
            .disabled(state.state == .finishing)
        Button("Copy Last Transcription") {
            _ = Paste.writeClipboard(state.store.lastTranscript)
        }
        .disabled(state.store.lastTranscript.isEmpty)
        Divider()
        Button("Transcribe File…") { open("file") }
        Button(state.meeting.isActive ? "Show Meeting" : "Start Meeting Transcription") {
            if !state.meeting.isActive {
                if let detected = state.detectedMeeting {
                    state.startDetectedMeeting(detected)
                    return
                }
                state.meeting.reset()
                state.meeting.start()
            }
            open("meeting")
        }
        Divider()
        Button("All Transcriptions…") { open("history") }
        Button("Settings…") { state.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Transcriptor") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// Agent apps must activate before a window can come forward.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    private var firstItemLabel: String {
        switch state.state {
        case .recording: "Stop Dictation"
        case .finishing: "Finishing…"
        case .idle: "Start Dictation"
        }
    }
}

// Captures the menu bar button's screen rect so the meeting banner drops right beneath it.
private struct TrayAnchor: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        state.meetingBanner.anchorRect = { [weak view] in
            guard let view, let window = view.window else { return nil }
            let inWindow = view.convert(view.bounds, to: nil)
            return window.convertToScreen(inWindow)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// macOS 14 killed the showSettingsWindow: selector that macOS 13 still answers.
@available(macOS 14, *)
private struct SettingsLender: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear { state.openSettings = { openSettings() } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app reopens nothing: no window comes back after a relaunch.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        for unreadable in appState.store.load() {
            switch unreadable {
            case "config":
                notify("Settings could not be read",
                       "Your settings file has been kept intact. Restart after restoring it.")
            case "history":
                notify("History could not be read",
                       "Your history file has been kept intact. New dictation can still be copied.")
            default: break
            }
        }
        // The hotkey is the product; register it before anything that can wait a frame.
        appState.registerHotkeyOrNotify()
        appState.applyLaunchAtLogin()
        // Paint the island once (invisible, inside the notch) so the first session is instant.
        appState.surface.install()
        appState.surface.onMinimize = { [appState] in appState.setNotchMinimized($0) }
        appState.applyMeetingDetection()
        // Warm mic, key and TLS shortly after launch so the first hotkey is as fast as the tenth.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [appState] in
            appState.prepare()
            // A new user meets the permissions one by one in the welcome window,
            // never as a system dialog over an empty desktop.
            if appState.config.onboarded { Paste.ensureAccessibility() } else { appState.showOnboarding() }
        }
    }
}
