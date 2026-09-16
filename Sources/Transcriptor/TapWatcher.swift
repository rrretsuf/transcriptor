import CoreGraphics
import Foundation

// In-process port of scripts/keytap.swift + main.js readTap/countTap: a listen-only
// event tap reports modifier-flag changes so tap:<modifier>:<count> hotkeys work.
// A tap only counts when its modifier is pressed and released completely alone.
@MainActor
final class TapWatcher {
    // (name, CGEventFlags bit) — same bits main.js watches.
    private static let modifiers: [(name: String, bit: UInt64)] = [
        ("Command", 0x100000), ("Control", 0x040000), ("Option", 0x080000),
        ("Shift", 0x020000), ("Fn", 0x800000),
    ]
    private static let modifierBits: UInt64 = 0x9e0000
    static let gapMs = 400.0

    // nonisolated(unsafe): the CGEvent callback runs on the main run loop's tap
    // point, so it can reach the main-actor singleton — the only bridge.
    nonisolated(unsafe) static weak var current: TapWatcher?

    /// Returns true from the handler to reset the count — a triggered tap must
    /// not keep counting into the gap window.
    var onTap: ((_ modifier: String, _ count: Int) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var flags: UInt64 = 0
    private var armed: String?
    private var tapName: String?
    private var tapCount = 0
    private var tapDeadline = 0.0

    func start() {
        guard tap == nil else { return }
        TapWatcher.current = self
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, _ in
            let flags = event.flags.rawValue
            switch type {
            case .flagsChanged: MainActor.assumeIsolated { TapWatcher.current?.readFlags(flags) }
            case .keyDown: MainActor.assumeIsolated { TapWatcher.current?.readKey() }
            default: break
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            notify("Hotkey watcher unavailable", "Fn and double-tap hotkeys are not available.")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        self.source = nil
        armed = nil
        flags = 0
    }

    private func readFlags(_ new: UInt64) {
        let before = flags
        flags = new
        let held = new & Self.modifierBits

        // Press: arm the tap only if this modifier is the only one held.
        if let pressed = Self.modifiers.first(where: { (new & $0.bit) != 0 && (before & $0.bit) == 0 }) {
            armed = held == pressed.bit ? pressed.name : nil
            return
        }
        if held != 0 { armed = nil; return }

        // Release with everything up: count a complete tap of the armed modifier.
        guard let released = Self.modifiers.first(where: { (before & $0.bit) != 0 }),
              released.name == armed else { armed = nil; return }
        armed = nil

        let now = ProcessInfo.processInfo.systemUptime * 1000
        if tapName != released.name || now > tapDeadline { tapCount = 0 }
        tapName = released.name
        tapCount += 1
        tapDeadline = now + Self.gapMs
        if onTap?(released.name, tapCount) == true { tapCount = 0 }
    }

    private func readKey() {
        armed = nil
    }
}
