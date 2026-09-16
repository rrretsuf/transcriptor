import Foundation
import Testing
@testable import Transcriptor

struct SonioxTests {
    private typealias Incoming = SonioxClient.Incoming
    private typealias Token = SonioxClient.Incoming.Token

    private func decode(_ json: String) throws -> Incoming {
        try JSONDecoder().decode(Incoming.self, from: Data(json.utf8))
    }

    @Test func decodesTokenMessage() throws {
        let message = try decode(#"{"tokens":[{"text":"hello","is_final":true},{"text":" world","is_final":false}]}"#)
        #expect(message.tokens?.count == 2)
        #expect(message.tokens?[0].text == "hello")
        #expect(message.tokens?[0].is_final == true)
        #expect(message.tokens?[1].is_final == false)
        #expect(message.finished == nil)
    }

    @Test func decodesErrorMessage() throws {
        let string = try decode(#"{"error_code":"invalid_api_key","error_message":"bad key"}"#)
        #expect(string.error_code?.value == "invalid_api_key")
        #expect(string.error_message == "bad key")
        let number = try decode(#"{"error_code":500}"#)
        #expect(number.error_code?.value == "500")
    }

    @Test func decodesFinishedMessage() throws {
        #expect(try decode(#"{"finished":true}"#).finished == true)
    }

    @Test func keepTokenDropsSpecials() {
        let end = Token(text: "<end>", is_final: true)
        #expect(SonioxClient.keepToken(end, translateTo: "") == false)
        #expect(SonioxClient.keepToken(end, translateTo: "en") == false)
        #expect(SonioxClient.keepToken(Token(text: "hi", is_final: true), translateTo: "") == true)
    }

    @Test func translationKeepsOnlyTranslatedTokens() {
        // tests/session.cjs: originals are dropped when translateTo is set.
        let original = Token(text: "izvirnik", is_final: true, translation_status: "original")
        let translated = Token(text: "translated", is_final: true, translation_status: "translation")
        #expect(SonioxClient.keepToken(original, translateTo: "en") == false)
        #expect(SonioxClient.keepToken(translated, translateTo: "en") == true)
        #expect(SonioxClient.keepToken(original, translateTo: "") == true)
    }

    @Test func configMessageMatchesBuildConfig() throws {
        var config = Config.defaults
        config.context = "Soniox, Filip Kustec\nENKI"
        config.translateTo = "en"
        let data = try JSONEncoder().encode(SonioxClient.configMessage(apiKey: "k", config: config))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["api_key"] as? String == "k")
        #expect(object["model"] as? String == "stt-rt-v5")
        #expect(object["audio_format"] as? String == "s16le")
        #expect(object["sample_rate"] as? Int == 16000)
        #expect(object["num_channels"] as? Int == 1)
        #expect(object["enable_endpoint_detection"] as? Bool == true)
        #expect(object["language_hints"] as? [String] == ["en"])
        #expect((object["context"] as? [String: Any])?["terms"] as? [String] == ["Soniox", "Filip Kustec", "ENKI"])
        let translation = try #require(object["translation"] as? [String: Any])
        #expect(translation["type"] as? String == "one_way")
        #expect(translation["target_language"] as? String == "en")
    }

    @Test func configMessageOmitsEmptyOptionals() throws {
        var config = Config.defaults
        config.languageHints = []
        config.context = "  \n "
        let data = try JSONEncoder().encode(SonioxClient.configMessage(apiKey: "k", config: config))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["language_hints"] == nil)
        #expect(object["context"] == nil)
        #expect(object["translation"] == nil)
    }

    @Test func resultWhitespaceNormalization() {
        #expect(Session.collapse("  hello   world \n ") == "hello world")
        #expect(Session.collapse("a\t\tb") == "a b")
        #expect(Session.collapse("") == "")
    }
}
