import AVFoundation
import Foundation

// Soniox async API: upload a file, wait for its transcript, delete both after.
// Video and unusual containers are reduced to their audio track first, so a
// one-hour screen recording uploads a few megabytes instead of gigabytes.
enum SonioxFiles {
    enum Stage { case preparing, uploading, transcribing }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let model = "stt-async-v5"
    private static let base = URL(string: "https://api.soniox.com/v1/")!
    private static let uploadable: Set<String> = ["mp3", "wav", "m4a", "flac", "ogg", "aac", "aiff", "aif", "amr"]

    @concurrent
    static func transcribe(_ url: URL, apiKey: String, languageHints: [String],
                           stage: @MainActor (Stage) -> Void) async throws -> (text: String, durationMs: Double?) {
        let asset = AVURLAsset(url: url)
        let seconds = try? await asset.load(.duration).seconds
        var upload = url
        if !uploadable.contains(url.pathExtension.lowercased()) {
            await stage(.preparing)
            upload = try await extractAudio(asset)
        }
        defer { if upload != url { try? FileManager.default.removeItem(at: upload) } }

        var fileID: String?, jobID: String?
        defer { cleanup(fileID: fileID, jobID: jobID, apiKey: apiKey) }
        await stage(.uploading)
        fileID = try await uploadFile(upload, apiKey: apiKey)
        await stage(.transcribing)
        let job = NewJob(model: model, file_id: fileID!, language_hints: languageHints.isEmpty ? nil : languageHints)
        jobID = try await send(Job.self, "transcriptions", apiKey: apiKey, method: "POST",
                               json: try JSONEncoder().encode(job)).id
        while true {
            try await Task.sleep(for: .seconds(1))
            let job = try await send(Job.self, "transcriptions/\(jobID!)", apiKey: apiKey)
            if job.status == "completed" { break }
            if job.status == "error" { throw Failure(job.error_message ?? "Soniox could not transcribe this file") }
        }
        let text = try await send(Transcript.self, "transcriptions/\(jobID!)/transcript", apiKey: apiKey).text
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), seconds.map { ($0 * 1000).rounded() })
    }

    private static func extractAudio(_ asset: AVURLAsset) async throws -> URL {
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure("This file has no audio") }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure("This file's audio cannot be read")
        }
        let out = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }

    private static func uploadFile(_ file: URL, apiKey: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(file.pathExtension)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n").utf8)
        body.append(try Data(contentsOf: file, options: .mappedIfSafe))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = request("files", apiKey: apiKey, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return try decode(Job.self, data, response).id
    }

    private static func send<T: Decodable>(_ type: T.Type, _ path: String, apiKey: String,
                                           method: String = "GET", json: Data? = nil) async throws -> T {
        var request = request(path, apiKey: apiKey, method: method)
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(type, data, response)
    }

    private static func request(_ path: String, apiKey: String, method: String) -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ response: URLResponse) throws -> T {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode(Job.self, from: data))?.message
            throw Failure(code == 401 ? "Your Soniox key was rejected" : message ?? "Soniox error \(code)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Soniox keeps files for 30 days unless told otherwise; nothing of the user's should linger.
    private static func cleanup(fileID: String?, jobID: String?, apiKey: String) {
        Task {
            if let jobID { _ = try? await URLSession.shared.data(for: request("transcriptions/\(jobID)", apiKey: apiKey, method: "DELETE")) }
            if let fileID { _ = try? await URLSession.shared.data(for: request("files/\(fileID)", apiKey: apiKey, method: "DELETE")) }
        }
    }

    private struct Job: Decodable {
        var id = ""
        var status: String?
        var error_message: String?
        var message: String?

        enum CodingKeys: CodingKey { case id, status, error_message, message }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status)
            error_message = try c.decodeIfPresent(String.self, forKey: .error_message)
            message = try c.decodeIfPresent(String.self, forKey: .message)
        }
    }

    private struct NewJob: Encodable {
        let model: String
        let file_id: String
        let language_hints: [String]?
    }

    private struct Transcript: Decodable { let text: String }
}

/// One file at a time, from drop to transcript; the result also lands in history.
@MainActor @Observable
final class FileTranscription {
    enum Status: Equatable {
        case idle
        case working(SonioxFiles.Stage)
        case done(String)
        case failed(String)
    }

    private(set) var status = Status.idle
    private(set) var fileName = ""
    private let store: Store
    private var task: Task<Void, Never>?

    init(store: Store) { self.store = store }

    func start(_ url: URL) {
        guard let apiKey = Keychain.get(Keychain.Account.soniox), !apiKey.isEmpty else {
            status = .failed("Add your Soniox API key in Settings first.")
            return
        }
        fileName = url.lastPathComponent
        status = .working(.uploading)
        let hints = store.config.languageHints
        task = Task {
            do {
                let result = try await SonioxFiles.transcribe(url, apiKey: apiKey, languageHints: hints) { [weak self] in
                    self?.status = .working($0)
                }
                guard !Task.isCancelled else { return }
                guard !result.text.isEmpty else { return status = .failed("No speech found in this file.") }
                status = .done(result.text)
                try? store.recordTranscript(result.text, durationMs: result.durationMs)
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        status = .idle
    }
}
