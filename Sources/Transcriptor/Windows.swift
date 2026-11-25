import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Config bindings

/// Edits land in memory immediately and reach disk once typing settles.
@MainActor
private func binding<V>(_ state: AppState, _ keyPath: WritableKeyPath<Config, V>,
                        then: @escaping () -> Void = {}) -> Binding<V> {
    Binding(
        get: { state.config[keyPath: keyPath] },
        set: { value in
            var next = state.config
            next[keyPath: keyPath] = value
            state.store.stage(next)
            then()
        }
    )
}

extension View {
    /// Liquid Glass on macOS 26, the bordered styles before it.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Languages Soniox recognizes, shown with the system's localized names.
private let languages: [String] = [
    "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fi",
    "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "ko", "lv", "lt", "mk", "ms",
    "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl", "es", "sw", "sv", "tl", "ta", "te",
    "th", "tr", "uk", "ur", "vi", "cy",
].sorted { languageName($0) < languageName($1) }

private func languageName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            dictation.tabItem { Label("Dictation", systemImage: "waveform") }
        }
        .frame(width: 540, height: 600)
        .onDisappear { state.store.flushConfig() }
    }

    private var general: some View {
        Form {
            Section {
                HotkeyRecorder(hotkey: binding(state, \.hotkey) { state.registerHotkeyOrNotify() })
                LabeledContent("Cancel Recording", value: Hotkeys.display(AppState.cancelHotkey))
                Toggle("Launch at Login", isOn: binding(state, \.launchAtLogin) { state.applyLaunchAtLogin() })
                if #available(macOS 14.2, *) {
                    Toggle("Detect Meetings", isOn: binding(state, \.detectMeetings) { state.applyMeetingDetection() })
                }
            }
            Section {
                KeyField(label: "Soniox", account: Keychain.Account.soniox) { state.forgetKey() }
            } header: {
                Text("API Key")
            } footer: {
                Text("Stored in your Keychain, never in a file.")
            }
            Section("Usage") {
                UsageGrid(state: state)
            }
        }
        .formStyle(.grouped)
    }

    private var dictation: some View {
        Form {
            Section {
                Picker("Model", selection: binding(state, \.model)) {
                    Text("Soniox Real-Time v6").tag("stt-rt-v6")
                    Text("Soniox Real-Time v5").tag("stt-rt-v5")
                    if !["stt-rt-v6", "stt-rt-v5"].contains(state.config.model) {
                        Text(state.config.model).tag(state.config.model)
                    }
                }
                LanguagesRow(state: state)
                Picker("Translate To", selection: binding(state, \.translateTo)) {
                    Text("Off").tag("")
                    Divider()
                    ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
                }
            } footer: {
                Text("Language hints steer recognition; leave them empty for auto-detection.")
            }
            Section {
                TextField("Context", text: binding(state, \.context),
                          prompt: Text("Names, products, jargon"), axis: .vertical)
                    .lineLimit(2...5)
                Toggle("Use Text Before Cursor", isOn: binding(state, \.cursorContext))
            } footer: {
                Text("Comma-separated terms Soniox should recognize. The text before the cursor goes along too, so dictation continues it; password fields are never read.")
            }
            Section {
                LabeledContent("Stop After Silence") {
                    HStack(spacing: 4) {
                        TextField("", value: binding(state, \.silenceStopMs), format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
                Toggle("Paste at Cursor", isOn: binding(state, \.autoPaste))
                Toggle("Restore Clipboard After Paste", isOn: binding(state, \.restoreClipboard))
                Toggle("Save Transcriptions", isOn: binding(state, \.saveHistory))
            } footer: {
                Text("0 ms keeps recording until you press the hotkey again.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, press the combination, done. Escape cancels; modifier double-taps live in the menu.
private struct HotkeyRecorder: View {
    @Binding var hotkey: String
    @StateObject private var capture = KeyCapture()

    var body: some View {
        LabeledContent("Dictation Hotkey") {
            HStack(spacing: 6) {
                Button(capture.recording ? "Press keys…" : Hotkeys.display(hotkey)) {
                    capture.recording ? capture.stop() : capture.start { hotkey = $0 }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(capture.recording ? .secondary : .primary)
                Menu {
                    Button("Double-tap ⌘") { set("tap:Command:2") }
                    Button("Double-tap ⌥") { set("tap:Option:2") }
                    Button("Double-tap fn") { set("tap:Fn:2") }
                    Divider()
                    Button("Reset to ⌥ Space") { set(Config.defaults.hotkey) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .onDisappear(perform: capture.stop)
    }

    private func set(_ value: String) {
        capture.stop()
        hotkey = value
    }
}

/// Secure field that saves on return; shows a check once a key is stored.
private struct KeyField: View {
    let label: String
    let account: String
    let onSave: () -> Void
    @State private var value = ""
    @State private var saved = false

    var body: some View {
        HStack {
            SecureField(label, text: $value, prompt: Text(saved ? "Saved" : "Paste key, press return"))
                .onSubmit(save)
            if !value.isEmpty {
                Button("Save", action: save)
            } else if saved {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .onAppear { saved = !(Keychain.get(account) ?? "").isEmpty }
    }

    private func save() {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try? Keychain.set(key, account: account)
        value = ""
        saved = true
        onSave()
    }
}

private struct LanguagesRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        LabeledContent("Languages") {
            HStack(spacing: 6) {
                ForEach(state.config.languageHints, id: \.self) { hint in
                    Button {
                        var next = state.config
                        next.languageHints.removeAll { $0 == hint }
                        state.store.stage(next)
                    } label: {
                        HStack(spacing: 4) {
                            Text(languageName(hint))
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(languageName(hint))")
                }
                Menu {
                    ForEach(languages.filter { !state.config.languageHints.contains($0) }, id: \.self) { code in
                        Button(languageName(code)) {
                            var next = state.config
                            next.languageHints.append(code)
                            state.store.stage(next)
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// Everything the local history can tell.
private struct UsageGrid: View {
    @ObservedObject var state: AppState

    var body: some View {
        let history = state.store.history
        let words = history.reduce(0) { $0 + ($1.words ?? 0) }
        let seconds = history.reduce(0.0) { $0 + ($1.durationMs ?? 0) } / 1000
        let today = history.filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.at / 1000)) }.count
        let wpm = seconds > 0 ? Double(words) / seconds * 60 : 0
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            StatTile(value: history.count.formatted(), label: "Transcriptions")
            StatTile(value: words.formatted(), label: "Words")
            StatTile(value: Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow)),
                     label: "Spoken")
            StatTile(value: wpm.formatted(.number.precision(.fractionLength(0))), label: "Words / min")
            StatTile(value: today.formatted(), label: "Today")
            // Soniox real-time list price: $0.12 per streamed hour (soniox.com/pricing).
            StatTile(value: (seconds / 3600 * 0.12).formatted(.currency(code: "USD").precision(.fractionLength(2))),
                     label: "Soniox spend (est.)")
        }
        .padding(.vertical, 4)
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var meetingsOnly = false
    @State private var opened: HistoryEntry?

    var body: some View {
        let filtered = filtered // evaluated once per render, not once per branch
        NavigationStack {
            Group {
                if meetingsOnly && !state.store.history.contains(where: \.isMeeting) {
                    EmptyState("No Meetings",
                               systemImage: "record.circle",
                               description: "Start one from the menu bar: Start Meeting Transcription.")
                } else if state.store.history.isEmpty {
                    EmptyState("No Transcriptions",
                               systemImage: "waveform",
                               description: "Press \(Hotkeys.display(state.config.hotkey)) and start talking.")
                } else if filtered.isEmpty {
                    EmptyState("No Results for “\(query)”",
                               systemImage: "magnifyingglass",
                               description: "Check the spelling or try a new search.")
                } else {
                    List(filtered, id: \.id) { entry in
                        HistoryRow(entry: entry, onOpen: { opened = entry }, onDelete: { delete(entry) })
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Transcriptions")
            .sheet(item: $opened) { TranscriptSheet(entry: $0) }
            .searchable(text: $query, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $meetingsOnly.animation(.snappy)) {
                        Text("All").tag(false)
                        Text("Meetings").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }

    private var filtered: [HistoryEntry] {
        let all = meetingsOnly ? state.store.history.filter(\.isMeeting) : state.store.history
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.title?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func delete(_ entry: HistoryEntry) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            try? state.store.saveHistory(state.store.history.filter { $0.id != entry.id })
        }
        if state.store.lastTranscript == entry.text { state.store.lastTranscript = "" }
    }
}

private struct TitleLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint).font(.caption)
            configuration.title.lineLimit(1)
        }
    }
}

extension HistoryEntry: Identifiable {
    /// "Oct 13 · 14:05 – 15:12 · 1,083 words · 4m 43s"
    var facts: String {
        let end = Date(timeIntervalSince1970: at / 1000)
        var parts = [startedAt.map { meetingSpan(Date(timeIntervalSince1970: $0 / 1000), end) }
            ?? end.formatted(.dateTime.month().day().hour().minute())]
        if let app { parts.append(app) }
        if let words { parts.append("\(words) words") }
        if let durationMs {
            parts.append(Duration.seconds(durationMs / 1000).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Click to read it in full; the copy button sits beside it, the trash appears on hover.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let title = entry.title {
                    Label(title, systemImage: entry.isMeeting ? "record.circle" : "doc")
                        .font(.headline)
                        .labelStyle(TitleLabel(tint: entry.isMeeting ? .red : .secondary))
                }
                Text(entry.text)
                    .lineLimit(entry.title != nil ? 3 : 4)
                    .foregroundStyle(entry.title != nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.facts)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            CopyIconButton(text: entry.text)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Delete")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// A square copy button whose icon turns into a check for a moment.
private struct CopyIconButton: View {
    let text: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            _ = Paste.writeClipboard(text)
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            ZStack {
                Image(systemName: "doc.on.doc")
                    .opacity(copied ? 0 : 1).scaleEffect(copied ? 0.25 : 1).blur(radius: copied ? 4 : 0)
                Image(systemName: "checkmark").fontWeight(.semibold)
                    .opacity(copied ? 1 : 0).scaleEffect(copied ? 1 : 0.25).blur(radius: copied ? 0 : 4)
            }
            .font(.system(size: 13, weight: .medium))
            .frame(width: 32, height: 32)
            .foregroundStyle(copied ? Color.accentColor : .secondary)
            .background(.quaternary.opacity(copied ? 0 : 0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(Color.accentColor.opacity(copied ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Copy")
        .animation(.spring(duration: 0.3, bounce: 0), value: copied)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One transcription in full: speakers labelled, selectable, copied or saved as text.
private struct TranscriptSheet: View {
    let entry: HistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title ?? entry.app.map { "Dictation in \($0)" } ?? "Dictation")
                        .font(.title3.weight(.semibold))
                    Text(entry.facts).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            ScrollView {
                Text(formatted)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Text("\(entry.text.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button(saved ? "Saved" : "Save as…", action: save)
                    .glassButton()
                    .keyboardShortcut("s")
                CopyButton(text: entry.text)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 680, minHeight: 420, idealHeight: 640)
    }

    private static let speakerColors: [Color] = [.accentColor, .green, .orange, .purple, .secondary]

    /// In a meeting, "Speaker 1: Hello" paragraphs get the speaker as a coloured label, once per turn.
    private var formatted: AttributedString {
        var result = AttributedString()
        var speakers: [String] = []
        var last: String?
        let paragraphs = entry.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        for (index, paragraph) in paragraphs.enumerated() where !paragraph.isEmpty {
            let turn = entry.isMeeting ? paragraph.range(of: #"^[^\n:]{1,32}:\s+"#, options: .regularExpression) : nil
            let speaker = turn.map { paragraph[$0].trimmingCharacters(in: .whitespaces).dropLast() }.map(String.init)
            let said = turn.map { String(paragraph[$0.upperBound...]) } ?? paragraph
            if index > 0 { result += AttributedString(speaker != nil && speaker != last ? "\n\n\n" : "\n\n") }
            if let speaker, speaker != last {
                if !speakers.contains(speaker) { speakers.append(speaker) }
                var label = AttributedString(speaker + "\n")
                label.font = .callout.weight(.semibold)
                label.foregroundColor = Self.speakerColors[speakers.firstIndex(of: speaker)! % Self.speakerColors.count]
                result += label
            }
            var body = AttributedString(said)
            body.font = .body
            result += body
            last = speaker
        }
        return result
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (entry.title ?? "Transcription \(Date(timeIntervalSince1970: entry.at / 1000).formatted(date: .abbreviated, time: .shortened))")
            .replacingOccurrences(of: "[/:\\n]", with: "-", options: .regularExpression) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = [entry.title, entry.facts].compactMap { $0 }.joined(separator: "\n")
        do {
            try "\(header)\n\n\(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))\n".write(to: url, atomically: true, encoding: .utf8)
            saved = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                saved = false
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
