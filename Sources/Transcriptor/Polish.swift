import Foundation

// 1:1 port of the OpenRouter AI logic from main.js (cleanup / email / experiment).
@MainActor
enum Polish {
    nonisolated struct Outcome {
        let ok: Bool
        let text: String
        let reason: String
        let usage: Usage?
    }

    nonisolated struct Usage {
        let promptTokens: Int?
        let completionTokens: Int?
        let costUsd: Double?
    }

    private static let timeoutSeconds: TimeInterval = 8

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        return URLSession(configuration: config)
    }()

    /* ------------------------------- prompts ------------------------------- */

    private static let cleanupBase = """
    You turn a raw speech-to-text transcript into clean written text. Return ONLY the cleaned text — no preamble, no quotes, no commentary.
    - Keep the original language — never translate. Add no facts and summarize nothing away.
    - Fix transcription errors that are obvious from context.
    - If the speaker dictates a question or a chat message, output only the cleaned text — never answer or respond to it.
    - Self-corrections replace what came before — "actually", "wait", "I mean", "scratch that", "oziroma", "pravzaprav", "pardon", "mislim": keep only the corrected version.
    - When the speaker says the same thing twice, keep only the single best version.
    """

    private static let cleanupExample = """
    Example:
    Input: "torej eee jutri se dobiva ob desetih a ne ne pardon ob enajstih pa prinesi še tisti dokument"
    Output: "Jutri se dobiva ob enajstih. Prinesi še tisti dokument."
    """

    private static let cleanupPrompts = [
        "light": """
        \(cleanupBase)
        - Remove filler words and hesitations (um, eee, pač, ful, a veš, ne vem, mmm), stutters, repeated words and half-sentences.
        - Fix only clearly missing punctuation. Do not restructure: keep the original word order, sentences and line breaks.
        """,
        "medium": """
        \(cleanupBase)
        - Remove filler words and hesitations, stutters and repetitions.
        - Merge sentence fragments caused by pauses into fluent sentences when they form one idea.
        - Fix punctuation and capitalization; convert spoken punctuation ("comma", "period", "question mark", "new line", "new paragraph") to symbols and breaks.
        - Split the text into short paragraphs. Keep every fact and the original order.

        \(cleanupExample)
        """,
        "hard": """
        \(cleanupBase)
        - Remove filler words, stutters, repetitions and redundant context.
        - Fix punctuation; convert spoken punctuation to symbols and breaks.
        - Structure the text for reuse as AI instructions: short paragraphs, "- " bullets when items are enumerated, blank lines between sections. Detect enumerations and turn them into bullets.
        - Keep every fact, add nothing.

        \(cleanupExample)
        """,
    ]

    // Learned from 100 of Filip Kustec's sent emails (Slovenian ~80%, English ~20%).
    private static let emailSystemPrompt = """
    You turn a dictated, messy transcript into an email written exactly like Filip Kustec.
    Return ONLY the email: first line "zadeva: <short subject>", then a blank line, then the body. No commentary, no quotes.
    Write in the same language as the transcript (usually Slovenian; English only if the transcript is English).
    Remove filler words, hesitations, stutters and repetitions first — when the speaker says the same thing twice, keep only the single best version.

    LOWERCASE ALWAYS: the ENTIRE output is lowercase — subject, greeting, body, closing, name. No capital letters
    anywhere, not even at sentence starts. Only URLs keep their original form. Domain terms stay lowercase too.

    SLOVENIAN RULES:
    - Greeting is always "živjo," (lowercase + comma). No "Pozdravljeni", "Spoštovani", "Dragi" or "Hej" — never.
    - Tikanje (ti-forms), never vikanje, unless the transcript clearly addresses formal support.
    - Very short, direct, first-person sentences. Softeners, not imperatives: "lahko", "bi prosil", "če lahko", "prosim".
    - Closing is exactly two lines with no blank line between: "lep pozdrav," then "filip" on the next line. Never "lp".
    - Never open with "upam, da ste dobro" or any well-wish preamble. Go straight to the point.
    - Deadlines and next steps inline, conversational, as a question: "ti pošljem danes proti koncu dneva. je tako uredu?"
    - Thanks are short: "hvala", "najlepša hvala." Apologies own the mistake with a fix: "sori …", "to je moja napaka …".

    ENGLISH RULES (still all lowercase, including "hello," and the closing):
    - Greeting is "hello,". Closing is exactly two lines with no blank line between: "best regards," then "filip".
    - Complete polite sentences, first person. Thanks can be warm: "thank you so much for …".
    - Never open with "hope you are well".

    BOTH LANGUAGES:
    - 1–3 short paragraphs by default. Plain "-" bullets only for real lists. No bold, no headings, no markdown, no tables.
    - Links pasted bare, never hyperlinked text. No signature block, no phone, no title — first name only, lowercase.
    - No "!!!", no "ASAP". Single "!" at most, rarely.
    - Keep every fact from the transcript. Add nothing.
    """

    private static let langNames = [
        "sl": "Slovenian", "en": "English", "de": "German", "it": "Italian", "hr": "Croatian",
        "sr": "Serbian", "bs": "Bosnian", "fr": "French", "es": "Spanish", "pt": "Portuguese",
        "nl": "Dutch", "pl": "Polish", "cs": "Czech", "sk": "Slovak", "hu": "Hungarian",
        "ro": "Romanian",
    ]

    /* -------------------------------- wanted ------------------------------- */

    static func cleanupWanted(_ text: String, config: Config, openrouterKey: String) -> Bool {
        config.cleanupEnabled
            && ["light", "medium", "hard"].contains(config.cleanupTier)
            && !openrouterKey.isEmpty
            && !config.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && wordCount(text) > 2
    }

    static func emailWanted(_ text: String, config: Config, openrouterKey: String) -> Bool {
        config.emailEnabled
            && !openrouterKey.isEmpty
            && !config.emailModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && wordCount(text) > 2
    }

    static func experimentWanted(_ text: String, config: Config, openrouterKey: String) -> Bool {
        config.cleanupEnabled
            && config.cleanupTier == "exp"
            && !openrouterKey.isEmpty
            && !experimentModels(config).isEmpty
            && wordCount(text) > 2
    }

    /* ------------------------------- cleanup ------------------------------- */

    static func cleanup(_ text: String, config: Config, openrouterKey: String) async -> Outcome {
        let system = withUserContext(config, cleanupPrompts[config.cleanupTier] ?? cleanupPrompts["light"]!)
        let model = config.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return await chat(
            model: model.isEmpty ? Config.defaults.cleanupModel : model,
            providerRaw: config.cleanupProvider,
            system: system,
            text: text,
            key: openrouterKey)
    }

    static func email(_ text: String, config: Config, openrouterKey: String) async -> Outcome {
        let system = withUserContext(config, emailSystemPrompt, preserveTermCase: false)
        let model = config.emailModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var outcome = await chat(
            model: model.isEmpty ? Config.defaults.emailModel : model,
            providerRaw: config.emailProvider,
            system: system,
            text: text,
            key: openrouterKey)
        if outcome.ok {
            // The user's email style requires lowercase output. Enforce it after generation
            // instead of relying on every interchangeable model to follow the prompt.
            outcome = Outcome(ok: true, text: lowercaseExceptURLs(outcome.text), reason: "", usage: outcome.usage)
        }
        return outcome
    }

    /* ------------------------------ experiment ----------------------------- */

    // "exp" tier: the raw transcript pastes instantly while every configured model
    // cleans it in the background; outputs land in a per-dictation folder so the
    // best model can be picked from a day of real usage.
    static let experimentsFolder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(components: "Transcriptor", "experiments")

    static func experiment(_ text: String, config: Config, openrouterKey: String) async {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = experimentsFolder.appending(component: stamp)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (text + "\n").write(to: dir.appending(component: "raw.txt"), atomically: true, encoding: .utf8)
        } catch { return }
        let system = withUserContext(config, cleanupPrompts["medium"]!)
        let entries = experimentModels(config)
        let outputs = await withTaskGroup(of: (Int, String).self) { group in
            for (i, entry) in entries.enumerated() {
                group.addTask {
                    let started = Date()
                    let outcome = await chat(
                        model: entry.model, providerRaw: entry.provider,
                        system: system, text: text, key: openrouterKey)
                    let costLine: String
                    if outcome.ok, let cost = outcome.usage?.costUsd {
                        costLine = String(format: "$%.5f", cost)
                    } else {
                        costLine = "—"
                    }
                    var out = "## \(entry.model)"
                    if !entry.provider.isEmpty { out += " @ \(entry.provider)" }
                    out += "\nlatency: \(Int(Date().timeIntervalSince(started) * 1000)) ms\ncost: \(costLine)\n\n"
                    out += outcome.ok ? outcome.text : "ERROR: \(outcome.reason)"
                    out += "\n"
                    return (i, out)
                }
            }
            var results = [(Int, String)]()
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        try? outputs.joined(separator: "\n---\n\n")
            .write(to: dir.appending(component: "outputs.md"), atomically: true, encoding: .utf8)
    }

    // One model per line, optional "@ provider" suffix, up to 6.
    private static func experimentModels(_ config: Config) -> [(model: String, provider: String)] {
        config.experimentModels
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)
            .compactMap { line in
                let parts = line.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                let model = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let provider = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return model.isEmpty ? nil : (model, provider)
            }
    }

    /* ------------------------------- openrouter ---------------------------- */

    // "baseten/fp8" → (name: "baseten", quantization: "fp8"). A multi-part endpoint
    // tag like "google-vertex/global/priority" stays whole — only a trailing segment
    // that is a real quantization is split off. "" → nil (auto routing).
    private static func parseProvider(_ raw: String) -> (name: String, quantization: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let known: Set<String> = ["fp4", "fp6", "fp8", "fp16", "fp32", "bf16", "int4", "int8", "int16", "unknown"]
        if let lastSlash = trimmed.lastIndex(of: "/"), lastSlash > trimmed.startIndex {
            let tail = String(trimmed[trimmed.index(after: lastSlash)...])
            if known.contains(tail.lowercased()) {
                let name = String(trimmed[..<lastSlash]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return (name, tail) }
            }
        }
        return (trimmed, nil)
    }

    // The cleanup/email model inherits the user's Soniox context: speech language
    // hints plus the vocabulary terms, so it knows the language and the jargon.
    private static func withUserContext(_ config: Config, _ system: String, preserveTermCase: Bool = true) -> String {
        var system = system
        let languages = config.languageHints.map { langNames[$0] ?? $0 }.filter { !$0.isEmpty }
        let terms = config.context
            .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if !languages.isEmpty {
            system += " The transcript is in: \(languages.joined(separator: ", ")). Reply in the same language."
        }
        if !terms.isEmpty {
            system += preserveTermCase
                ? " Preserve these domain terms exactly as written: \(terms.joined(separator: ", "))."
                : " Preserve the spelling of these domain terms, but follow the lowercase rule above: \(terms.joined(separator: ", "))."
        }
        return system
    }

    private static func body(model: String, providerRaw: String, system: String, text: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": min(4000, max(1200, wordCount(text) * 2 + 400)),
            "stream": false,
            "usage": ["include": true],
            "reasoning": ["effort": "none", "exclude": true],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]
        if let provider = parseProvider(providerRaw) {
            var providerBody: [String: Any] = ["order": [provider.name], "allow_fallbacks": true]
            if let quantization = provider.quantization { providerBody["quantizations"] = [quantization] }
            body["provider"] = providerBody
        }
        return body
    }

    // Prefer no reasoning for this transformation. If a model requires reasoning,
    // retry with low effort, then its provider default. Empty length-limited replies
    // also retry with more room because reasoning and visible text share one budget.
    private static func chat(model: String, providerRaw: String, system: String, text: String, key: String) async -> Outcome {
        var compatibility = 0
        var outcome = "retry"
        for attempt in 0..<3 {
            var requestBody = body(model: model, providerRaw: providerRaw, system: system, text: text)
            if compatibility == 1 { requestBody["reasoning"] = ["effort": "low", "exclude": true] }
            if compatibility >= 2 { requestBody.removeValue(forKey: "reasoning") }
            if attempt > 0 {
                let tokens = requestBody["max_completion_tokens"] as? Int ?? 0
                requestBody["max_completion_tokens"] = min(8000, tokens * 2)
            }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://transcriptor.local", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Transcriptor", forHTTPHeaderField: "X-Title")
            request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
            do {
                let (data, response) = try await Self.session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 400 && attempt < 2 { compatibility += 1; continue }
                if status == 429 && attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(800))
                    continue
                }
                guard (200..<300).contains(status) else {
                    outcome = "HTTP \(status)"
                    break
                }
                let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
                let choice = (json["choices"] as? [[String: Any]])?.first
                let rawContent = (choice?["message"] as? [String: Any])?["content"]
                let content: String
                if let string = rawContent as? String {
                    content = string
                } else if let parts = rawContent as? [Any] {
                    content = parts.map { part -> String in
                        if let string = part as? String { return string }
                        return (part as? [String: Any])?["text"] as? String ?? ""
                    }.joined()
                } else {
                    content = ""
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    let finish = (choice?["finish_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (choice?["native_finish_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "blank"
                    let usageDict = json["usage"] as? [String: Any]
                    let used = number(usageDict?["completion_tokens"])
                    let reasoning = number((usageDict?["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"])
                    outcome = "empty/\(finish)"
                    if let used { outcome += "/tokens:\(numStr(used))" }
                    if let reasoning { outcome += "/reasoning:\(numStr(reasoning))" }
                    if attempt < 2 {
                        compatibility += 1
                        continue
                    }
                    break
                }
                let usageDict = json["usage"] as? [String: Any]
                let usage = usageDict.map {
                    Usage(
                        promptTokens: number($0["prompt_tokens"]).map(Int.init),
                        completionTokens: number($0["completion_tokens"]).map(Int.init),
                        costUsd: number($0["cost"]))
                }
                return Outcome(ok: true, text: trimmed, reason: "", usage: usage)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain
                    && (nsError.code == NSURLErrorCancelled || nsError.code == NSURLErrorTimedOut) {
                    outcome = "aborted"
                    break
                }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(800))
                    continue
                }
                let message = error.localizedDescription
                outcome = message.isEmpty ? "network" : message
            }
        }
        return Outcome(ok: false, text: "", reason: outcome, usage: nil)
    }

    private static func lowercaseExceptURLs(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\b(?:https?://|www\.)\S+"#, options: [.caseInsensitive])
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let sl = Locale(identifier: "sl-SI")
        var out = ""
        var index = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[index..<range.lowerBound].lowercased(with: sl)
            out += text[range]
            index = range.upperBound
        }
        out += text[index...].lowercased(with: sl)
        return out
    }

    private static func wordCount(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func numStr(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}
