import Foundation

@MainActor @Observable
final class Store {
    let directory: URL
    private(set) var config = Config.defaults
    private(set) var history: [HistoryEntry] = []
    private(set) var configReadable = true
    private(set) var historyReadable = true
    var lastTranscript = ""
    private var persistTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(component: "Transcriptor")
    }

    private func path(_ name: String) -> URL { directory.appending(component: name) }

    private func writeJSON(_ url: URL, _ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = url.appendingPathExtension("tmp")
        try encoder.encode(value).write(to: tmp, options: .atomic)
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
        return unreadable
    }

    func saveConfig(_ next: Config? = nil) throws {
        guard configReadable else { throw SaveError.unreadable("Settings file could not be read. It has not been overwritten.") }
        var out = next ?? config
        out.apiKey = ""
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

    /// Returns the new entry's id, or nil when history is off.
    @discardableResult
    func recordTranscript(_ text: String, durationMs: Double?, title: String? = nil, startedAt: Date? = nil,
                          kind: HistoryEntry.Kind? = nil, app: String? = nil) throws -> String? {
        lastTranscript = text
        guard config.saveHistory else { return nil }
        let entry = HistoryEntry(
            id: UUID().uuidString.lowercased(),
            text: text,
            at: Date.now.timeIntervalSince1970 * 1000,
            durationMs: durationMs,
            words: text.split(whereSeparator: { $0.isWhitespace }).count,
            title: title,
            startedAt: startedAt.map { $0.timeIntervalSince1970 * 1000 },
            kind: kind,
            app: app
        )
        var dictations = 0
        try saveHistory(([entry] + history).filter {
            guard $0.kind == .dictation else { return true }
            dictations += 1
            return dictations <= historyLimit
        })
        return entry.id
    }

    func retitle(_ id: String, _ title: String) {
        guard let index = history.firstIndex(where: { $0.id == id }), history[index].title != title else { return }
        var next = history
        next[index].title = title
        try? saveHistory(next)
    }

    enum SaveError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let message) = self { return message }
            return nil
        }
    }
}
