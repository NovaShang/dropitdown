import AppKit
import OSLog

private let log = Logger(subsystem: "app.dropitdown.mac", category: "StatusItem")

/// Owns the menu-bar `NSStatusItem` and its drop interaction.
///
/// Interaction model:
/// - Drop files straight onto the icon → the **default** action (config).
/// - Hover-dwell while dragging → a panel of the four actions drops down;
///   release on a tile to run that action instead.
/// - Plain click → open the main window. Right/Control-click → a small menu
///   (Open / Settings / Quit) so a Dock-less agent is still controllable.
///
/// Accepts files, plain text, and images. Non-file drops are materialized to
/// temp files so the rest of the pipeline is unchanged.
@MainActor
final class StatusItemController: NSObject {
    /// Run `action` on the dropped items. `nil` action means "use default".
    var onAction: (([URL], DropAction?) -> Void)?
    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Supplies the current default action for the panel's highlight.
    var defaultAction: () -> DropAction = { .archive }

    private var statusItem: NSStatusItem?
    private let panel = ActionPanelController()
    private weak var dropZone: DropZoneView?
    private var spinner: NSProgressIndicator?

    /// Coalesces button↔panel hover transitions so moving the drag from the
    /// icon down into the panel doesn't dismiss it.
    private var hideWork: DispatchWorkItem?
    private var dwellWork: DispatchWorkItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.icon()
            button.toolTip = "DropItDown — drop files, text, or images here"

            let zone = DropZoneView(frame: button.bounds)
            zone.autoresizingMask = [.width, .height]
            zone.controller = self
            zone.button = button
            button.addSubview(zone)
            dropZone = zone
        }
        statusItem = item
        panel.onPick = { [weak self] action, urls in self?.finishDrop(urls: urls, action: action) }
        panel.onPanelEntered = { [weak self] in self?.cancelHide() }
        panel.onPanelExited = { [weak self] in self?.scheduleHide() }
        // Build the panel window up front (ordered out). A window that already
        // exists before the drag begins reliably receives the drag session's
        // events; one created mid-drag often does not.
        panel.prepare()
        log.info("status item installed")
    }

    func remove() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        panel.hide()
    }

    /// Reflect processing state in the menu bar: a small spinner replaces the
    /// tray glyph while a drop is being worked on.
    func setBusy(_ busy: Bool) {
        guard let button = statusItem?.button else { return }
        if busy {
            let spinner = self.spinner ?? makeSpinner(in: button)
            self.spinner = spinner
            button.image = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
            button.image = Self.icon()
        }
    }

    private func makeSpinner(in button: NSStatusBarButton) -> NSProgressIndicator {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isIndeterminate = true
        s.translatesAutoresizingMaskIntoConstraints = false
        // Insert below the drag overlay so it never intercepts drops.
        if let zone = dropZone {
            button.addSubview(s, positioned: .below, relativeTo: zone)
        } else {
            button.addSubview(s)
        }
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            s.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            s.widthAnchor.constraint(equalToConstant: 14),
            s.heightAnchor.constraint(equalToConstant: 14),
        ])
        return s
    }

    /// A custom mark matching the app icon: a wide funnel mouth that converges
    /// into a downward arrow ("funnel things down"). Drawn as one filled
    /// vector silhouette so it stays crisp at any size, and marked template so
    /// the menu bar tints it to match the bar's appearance.
    private static func icon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Coordinates: origin bottom-left. Mouth at top (y≈15), arrow tip
            // at bottom (y≈2.3); symmetric about x = 9.
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 2.5, y: 15))     // mouth top-left
            p.line(to: NSPoint(x: 15.5, y: 15))    // mouth top-right
            p.line(to: NSPoint(x: 10.3, y: 9.2))   // right wall → neck
            p.line(to: NSPoint(x: 10.3, y: 6))     // shaft right
            p.line(to: NSPoint(x: 12.6, y: 6))     // arrowhead right wing
            p.line(to: NSPoint(x: 9, y: 2.3))      // arrow tip
            p.line(to: NSPoint(x: 5.4, y: 6))      // arrowhead left wing
            p.line(to: NSPoint(x: 7.7, y: 6))      // shaft left
            p.line(to: NSPoint(x: 7.7, y: 9.2))    // neck → left wall
            p.close()
            NSColor.black.setFill()
            p.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Click / menu (called by the overlay)

    func clicked() { onOpen?() }

    func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open DropItDown", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit DropItDown", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func menuOpen() { onOpen?() }
    @objc private func menuSettings() { onSettings?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Drag coordination (called by the overlay / panel)

    /// Drag entered the icon — arm the dwell timer that reveals the panel.
    func dragEnteredButton() {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Drag left the icon — if it's not going into the panel, dismiss soon.
    func dragExitedButton() {
        dwellWork?.cancel(); dwellWork = nil
        scheduleHide()
    }

    /// A drop landed. `action == nil` ⇒ default (drop went to the icon).
    func finishDrop(urls: [URL], action: DropAction?) {
        dwellWork?.cancel(); dwellWork = nil
        cancelHide()
        panel.hide()
        guard !urls.isEmpty else { return }
        onAction?(urls, action)
    }

    private func showPanel() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        panel.show(below: screenRect, highlight: defaultAction())
    }

    private func scheduleHide() {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in self?.panel.hide() }
        hideWork = work
        // Generous so crossing the menu-bar boundary into the panel doesn't
        // dismiss it before the panel's own draggingEntered cancels the hide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }
}

/// Transparent overlay pinned over the status button. Owns the drag
/// destination and click handling so the system button instance is untouched.
final class DropZoneView: NSView {
    weak var controller: StatusItemController?
    weak var button: NSStatusBarButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(acceptedDropTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: clicks

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            controller?.showMenu()
        } else {
            controller?.clicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu()
    }

    // MARK: drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        button?.highlight(true)
        controller?.dragEnteredButton()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
        controller?.dragExitedButton()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let urls = resolveDropURLs(from: sender.draggingPasteboard)
        controller?.finishDrop(urls: urls, action: nil)
        return !urls.isEmpty
    }
}

// MARK: - Pasteboard → file URLs

/// Drag types we accept on the icon and the action tiles.
let acceptedDropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string, .URL, .tiff, .png]

/// Resolve a dragging pasteboard to file URLs the pipeline can process.
/// Real files pass through; plain text and images are written to temp files.
func resolveDropURLs(from pb: NSPasteboard) -> [URL] {
    let fileOpts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOpts) as? [URL], !urls.isEmpty {
        return urls
    }
    if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let image = images.first, let url = writeImageTemp(image) {
        return [url]
    }
    if let text = pb.string(forType: .string),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let url = writeTextTemp(text) {
        return [url]
    }
    return []
}

private func dropTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DropItDown-drops/\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func writeTextTemp(_ text: String) -> URL? {
    let url = dropTempDir().appendingPathComponent("Dropped text.txt")
    do { try text.write(to: url, atomically: true, encoding: .utf8); return url }
    catch { return nil }
}

func writeImageTemp(_ image: NSImage) -> URL? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = dropTempDir().appendingPathComponent("Dropped image.png")
    do { try png.write(to: url); return url }
    catch { return nil }
}
