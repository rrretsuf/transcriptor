import Foundation

@MainActor @Observable
final class Store {
    let directory: URL
    private(set) var config = Config.defaults
    private(set) var history: [HistoryEntry] = []
    private(set) var stats = CleanupStats()
    private(set) var configReadable = true
    private(set) var historyReadable = true
    private(set) var statsReadable = true
    var lastTranscript = ""
    private var persistTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(component: "Transcriptor")
    }

    private func path(_ name: String) -> URL { directory.appending(component: name) }

    private func writeJSON(_ url: URL, _ value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try pretty.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private func read<T: Decodable>(_ url: URL, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func isMissing(_ error: Error) -> Bool {
        (error as NSError).domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains((error as NSError).code)
    }

    /// Returns names of files that existed but could not be parsed, so the caller can notify.
    @discardableResult
    func load() -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var unreadable: [String] = []
        do {
            config = try read(path("config.json"), as: Config.self)
            // The Electron-era default moves to the new one; anything custom stays.
            if config.hotkey == "Command+Shift+Space" { config.hotkey = Config.defaults.hotkey }
        } catch {
            configReadable = isMissing(error)
            if !configReadable { unreadable.append("config") }
        }
        do {
            history = try read(path("history.json"), as: [HistoryEntry].self)
            lastTranscript = history.first?.text ?? ""
        } catch {
            historyReadable = isMissing(error)
            if !historyReadable { unreadable.append("history") }
        }
        do { stats = try read(path("cleanup-stats.json"), as: CleanupStats.self) }
        catch { statsReadable = isMissing(error) }
        return unreadable
    }

    func saveConfig(_ next: Config? = nil) throws {
        guard configReadable else { throw SaveError.unreadable("Settings file could not be read. It has not been overwritten.") }
        var out = next ?? config
        out.apiKey = ""
        out.openrouterKey = ""
        try writeJSON(path("config.json"), out)
        if let next { config = next }
    }

    func updateConfig(_ next: Config) throws {
        try saveConfig(next)
        config = next
    }

    func saveHistory(_ next: [HistoryEntry]) throws {
        guard historyReadable else { throw SaveError.unreadable("History file could not be read. It has not been overwritten.") }
        try writeJSON(path("history.json"), next)
        history = next
    }

    func saveStats() throws {
        guard statsReadable else { return }
        try writeJSON(path("cleanup-stats.json"), stats)
    }

    func recordCleanup(_ mutate: (inout CleanupStats) -> Void) {
        mutate(&stats)
        try? saveStats()
    }

    /// Settings edits: update memory now, write to disk once typing settles.
    func stage(_ next: Config) {
        config = next
        persistConfig()
    }

    // Disk and keychain writes on every click would stutter the surface; batch them instead.
    func persistConfig() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushConfig()
        }
    }

    func flushConfig() {
        persistTask?.cancel()
        persistTask = nil
        do { try saveConfig() } catch { notify("Settings not saved", error.localizedDescription) }
    }

    func recordTranscript(_ text: String, durationMs: Double?) throws {
        lastTranscript = text
        guard config.saveHistory else { return }
        let entry = HistoryEntry(
            id: UUID().uuidString.lowercased(),
            text: text,
            at: Date.now.timeIntervalSince1970 * 1000,
            durationMs: durationMs,
            words: text.split(whereSeparator: { $0.isWhitespace }).count
        )
        try saveHistory(Array(([entry] + history).prefix(historyLimit)))
    }

    enum SaveError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let message) = self { return message }
            return nil
        }
    }
}
