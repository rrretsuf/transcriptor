import SwiftUI

// The two windows that work with longer audio: a dropped file and a live
// meeting. Both end on the same transcript panel, so copying looks the same.

private let stateChange = Animation.spring(response: 0.45, dampingFraction: 0.86)

// MARK: - File

struct FileView: View {
    let files: FileTranscription
    @State private var targeted = false
    @State private var choosing = false

    var body: some View {
        ZStack {
            switch files.status {
            case .idle:
                dropZone.transition(.blurReplace)
            case .working(let stage):
                Working(title: files.fileName, detail: label(stage)) { files.reset() }
                    .transition(.blurReplace)
            case .done(let text):
                TranscriptPanel(text: text, again: ("New File", files.reset))
                    .transition(.blurReplace)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not transcribe", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Another File", action: files.reset).buttonStyle(.glass)
                }
                .transition(.blurReplace)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 340)
        .animation(stateChange, value: files.status)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio, .audiovisualContent]) { result in
            if case .success(let url) = result { files.start(url) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: targeted)
            VStack(spacing: 4) {
                Text("Drop audio or video").font(.title3.weight(.semibold))
                Text("or click to choose a file").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape.fill(Color.accentColor.opacity(targeted ? 0.08 : 0))
            shape.strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.35),
                               style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        }
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .contentShape(.rect)
        .onTapGesture { choosing = true }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            files.start(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func label(_ stage: SonioxFiles.Stage) -> String {
        switch stage {
        case .preparing: "Extracting audio…"
        case .uploading: "Uploading…"
        case .transcribing: "Transcribing…"
        }
    }
}

private struct Working: View {
    let title: String
    let detail: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            WaveBars()
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: detail)
            }
            Button("Cancel", action: cancel).buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tray icon's five bars, breathing while Soniox works.
private struct WaveBars: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(.tint)
                        .frame(width: 6, height: 12 + 30 * (0.5 + 0.5 * sin(t * 4.2 - Double(i) * 0.75)))
                }
            }
            .frame(height: 44)
        }
    }
}

// MARK: - Meeting

struct MeetingView: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TitleField(meeting: meeting)
            ZStack {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .animation(stateChange, value: meeting.status)
    }

    @ViewBuilder private var content: some View {
        switch meeting.status {
        case .idle:
            VStack(spacing: 16) {
                RecordingDot(active: false).scaleEffect(2.4)
                Text("Transcribe a meeting").font(.title3.weight(.semibold))
                Text("Your microphone and everything the Mac plays, with or without headphones.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Start Recording", systemImage: "record.circle", action: meeting.start)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.large)
            }
            .frame(maxWidth: 320)
            .transition(.blurReplace)
        case .done:
            VStack(alignment: .leading, spacing: 12) {
                if let start = meeting.startedAt, let end = meeting.endedAt {
                    Text(meetingSpan(start, end)).foregroundStyle(.secondary)
                }
                TranscriptPanel(text: meeting.transcript, again: ("New Meeting", {
                    meeting.reset()
                    meeting.start()
                }))
            }
            .transition(.blurReplace)
        case .recording, .paused, .finishing:
            live.transition(.blurReplace)
        }
    }

    private var live: some View {
        let paused = meeting.status == .paused
        return VStack(spacing: 16) {
            HStack(spacing: 10) {
                RecordingDot(active: meeting.status == .recording)
                Text(title)
                    .font(.headline)
                    .contentTransition(.opacity)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Duration.seconds(meeting.elapsed(at: context.date)),
                         format: .time(pattern: .hourMinuteSecond))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(tail.isEmpty ? "Words appear here as people speak." : tail)
                    .foregroundStyle(tail.isEmpty ? .secondary : .primary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let problem = meeting.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 12) {
                Button(action: meeting.togglePause) {
                    Label(paused ? "Continue" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 96)
                }
                .buttonStyle(.glass)
                Button(action: meeting.end) {
                    Label("End", systemImage: "stop.fill").frame(minWidth: 72)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
            .controlSize(.large)
            .disabled(meeting.status == .finishing)
        }
        .animation(.snappy, value: meeting.status)
        .animation(.snappy, value: meeting.problem)
    }

    private var title: String {
        switch meeting.status {
        case .paused: "Paused"
        case .finishing: "Finishing…"
        default: "Recording meeting"
        }
    }

    /// The live view shows the recent stretch; the finished transcript shows everything.
    /// Re-laying out an hour of text on every partial word would make typing elsewhere stutter.
    private var tail: String {
        let text = meeting.transcript
        guard text.count > 3000 else { return text }
        let cut = text.suffix(3000)
        return "…" + (cut.firstIndex(of: " ").map { cut[$0...] } ?? cut)
    }
}

/// Named at the start, renamable the whole time — even after the meeting ends.
private struct TitleField: View {
    @Bindable var meeting: Meeting
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Untitled meeting", text: $meeting.title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($focused)
                .onSubmit { focused = false }
            Image(systemName: "pencil")
                .foregroundStyle(.tertiary)
                .opacity(focused ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
        .onChange(of: focused) { if !focused { meeting.commitTitle() } }
        .onDisappear { meeting.commitTitle() }
    }
}

/// "Oct 13 · 14:05 – 15:12"
func meetingSpan(_ start: Date, _ end: Date) -> String {
    let time = Date.FormatStyle(date: .omitted, time: .shortened)
    return "\(start.formatted(.dateTime.month().day())) · \(start.formatted(time)) – \(end.formatted(time))"
}

/// Blinks while recording, with a ring rippling out like a broadcast light.
private struct RecordingDot: View {
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.red : .secondary)
            .frame(width: 10, height: 10)
            .background {
                if active {
                    Circle()
                        .stroke(.red, lineWidth: 1.5)
                        .phaseAnimator([false, true]) { ring, out in
                            ring.scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 0.7)
                        } animation: { out in out ? .easeOut(duration: 1.4) : nil }
                }
            }
            .phaseAnimator([true, false]) { dot, bright in
                dot.opacity(active && !bright ? 0.35 : 1)
            } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

// MARK: - Shared

private struct TranscriptPanel: View {
    let text: String
    let again: (title: String, action: () -> Void)

    var body: some View {
        VStack(spacing: 14) {
            ScrollView {
                Text(text.isEmpty ? "No speech was captured." : text)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack {
                Text("\(text.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button(again.title, action: again.action).buttonStyle(.glass)
                CopyButton(text: text).disabled(text.isEmpty)
            }
            .controlSize(.large)
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            Paste.writeClipboard(text)
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 72)
        }
        .buttonStyle(.glassProminent)
        .animation(.snappy, value: copied)
    }
}
