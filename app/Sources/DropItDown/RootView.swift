import SwiftUI
import AppKit
import UserNotifications

/// Open the Settings scene via AppKit. `@Environment(\.openSettings)` only
/// exists in newer SDKs (it fails to compile against the macOS 14 SDK CI
/// uses), so go through the responder chain — `showSettingsWindow:` on
/// macOS 13+, falling back to the old `showPreferencesWindow:` name.
@MainActor
func openSettingsWindow() {
    // The SwiftUI `Settings` scene + `showSettingsWindow:` is unreliable in
    // accessory (menu-bar) mode, so the AppDelegate hosts its own preferences
    // window. Route everyone through it via a notification.
    NotificationCenter.default.post(name: .dropItDownOpenSettings, object: nil)
}

enum Tab: Hashable, CaseIterable {
    case history
    case notes

    var label: String {
        switch self {
        case .history: return "History"
        case .notes:   return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .notes:   return "doc.text"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var config: ConfigStore
    @State private var tab: Tab = .history
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if !config.hasLoadedOnce {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if config.needsSetup {
                OnboardingView()
            } else {
                mainContent
            }
        }
        .task {
            history.refresh()
            config.refresh()
        }
    }

    private var brandLabel: some View {
        HStack(spacing: 8) {
            AppLogoView()
                .frame(width: 22, height: 22)
            Text("DropItDown")
                .font(.headline)
        }
        .padding(.trailing, 8)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            NotificationHint()
            Group {
                switch tab {
                case .history: HistoryView(searchText: $searchText)
                case .notes:   NotesView()
                }
            }
        }
        .toolbar {
            // The logo + brand belong to the title bar, not a control. On the
            // macOS 26 SDK (Liquid Glass) every custom toolbar item is given a
            // glass "capsule" background by default, which makes the brand look
            // like a button — opt it out so it reads flush with the title bar.
            //   • `if #available` guards the runtime (symbol only on macOS 26+).
            //   • `#if compiler(>=6.2)` guards the SDK: the release build links
            //     against the macOS 14 SDK where this symbol doesn't exist, so
            //     even referencing it inside `#available` wouldn't compile there.
            //     (That older-SDK build has no glass capsule to begin with.)
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { brandLabel }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { brandLabel }
            }
            #else
            ToolbarItem(placement: .navigation) { brandLabel }
            #endif
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Label(t.label, systemImage: t.systemImage)
                            .labelStyle(.titleAndIcon)
                            .tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            // Gear + search live in one trailing group so they sit flush
            // against each other — no stray gap between them.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")

                if tab == .history {
                    SearchField(text: $searchText, prompt: "Search history")
                        .frame(width: 200)
                }
            }
        }
    }
}

/// Native `NSSearchField` wrapped for SwiftUI so we can place it inside a
/// toolbar group next to other controls (SwiftUI's `.searchable` always
/// floats to the far edge with its own spacing, which left an awkward gap).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}

/// A thin banner shown only when macOS notification permission is denied.
/// For a use-once-and-die app the notification *is* the result feedback, so
/// a silent denial would leave the user with no signal at all.
struct NotificationHint: View {
    @State private var denied = false
    @State private var dismissed = false

    var body: some View {
        Group {
            if denied && !dismissed {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(.orange)
                    Text("Notifications are off — you won't see archive results when a drop finishes.")
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button("Open Settings") { openNotificationSettings() }
                    Button {
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                .overlay(Divider(), alignment: .bottom)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let isDenied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { self.denied = isDenied }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
