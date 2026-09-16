import AppKit
import Carbon
import Foundation

// A hotkey is either an accelerator like "Command+Shift+Space" or
// "tap:<modifier>:<count>", which Carbon cannot express; taps are handled later.
let tapModifiers = ["Command", "Control", "Option", "Shift", "Fn"]

@MainActor
final class Hotkeys {
    struct Parsed {
        let modifiers: UInt32
        let keyCode: UInt32
    }

    // nonisolated(unsafe): Carbon delivers hotkey events on the main run loop,
    // so the C callback can assume the main actor — this is the only bridge.
    nonisolated(unsafe) static weak var current: Hotkeys?

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef?] = [:]
    private var registrations: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    nonisolated static func parseTap(_ hotkey: String) -> (modifier: String, count: Int)? {
        let parts = hotkey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "tap",
              tapModifiers.contains(String(parts[1])),
              let count = Int(parts[2]), count > 0 else { return nil }
        return (String(parts[1]), count)
    }

    nonisolated private static let modifierMap: [String: UInt32] = [
        "command": UInt32(cmdKey), "cmd": UInt32(cmdKey),
        "control": UInt32(controlKey), "ctrl": UInt32(controlKey),
        "option": UInt32(optionKey), "alt": UInt32(optionKey),
        "shift": UInt32(shiftKey),
    ]

    nonisolated private static let symbols: [String: String] = [
        "command": "⌘", "cmd": "⌘", "control": "⌃", "ctrl": "⌃", "option": "⌥", "alt": "⌥",
        "shift": "⇧", "fn": "fn", "space": "Space", "escape": "⎋", "esc": "⎋", "return": "↩",
        "enter": "↩", "tab": "⇥", "backspace": "⌫", "delete": "⌫",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
    ]

    /// "Option+Space" → "⌥ Space", "tap:Command:2" → "⌘ ×2".
    nonisolated static func display(_ hotkey: String) -> String {
        if let tap = parseTap(hotkey) {
            return "\(symbols[tap.modifier.lowercased()] ?? tap.modifier) ×\(tap.count)"
        }
        return hotkey.split(separator: "+").map { part in
            let name = part.trimmingCharacters(in: .whitespaces).lowercased()
            return symbols[name] ?? name.uppercased()
        }.joined(separator: " ")
    }

    /// Builds an accelerator from a recorded key press; nil when it has no
    /// modifier (a bare key would swallow typing) or an unknown key.
    nonisolated static func accelerator(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        let names = keyCodes.filter { $0.value == UInt32(keyCode) }.keys
        guard let key = names.max(by: { $0.count < $1.count }) else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        let functionKey = key.count > 1 && key.hasPrefix("f") && key != "fn"
        guard !parts.isEmpty || functionKey else { return nil }
        return (parts + [key.capitalized]).joined(separator: "+")
    }

    nonisolated private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "escape": 53, "esc": 53, "return": 36, "enter": 36,
        "tab": 48, "backspace": 51, "delete": 51,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    nonisolated static func parseAccelerator(_ accelerator: String) -> Parsed? {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for part in accelerator.split(separator: "+") {
            let name = part.trimmingCharacters(in: .whitespaces).lowercased()
            if let mod = modifierMap[name] { modifiers |= mod }
            else if let code = keyCodes[name] { keyCode = code }
            else if name.count == 1, let code = keyCodes[name] { keyCode = code }
            else { return nil }
        }
        guard let keyCode else { return nil }
        return Parsed(modifiers: modifiers, keyCode: keyCode)
    }

    @discardableResult
    func register(_ accelerator: String, handler: @escaping () -> Void) -> Bool {
        guard let parsed = Hotkeys.parseAccelerator(accelerator) else { return false }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                       EventHotKeyID(signature: 0x54524342, id: id), // 'TRCB'
                                       GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        refs[id] = ref
        handlers[id] = handler
        registrations[accelerator] = id
        return true
    }

    func unregister(_ accelerator: String) {
        guard let id = registrations.removeValue(forKey: accelerator) else { return }
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        registrations.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        if installed { return }
        installed = true
        Hotkeys.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            MainActor.assumeIsolated { Hotkeys.current?.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
