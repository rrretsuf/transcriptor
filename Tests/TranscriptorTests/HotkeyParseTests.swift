import Carbon
import Testing
@testable import Transcriptor

struct HotkeyParseTests {
    @Test(arguments: [
        ("tap:Command:2", "Command", 2),
        ("tap:Fn:2", "Fn", 2),
        ("tap:Shift:1", "Shift", 1),
    ])
    func parsesTap(hotkey: String, modifier: String, count: Int) {
        let tap = Hotkeys.parseTap(hotkey)
        #expect(tap?.modifier == modifier)
        #expect(tap?.count == count)
    }

    @Test(arguments: [
        "Command+Shift+Space", "tap:Bad:2", "tap:Command:0", "tap:Command:x",
        "tap:Command", "tap::2", "tap:Command:2:extra", "",
    ])
    func rejectsNonTap(hotkey: String) {
        #expect(Hotkeys.parseTap(hotkey) == nil)
    }

    @Test func parsesAccelerator() throws {
        let parsed = try #require(Hotkeys.parseAccelerator("Command+Shift+Space"))
        #expect(parsed.modifiers == UInt32(cmdKey | shiftKey))
        #expect(parsed.keyCode == 49)
    }

    @Test func parsesEscape() throws {
        let parsed = try #require(Hotkeys.parseAccelerator("Escape"))
        #expect(parsed.keyCode == 53)
        #expect(parsed.modifiers == 0)
    }

    @Test(arguments: ["garbage++x", "Command+", "", "Nope"])
    func rejectsGarbage(accelerator: String) {
        #expect(Hotkeys.parseAccelerator(accelerator) == nil)
    }

    @Test func displaysSymbols() {
        #expect(Hotkeys.display("Option+Space") == "⌥ Space")
        #expect(Hotkeys.display("Command+Shift+E") == "⌘ ⇧ E")
        #expect(Hotkeys.display("tap:Command:2") == "⌘ ×2")
    }

    @Test func recordsAccelerator() {
        #expect(Hotkeys.accelerator(keyCode: 49, flags: .option) == "Option+Space")
        #expect(Hotkeys.accelerator(keyCode: 53, flags: [.command, .shift]) == "Shift+Command+Escape") // Apple order: ⌃ ⌥ ⇧ ⌘
        #expect(Hotkeys.accelerator(keyCode: 49, flags: []) == nil) // bare key would swallow typing
        #expect(Hotkeys.accelerator(keyCode: 96, flags: []) == "F5")
    }
}
