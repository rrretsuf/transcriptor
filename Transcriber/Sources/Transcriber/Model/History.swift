import Foundation

let historyLimit = 500

struct HistoryEntry: Codable {
    var id = ""
    var text = ""
    var at = 0.0
    var durationMs: Double?
    var words: Int?

    init(id: String, text: String, at: Double, durationMs: Double?, words: Int?) {
        self.id = id
        self.text = text
        self.at = at
        self.durationMs = durationMs
        self.words = words
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Double.self, forKey: .at)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        words = try c.decodeIfPresent(Int.self, forKey: .words)
    }
}

struct CleanupStats: Codable {
    var count = 0
    var promptTokens = 0
    var completionTokens = 0
    var costUsd = 0.0
    var emailCount = 0
    var emailCostUsd = 0.0
}
