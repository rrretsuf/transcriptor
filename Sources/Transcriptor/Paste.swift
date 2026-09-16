import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum Paste {
    private static var clipboardVersion = 0
    private static var accessibilityPrompted = false

    /// Returns the clipboard version; the restore logic uses it to
    /// avoid clobbering a newer copy.
    @discardableResult
    static func writeClipboard(_ text: String) -> Int {
        clipboardVersion += 1
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return clipboardVersion
    }

    /// Pasting is a synthetic ⌘V, which macOS only allows from trusted apps.
    /// Asks once with the system dialog (which deep-links to the right pane).
    @discardableResult
    static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !accessibilityPrompted {
            accessibilityPrompted = true
            // The literal is the documented value of kAXTrustedCheckOptionPrompt,
            // which Swift 6 refuses to read as a global var.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return false
    }

    static func pasteAtCursor(_ text: String, autoPaste: Bool, restoreClipboard: Bool = false) {
        let previous = restoreClipboard && autoPaste ? snapshot() : nil
        let version = writeClipboard(text)
        guard autoPaste else { return }
        guard ensureAccessibility() else {
            notify("Copied — paste with ⌘V",
                   "Allow Transcriptor under Privacy › Accessibility to paste at the cursor automatically.")
            return
        }
        // Same ⌘V as scripts/keytap.swift --paste.
        let source = CGEventSource(stateID: .combinedSessionState)
        let strokes: [(CGKeyCode, Bool, CGEventFlags)] = [
            (0x37, true, .maskCommand),
            (0x09, true, .maskCommand),
            (0x09, false, .maskCommand),
            (0x37, false, CGEventFlags()),
        ]
        for (key, isDown, flags) in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else {
                notify("Paste failed", "Your transcription is on the clipboard.")
                return
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        guard previous != nil else { return }
        // The transcription stays on the clipboard if anything about it changed
        // since the paste — that means someone else copied something newer.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled,
                  version == clipboardVersion,
                  NSPasteboard.general.string(forType: .string) == text else { return }
            restore(previous!)
        }
    }

    /* ------------------------------ clipboard restore ----------------------------- */

    private typealias Item = [NSPasteboard.PasteboardType: Data]

    private static func snapshot() -> [Item] {
        let items: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems ?? []
        var out: [Item] = []
        for item in items {
            var stored: Item = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            out.append(stored)
        }
        return out
    }

    private static func restore(_ items: [Item]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { item in
            let out = NSPasteboardItem()
            for (type, data) in item { out.setData(data, forType: type) }
            return out
        })
    }
}
