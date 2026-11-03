import AppKit
import ServiceManagement
import SwiftUI

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
    let state: AppState

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Dictation", systemImage: "waveform") { dictation }
        }
        .frame(width: 540, height: 600)
        .onDisappear { state.store.flushConfig() }
    }

    private var general: some View {
        Form {
            Section {
                HotkeyRecorder(hotkey: binding(state, \.hotkey) { state.registerHotkey() })
                LabeledContent("Cancel Recording", value: Hotkeys.display(AppState.cancelHotkey))
                Toggle("Launch at Login", isOn: binding(state, \.launchAtLogin) {
                    if state.config.launchAtLogin { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                })
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
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Dictation Hotkey") {
            HStack(spacing: 6) {
                Button(recording ? "Press keys…" : Hotkeys.display(hotkey)) {
                    recording ? stop() : start()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(recording ? .secondary : .primary)
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
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode != 53, // escape cancels
                   let accelerator = Hotkeys.accelerator(keyCode: event.keyCode, flags: event.modifierFlags) {
                    set(accelerator)
                }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ value: String) {
        hotkey = value
        stop()
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
    let state: AppState

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
    let state: AppState

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
    let state: AppState
    @State private var query = ""
    @State private var meetingsOnly = false

    var body: some View {
        let filtered = filtered // evaluated once per render, not once per branch
        NavigationStack {
            Group {
                if meetingsOnly && !state.store.history.contains(where: \.isMeeting) {
                    ContentUnavailableView("No Meetings",
                                           systemImage: "record.circle",
                                           description: Text("Start one from the menu bar: Start Meeting Transcription."))
                } else if state.store.history.isEmpty {
                    ContentUnavailableView("No Transcriptions",
                                           systemImage: "waveform",
                                           description: Text("Press \(Hotkeys.display(state.config.hotkey)) and start talking."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(filtered, id: \.id) { entry in
                        HistoryRow(entry: entry) { delete(entry) }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Transcriptions")
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

private struct MeetingLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.red).font(.caption)
            configuration.title.lineLimit(1)
        }
    }
}

/// Click anywhere on the text to copy; the trash appears on hover.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let title = entry.title {
                    Label(title, systemImage: "record.circle")
                        .font(.headline)
                        .labelStyle(MeetingLabel())
                }
                Text(entry.text)
                    .lineLimit(entry.isMeeting ? 3 : 4)
                    .foregroundStyle(entry.isMeeting ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let start = entry.startedAt {
                        Text(meetingSpan(Date(timeIntervalSince1970: start / 1000), Date(timeIntervalSince1970: entry.at / 1000)))
                    } else {
                        Text(Date(timeIntervalSince1970: entry.at / 1000), format: .dateTime.month().day().hour().minute())
                    }
                    if let words = entry.words { Text("·"); Text("\(words) words") }
                    if let ms = entry.durationMs {
                        Text("·")
                        Text(Duration.seconds(ms / 1000), format: .units(allowed: [.minutes, .seconds], width: .narrow))
                    }
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
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
                .fill(copied ? Color.accentColor.opacity(0.14) : hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: copied)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private func copy() {
        _ = Paste.writeClipboard(entry.text)
        copied = true
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
