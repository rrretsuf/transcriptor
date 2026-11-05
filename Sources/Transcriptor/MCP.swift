import Foundation

// `Transcriptor mcp` lets AI agents (Claude, Codex, any MCP client) list, search and
// read the saved transcriptions: Model Context Protocol, one JSON-RPC message per line
// on stdin and stdout. Read-only, and history.json is read again on every call, so a
// meeting that just ended is already there.
@MainActor
enum MCP {
    static func serve() {
        while let line = readLine() {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let reply = respond(to: message, history: load),
                  let data = try? JSONSerialization.data(withJSONObject: reply) else { continue }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }

    private static func load() throws -> [HistoryEntry] {
        let store = Store()
        guard !store.load().contains("history") else { throw Failure("history.json exists but could not be read.") }
        return store.history
    }

    /// nil for notifications, which get no reply.
    static func respond(to message: [String: Any], history: () throws -> [HistoryEntry]) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch message["method"] as? String {
        case "initialize":
            reply["result"] = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "transcriptor", "version": version],
                "instructions": instructions,
            ] as [String: Any]
        case "ping":
            reply["result"] = [String: Any]()
        case "tools/list":
            reply["result"] = ["tools": tools]
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(params["name"] as? String, arguments, history())
                reply["result"] = ["content": [["type": "text", "text": text]]]
            } catch {
                reply["result"] = ["content": [["type": "text", "text": error.localizedDescription]],
                                   "isError": true] as [String: Any]
            }
        default:
            reply["error"] = ["code": -32601, "message": "Method not found"] as [String: Any]
        }
        return reply
    }

    private static func call(_ name: String?, _ arguments: [String: Any], _ history: [HistoryEntry]) throws -> String {
        switch name {
        case "list_transcripts": try list(history, arguments)
        case "read_transcript": try read(history, arguments)
        default: throw Failure("Unknown tool \(name ?? "").")
        }
    }

    /* ---------------------------------- tools ----------------------------------- */

    private static func list(_ history: [HistoryEntry], _ arguments: [String: Any]) throws -> String {
        let found = try find(history, arguments)
        let words = queryWords(arguments)
        let limit = min(max(int(arguments["limit"]) ?? 20, 1), 100)
        let offset = max(int(arguments["offset"]) ?? 0, 0)
        let page = found.dropFirst(offset).prefix(limit)
        guard !page.isEmpty else {
            return found.isEmpty ? "No transcriptions match." : "No more results: \(found.count) match in total."
        }
        var out = "\(found.count) match, newest first; showing \(offset + 1)–\(offset + page.count). "
            + "Times are local (\(TimeZone.current.identifier)).\n"
        for entry in page {
            out += "\n• \(entry.kind.rawValue)" + (entry.title.map { " · \($0)" } ?? "") + "\n"
            out += "  " + (["id: \(entry.id)"] + facts(entry)).joined(separator: " · ") + "\n"
            out += "  \"\(excerpt(entry.text, around: words))\"\n"
        }
        if offset + page.count < found.count { out += "\nMore: call again with offset \(offset + page.count)." }
        return out
    }

    /// Every entry that passes the filters, newest first.
    static func find(_ history: [HistoryEntry], _ arguments: [String: Any]) throws -> [HistoryEntry] {
        var kind: HistoryEntry.Kind?
        if let raw = text(arguments["kind"]), raw != "all" {
            guard let parsed = HistoryEntry.Kind(rawValue: raw) else {
                throw Failure("kind is meeting, dictation or file, not \(raw).")
            }
            kind = parsed
        }
        let from = try text(arguments["from"]).map { try moment($0) }
        let to = try text(arguments["to"]).map { try moment($0, endOfDay: true) }
        let words = queryWords(arguments)
        return history
            .filter { entry in
                (kind.map { entry.kind == $0 } ?? true)
                    && (from.map { entry.start >= $0 } ?? true)
                    && (to.map { entry.start <= $0 } ?? true)
                    && words.allSatisfy(entry.mentions)
            }
            .sorted { $0.start > $1.start }
    }

    private static func queryWords(_ arguments: [String: Any]) -> [String] {
        (arguments["query"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func read(_ history: [HistoryEntry], _ arguments: [String: Any]) throws -> String {
        guard let id = text(arguments["id"]) else { throw Failure("Give the id of a transcription from list_transcripts.") }
        guard let entry = history.first(where: { $0.id == id }) else { throw Failure("No transcription has the id \(id).") }
        let parts = parts(entry.text)
        let part = int(arguments["part"]) ?? 1
        guard (1...parts.count).contains(part) else { throw Failure("This transcription has \(parts.count) part(s).") }

        var header = ["# \(entry.title ?? "Dictation")", "id: \(entry.id)", "kind: \(entry.kind.rawValue)",
                      "when: \(when(entry)) (\(TimeZone.current.identifier))"]
        if let ms = entry.durationMs { header.append("duration: \(span(ms))") }
        if let words = entry.words { header.append("words: \(words)") }
        let voices = speakers(entry.text)
        if voices > 0 { header.append("speakers: \(voices), labelled \"Speaker N:\"") }
        if let app = entry.app { header.append("dictated into: \(app)") }
        if parts.count > 1 { header.append("part: \(part) of \(parts.count)") }

        var out = header.joined(separator: "\n") + "\n\n" + parts[part - 1].trimmingCharacters(in: .newlines)
        if part < parts.count { out += "\n\n[Part \(part) of \(parts.count). Read part \(part + 1) for the rest.]" }
        return out
    }

    /* --------------------------------- helpers ---------------------------------- */

    /// Long meetings come in parts that fit an agent's tool output, cut between paragraphs.
    static func parts(_ text: String, size: Int = 40_000) -> [Substring] {
        var parts: [Substring] = []
        var rest = text[...]
        while rest.count > size {
            let window = rest.prefix(size)
            let tail = window[window.index(window.startIndex, offsetBy: size / 2)...]
            let cut = ["\n\n", "\n", " "].lazy
                .compactMap { tail.range(of: $0, options: .backwards)?.upperBound }
                .first ?? window.endIndex
            parts.append(rest[..<cut])
            rest = rest[cut...]
        }
        return parts + [rest]
    }

    static func speakers(_ text: String) -> Int {
        Set(text.matches(of: /^Speaker (\d+):/.anchorsMatchLineEndings()).map(\.output.1)).count
    }

    private static func facts(_ entry: HistoryEntry) -> [String] {
        var facts = [when(entry)]
        if let ms = entry.durationMs { facts.append(span(ms)) }
        if let words = entry.words { facts.append("\(words) words") }
        let voices = speakers(entry.text)
        if voices > 0 { facts.append(voices == 1 ? "1 speaker" : "\(voices) speakers") }
        if let app = entry.app { facts.append("into \(app)") }
        return facts
    }

    private static func when(_ entry: HistoryEntry) -> String {
        let start = stamp(entry.start, "EEE yyyy-MM-dd HH:mm")
        guard entry.startedAt != nil else { return start }
        let sameDay = Calendar.current.isDate(entry.start, inSameDayAs: entry.end)
        return start + "–" + stamp(entry.end, sameDay ? "HH:mm" : "EEE yyyy-MM-dd HH:mm")
    }

    private static func span(_ ms: Double) -> String {
        let s = Int((ms / 1000).rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    private static func excerpt(_ text: String, around words: [String], length: Int = 240) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > length else { return flat }
        guard let hit = words.lazy.compactMap({ flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first
        else { return flat.prefix(length) + "…" }
        let start = flat.index(hit.lowerBound, offsetBy: -80, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    /// 2026-11-04, 2026-11-04T15:00 or a full ISO 8601 moment; local time unless it says otherwise.
    static func moment(_ text: String, endOfDay: Bool = false) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: text) else {
            throw Failure("Could not read the date \"\(text)\". Use 2026-11-04 or 2026-11-04T15:00.")
        }
        guard endOfDay, let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return day }
        return next.addingTimeInterval(-0.001)
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ value: Any?) -> Int? { value as? Int ?? (value as? String).flatMap { Int($0) } }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /* -------------------------------- descriptions ------------------------------ */

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static let instructions = """
        The user's saved Transcriptor transcriptions: meetings (title, start and end time, \
        speakers labelled "Speaker N:"), dictations (with the app they were dictated into) and \
        transcribed audio or video files. Find them with list_transcripts, then read one in full \
        with read_transcript. Speaker numbers are not names; infer who is who from the text.
        """

    private static let tools: [[String: Any]] = [
        [
            "name": "list_transcripts",
            "description": """
                List and search saved transcriptions, newest first. Each result has its id, kind \
                (meeting, dictation or file), title, local date and time, duration, word count, \
                number of speakers, and an excerpt around the first match. Use read_transcript \
                with an id for the full text.
                """,
            "annotations": ["readOnlyHint": true],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Words that must all appear in the title, text or app. Case and accents are ignored."],
                    "kind": ["type": "string", "enum": ["meeting", "dictation", "file"],
                             "description": "Only this kind. Leave out for all."],
                    "from": ["type": "string",
                             "description": "Started on or after this local day or moment: 2026-11-04 or 2026-11-04T15:00."],
                    "to": ["type": "string",
                           "description": "Started on or before this local day or moment; a day counts until its end."],
                    "limit": ["type": "integer", "description": "Results per page, default 20, at most 100."],
                    "offset": ["type": "integer", "description": "Results to skip, for the next page."],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "name": "read_transcript",
            "description": """
                Read one transcription in full with its details: title, kind, local date and time, \
                duration, word count, speakers, the app it was dictated into. Long meetings come \
                in parts of about 40,000 characters; the end of each part says how to read the next.
                """,
            "annotations": ["readOnlyHint": true],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The id from list_transcripts."],
                    "part": ["type": "integer", "description": "Which part of a long transcription, default 1."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
    ]
}

extension HistoryEntry {
    var start: Date { Date(timeIntervalSince1970: (startedAt ?? at) / 1000) }
    var end: Date { Date(timeIntervalSince1970: at / 1000) }

    func mentions(_ word: String) -> Bool {
        [title, app, text].contains { $0?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
