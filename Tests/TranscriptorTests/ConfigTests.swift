import Foundation
import Testing
@testable import Transcriptor

struct ConfigTests {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func dropsEncryptedAndUnknownKeys() throws {
        // Electron safeStorage blobs and retired keys are silently ignored.
        let config = try decode(#"{"hotkey":"Control+K","apiKeyEnc":"aabb","openrouterKeyEnc":"ccdd","trigger":"DoubleCommand"}"#)
        #expect(config.hotkey == "Control+K")
        #expect(config.apiKey == "")
        #expect(config.openrouterKey == "")
    }

    @Test func missingKeysGetDefaults() throws {
        let config = try decode("{}")
        #expect(config == Config.defaults)
        #expect(config.model == "stt-rt-v5")
        #expect(config.languageHints == ["en"])
    }

    @Test func typeMismatchThrows() {
        #expect(throws: (any Error).self) { try decode(#"{"hotkey":123}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"languageHints":"en"}"#) }
        #expect(throws: (any Error).self) { try decode(#"[1,2]"#) }
    }

    @Test func encodingOmitsApiKeys() throws {
        var config = Config.defaults
        config.apiKey = "secret"
        config.openrouterKey = "secret2"
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["apiKey"] == nil)
        #expect(object?["openrouterKey"] == nil)
        #expect(object?["hotkey"] as? String == "Option+Space")
        // round-trip preserves everything else
        #expect(try JSONDecoder().decode(Config.self, from: data) == Config.defaults)
    }
}
