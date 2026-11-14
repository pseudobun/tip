import AppKit

/// An installed or running app, as the picker lists it.
struct InstalledApp: Hashable {
    /// The name macOS shows for it (`NSRunningApplication.localizedName`), which config matches.
    let name: String
    let bundleID: String?
    let url: URL
}

/// Every app in the usual folders plus the running ones, by name. Scanned off the main thread,
/// cached, and scanned again each time a picker opens so new installs show up.
final class InstalledApps: @unchecked Sendable {
    static let shared = InstalledApps()

    private let lock = NSLock()
    private var cached: [InstalledApp] = []
    private var scanning = false

    static let folders: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications",
    ]

    var apps: [InstalledApp] { lock.withLock { cached } }

    /// Rescans; `done` runs on the main thread with the new list.
    func refresh(_ done: @escaping ([InstalledApp]) -> Void) {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> InstalledApp? in
                guard let name = app.localizedName, let url = app.bundleURL else { return nil }
                return InstalledApp(name: name, bundleID: app.bundleIdentifier, url: url)
            }
        let start = lock.withLock { () -> Bool in
            if scanning { return false }
            scanning = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var byName: [String: InstalledApp] = [:]
            for app in running { byName[app.name] = app }
            for folder in Self.folders {
                for url in Self.bundles(in: URL(fileURLWithPath: folder), depth: 2) {
                    let app = Self.describe(url)
                    if byName[app.name] == nil { byName[app.name] = app }
                }
            }
            let list = byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lock.withLock {
                cached = list
                scanning = false
            }
            DispatchQueue.main.async { done(list) }
        }
    }

    private static func bundles(in folder: URL, depth: Int) -> [URL] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for item in items {
            if item.pathExtension == "app" {
                found.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                found += bundles(in: item, depth: depth - 1)
            }
        }
        return found
    }

    /// The name macOS gives a running copy: the localized display name, else the bundle name,
    /// else the file name.
    static func describe(_ url: URL) -> InstalledApp {
        let bundle = Bundle(url: url)
        let info = (bundle?.infoDictionary ?? [:]).merging(bundle?.localizedInfoDictionary ?? [:]) { _, localized in localized }
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? fileName
        return InstalledApp(name: name, bundleID: bundle?.bundleIdentifier, url: url)
    }
}

/// A searchable list of apps in a popover. Click or ↵ picks; with `multiple`, clicks tick several
/// and ↵ or "Add" adds them (nothing ticked: the highlighted one).
final class AppPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let multiple: Bool
    private let onPick: ([InstalledApp]) -> Void
    private var all: [InstalledApp] = InstalledApps.shared.apps
    private var shown: [InstalledApp] = []
    private var checked: Set<String> = []
    private let search = NSSearchField()
    private let table = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private weak var popover: NSPopover?
    private static let iconCache = NSCache<NSURL, NSImage>()

    /// Shows a picker under `view`. `exclude`: names already chosen, left out of the list.
    @discardableResult
    static func show(from view: NSView, multiple: Bool, exclude: Set<String> = [],
                     _ onPick: @escaping ([InstalledApp]) -> Void) -> NSPopover {
        let picker = AppPicker(multiple: multiple, exclude: exclude, onPick: onPick)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        picker.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        picker.view.window?.makeFirstResponder(picker.search)
        return popover
    }

    /// The small button that opens a picker, for next to a text field.
    static func button(toolTip: String = "Choose an app", _ action: @escaping (NSButton) -> Void) -> NSButton {
        let b = ClosureButton(action)
        b.bezelStyle = .push
        b.image = NSImage(systemSymbolName: "app.badge.plus", accessibilityDescription: toolTip)
            ?? NSImage(systemSymbolName: "plus.app", accessibilityDescription: toolTip)
        b.imagePosition = .imageOnly
        b.toolTip = toolTip
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private let exclude: Set<String>

    private init(multiple: Bool, exclude: Set<String>, onPick: @escaping ([InstalledApp]) -> Void) {
        self.multiple = multiple
        self.exclude = exclude
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        search.placeholderString = "Search apps"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filter)

        let column = NSTableColumn(identifier: .init("app"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = multiple
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(commitSelection)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: multiple ? "Click to toggle · ↵ adds" : "Click or ↵ picks · names still work as /regex/ in the field")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        addButton.bezelStyle = .push
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(commitSelection)
        addButton.isHidden = !multiple
        let bottom = NSStackView(views: [hint, addButton])
        bottom.spacing = 8

        let stack = NSStackView(views: [search, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for v in [search, scroll, bottom] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 380)
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view = stack
        apply()
        InstalledApps.shared.refresh { [weak self] list in
            self?.all = list
            self?.apply()
        }
    }

    @objc private func filter() { apply() }

    private func apply() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = all.filter { !exclude.contains($0.name) }
        shown = q.isEmpty ? candidates : candidates
            .compactMap { app -> (InstalledApp, Int)? in
                let name = app.name.lowercased()
                if name.hasPrefix(q) { return (app, 0) }
                if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return (app, 1) }
                if name.contains(q) { return (app, 2) }
                if app.bundleID?.lowercased().contains(q) == true { return (app, 3) }
                return nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
            .map(\.0)
        table.reloadData()
        if !shown.isEmpty, !multiple { table.selectRowIndexes([0], byExtendingSelection: false) }
        updateAdd()
    }

    private func updateAdd() {
        addButton.title = checked.isEmpty ? "Add" : "Add \(checked.count)"
        addButton.isEnabled = !checked.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = shown[row]
        let icon = NSImageView()
        let key = app.url as NSURL
        if let cached = Self.iconCache.object(forKey: key) {
            icon.image = cached
        } else {
            let image = NSWorkspace.shared.icon(forFile: app.url.path)
            image.size = NSSize(width: 20, height: 20)
            Self.iconCache.setObject(image, forKey: key)
            icon.image = image
        }
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = NSTextField(labelWithString: app.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var views: [NSView] = [icon, name]
        if multiple {
            let mark = NSImageView(image: NSImage(systemSymbolName: checked.contains(app.name) ? "checkmark.circle.fill" : "circle",
                                                  accessibilityDescription: nil) ?? NSImage())
            mark.contentTintColor = checked.contains(app.name) ? .controlAccentColor : .tertiaryLabelColor
            views.insert(mark, at: 0)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        row.toolTip = app.bundleID
        return row
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard shown.indices.contains(row) else { return }
        if multiple {
            toggle(shown[row])
        } else {
            finish([shown[row]])
        }
    }

    private func toggle(_ app: InstalledApp) {
        if checked.contains(app.name) { checked.remove(app.name) } else { checked.insert(app.name) }
        if let i = shown.firstIndex(of: app) { table.reloadData(forRowIndexes: [i], columnIndexes: [0]) }
        updateAdd()
    }

    @objc private func commitSelection() {
        if multiple {
            if checked.isEmpty, shown.indices.contains(table.selectedRow) { toggle(shown[table.selectedRow]) }
            finish(all.filter { checked.contains($0.name) })
        } else if shown.indices.contains(table.selectedRow) {
            finish([shown[table.selectedRow]])
        }
    }

    private func finish(_ apps: [InstalledApp]) {
        guard !apps.isEmpty else { NSSound.beep(); return }
        popover?.close()
        onPick(apps)
    }

    // Arrows and ↵ in the search field drive the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !shown.isEmpty else { return true }
            let down = selector == #selector(NSResponder.moveDown(_:))
            let next = max(0, min(shown.count - 1, table.selectedRow + (down ? 1 : -1)))
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.close()
            return true
        default:
            return false
        }
    }
}

/// An NSButton that runs a closure, with itself as the argument.
final class ClosureButton: NSButton {
    private let run: (NSButton) -> Void

    init(_ run: @escaping (NSButton) -> Void) {
        self.run = run
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { run(self) }
}
