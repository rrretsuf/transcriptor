import Foundation
import Testing
@testable import Transcriptor

// Spec. Entry point: MCP.respond, fed one JSON-RPC message per line by an agent.
// Untrusted: every tool argument (an LLM writes them). Trusted: history.json.
// Correct failures: a reply with isError and a message. Bugs: a trap, a missing
// reply, a result that breaks a filter, a part that loses or adds text.

/// SplitMix64, so every failing case can be replayed from its seed.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct MCPTests {
    static let pieces = ["a", "beseda", " ", "\n", "\n\n", "Speaker 1: ", "Speaker 12: ", "č", "Ž", "e\u{301}",
                         " \u{301}", "🇸🇮", "\r\n", "Tjaša", "—", ".", "\t"]

    func text(_ rng: inout Seeded, upTo count: Int) -> String {
        (0..<Int.random(in: 0...count, using: &rng)).map { _ in Self.pieces.randomElement(using: &rng)! }.joined()
    }

    func history(_ rng: inout Seeded, count: Int) -> [HistoryEntry] {
        let base = try! MCP.moment("2026-11-01").timeIntervalSince1970 * 1000
        return (0..<count).map { i in
            let kind = [HistoryEntry.Kind.dictation, .meeting, .file].randomElement(using: &rng)!
            let at = base + Double.random(in: 0...(10 * 86_400_000), using: &rng)
            return HistoryEntry(id: "e\(i)", text: text(&rng, upTo: 30), at: at, durationMs: 60_000, words: 3,
                                title: kind == .dictation ? nil : text(&rng, upTo: 3),
                                startedAt: kind == .meeting ? at - 3_600_000 : nil,
                                kind: kind, app: kind == .dictation ? "Slack" : nil)
        }
    }

    /// The real path: through JSON and back, like a message from an agent.
    func send(_ message: [String: Any], _ history: [HistoryEntry]) -> [String: Any]? {
        let data = try! JSONSerialization.data(withJSONObject: message)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return MCP.respond(to: parsed, history: { history })
    }

    func call(_ tool: String, _ arguments: [String: Any], _ history: [HistoryEntry]) -> (text: String, error: Bool) {
        let reply = send(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": ["name": tool, "arguments": arguments]], history)
        let result = reply?["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    /* -------------------------------- properties -------------------------------- */

    @Test func partsRejoinIntoTheOriginalAndStayWithinSize() {
        for seed in 0..<3000 as Range<UInt64> {
            var rng = Seeded(state: seed)
            let original = text(&rng, upTo: 120)
            let size = Int.random(in: 1...60, using: &rng)
            let parts = MCP.parts(original, size: size)
            #expect(Array(parts.joined().unicodeScalars) == Array(original.unicodeScalars), "seed \(seed)")
            #expect(parts.allSatisfy { $0.count <= size }, "seed \(seed)")
            #expect(parts.count == 1 || parts.allSatisfy { !$0.isEmpty }, "seed \(seed)")
        }
    }

    @Test func everyRequestGetsAReplyWhateverTheArguments() {
        let values: [Any?] = [nil, "", " ", "all", "meeting", "file", "x", "2026-11-04", "2026-13-45", "e0",
                              "-9223372036854775808", "9223372036854775807", Int.min, Int.max, -1, 0, 1, 3,
                              2.5, true, [1, 2], ["a": 1], "Tjaša Speaker"]
        let keys = ["query", "kind", "from", "to", "limit", "offset", "id", "part"]
        for seed in 0..<2000 as Range<UInt64> {
            var rng = Seeded(state: seed)
            let history = history(&rng, count: Int.random(in: 0...6, using: &rng))
            var arguments: [String: Any] = [:]
            for key in keys { if let value = values.randomElement(using: &rng)! { arguments[key] = value } }
            let tool = ["list_transcripts", "read_transcript", "nope"].randomElement(using: &rng)!
            let id: Any = Bool.random(using: &rng) ? seed : "req-\(seed)"
            let reply = send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                              "params": ["name": tool, "arguments": arguments]], history)
            let result = reply?["result"] as? [String: Any]
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
            #expect("\(reply?["id"] ?? "none")" == "\(id)", "seed \(seed)")
            #expect(text?.isEmpty == false, "seed \(seed)")
        }
    }

    @Test func resultsObeyEveryFilterAndPagesCoverThemOnce() throws {
        let ids = /id: (\S+)/
        for seed in 0..<400 as Range<UInt64> {
            var rng = Seeded(state: seed)
            let history = history(&rng, count: Int.random(in: 0...30, using: &rng))
            var arguments: [String: Any] = [:]
            if Bool.random(using: &rng) { arguments["kind"] = ["meeting", "dictation", "file"].randomElement(using: &rng)! }
            if Bool.random(using: &rng) { arguments["from"] = "2026-11-0\(Int.random(in: 1...9, using: &rng))" }
            if Bool.random(using: &rng) { arguments["to"] = "2026-11-0\(Int.random(in: 1...9, using: &rng))" }
            if Bool.random(using: &rng) { arguments["query"] = ["tjasa", "BESEDA", "č speaker", "slack", "e"].randomElement(using: &rng)! }

            let found = try MCP.find(history, arguments)
            let from = try (arguments["from"] as? String).map { try MCP.moment($0) }
            let to = try (arguments["to"] as? String).map { try MCP.moment($0, endOfDay: true) }
            let words = (arguments["query"] as? String ?? "").split(separator: " ").map(String.init)
            let expected = history.filter { entry in
                (arguments["kind"].map { entry.kind.rawValue == $0 as? String } ?? true)
                    && (from.map { entry.start >= $0 } ?? true)
                    && (to.map { entry.start <= $0 } ?? true)
                    && words.allSatisfy { word in
                        [entry.title, entry.app, entry.text].contains {
                            $0?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                                .contains(word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) == true
                        }
                    }
            }
            #expect(Set(found.map(\.id)) == Set(expected.map(\.id)), "seed \(seed)")
            #expect(zip(found, found.dropFirst()).allSatisfy { $0.start >= $1.start }, "seed \(seed)")

            let limit = Int.random(in: 1...7, using: &rng)
            var paged: [String] = []
            var offset = 0
            while offset <= found.count {
                var page = arguments
                page["limit"] = limit
                page["offset"] = offset
                paged += call("list_transcripts", page, history).text.matches(of: ids).map { String($0.output.1) }
                offset += limit
            }
            #expect(paged == found.map(\.id), "seed \(seed)")
        }
    }

    @Test func entriesSurviveSaveAndLoad() throws {
        for seed in 0..<300 as Range<UInt64> {
            var rng = Seeded(state: seed)
            let entries = history(&rng, count: 5)
            let back = try JSONDecoder().decode([HistoryEntry].self, from: JSONEncoder().encode(entries))
            for (a, b) in zip(entries, back) {
                #expect(a.id == b.id && a.text == b.text && a.kind == b.kind && a.title == b.title
                        && a.app == b.app && a.startedAt == b.startedAt, "seed \(seed)")
            }
        }
    }

    /* --------------------------------- examples --------------------------------- */

    @Test func entriesFromBeforeKindExistedKeepTheirMeaning() throws {
        let json = #"[{"id":"m","text":"x","at":1,"title":"Standup","startedAt":0},{"id":"d","text":"y","at":2}]"#
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(entries.map(\.kind) == [.meeting, .dictation])
    }

    @Test func initializeEchoesTheVersionAndNotificationsGetNoReply() throws {
        let reply = try #require(send(["jsonrpc": "2.0", "id": 7, "method": "initialize",
                                       "params": ["protocolVersion": "2025-03-26"]], []))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(send(["jsonrpc": "2.0", "method": "notifications/initialized"], []) == nil)
        #expect(send(["jsonrpc": "2.0", "id": 8, "method": "resources/list"], [])?["error"] != nil)
        let tools = (send(["jsonrpc": "2.0", "id": 9, "method": "tools/list"], [])?["result"] as? [String: Any])?["tools"]
        #expect((tools as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["list_transcripts", "read_transcript"])
    }

    @Test func searchIgnoresCaseAndAccentsAndShowsTheMeeting() {
        let start = try! MCP.moment("2026-11-04T12:51")
        let meeting = HistoryEntry(id: "m1", text: "Speaker 1: Živjo Tjaša.\n\nSpeaker 2: Živjo.", at: start.timeIntervalSince1970 * 1000 + 5_000_000,
                                   durationMs: 4_980_000, words: 5, title: "soma44: sestanek",
                                   startedAt: start.timeIntervalSince1970 * 1000)
        let found = call("list_transcripts", ["query": "TJASA zivjo", "kind": "meeting", "to": "2026-11-04"], [meeting])
        #expect(!found.error)
        #expect(found.text.contains("• meeting · soma44: sestanek"))
        #expect(found.text.contains("Wed 2026-11-04 12:51–14:14 · 1 h 23 min · 5 words · 2 speakers"))
        #expect(call("list_transcripts", ["query": "tjasa", "from": "2026-11-05"], [meeting]).text == "No transcriptions match.")
    }

    @Test func longTranscriptsAreReadInPartsWithTheirDetails() {
        let body = (1...4000).map { "Speaker \($0 % 3 + 1): stavek številka \($0)." }.joined(separator: "\n\n")
        let entry = HistoryEntry(id: "long", text: body, at: 0, durationMs: 90_000, words: 12_000, title: "Dolg sestanek")
        let count = MCP.parts(body).count
        #expect(count > 2)
        let first = call("read_transcript", ["id": "long"], [entry])
        #expect(first.text.hasPrefix("# Dolg sestanek\nid: long\nkind: meeting\n"))
        #expect(first.text.contains("speakers: 3, labelled \"Speaker N:\""))
        #expect(first.text.contains("part: 1 of \(count)"))
        #expect(first.text.hasSuffix("[Part 1 of \(count). Read part 2 for the rest.]"))
        #expect(call("read_transcript", ["id": "long", "part": count], [entry]).text.hasSuffix("stavek številka 4000."))
        #expect(call("read_transcript", ["id": "long", "part": count + 1], [entry]).error)
        #expect(call("read_transcript", ["id": "missing"], [entry]).error)
    }

    @Test func speakersCountOnlyLabelsThatOpenALine() {
        #expect(MCP.speakers("Speaker 1: a\n\nSpeaker 2: b\n\nSpeaker 1: c said Speaker 3: x") == 2)
        #expect(MCP.speakers("no labels here") == 0)
    }
}
