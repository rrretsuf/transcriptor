import SwiftUI

// First launch: key, hotkey, permissions, one real dictation. Each page asks
// for one thing, and the last one proves the whole chain works before the
// window closes and the app retreats to the menu bar.

struct OnboardingView: View {
    let state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.key

    private enum Step: Int, CaseIterable { case key, hotkey, permissions, trial }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .key: KeyPage(state: state, next: next).transition(.blurReplace)
                case .hotkey: HotkeyPage(state: state, next: next).transition(.blurReplace)
                case .permissions: PermissionsPage(state: state, next: next).transition(.blurReplace)
                case .trial: TrialPage(state: state, next: finish).transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { page in
                    Capsule()
                        .fill(page == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: page == step ? 18 : 6, height: 6)
                }
            }
            .padding(.bottom, 22)
        }
        .frame(width: 460, height: 570)
        .overlay(alignment: .topLeading) {
            if step != .key {
                Button("Back", systemImage: "chevron.left") { step = Step(rawValue: step.rawValue - 1)! }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
    }

    private func next() {
        step = Step(rawValue: step.rawValue + 1) ?? step
    }

    private func finish() {
        state.finishOnboarding()
        dismissWindow(id: "onboarding")
    }
}

// MARK: - Layout

private struct Page<Hero: View, Content: View, Action: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 0) {
            hero.frame(height: 96)
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 18)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            content.padding(.top, 28)
            Spacer(minLength: 16)
            action
        }
        .padding(.horizontal, 44)
        .padding(.top, 40)
        .padding(.bottom, 20)
    }
}

private struct Symbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 84, height: 84)
            .background(.tint.opacity(0.12), in: Circle())
    }
}

private struct PrimaryButton: View {
    let title: String
    var prominent = true
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).frame(maxWidth: .infinity)
        }
        .glassButton(prominent: prominent)
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(disabled)
    }
}

private let field = RoundedRectangle(cornerRadius: 12, style: .continuous)

// MARK: - Key

private struct KeyPage: View {
    let state: AppState
    let next: () -> Void
    @State private var key = ""
    @State private var saved = false
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        Page(title: "Welcome to Transcriptor",
             subtitle: "Press a key, speak, and the text lands at your cursor. It runs on your own Soniox key.") {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
        } content: {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    SecureField("Soniox API key", text: $key,
                                prompt: Text(saved ? "Key saved in your Keychain" : "Paste your Soniox API key"))
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(submit)
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if saved && key.isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.quaternary.opacity(0.6), in: field)
                .overlay(field.strokeBorder(problem == nil ? .clear : .red.opacity(0.6)))
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red).transition(.opacity)
                } else {
                    Link("Get a key at console.soniox.com", destination: URL(string: "https://console.soniox.com")!)
                        .font(.callout)
                }
            }
            .animation(.easeOut(duration: 0.18), value: problem)
        } action: {
            PrimaryButton(title: checking ? "Checking…" : "Continue",
                          disabled: checking || (key.isEmpty && !saved), action: submit)
        }
        .onAppear {
            saved = !(Keychain.get(Keychain.Account.soniox) ?? "").isEmpty
            focused = true
        }
        .onChange(of: key) { problem = nil }
    }

    private func submit() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !checking else { return }
        guard !candidate.isEmpty else { if saved { next() }; return }
        checking = true
        Task {
            defer { checking = false }
            switch await SonioxFiles.accepts(apiKey: candidate) {
            case true?:
                do {
                    try Keychain.set(candidate, account: Keychain.Account.soniox)
                    state.forgetKey()
                    next()
                } catch {
                    problem = "The key could not be saved to your Keychain."
                }
            case false?: problem = "Soniox did not accept this key."
            case nil: problem = "Soniox could not be reached. Check your connection."
            }
        }
    }
}

// MARK: - Hotkey

private struct HotkeyPage: View {
    let state: AppState
    let next: () -> Void
    @State private var capture = KeyCapture()
    @State private var taken = false
    @State private var hovering = false

    private static let taps = [("Double-tap ⌘", "tap:Command:2"), ("Double-tap ⌥", "tap:Option:2"),
                               ("Double-tap fn", "tap:Fn:2")]

    var body: some View {
        Page(title: "Choose your hotkey",
             subtitle: "Press it anywhere to start talking. Press it again and the text is typed for you.") {
            Symbol(name: "keyboard")
        } content: {
            VStack(spacing: 16) {
                Button(action: record) {
                    HStack(spacing: 8) {
                        if capture.recording {
                            Text("Press the keys…").foregroundStyle(.secondary)
                        } else {
                            ForEach(Hotkeys.display(state.config.hotkey).split(separator: " "), id: \.self) { key in
                                Text(key)
                                    .padding(.horizontal, 12)
                                    .frame(minWidth: 40, minHeight: 40)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
                            }
                        }
                    }
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .background(.quaternary.opacity(hovering || capture.recording ? 0.9 : 0.6), in: field)
                    .overlay(field.strokeBorder(.tint.opacity(capture.recording ? 1 : 0), lineWidth: 2))
                    .contentShape(field)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Click, then press a new combination")
                if taken {
                    Text("Another app already uses this one. Pick a different combination.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Click to change it, or pick a double-tap:").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(Self.taps, id: \.1) { label, hotkey in
                        Button(label) { set(hotkey) }
                            .buttonStyle(.bordered)
                            .tint(state.config.hotkey == hotkey ? .accentColor : nil)
                    }
                }
                .controlSize(.small)
            }
            .animation(.easeOut(duration: 0.15), value: capture.recording)
            .animation(.easeOut(duration: 0.15), value: taken)
        } action: {
            PrimaryButton(title: "Continue", disabled: taken || capture.recording, action: next)
        }
        // The hotkey stays unregistered while a new one is recorded, so pressing
        // the current combination records it instead of starting a dictation.
        .onChange(of: capture.recording) { _, recording in
            if !recording { taken = !state.registerHotkey() }
        }
        .onDisappear(perform: capture.stop)
    }

    private func record() {
        if capture.recording { return capture.stop() }
        state.suspendHotkey()
        capture.start { set($0) }
    }

    private func set(_ hotkey: String) {
        var config = state.config
        config.hotkey = hotkey
        state.store.stage(config)
        if capture.recording { capture.stop() } else { taken = !state.registerHotkey() }
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    let state: AppState
    let next: () -> Void

    var body: some View {
        // macOS has no "permission changed" event; a light poll keeps the checkmarks honest.
        TimelineView(.periodic(from: .now, by: 0.6)) { _ in
            let microphone = Permission.microphone.granted
            let accessibility = Permission.accessibility.granted
            Page(title: "Allow three things",
                 subtitle: "macOS asks once for each. Nothing is heard until you press your hotkey.") {
                Symbol(name: "lock.shield")
            } content: {
                VStack(spacing: 10) {
                    Row(permission: .microphone, granted: microphone, icon: "mic.fill",
                        title: "Microphone", detail: "Hears you while you dictate.")
                    Row(permission: .accessibility, granted: accessibility, icon: "character.cursor.ibeam",
                        title: "Accessibility", detail: "Types the text where your cursor is.")
                    Row(permission: .systemAudio, granted: Permission.systemAudio.granted, icon: "speaker.wave.2.fill",
                        title: "System Audio", detail: "Hears the other side in meetings.")
                }
            } action: {
                PrimaryButton(title: accessibility || !microphone ? "Continue" : "Continue without typing",
                              disabled: !microphone, action: next)
            }
            // Double-tap hotkeys listen through an event tap that only opens once trusted.
            .onChange(of: accessibility) { state.registerHotkey() }
        }
    }

    private struct Row: View {
        let permission: Permission
        let granted: Bool
        let icon: String
        let title: String
        let detail: String

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Allow") { Task { await permission.request() } }
                        .buttonStyle(.bordered)
                        .transition(.opacity)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: field)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: granted)
        }
    }
}

// MARK: - Trial

private struct TrialPage: View {
    let state: AppState
    let next: () -> Void
    @State private var text = ""
    @State private var worked = false
    @FocusState private var focused: Bool

    var body: some View {
        let hotkey = Hotkeys.display(state.config.hotkey)
        Page(title: "Try it",
             subtitle: "Press \(hotkey), say a sentence, then press \(hotkey) again.") {
            Symbol(name: worked ? "checkmark" : "waveform")
                .contentTransition(.symbolEffect(.replace))
        } content: {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .writingToolsBehavior(.disabled)
                    .padding(10)
                    .frame(height: 132)
                    .background(.quaternary.opacity(0.6), in: field)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(worked ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: status)
        } action: {
            PrimaryButton(title: worked ? "Start using Transcriptor" : "Skip", prominent: worked, action: next)
        }
        .onAppear { focused = true }
        .onChange(of: state.store.lastTranscript) { _, transcript in
            worked = true
            // Without Accessibility nothing is typed; show the words anyway.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if text.isEmpty { text = transcript }
            }
        }
    }

    private var status: String {
        switch state.state {
        case .recording: "Listening…"
        case .finishing: "Finishing…"
        case .idle: worked ? "It works. Transcriptor now lives in your menu bar." : "Waiting for \(Hotkeys.display(state.config.hotkey))"
        }
    }
}
