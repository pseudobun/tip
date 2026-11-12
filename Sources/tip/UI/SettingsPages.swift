import AppKit
import TipCore

extension SettingsController {
    // MARK: General

    func generalPage() {
        let c = store.config
        section("Bar", [
            rows.row("Height", "Points; islands sit centred in it.", rows.number(c.bar.height, range: 20...80) { [unowned self] v in
                write(["bar", "height"], Rows.fmt(v))
            }),
            rows.row("Position", nil, rows.popup(["top", "bottom"], c.bar.position, titles: ["Top", "Bottom"]) { [unowned self] v in
                write(["bar", "position"], ConfigEdit.literal(v))
            }),
            rows.row("Left margin", "25 lines up with paw's window edges.", rows.number(c.bar.margin.left, range: 0...400) { [unowned self] v in
                write(["bar", "margin", "left"], Rows.fmt(v))
            }),
            rows.row("Right margin", nil, rows.number(c.bar.margin.right, range: 0...400) { [unowned self] v in
                write(["bar", "margin", "right"], Rows.fmt(v))
            }),
            rows.row("Displays", "Which displays get a bar.", rows.popup(["all", "main"], c.bar.displays.first ?? "all",
                                                                          titles: ["All displays", "Main display only"]) { [unowned self] v in
                write(["bar", "displays"], v == "all" ? "[]" : "[\"main\"]")
            }),
            rows.row("Center zone from", "Displays narrower than this (points) hide the center zone.",
                     rows.number(c.bar.minCenterWidth, range: 0...6000, step: 100) { [unowned self] v in
                         write(["bar", "minCenterWidth"], Rows.fmt(v))
                     }),
        ])
        section("Zen mode", [
            rows.row("Hotkey", "Toggles zen mode, e.g. ctrl+alt+z. Clicking the clock does too.",
                     rows.field(c.zen.hotkey, width: 160, placeholder: "ctrl+alt+z", mono: true) { [unowned self] v in
                         write(["zen", "hotkey"], ConfigEdit.literal(v.trimmingCharacters(in: .whitespaces)))
                     }),
            rows.row("Keep", "Items still shown in zen mode, comma separated.",
                     rows.field(c.zen.keep.joined(separator: ", "), width: 260, mono: true) { [unowned self] v in
                         write(["zen", "keep"], ConfigEdit.literal(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
                     }),
        ])
        section("Animation", [
            rows.row("Animate changes", "Islands glide when their width changes; off under Reduce Motion.",
                     rows.toggle(c.animation.enabled) { [unowned self] on in write(["animation", "enabled"], ConfigEdit.literal(on)) }),
            rows.row("Duration", "Milliseconds.", rows.number(c.animation.durationMs, range: 0...2000, step: 10) { [unowned self] v in
                write(["animation", "durationMs"], Rows.fmt(v))
            }),
            rows.row("Easing", nil, rows.popup(Easing.names, c.animation.easing) { [unowned self] v in
                write(["animation", "easing"], ConfigEdit.literal(v))
            }),
        ])
        section("Startup and updates", [
            rows.row("Open at login", nil, rows.toggle(c.openAtLogin) { [unowned self] on in write(["openAtLogin"], ConfigEdit.literal(on)) }),
            rows.row("Check for updates", "Daily; downloads in the background, installs when tip quits.",
                     rows.toggle(c.updates.check) { [unowned self] on in write(["updates", "check"], ConfigEdit.literal(on)) }),
            rows.row("Install automatically", "tip restarts by itself.",
                     rows.toggle(c.updates.automatic) { [unowned self] on in write(["updates", "automatic"], ConfigEdit.literal(on)) }),
            rows.row("Channel", nil, rows.popup(["auto", "stable", "beta"], c.updates.channel, titles: ["Automatic", "Stable", "Beta"]) { [unowned self] v in
                write(["updates", "channel"], ConfigEdit.literal(v))
            }),
        ], footer: "Everything here is a key in \(store.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")); edits keep its comments.")
        section(nil, [rows.row("Config file", store.url.path, rows.hstack([
            rows.button("Open") { [unowned self] in NSWorkspace.shared.open(store.url) },
            rows.button("Reveal") { [unowned self] in NSWorkspace.shared.activateFileViewerSelecting([store.url]) },
            rows.button("Reload") { [unowned self] in store.load() },
        ]))])
    }

    // MARK: Layout

    func layoutPage() {
        let c = store.config
        let keys = ["default", "builtin", "external"] + c.layout.keys.filter { !["default", "builtin", "external"].contains($0) }.sorted()
        let ids = c.items.keys.sorted()
        for key in keys {
            let z = c.layout[key] ?? TipConfig.Zones()
            let title = key == "default" ? "Every display" : key == "builtin" ? "Built-in display (notch)" : key == "external" ? "External displays" : key
            var views: [NSView] = []
            for (zone, value) in [("left", z.left), ("center", z.center), ("right", z.right)] {
                let field = IslandField(islands: value, inherits: key != "default")
                field.onChange = { [unowned self] islands in
                    if let islands {
                        write(["layout", key, zone], "[" + islands.map { "[" + $0.map(ConfigEdit.literal).joined(separator: ", ") + "]" }.joined(separator: ", ") + "]")
                    } else {
                        _ = store.remove(["layout", key, zone])
                    }
                }
                views.append(rows.row(zone.capitalized, key == "default" ? nil : "Empty: as on every display.", field))
            }
            section(title, views)
        }
        section("Add a display", [rows.row("Display", "Its own zones override the ones above.", rows.popup(
            [""] + bars.displays.map(\.name).filter { !c.layout.keys.contains($0) }, "",
            titles: ["Choose…"] + bars.displays.map(\.name).filter { !c.layout.keys.contains($0) }) { [unowned self] name in
                guard !name.isEmpty else { return }
                write(["layout", name], "{ center: [] }")
            })],
            footer: "Islands are separated by | and items inside one island by +, e.g. \"cpu + net + battery | clock\". Drag text between fields freely. Items: \(ids.joined(separator: ", ")).")
    }

    // MARK: Items

    func itemsPage() {
        let c = store.config
        let used = Set(c.layout.values.flatMap(\.all))
        for (id, item) in c.items.sorted(by: { $0.key < $1.key }) {
            let kind = item.provider
            let spec = ProviderCatalog.spec(kind)
            var views: [NSView] = []
            let head = rows.row("\(id)", "\(spec?.name ?? kind) — \(spec?.summary ?? "")" + (used.contains(id) ? "" : " Not in the layout."),
                                rows.hstack([
                                    rows.button("Popup") { [unowned self] in bars.perform(.popup, item: id) },
                                    rows.button("Remove") { [unowned self] in write(["items", id], "null") },
                                ]))
            views.append(head)
            for opt in spec?.options ?? [] where opt.kind != .rows {
                views.append(optionRow(id, item, opt))
            }
            for key in ["click", "rightClick"] {
                views.append(rows.row(key == "click" ? "Click" : "Right click", "An action: zen, popup, toggle-label, open:<url>, app:<name>, shell:<cmd>, paw:<cmd>…",
                                      rows.field(item.string(key) ?? "", width: 240, placeholder: "default", mono: true) { [unowned self] v in
                                          if v.isEmpty { _ = store.remove(["items", id, key]) } else { write(["items", id, key], ConfigEdit.literal(v)) }
                                      }))
            }
            section(nil, views)
        }
        section("New item", [rows.row("Provider", "Adds an item; then place it on the Layout page.", rows.popup(
            [""] + ProviderCatalog.all.map(\.id), "", titles: ["Choose…"] + ProviderCatalog.all.map(\.name)) { [unowned self] kind in
                guard !kind.isEmpty else { return }
                var id = kind, n = 2
                while store.config.items[id] != nil { id = "\(kind)\(n)"; n += 1 }
                write(["items", id], kind == "script" ? "{ command: \"date +%H:%M\", interval: 60 }" : "{ provider: \(ConfigEdit.literal(kind)) }")
            })])
    }

    private func optionRow(_ id: String, _ item: ItemConfig, _ opt: ProviderSpec.Option) -> NSView {
        let path = ["items", id, opt.key]
        let current = item[opt.key] ?? opt.fallback
        let control: NSView
        switch opt.kind {
        case .toggle:
            control = rows.toggle(current.bool ?? false) { [unowned self] on in write(path, ConfigEdit.literal(on)) }
        case .number:
            control = rows.number(current.number ?? 0, range: 0...100_000) { [unowned self] v in write(path, Rows.fmt(v)) }
        case .choice:
            control = rows.popup(opt.choices, current.string ?? opt.choices.first ?? "") { [unowned self] v in write(path, ConfigEdit.literal(v)) }
        case .list:
            control = rows.field((current.strings ?? []).joined(separator: ", "), width: 260, mono: true) { [unowned self] v in
                write(path, ConfigEdit.literal(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            }
        case .text, .rows:
            control = rows.field(current.string ?? "", width: 260, mono: true) { [unowned self] v in write(path, ConfigEdit.literal(v)) }
        }
        return rows.row(opt.key, opt.help, control)
    }

    // MARK: Plugins

    func pluginsPage() {
        let c = store.config
        let all = bars.plugins.all
        if all.isEmpty { section(nil, [rows.row("No plugins", "Install one below, or link a folder: tip plugins link <dir>.", nil)]) }
        for p in all {
            let m = p.manifest
            let state = bars.plugins.state(m.id)
            let enabled = !c.plugins.disabled.contains(m.id)
            let source = p.bundled ? "bundled with tip" : p.linked ? "linked: \(p.directory.path)" : "installed"
            var help = "\(m.summary ?? "") \(m.version), \(source). \(state.rawValue)"
            if let e = bars.plugins.lastError(m.id), !e.isEmpty { help += ": \(e)" }
            if !m.permissions.isEmpty { help += "\nUses: \(m.permissions.joined(separator: ", "))" }
            var views: [NSView] = [rows.row(m.name, help, rows.hstack([
                rows.button("Logs") { [unowned self] in alert("\(m.name) log", bars.plugins.logs(m.id).suffix(30).joined(separator: "\n")) },
                rows.button("Restart") { [unowned self] in bars.plugins.restart(m.id) },
                rows.toggle(enabled) { [unowned self] on in
                    var list = store.config.plugins.disabled.filter { $0 != m.id }
                    if !on { list.append(m.id) }
                    write(["plugins", "disabled"], ConfigEdit.literal(list))
                },
            ]))]
            let settings = c.plugins.settings[m.id]
            for pref in m.preferences {
                let path = ["plugins", m.id, pref.id]
                let current = settings?[pref.id] ?? pref.default ?? .null
                let control: NSView
                switch pref.type {
                case "secret":
                    let f = NSSecureTextField(string: Keychain.read(plugin: m.id, key: pref.id) ?? "")
                    f.placeholderString = current.string.map { $0.isEmpty ? "" : "from config: \($0)" } ?? "in the Keychain"
                    f.widthAnchor.constraint(equalToConstant: 240).isActive = true
                    let h = rows.handler { [unowned self] sender in
                        Keychain.write(plugin: m.id, key: pref.id, value: (sender as? NSTextField)?.stringValue)
                        bars.plugins.sync(config: store.config, store: store)
                    }
                    f.target = h
                    f.action = #selector(Handler.fire(_:))
                    control = f
                case "toggle":
                    control = rows.toggle(current.bool ?? false) { [unowned self] on in write(path, ConfigEdit.literal(on)) }
                case "number":
                    control = rows.number(current.number ?? 0, range: 0...1_000_000) { [unowned self] v in write(path, Rows.fmt(v)) }
                case "choice":
                    control = rows.popup(pref.options ?? [], current.string ?? "") { [unowned self] v in write(path, ConfigEdit.literal(v)) }
                case "list":
                    control = rows.field((current.strings ?? []).joined(separator: ", "), width: 240, mono: true) { [unowned self] v in
                        write(path, ConfigEdit.literal(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
                    }
                default:
                    control = rows.field(current.string ?? "", width: 240, placeholder: pref.placeholder, mono: true) { [unowned self] v in
                        write(path, ConfigEdit.literal(v))
                    }
                }
                views.append(rows.row(pref.title ?? pref.id, pref.help, control))
            }
            let shown = c.items.filter { $0.value.string("plugin") == m.id }.map(\.key)
            if shown.isEmpty {
                views.append(rows.row("Not shown", "Add it as an item to place it in the layout.", rows.button("Add item") { [unowned self] in
                    let id = String(m.id.split(separator: ".").last ?? "plugin")
                    write(["items", id], "{ plugin: \(ConfigEdit.literal(m.id)) }")
                }))
            }
            section(nil, views)
        }
        let field = NSTextField(string: "")
        field.placeholderString = "owner/repo, owner/repo@v1.0.0 or a .tipplugin.zip URL"
        field.font = SettingsTheme.mono(12)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        section("Install", [rows.row("From GitHub", "A plugin is a program that runs as you. Install only what you trust.", rows.hstack([
            field,
            rows.button("Install") { [unowned self] in install(field.stringValue) },
        ]))], footer: "Plugins live in \(PluginHost.userFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Write your own in any language: docs/plugins.md.")
    }

    private func install(_ source: String) {
        let s = source.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Install \(s)?"
        a.informativeText = "A plugin runs as you, with access to your files and the network, like any program you download."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            DispatchQueue.global().async {
                let result = Result { try PluginInstaller.install(s) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case .success(let m): self?.alert("Installed \(m.name)", "Add it as an item on this page to show it.")
                        case .failure(let e): self?.alert("Not installed", "\(e)")
                        }
                        self?.showPage(keepScroll: true)
                    }
                }
            }
        }
    }

    // MARK: Permissions

    func permissionsPage() {
        section(nil, [
            rows.row("Accessibility", "Not needed: tip draws its own panels and reads no other app's windows.", status("checkmark.circle.fill", .systemGreen)),
            rows.row("Screen Recording", "Not needed.", status("checkmark.circle.fill", .systemGreen)),
            rows.row("Location", "Only for the Wi-Fi name in the network popup; macOS asks the first time it's shown.", status("minus.circle", .secondaryLabelColor)),
            rows.row("Plugins", "Each runs as its own responsible process: macOS asks for its permissions in its own name, never tip's.",
                     status("checkmark.circle.fill", .systemGreen)),
        ], footer: "Workspaces come from paw's socket: paw holds Accessibility, tip needs none.")
    }

    private func status(_ symbol: String, _ color: NSColor) -> NSImageView {
        let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        v.contentTintColor = color
        return v
    }

    // MARK: About

    func aboutPage() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = rows.label("tip", size: 24, weight: .semibold)
        let version = rows.label("Version \(AppPaths.version)", size: 12, color: .secondaryLabelColor)
        let tag = rows.label("A fast, native menu bar. Sibling of paw and hop.", size: 12, color: .secondaryLabelColor)
        let col = NSStackView(views: [icon, name, version, tag])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 6
        col.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        section(nil, [col])
        var views: [NSView] = []
        if Updater.shared.isAvailable {
            views.append(rows.row("Updates", Updater.shared.state.text, rows.button(Updater.shared.pending.map { "Install \($0)" } ?? "Check Now") {
                Updater.shared.onResult = { [weak self] _ in self?.showPage(keepScroll: true) }
                if Updater.shared.pending != nil { Updater.shared.installNow() } else { Updater.shared.checkOnly() }
            }))
        }
        views.append(rows.row("Memory", "\(Bench.footprintMB()) MB footprint", nil))
        views.append(rows.row("GitHub", "github.com/pseudobun/tip", rows.button("Open") { NSWorkspace.shared.open(URL(string: "https://github.com/pseudobun/tip")!) }))
        section(nil, views)
        let footer = AuthorFooter.make(width: SettingsWindow.size.width - Self.sidebarWidth - 2 * Self.pad,
                                       style: .init(foreground: .labelColor, muted: .secondaryLabelColor, line: .separatorColor,
                                                    font: { size, w in SettingsTheme.sans(size, w >= 600 ? .semibold : .regular) }))
        contentStack.addArrangedSubview(footer)
    }
}

/// A zone as text: islands split by |, items by +. Empty (in an override) means inherited.
final class IslandField: NSTextField, NSTextFieldDelegate {
    var onChange: (([[String]]?) -> Void)?
    private let inherits: Bool

    init(islands: [[String]]?, inherits: Bool) {
        self.inherits = inherits
        super.init(frame: .zero)
        stringValue = islands.map(Self.text) ?? ""
        placeholderString = inherits ? "as on every display" : "nothing"
        font = SettingsTheme.mono(12)
        widthAnchor.constraint(equalToConstant: 380).isActive = true
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    static func text(_ islands: [[String]]) -> String { islands.map { $0.joined(separator: " + ") }.joined(separator: "  |  ") }

    static func parse(_ s: String) -> [[String]] {
        s.split(separator: "|").map { $0.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let t = stringValue.trimmingCharacters(in: .whitespaces)
        onChange?(t.isEmpty && inherits ? nil : Self.parse(t))
    }
}
