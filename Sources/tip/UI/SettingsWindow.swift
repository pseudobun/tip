import AppKit
import TipCore

/// Opens the one Settings window (`tip settings`, the Apple popup's "tip Settings…").
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var controller: SettingsController?

    func show(app: AppDelegate, page: String? = nil) {
        guard let bars = app.bars else { return }
        let c = controller ?? SettingsController(store: app.store, bars: bars)
        controller = c
        c.show(page: page)
    }

    /// The config was read again (saved here, in an editor, or reloaded): show its values.
    func configDidChange() { controller?.configDidChange() }
}

struct SettingsPage {
    let id: String
    let title: String
    let symbol: String
    let color: NSColor
}

/// The Settings window, laid out like paw's and hop's: pages on the left, the selected one's
/// values on the right. Every change is written to config.json5 at once through ConfigEdit
/// (comments kept), so the file stays the source of truth; the file watcher applies it.
final class SettingsWindow: NSWindow {
    static let size = NSSize(width: 880, height: 620)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "tip Settings"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        standardWindowButton(.zoomButton)?.isEnabled = false
    }

    /// tip has no main menu, so the usual shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), let c = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let selector: Selector? = switch (c, mods) {
        case ("w", .command), (",", .command): #selector(performClose(_:))
        case ("m", .command): #selector(performMiniaturize(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window = SettingsWindow()
    let store: ConfigStore
    let bars: BarManager
    let rows = Rows()
    private(set) var pageID = "general"
    private let sidebar = NSTableView()
    private let contentScroll = NSScrollView()
    let contentStack = NSStackView()
    private var previousApp: NSRunningApplication?
    /// The custom theme being edited on the Appearance page (its id).
    var editingTheme: String?
    var pendingThemeWrite: DispatchWorkItem?

    static let pages: [SettingsPage] = [
        SettingsPage(id: "general", title: "General", symbol: "gearshape.fill", color: .systemGray),
        SettingsPage(id: "appearance", title: "Appearance", symbol: "paintpalette.fill", color: .systemPurple),
        SettingsPage(id: "layout", title: "Layout", symbol: "rectangle.split.3x1.fill", color: .systemBlue),
        SettingsPage(id: "items", title: "Items", symbol: "square.grid.3x1.below.line.grid.1x2.fill", color: .systemOrange),
        SettingsPage(id: "plugins", title: "Plugins", symbol: "puzzlepiece.extension.fill", color: .systemGreen),
        SettingsPage(id: "permissions", title: "Permissions", symbol: "hand.raised.fill", color: .systemPink),
        SettingsPage(id: "about", title: "About", symbol: "info.circle.fill", color: .systemTeal),
    ]

    static let sidebarWidth: CGFloat = 224
    static let pad: CGFloat = 32

    init(store: ConfigStore, bars: BarManager) {
        self.store = store
        self.bars = bars
        super.init()
        build()
    }

    func show(page: String?) {
        if let page, Self.pages.contains(where: { $0.id == page.lowercased() }) { pageID = page.lowercased() }
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            window.center()
        }
        sidebar.reloadData()
        if let i = Self.pages.firstIndex(where: { $0.id == pageID }) { sidebar.selectRowIndexes([i], byExtendingSelection: false) }
        showPage()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func configDidChange() {
        guard window.isVisible else { return }
        // A text field being typed in keeps its page; anything else redraws with the new values.
        if let editor = window.firstResponder as? NSTextView, (editor.delegate as? NSView)?.isDescendant(of: contentStack) == true { return }
        showPage(keepScroll: true)
    }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        bars.previewTheme = nil
        NSColorPanel.shared.orderOut(nil)
        if let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
    }

    private func build() {
        window.delegate = self
        window.backgroundColor = SettingsTheme.background
        NSColorPanel.shared.showsAlpha = true
        let root = NSView()
        window.contentView = root

        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState
        side.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(side)
        let divider = Hairline(vertical: true)
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        sidebar.addTableColumn(NSTableColumn(identifier: .init("page")))
        sidebar.headerView = nil
        sidebar.backgroundColor = .clear
        sidebar.style = .sourceList
        sidebar.intercellSpacing = .zero
        sidebar.focusRingType = .none
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(sideScroll)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 46, left: Self.pad, bottom: Self.pad, right: Self.pad)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(contentStack)
        contentScroll.documentView = doc
        contentScroll.drawsBackground = false
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentScroll)

        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideScroll.topAnchor.constraint(equalTo: side.topAnchor, constant: 46),
            sideScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            sideScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentScroll.topAnchor.constraint(equalTo: root.topAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: doc.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { Self.pages.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 28 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = Self.pages[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: SettingsTheme.tile(page.symbol, page.color, size: 20))
        let label = NSTextField(labelWithString: page.title)
        label.font = SettingsTheme.sans(13)
        cell.textField = label
        for v in [icon, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, Self.pages[row].id != pageID else { return }
        window.makeFirstResponder(sidebar)
        pageID = Self.pages[row].id
        bars.previewTheme = nil
        showPage()
    }

    // MARK: Page

    func showPage(keepScroll: Bool = false) {
        let scroll = contentScroll.contentView.bounds.origin
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.reset()
        let page = Self.pages.first { $0.id == pageID } ?? Self.pages[0]
        let title = rows.label(page.title, size: 20, weight: .semibold)
        contentStack.addArrangedSubview(title)
        contentStack.setCustomSpacing(16, after: title)
        if let e = store.error { section(nil, [problem("Config error: \(e). tip keeps the last good config.", .systemRed)]) }
        else if !store.warnings.isEmpty, pageID == "general" {
            section(nil, store.warnings.prefix(8).map { problem($0, .systemOrange) })
        }
        switch pageID {
        case "general": generalPage()
        case "appearance": appearancePage()
        case "layout": layoutPage()
        case "items": itemsPage()
        case "plugins": pluginsPage()
        case "permissions": permissionsPage()
        default: aboutPage()
        }
        contentStack.layoutSubtreeIfNeeded()
        if keepScroll { contentScroll.contentView.scroll(to: scroll) } else { contentScroll.contentView.scroll(to: .zero) }
    }

    private func problem(_ text: String, _ color: NSColor) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = color
        let l = rows.label(text, size: 12)
        l.preferredMaxLayoutWidth = 520
        let s = rows.hstack([icon, l])
        s.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return s
    }

    /// A titled card of rows.
    func section(_ title: String?, _ views: [NSView], footer: String? = nil) {
        if let title {
            let t = rows.label(title, size: 13, weight: .semibold)
            contentStack.addArrangedSubview(t)
        }
        let card = Card()
        views.forEach(card.add)
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -2 * Self.pad).isActive = true
        if let footer {
            let f = rows.label(footer, size: 11, color: .secondaryLabelColor)
            f.preferredMaxLayoutWidth = SettingsWindow.size.width - Self.sidebarWidth - 2 * Self.pad
            contentStack.addArrangedSubview(f)
        }
        contentStack.setCustomSpacing(20, after: contentStack.arrangedSubviews.last!)
    }

    /// Writes one config key; shows why when it was refused.
    func write(_ path: [String], _ literal: String) {
        if let e = store.set(path, literal: literal) { alert("Not saved", e) }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.beginSheetModal(for: window)
    }
}
