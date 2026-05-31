import SwiftUI
import AppKit

/// A two-pane master/detail split with an explicitly-controlled sidebar
/// width. Unlike `HSplitView`, the divider position is plain `@State` (here a
/// persisted binding): it changes *only* when the user drags the divider —
/// never when the panes rebuild on selection, search, or tab switch, which is
/// what made HSplitView's left column jump around. The detail pane absorbs
/// window resizing; the sidebar stays put.
struct SidebarSplit<Sidebar: View, Detail: View>: View {
    @Binding var width: Double
    var minWidth: Double = 280
    var maxWidth: Double = 600
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            sidebar()
                .frame(width: width)
                .frame(maxHeight: .infinity)
            divider
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? width
                                if dragStart == nil { dragStart = width }
                                width = min(max(minWidth, start + value.translation.width), maxWidth)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

/// Bridges a SwiftUI view to its hosting `NSWindow`. Used so the AppDelegate
/// can identify and control the WindowGroup's main window (show/hide/observe)
/// without guessing among `NSApp.windows`.
///
/// Resolution happens in `viewDidMoveToWindow` — i.e. the moment the content
/// view is installed into the window, which is *before* SwiftUI orders that
/// window on-screen. That's the only hook early enough for the delegate to
/// hide the window (no launch flash on a headless drop).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        ResolvingView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ResolvingView: NSView {
        let onResolve: (NSWindow) -> Void

        init(onResolve: @escaping (NSWindow) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onResolve(window) }
        }
    }
}

/// Universal placeholder for "nothing selected / nothing to show" states.
struct PlaceholderView: View {
    let systemImage: String
    let title: String
    let subtitle: String?

    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let s = subtitle {
                Text(s)
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 320)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// A list section header with the macOS sidebar small-caps style applied to
/// regular content sections.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 4)
    }
}
