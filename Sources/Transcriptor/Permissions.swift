import AppKit
import ApplicationServices
import AVFoundation

// The three grants the app lives on. Microphone and Accessibility have public
// APIs; System Audio Recording has none, so its status comes from the TCC
// framework that System Settings itself uses. Without it the status is unknown
// and the first meeting triggers the system prompt as before.
@MainActor
enum Permission: CaseIterable {
    case microphone, accessibility, systemAudio

    private static var accessibilityAsked = false
    private static var screenAsked = false
    /// Before macOS 14.2 meetings hear the Mac through ScreenCaptureKit, behind Screen Recording.
    private static let usesScreenRecording = { if #available(macOS 14.2, *) { false } else { true } }()
    static var systemAudioName: String { usesScreenRecording ? "Screen Recording" : "System Audio" }

    var granted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        case .systemAudio:
            Self.usesScreenRecording ? CGPreflightScreenCaptureAccess() : TCC.preflight?(TCC.audioCapture, nil) == 0
        }
    }

    /// Shows the system prompt the first time; after a refusal macOS never asks
    /// again, so the right pane of System Settings opens instead.
    func request() async {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                openSettings()
            }
        case .accessibility:
            // The system dialog appears once per launch; a second ask goes straight to the pane.
            guard !Self.accessibilityAsked else { return openSettings() }
            Self.accessibilityAsked = true
            // The literal is the documented value of kAXTrustedCheckOptionPrompt,
            // which Swift 6 refuses to read as a global var.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .systemAudio:
            if Self.usesScreenRecording {
                guard !Self.screenAsked else { return openSettings() }
                Self.screenAsked = true
                CGRequestScreenCaptureAccess()
                return
            }
            // Refused earlier: macOS will not ask again, only the pane can change it.
            guard let request = TCC.request, TCC.preflight?(TCC.audioCapture, nil) == 2 else { return openSettings() }
            await withCheckedContinuation { done in
                request(TCC.audioCapture, nil) { _ in done.resume() }
            }
            // Still unanswered means no prompt came up.
            if TCC.preflight?(TCC.audioCapture, nil) == 2 { openSettings() }
        }
    }

    private func openSettings() {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .systemAudio: Self.usesScreenRecording ? "Privacy_ScreenCapture" : "Privacy_AudioCapture"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

@MainActor
private enum TCC {
    /// 0 granted, 1 denied, 2 not asked yet.
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static let audioCapture = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    static let preflight = symbol("TCCAccessPreflight").map { unsafeBitCast($0, to: Preflight.self) }
    static let request = symbol("TCCAccessRequest").map { unsafeBitCast($0, to: Request.self) }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        framework.flatMap { dlsym($0, name) }
    }
}
