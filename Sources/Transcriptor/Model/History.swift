import Foundation

/// Dictations beyond this many fall off; meetings and files are kept for good.
let historyLimit = 5000

struct HistoryEntry: Codable {
    enum Kind: String, Codable { case dictation, meeting, file }

    var id = ""
    var text = ""
    var at = 0.0
    var durationMs: Double?
    var words: Int?
    var kind = Kind.dictation
    // Meetings: their name. Files: the file name.
    var title: String?
    // Meetings only: when recording began (`at` is when it ended).
    var startedAt: Double?
    // Dictations only: the app the text was dictated into.
    var app: String?

    var isMeeting: Bool { kind == .meeting }

    init(id: String, text: String, at: Double, durationMs: Double?, words: Int?,
         title: String? = nil, startedAt: Double? = nil, kind: Kind? = nil, app: String? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.durationMs = durationMs
        self.words = words
        self.title = title
        self.startedAt = startedAt
        self.kind = kind ?? (title == nil ? .dictation : .meeting)
        self.app = app
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
        // Entries saved before `kind` existed: a title meant a meeting.
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? (title == nil ? .dictation : .meeting)
        app = try c.decodeIfPresent(String.self, forKey: .app)
    }
}
