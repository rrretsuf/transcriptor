import Foundation
import Testing
@testable import Transcriptor

@MainActor
struct StoreTests {
    private func makeStore() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "TranscriptorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (Store(directory: dir), dir)
    }

    @Test func corruptConfigIsKeptIntactAndNeverOverwritten() throws {
        let (store, dir) = try makeStore()
        let configURL = dir.appending(component: "config.json")
        try Data("not json".utf8).write(to: configURL)
        #expect(store.load() == ["config"])
        #expect(store.configReadable == false)
        #expect(throws: (any Error).self) { try store.saveConfig() }
        // the corrupt file survives untouched
        #expect(String(decoding: try Data(contentsOf: configURL), as: UTF8.self) == "not json")
    }

    @Test func meetingKeepsNameAndSpanAcrossReloadAndRename() throws {
        let (store, dir) = try makeStore()
        store.load()
        let start = Date.now.addingTimeInterval(-3600)
        let id = try #require(try store.recordTranscript("hello team", durationMs: 1000, title: "Standup", startedAt: start))
        try store.recordTranscript("plain dictation", durationMs: 500)
        store.retitle(id, "Weekly standup")

        let reloaded = Store(directory: dir)
        reloaded.load()
        let meeting = try #require(reloaded.history.first { $0.id == id })
        #expect(meeting.title == "Weekly standup")
        #expect(meeting.startedAt == start.timeIntervalSince1970 * 1000)
        #expect(reloaded.history.filter(\.isMeeting).count == 1)
    }

    @Test func missingFilesAreReadable() throws {
        let (store, _) = try makeStore()
        #expect(store.load() == [])
        #expect(store.configReadable && store.historyReadable)
        #expect(store.config == Config.defaults)
    }

    @Test func recordTranscriptCapsAt500() throws {
        let (store, _) = try makeStore()
        _ = store.load()
        let old = (0..<500).map { HistoryEntry(id: "\($0)", text: "entry \($0)", at: Double($0), durationMs: nil, words: 2) }
        try store.saveHistory(old)
        try store.recordTranscript("new", durationMs: 10)
        #expect(store.history.count == 500)
        #expect(store.history.first?.text == "new")
        #expect(store.history.last?.id == "498") // the oldest entry fell off
    }

    @Test func lastTranscriptUpdatesWhenHistoryDisabled() throws {
        let (store, dir) = try makeStore()
        _ = store.load()
        var config = store.config
        config.saveHistory = false
        try store.updateConfig(config)
        try store.recordTranscript("kept", durationMs: nil)
        #expect(store.lastTranscript == "kept")
        #expect(FileManager.default.fileExists(atPath: dir.appending(component: "history.json").path) == false)
    }

    @Test func atomicWriteProducesValidPrettyJSON() throws {
        let (store, dir) = try makeStore()
        _ = store.load()
        var config = store.config
        config.apiKey = "secret"
        config.hotkey = "Control+K"
        try store.saveConfig(config)
        let raw = try String(decoding: Data(contentsOf: dir.appending(component: "config.json")), as: UTF8.self)
        #expect(raw.contains("\n")) // pretty-printed
        let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(object["hotkey"] as? String == "Control+K")
        #expect(object["apiKey"] == nil)
        #expect(object["apiKeyEnc"] == nil)
        // the file is readable again and no .tmp is left behind
        #expect(try JSONDecoder().decode(Config.self, from: Data(raw.utf8)).hotkey == "Control+K")
        #expect(FileManager.default.fileExists(atPath: dir.appending(component: "config.json.tmp").path) == false)
    }
}
