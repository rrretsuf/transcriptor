import AppKit
import SwiftUI

// Dynamic-island style surface: a black shape that hides inside the hardware
// notch while idle and drops out on a spring while dictation runs. The panel
// itself never resizes — only the shape inside it animates, which keeps every
// frame cheap and jitter-free. The minus button folds the island up to the
// notch's own height, leaving only a dot on the left and a plus on the right,
// so the screen behind stays visible.
@MainActor
final class NotchSurface {
    @Observable
    final class Model {
        var phase: Phase = .idle
        var tail = ""
        var message = ""
        var level: Double = 0
        var open = false
        var minimized = false
        var notch = CGSize(width: 180, height: 32)

        /// Messages still unfold the island: they are the one thing worth reading.
        var compact: Bool { minimized && message.isEmpty }
    }

    nonisolated static let rowHeight: CGFloat = 30
    nonisolated static let wing: CGFloat = 26
    nonisolated static let panelSize = CGSize(width: 560, height: 120)
    private static let tailLength = 90

    let model = Model()
    var onMinimize: ((Bool) -> Void)?
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
        host.sizingOptions = [] // fixed panel: skip intrinsic-size layout passes on every transcript update
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

    func show(minimized: Bool) {
        install()
        guard let panel else { return }
        hideTask?.cancel()
        let screen = screen()
        model.notch = notch(on: screen)
        model.phase = .recording
        model.message = ""
        model.tail = ""
        model.level = 0
        model.minimized = minimized
        model.open = false
        panel.setFrame(frame(on: screen), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Start inside the notch this frame, spring out on the next.
        DispatchQueue.main.async { [model] in
            withAnimation(Self.openSpring) { model.open = true }
        }
    }

    func idle() {
        model.phase = .idle
        model.level = 0
        withAnimation(Self.closeSpring) { model.open = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.panel?.alphaValue = 0
        }
    }

    func finishing() { model.phase = .finishing }

    func setMinimized(_ minimized: Bool) {
        withAnimation(minimized ? Self.closeSpring : Self.openSpring) { model.minimized = minimized }
    }

    func update(final: String, partial: String) {
        let text = Session.collapse(final + " " + partial)
        var tail = String(text.suffix(Self.tailLength))
        if tail.count < text.count, let space = tail.firstIndex(of: " ") {
            tail = String(tail[tail.index(after: space)...]) // cut on a word, not mid-word
        }
        // Unchanged writes would still invalidate the views that read them.
        if model.tail != tail { model.tail = tail }
    }

    /// Quantized so near-identical levels don't re-render the dot 25 times a second.
    func level(_ rms: Float) {
        let level = (min(1, Double(rms) * 8) * 20).rounded() / 20
        if model.level != level { model.level = level }
    }

    /// Flash the message in the open island, then retreat into the notch.
    func fail(_ message: String) {
        guard let panel, panel.alphaValue > 0 else { return }
        model.phase = .idle
        model.level = 0
        model.message = message
        withAnimation(Self.openSpring) { model.open = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.idle()
        }
    }

    /* --------------------------------- geometry -------------------------------- */

    // Opening overshoots a touch like the hardware island; closing is critically damped
    // and quicker, so the shape never bounces past the notch on its way home.
    private static var openSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.78)
    }
    private static var closeSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1)
    }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    nonisolated static func size(for model: Model) -> CGSize {
        guard model.open else { return model.notch }
        if model.compact { return CGSize(width: model.notch.width + wing * 2, height: model.notch.height) }
        return CGSize(width: model.notch.width + 88 * 2, height: model.notch.height + rowHeight)
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

/// Lets clicks fall through everywhere except the island.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var hit: (NSPoint) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hit(point) ? super.hitTest(point) : nil
    }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// Each subview reads only the model fields it draws, so a transcript update
// re-renders the caption, a level tick re-renders the dot, and the island
// shape is left alone.
private struct NotchContent: View {
    var model: NotchSurface.Model
    let surface: NotchSurface
    @Namespace private var namespace

    var body: some View {
        let size = NotchSurface.size(for: model)
        ZStack(alignment: .top) {
            if model.compact {
                // Hugs the notch: the dot sits just left of it, the plus just right.
                HStack(spacing: model.notch.width) {
                    Dot(model: model)
                        .matchedGeometryEffect(id: "dot", in: namespace)
                        .padding(.trailing, 6)
                        .frame(width: NotchSurface.wing, alignment: .trailing)
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 6)
                        .frame(width: NotchSurface.wing, alignment: .leading)
                }
                .frame(height: model.notch.height)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                HStack(spacing: 10) {
                    Dot(model: model)
                        .matchedGeometryEffect(id: "dot", in: namespace)
                    Caption(model: model)
                    MinimizeButton { surface.onMinimize?(true) }
                }
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .frame(width: size.width, height: NotchSurface.rowHeight)
                .offset(y: model.notch.height)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .opacity(model.open ? 1 : 0)
        .blur(radius: model.open ? 0 : 4)
        .frame(width: NotchSurface.panelSize.width, height: NotchSurface.panelSize.height, alignment: .top)
        .background(.black)
        // Clipping to the animated shape keeps text from spilling past the island while it shrinks.
        .clipShape(IslandShape(width: size.width, height: size.height, ear: model.open ? 10 : 0))
        .contentShape(IslandShape(width: size.width, height: size.height, ear: 0))
        .onTapGesture { if model.compact { surface.onMinimize?(false) } }
    }
}

private struct MinimizeButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "minus")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.35))
            .frame(width: 22, height: 22)
            .background(.white.opacity(hovering ? 0.14 : 0), in: Circle())
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture(perform: action)
    }
}

private struct Caption: View {
    var model: NotchSurface.Model

    var body: some View {
        Group {
            if !model.message.isEmpty {
                Text(model.message).foregroundStyle(Dot.color(for: model.phase))
            } else if model.tail.isEmpty {
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
        // Status swaps (Listening → Finishing, first words, messages) crossfade.
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .animation(.easeOut(duration: 0.18), value: model.message)
        .animation(.easeOut(duration: 0.18), value: model.tail.isEmpty)
    }

    private var status: String {
        model.phase == .finishing ? "Finishing…" : "Listening…"
    }
}

// Solid while recording, breathing with the voice level; dim otherwise.
private struct Dot: View {
    var model: NotchSurface.Model

    var body: some View {
        Circle()
            .fill(Self.color(for: model.phase))
            .frame(width: 7, height: 7)
            .scaleEffect(1 + model.level * 0.6)
            // A spring retargets with its velocity intact, so 25 Hz level ticks read as one fluid motion.
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: model.level)
            .animation(.easeOut(duration: 0.25), value: model.phase)
    }

    static func color(for phase: Phase) -> Color {
        switch phase {
        case .recording: .red
        case .finishing: .orange
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
