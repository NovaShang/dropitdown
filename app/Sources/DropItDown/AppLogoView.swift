import SwiftUI
import AppKit

/// Reads `AppIcon.icns` out of the running bundle and renders the highest-
/// quality representation as a SwiftUI Image. Used in the toolbar so the
/// product mark in the title bar matches the Dock icon.
struct AppLogoView: View {
    var body: some View {
        if let nsImage = Self.bundleIcon {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "tray.and.arrow.down.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
        }
    }

    private static let bundleIcon: NSImage? = {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }()
}
