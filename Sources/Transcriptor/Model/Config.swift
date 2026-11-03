import Foundation

struct Config: Codable, Equatable {
    var apiKey = ""
    var model = "stt-rt-v6"
    var languageHints = ["en"]
    var context = ""
    var cursorContext = true
    var translateTo = ""
    var hotkey = "Option+Space"
    var autoPaste = true
    var restoreClipboard = false
    var silenceStopMs = 0.0
    var launchAtLogin = false
    var saveHistory = true
    var notchMinimized = false

    // Per session, never saved.
    var precedingText = ""
    var labelSpeakers = false

    static let defaults = Config()

    /// Context terms, separated by commas or lines.
    var terms: [String] {
        context.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // apiKey lives in the Keychain, never in config.json.
    enum CodingKeys: String, CodingKey {
        case model, languageHints, context, cursorContext, translateTo
        case hotkey, autoPaste, restoreClipboard, silenceStopMs, launchAtLogin, saveHistory, notchMinimized
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        languageHints = try c.decodeIfPresent([String].self, forKey: .languageHints) ?? d.languageHints
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? d.context
        cursorContext = try c.decodeIfPresent(Bool.self, forKey: .cursorContext) ?? d.cursorContext
        translateTo = try c.decodeIfPresent(String.self, forKey: .translateTo) ?? d.translateTo
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? d.autoPaste
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        silenceStopMs = try c.decodeIfPresent(Double.self, forKey: .silenceStopMs) ?? d.silenceStopMs
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? d.saveHistory
        notchMinimized = try c.decodeIfPresent(Bool.self, forKey: .notchMinimized) ?? d.notchMinimized
    }
}
