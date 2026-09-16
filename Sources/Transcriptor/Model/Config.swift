import Foundation

struct Config: Codable, Equatable {
    var apiKey = ""
    var openrouterKey = ""
    var cleanupEnabled = false
    var cleanupTier = "light"
    var cleanupModel = "thinkingmachines/inkling-small"
    var cleanupProvider = "baseten"
    var experimentModels = ""
    var emailEnabled = true
    var emailModel = "thinkingmachines/inkling-small"
    var emailProvider = "baseten"
    var model = "stt-rt-v5"
    var languageHints = ["en"]
    var context = ""
    var translateTo = ""
    var hotkey = "Option+Space"
    var autoPaste = true
    var restoreClipboard = false
    var silenceStopMs = 0.0
    var launchAtLogin = false
    var saveHistory = true
    var notchExpanded = false

    static let defaults = Config()

    // apiKey/openrouterKey live in the Keychain, never in config.json.
    enum CodingKeys: String, CodingKey {
        case cleanupEnabled, cleanupTier, cleanupModel, cleanupProvider, experimentModels
        case emailEnabled, emailModel, emailProvider, model, languageHints, context, translateTo
        case hotkey, autoPaste, restoreClipboard, silenceStopMs, launchAtLogin, saveHistory, notchExpanded
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? d.cleanupEnabled
        cleanupTier = try c.decodeIfPresent(String.self, forKey: .cleanupTier) ?? d.cleanupTier
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel) ?? d.cleanupModel
        cleanupProvider = try c.decodeIfPresent(String.self, forKey: .cleanupProvider) ?? d.cleanupProvider
        experimentModels = try c.decodeIfPresent(String.self, forKey: .experimentModels) ?? d.experimentModels
        emailEnabled = try c.decodeIfPresent(Bool.self, forKey: .emailEnabled) ?? d.emailEnabled
        emailModel = try c.decodeIfPresent(String.self, forKey: .emailModel) ?? d.emailModel
        emailProvider = try c.decodeIfPresent(String.self, forKey: .emailProvider) ?? d.emailProvider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        languageHints = try c.decodeIfPresent([String].self, forKey: .languageHints) ?? d.languageHints
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? d.context
        translateTo = try c.decodeIfPresent(String.self, forKey: .translateTo) ?? d.translateTo
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? d.autoPaste
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        silenceStopMs = try c.decodeIfPresent(Double.self, forKey: .silenceStopMs) ?? d.silenceStopMs
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? d.saveHistory
        notchExpanded = try c.decodeIfPresent(Bool.self, forKey: .notchExpanded) ?? d.notchExpanded
    }
}
