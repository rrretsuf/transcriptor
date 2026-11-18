import SwiftUI

// What macOS 13 and 14 lack: newer systems keep the effect, older ones get the plain version.

extension AnyTransition {
    @MainActor static var blurOrFade: AnyTransition {
        if #available(macOS 14, *) { AnyTransition(.blurReplace) } else { .opacity }
    }
}

extension View {
    @ViewBuilder func bounce(on value: some Equatable) -> some View {
        if #available(macOS 14, *) { symbolEffect(.bounce, value: value) } else { self }
    }

    @ViewBuilder func replacesSymbol() -> some View {
        if #available(macOS 14, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// Opens at the bottom and stays there as text grows.
    @ViewBuilder func followsBottom() -> some View {
        if #available(macOS 15, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else if #available(macOS 14, *) {
            defaultScrollAnchor(.bottom)
        } else { self }
    }

    /// A large capsule button; macOS 13 has neither the shape nor the size.
    @ViewBuilder func pill() -> some View {
        if #available(macOS 14, *) { buttonBorderShape(.capsule).controlSize(.extraLarge) } else { controlSize(.large) }
    }

    @ViewBuilder func noWritingTools() -> some View {
        if #available(macOS 15, *) { writingToolsBehavior(.disabled) } else { self }
    }

    @ViewBuilder func changed<V: Equatable>(_ value: V, _ action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14, *) { onChange(of: value) { action($1) } } else { onChange(of: value, perform: action) }
    }
}

struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    @ViewBuilder var actions: Actions

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(.secondary)
                Text(title).font(.title2.bold())
                Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center)
                actions.padding(.top, 6)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
