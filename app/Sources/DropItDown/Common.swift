import SwiftUI
import AppKit

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
