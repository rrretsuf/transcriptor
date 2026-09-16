// Reports modifier-flag changes and key presses so the app can offer triggers that
// globalShortcut cannot express: the Fn key and double-tapped modifiers.
import CoreGraphics
import Foundation

// Pasting through System Events would need a second permission on top of Accessibility.
if CommandLine.arguments.contains("--paste") {
    let source = CGEventSource(stateID: .combinedSessionState)
    let command: CGKeyCode = 0x37
    let letterV: CGKeyCode = 0x09
    let strokes: [(CGKeyCode, Bool, CGEventFlags)] = [
        (command, true, .maskCommand),
        (letterV, true, .maskCommand),
        (letterV, false, .maskCommand),
        (command, false, CGEventFlags()),
    ]
    for (key, isDown, flags) in strokes {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { exit(1) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    exit(0)
}

let events = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

func emit(_ line: String) {
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

let handler: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .flagsChanged: emit("flags \(event.flags.rawValue)")
    case .keyDown: emit("key")
    default: break
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(events),
    callback: handler,
    userInfo: nil
) else {
    emit("denied")
    exit(1)
}

CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
emit("ready")
CFRunLoopRun()
