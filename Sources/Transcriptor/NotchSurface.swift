import AppKit
import SwiftUI

// Dynamic-island style surface: a black shape that hides inside the hardware
// notch while idle and drops out on a spring while dictation runs. The panel
// itself never resizes — only the shape inside it animates, which keeps every
// frame cheap and jitter-free. A click on the island toggles the transcript
// feed: newest sentence on top, older ones sinking below.
@MainActor
final class NotchSurface {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    @Observable
    final class Model {
        var phase: Phase = .idle
        var tail = ""
        var feed: [Line] = []
        var message = ""
        var level: Double = 0
        var open = false
        var expanded = false
        var notch = CGSize(width: 180, height: 32)
    }

    nonisolated static let rowHeight: CGFloat = 30
    nonisolated static let feedHeight: CGFloat = 120
    nonisolated static let panelSize = CGSize(width: 560, height: 240)
    private static let tailLength = 90
    private static let feedLines = 6

    let model = Model()
    var onTap: (() -> Void)?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func install() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = IslandHostingView(rootView: NotchContent(model: model, surface: self))
        // Only the island itself takes clicks; the menu bar around it stays live.
        host.hit = { [model] point in
            guard model.open else { return false }
            let size = Self.size(for: model)
            let x = Self.panelSize.width / 2
            return abs(point.x - x) <= size.width / 2 && point.y >= Self.panelSize.height - size.height
        }
        panel.contentView = host
        panel.alphaValue = 0
        panel.setFrame(frame(on: screen()), display: false)
        panel.orderFrontRegardless() // warm paint, so the first show is instant
        self.panel = panel
    }

    func show(expanded: Bool) {
        install()
        guard let panel else { return }
        hideTask?.cancel()
        let screen = screen()
        model.notch = notch(on: screen)
        model.phase = .recording
        model.message = ""
        model.tail = ""
        model.feed = []
        model.level = 0
        model.expanded = expanded
        model.open = false
        panel.setFrame(frame(on: screen), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Start inside the notch this frame, spring out on the next.
        DispatchQueue.main.async { [model] in
            withAnimation(Self.spring) { model.open = true }
        }
    }

    func idle() {
        model.phase = .idle
        model.level = 0
        withAnimation(Self.spring) { model.open = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.panel?.alphaValue = 0
        }
    }

    func finishing() { model.phase = .finishing }
    func polishing() { model.phase = .polishing }

    func setExpanded(_ expanded: Bool) {
        withAnimation(Self.spring) { model.expanded = expanded }
    }

    func update(final: String, partial: String) {
        let text = collapseSpaces(final + " " + partial)
        var tail = String(text.suffix(Self.tailLength))
        if tail.count < text.count, let space = tail.firstIndex(of: " ") {
            tail = String(tail[tail.index(after: space)...]) // cut on a word, not mid-word
        }
        model.tail = tail
        let sentences = Self.sentences(text)
        model.feed = sentences.enumerated().reversed().prefix(Self.feedLines).map { Line(id: $0.offset, text: $0.element) }
    }

    func level(_ rms: Float) {
        model.level = min(1, Double(rms) * 8)
    }

    /// Flash the message in the open island, then retreat into the notch.
    func fail(_ message: String) {
        guard let panel, panel.alphaValue > 0 else { return }
        model.phase = .idle
        model.level = 0
        model.message = message
        withAnimation(Self.spring) { model.open = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.idle()
        }
    }

    /// Sentence boundaries: terminal punctuation followed by a space.
    nonisolated static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            if character == " ", ".!?…".contains(previous) {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /* --------------------------------- geometry -------------------------------- */

    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    nonisolated static func size(for model: Model) -> CGSize {
        guard model.open else { return model.notch }
        let wing: CGFloat = model.expanded ? 112 : 88
        let height = model.notch.height + rowHeight + (model.expanded ? feedHeight + 6 : 0)
        return CGSize(width: model.notch.width + wing * 2, height: height)
    }

    private func screen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The hardware cutout, measured from the menu bar's auxiliary areas.
    /// Screens without a notch get a virtual one so the island still hangs
    /// from the top edge.
    private func notch(on screen: NSScreen) -> CGSize {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 180, height: max(24, screen.safeAreaInsets.top))
        }
        return CGSize(width: right.minX - left.maxX, height: left.height)
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let size = Self.panelSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

private func collapseSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Lets clicks fall through everywhere except the island.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var hit: (NSPoint) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hit(point) ? super.hitTest(point) : nil
    }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct NotchContent: View {
    var model: NotchSurface.Model
    let surface: NotchSurface

    var body: some View {
        let size = NotchSurface.size(for: model)
        ZStack(alignment: .top) {
            IslandShape(width: size.width, height: size.height, ear: model.open ? 10 : 0)
                .fill(.black)
            VStack(spacing: 0) {
                row.frame(height: NotchSurface.rowHeight)
                if model.expanded {
                    Feed(lines: model.feed)
                        .frame(height: NotchSurface.feedHeight)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width)
            .offset(y: model.notch.height)
            .opacity(model.open ? 1 : 0)
        }
        .frame(width: NotchSurface.panelSize.width, height: NotchSurface.panelSize.height, alignment: .top)
        .contentShape(IslandShape(width: size.width, height: size.height, ear: 0))
        .onTapGesture { surface.onTap?() }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Dot(level: model.level, phase: model.phase)
            Group {
                if !model.message.isEmpty {
                    Text(model.message).foregroundStyle(Dot.color(for: model.phase))
                } else if model.expanded || model.tail.isEmpty {
                    Text(status).foregroundStyle(.white.opacity(0.45))
                } else {
                    // Starts centered; once it outgrows the row the newest words pin right
                    // and the older ones slide off into a soft fade. The overlay keeps the
                    // row's width fixed no matter how long the text gets.
                    Color.clear.overlay(alignment: .trailing) {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Text(model.tail).foregroundStyle(.white).fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)],
                                         startPoint: .leading, endPoint: .trailing))
                }
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
    }

    private var status: String {
        switch model.phase {
        case .polishing: "Polishing…"
        case .finishing: "Finishing…"
        default: "Listening…"
        }
    }
}

// Newest sentence on top, older ones sink and fade.
private struct Feed: View {
    let lines: [NotchSurface.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                Text(line.text)
                    .font(.system(size: 13, weight: index == 0 ? .medium : .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(index == 0 ? 1 : max(0.25, 0.7 - Double(index) * 0.12)))
                    .lineLimit(index == 0 ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            if lines.isEmpty {
                Text("Your words appear here as you speak.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: lines.map(\.id))
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipped()
    }
}

// Solid while recording, breathing with the voice level; dim otherwise.
private struct Dot: View {
    var level: Double
    var phase: Phase

    var body: some View {
        Circle()
            .fill(Self.color(for: phase))
            .frame(width: 7, height: 7)
            .scaleEffect(1 + level * 0.6)
            .animation(.linear(duration: 0.06), value: level)
            .animation(.easeOut(duration: 0.25), value: phase)
    }

    static func color(for phase: Phase) -> Color {
        switch phase {
        case .recording: .red
        case .finishing: .orange
        case .polishing: .blue
        case .idle: .white.opacity(0.4)
        }
    }
}

// The island: flush with the top edge, concave "ears" blending into the
// screen edge, rounded at the bottom. Centered in whatever rect it is given.
private struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var ear: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), ear) }
        set { width = newValue.first.first; height = newValue.first.second; ear = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(18, height / 2)
        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let top = rect.minY
        let bottom = top + height
        var path = Path()
        path.move(to: CGPoint(x: left - ear, y: top))
        path.addQuadCurve(to: CGPoint(x: left, y: top + ear), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: top + ear))
        path.addQuadCurve(to: CGPoint(x: right + ear, y: top), control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }
}
