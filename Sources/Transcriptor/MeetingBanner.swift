import AppKit
import SwiftUI

// Sleek floating pill that drops directly beneath Transcriptor's menu bar icon
// when a live meeting is detected. Non-activating so it never steals focus,
// concentric 48pt capsule geometry (24pt outer = 15pt inner + 9pt padding),
// and origin-aware motion anchored to the menu bar item.
@MainActor
final class MeetingBanner {
    final class Model: ObservableObject {
        @Published var meeting: DetectedMeeting?
        @Published var open = false
        @Published var anchorX: CGFloat = 0.5
    }

    nonisolated static let cardWidth: CGFloat = 356
    nonisolated static let cardHeight: CGFloat = 48
    nonisolated static let horizontalMargin: CGFloat = 36
    nonisolated static let topGap: CGFloat = 7
    nonisolated static let bottomMargin: CGFloat = 40
    nonisolated static let panelSize = CGSize(
        width: cardWidth + horizontalMargin * 2,
        height: topGap + cardHeight + bottomMargin
    )

    let model = Model()
    var onStart: ((DetectedMeeting) -> Void)?
    var onDismiss: (() -> Void)?
    var anchorRect: (() -> NSRect?)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var visible = false

    func install() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true

        let host = BannerHostingView(rootView: MeetingBannerContent(model: model, banner: self))
        host.sizingOptions = []
        host.hit = { [model] point in
            guard model.open else { return false }
            let cardTop = Self.panelSize.height - Self.topGap
            let cardBottom = cardTop - Self.cardHeight
            let cardLeft = Self.horizontalMargin
            let cardRight = cardLeft + Self.cardWidth
            return point.x >= cardLeft && point.x <= cardRight
                && point.y >= cardBottom && point.y <= cardTop
        }
        panel.contentView = host
        panel.alphaValue = 0
        self.panel = panel
    }

    func show(_ meeting: DetectedMeeting) {
        install()
        guard let panel, let placement = computePlacement() else { return }
        hideTask?.cancel()
        visible = true

        model.meeting = meeting
        model.anchorX = placement.anchorX
        model.open = false

        panel.setFrame(placement.frame, display: false)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.visible else { return }
            withAnimation(Self.openAnimation) { self.model.open = true }
        }
    }

    func update(_ meeting: DetectedMeeting) {
        guard model.open else { return show(meeting) }
        withAnimation(.easeOut(duration: 0.18)) {
            model.meeting = meeting
        }
    }

    func hide() {
        guard let panel, panel.alphaValue > 0 || model.open else { return }
        visible = false
        panel.ignoresMouseEvents = true
        withAnimation(Self.closeAnimation) { model.open = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, !self.model.open else { return }
            self.panel?.alphaValue = 0
            self.panel?.orderOut(nil)
            self.model.meeting = nil
        }
    }

    func triggerStart() {
        guard let meeting = model.meeting else { return }
        hide()
        onStart?(meeting)
    }

    func triggerDismiss() {
        hide()
        onDismiss?()
    }

    // MARK: - Positioning & motion

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Sub-300ms origin-aware enter; noticeably snappier exit (asymmetric timing).
    private static var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.26, dampingFraction: 0.90)
    }

    private static var closeAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.16)
    }

    private func computePlacement() -> (frame: NSRect, anchorX: CGFloat)? {
        let iconRect = resolveStatusItemRect()
        guard let screen = screenFor(rect: iconRect) else { return nil }
        let visible = screen.visibleFrame
        let screenEdgePad: CGFloat = 12

        let desiredCardMinX: CGFloat
        let menuBottomY: CGFloat
        if let iconRect {
            desiredCardMinX = iconRect.midX - Self.cardWidth / 2
            menuBottomY = min(iconRect.minY, visible.maxY)
        } else {
            desiredCardMinX = visible.maxX - Self.cardWidth - screenEdgePad
            menuBottomY = visible.maxY
        }

        let minCardX = visible.minX + screenEdgePad
        let maxCardX = max(minCardX, visible.maxX - Self.cardWidth - screenEdgePad)
        let cardMinX = min(max(desiredCardMinX, minCardX), maxCardX)

        let iconMidX = iconRect?.midX ?? (cardMinX + Self.cardWidth - 28)
        let normalizedAnchor = min(max((iconMidX - cardMinX) / Self.cardWidth, 0.14), 0.88)

        let panelOrigin = NSPoint(
            x: cardMinX - Self.horizontalMargin,
            y: menuBottomY - Self.panelSize.height
        )
        return (NSRect(origin: panelOrigin, size: Self.panelSize), normalizedAnchor)
    }

    private func resolveStatusItemRect() -> NSRect? {
        if let rect = anchorRect?(), rect.width > 0, rect.height > 0 {
            return rect
        }
        return NSApp.windows.first { window in
            let name = String(describing: type(of: window))
            return name.contains("StatusBar")
                && window.frame.width > 0
                && window.frame.width < 120
                && window.frame.height > 0
                && window.frame.height <= 44
        }?.frame
    }

    private func screenFor(rect: NSRect?) -> NSScreen? {
        if let rect {
            let center = NSPoint(x: rect.midX, y: rect.midY)
            if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return match
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

private final class BannerHostingView<Content: View>: NSHostingView<Content> {
    var hit: (NSPoint) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hit(point) ? super.hitTest(point) : nil
    }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - SwiftUI Pill

private struct MeetingBannerContent: View {
    @ObservedObject var model: MeetingBanner.Model
    let banner: MeetingBanner
    @Environment(\.colorScheme) private var colorScheme

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let meeting = model.meeting {
                pill(for: meeting)
                    .padding(.top, MeetingBanner.topGap)
                    .opacity(model.open ? 1 : 0)
                    .scaleEffect(
                        model.open || reduceMotion ? 1 : 0.95,
                        anchor: UnitPoint(x: model.anchorX, y: 0)
                    )
                    .offset(y: model.open || reduceMotion ? 0 : -6)
            }
        }
        .frame(width: MeetingBanner.panelSize.width, height: MeetingBanner.panelSize.height, alignment: .top)
    }

    private func pill(for meeting: DetectedMeeting) -> some View {
        let outerRadius: CGFloat = MeetingBanner.cardHeight / 2 // 24pt
        let shape = Capsule(style: .continuous)
        let isDark = colorScheme == .dark

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 5.5, height: 5.5)
                    Text(meeting.isGenericTitle ? "Meeting detected" : meeting.source)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(meeting.title)

            HStack(spacing: 5) {
                Button(action: banner.triggerStart) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: .systemRed))
                            .frame(width: 6.5, height: 6.5)
                        Text("Transcribe")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    // Optical alignment: icon-side padding = text-side padding - 2pt.
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .frame(height: 30)
                }
                .buttonStyle(TranscribePillButtonStyle())
                .fixedSize()

                Button(action: banner.triggerDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(DismissCircleButtonStyle())
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .fixedSize()
            }
        }
        // Concentric math: 24pt outer radius = 15pt inner radius + 9pt vertical/trailing padding.
        .padding(.leading, 18)
        .padding(.trailing, 9)
        .frame(width: MeetingBanner.cardWidth, height: MeetingBanner.cardHeight)
        .background(BannerSurface(cornerRadius: outerRadius))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07),
                lineWidth: 0.5
            )
        }
        // Layered shadow-border: crisp contact ring + soft lift, never muddy.
        .shadow(color: .black.opacity(isDark ? 0.36 : 0.10), radius: 14, x: 0, y: 6)
        .shadow(color: .black.opacity(isDark ? 0.20 : 0.06), radius: 2, x: 0, y: 1)
    }
}

/// Elevated tactile pill that reads unmistakably active inside a non-activating
/// panel without heavy dark slabs or screaming neon fills.
private struct TranscribePillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        let isDark = colorScheme == .dark
        let fill: Color = if isDark {
            Color.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.19 : 0.13)
        } else {
            Color.white.opacity(configuration.isPressed ? 0.88 : hovering ? 1.0 : 0.94)
        }

        configuration.label
            .foregroundStyle(.primary)
            .background {
                shape
                    .fill(fill)
                    .overlay {
                        shape.strokeBorder(
                            isDark
                                ? Color.white.opacity(hovering ? 0.20 : 0.12)
                                : Color.black.opacity(hovering ? 0.11 : 0.07),
                            lineWidth: 0.5
                        )
                    }
            }
            .shadow(
                color: .black.opacity(isDark ? 0 : hovering ? 0.09 : 0.06),
                radius: hovering ? 4 : 2.5,
                x: 0,
                y: 1
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

private struct DismissCircleButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? .primary : .secondary)
            .background {
                Circle().fill(
                    Color.primary.opacity(configuration.isPressed ? 0.13 : hovering ? 0.08 : 0.03)
                )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// Real behind-window Liquid Glass on macOS 26+, masked vibrancy on macOS 13–25.
private struct BannerSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26, *) {
            GlassBackdrop(cornerRadius: cornerRadius)
        } else {
            VisualEffectBackdrop(material: .popover, cornerRadius: cornerRadius)
        }
    }
}

@available(macOS 26, *)
private struct GlassBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
