import AppKit
import SwiftUI

@main
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
    }

}

// The tray label is the one view alive from launch, so it lends AppState the
// scene's openSettings action (the private showSettingsWindow: selector is dead).
private struct TrayLabel: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: Self.trayImage(active: state.state != .idle))
            .onAppear { state.openSettings = { openSettings() } }
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
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("\(firstItemLabel)  \(Hotkeys.display(state.config.hotkey))") { state.toggle() }
            .disabled(state.state == .finishing || state.state == .polishing)
        Button("Copy Last Transcription") {
            _ = Paste.writeClipboard(state.store.lastTranscript)
        }
        .disabled(state.store.lastTranscript.isEmpty)
        Divider()
        Button("All Transcriptions…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }
        Button("Settings…") { state.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Transcriptor") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var firstItemLabel: String {
        switch state.state {
        case .recording: state.sessionMode == .email ? "Stop Email" : "Stop Dictation"
        case .finishing: "Finishing…"
        case .polishing: "Polishing…"
        case .idle: "Start Dictation"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        appState.registerHotkey()
        // Paint the island once (invisible, inside the notch) so the first session is instant.
        appState.surface.install()
        appState.surface.onTap = { [appState] in appState.toggleNotchExpanded() }
        // Warm mic, key and TLS shortly after launch so the first hotkey is as fast as the tenth.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [appState] in
            appState.prepare()
            Paste.ensureAccessibility()
        }
    }
}
