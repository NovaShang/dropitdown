import AppKit

/// A small borderless panel that drops down under the menu-bar icon during a
/// drag, showing the four actions as drop targets. Releasing the drag on a
/// tile runs that action.
///
/// The window is built once (`prepare()`) and reused. Creating it up front,
/// before any drag, is what makes it reliably receive the in-flight drag's
/// events — a window first ordered in mid-drag often gets none.
@MainActor
final class ActionPanelController {
    /// Called when the drag is released on a tile, with the resolved URLs.
    var onPick: ((DropAction, [URL]) -> Void)?
    /// Hover bookkeeping so the parent can coordinate show/hide timing.
    var onPanelEntered: (() -> Void)?
    var onPanelExited: (() -> Void)?

    private var panel: NSPanel?
    private var tiles: [ActionTile] = []

    /// Build the (hidden) panel window. Safe to call repeatedly.
    func prepare() {
        guard panel == nil else { return }
        panel = makePanel()
    }

    func show(below iconRect: NSRect, highlight defaultAction: DropAction) {
        prepare()
        guard let panel, let content = panel.contentView else { return }

        for tile in tiles {
            tile.isDefault = (tile.action == defaultAction)
            tile.setHighlighted(false)
        }

        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        // Flush under the icon (no gap) so there's no dead zone between the
        // menu-bar icon and the panel for the drag to fall through.
        var x = iconRect.midX - size.width / 2
        let y = iconRect.minY - size.height
        if let screen = NSScreen.main {
            x = min(max(screen.visibleFrame.minX + 6, x),
                    screen.visibleFrame.maxX - size.width - 6)
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 96),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        tiles = DropAction.allCases.map { action in
            let tile = ActionTile(action: action)
            tile.onEnter = { [weak self] in self?.onPanelEntered?() }
            tile.onExit = { [weak self] in self?.onPanelExited?() }
            tile.onDrop = { [weak self] act, urls in self?.onPick?(act, urls) }
            return tile
        }
        tiles.forEach { stack.addArrangedSubview($0) }

        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        return panel
    }
}

/// One action as a vertical icon+label drop target.
final class ActionTile: NSView {
    let action: DropAction
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: ((DropAction, [URL]) -> Void)?

    /// Marks the configured default action with a subtle persistent tint.
    var isDefault = false { didSet { needsDisplay = true } }
    private var highlighted = false

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(action: DropAction) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: action.title)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = action.title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 92),
            heightAnchor.constraint(equalToConstant: 76),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
        ])

        registerForDraggedTypes(acceptedDropTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        highlighted = on
        needsDisplay = true
    }

    override func updateLayer() {
        if highlighted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        } else if isDefault {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setHighlighted(true)
        onEnter?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlighted(false)
        onExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let urls = resolveDropURLs(from: sender.draggingPasteboard)
        onDrop?(action, urls)
        return !urls.isEmpty
    }
}
