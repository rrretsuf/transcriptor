import Foundation

let historyLimit = 500

struct HistoryEntry: Codable {
    var id = ""
    var text = ""
    var at = 0.0
    var durationMs: Double?
    var words: Int?
    // Meetings only: their name and when recording began (`at` is when it ended).
    var title: String?
    var startedAt: Double?

    var isMeeting: Bool { title != nil }

    init(id: String, text: String, at: Double, durationMs: Double?, words: Int?,
         title: String? = nil, startedAt: Double? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.durationMs = durationMs
        self.words = words
        self.title = title
        self.startedAt = startedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Double.self, forKey: .at)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        words = try c.decodeIfPresent(Int.self, forKey: .words)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
    }
}
