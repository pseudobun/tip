import AppKit
import TipCore

/// The hub: config → providers and plugins → item contents → bars. Changes mark the bars dirty;
/// they redraw once per run-loop turn.
@MainActor
final class BarManager: ProviderHost {
    let store: ConfigStore
    let plugins: PluginHost
    private(set) var style: Style
    private(set) var bars: [CGDirectDisplayID: Bar] = [:]
    private(set) var displays: [DisplayInfo] = []
    private var providers: [String: Provider] = [:]
    /// Item node → content for every bar, and per display.
    private var contents: [String: ItemContent] = [:]
    private var perDisplay: [String: [CGDirectDisplayID: ItemContent]] = [:]
    /// `tip set` changes, over what providers set (not persisted).
    private(set) var overrides: [String: ItemSpec] = [:]
    private var graphs: [String: RingBuffer] = [:]
    /// Items whose collapsible label is open.
    private(set) var expanded: Set<String> = []
    private(set) var zen = false
    let popup = PopupController()
    private var dirty = false
    private var animateNext = false
    /// Theme preview from Settings (hovering a tile): drawn instead of the config's theme.
    var previewTheme: BarTheme? { didSet { restyle() } }

    var iconGap: CGFloat { CGFloat(store.config.island.iconGap) }

    init(store: ConfigStore) {
        self.store = store
        style = Style(theme: store.theme(store.config.theme), island: store.config.island, barHeight: store.config.bar.height)
        plugins = PluginHost()
        plugins.manager = self
        popup.onAction = { [weak self] row in self?.popupRowPicked(row) }
    }

    func start() {
        rebuild()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildBars()
                self?.broadcast("display_change", ["displays": self?.displays.map(\.name) ?? []])
                self?.publish("displaysChanged", ["displays": self?.displays.map(\.name) ?? []])
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcast("system_woke", [:]) }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcast("system_will_sleep", [:]) }
        }
        ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markDirty() }
        }
    }

    /// Everything again: after a config, theme or plugin change.
    func rebuild() {
        restyle(redraw: false)
        rebuildBars()
        syncProviders()
        plugins.sync(config: store.config, store: store)
        markDirty()
    }

    private func restyle(redraw: Bool = true) {
        let theme = previewTheme ?? store.theme(store.config.theme)
        let next = Style(theme: theme, island: store.config.island, barHeight: store.config.bar.height)
        guard next != style else { return }
        let themeChanged = next.theme != style.theme
        style = next
        if themeChanged {
            Renderer.clear()
            if previewTheme == nil {
                broadcast("theme_change", ["theme": theme.id, "light": theme.light])
                publish("themeChanged", ["theme": theme.id])
            }
        }
        if redraw { markDirty(animate: true) }
    }

    // MARK: Displays

    private func rebuildBars() {
        let cfg = store.config
        var infos: [(DisplayInfo, NSScreen)] = []
        for (i, s) in NSScreen.screens.enumerated() {
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let info = DisplayInfo(id: id, name: s.localizedName, builtin: CGDisplayIsBuiltin(id) != 0, frame: s.frame, isMain: i == 0)
            let wanted = cfg.bar.displays
            if !wanted.isEmpty, !wanted.contains(where: { $0 == "main" ? info.isMain : $0 == "all" || $0 == info.name }) { continue }
            infos.append((info, s))
        }
        let ids = Set(infos.map(\.0.id))
        for (id, bar) in bars where !ids.contains(id) || bar.display != infos.first(where: { $0.0.id == id })?.0 {
            bar.close()
            bars[id] = nil
        }
        for (info, screen) in infos {
            let bar = bars[info.id] ?? Bar(display: info, screen: screen)
            bar.manager = self
            bars[info.id] = bar
            bar.place(on: screen, config: cfg)
        }
        let changed = displays != infos.map(\.0)
        displays = infos.map(\.0)
        if changed { providers.values.forEach { $0.event("display_change", [:]) } }
        markDirty()
    }

    func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
    }

    // MARK: Items

    /// The nodes an item id draws: itself, or a plugin's items (`markets` → `markets.btc`, …).
    func nodes(of item: String) -> [String] {
        guard let cfg = store.config.items[item] else { return [] }
        if cfg.provider == "plugin" {
            let ids = cfg.strings("items")
            let declared = plugins.itemIDs(cfg.string("plugin", ""))
            return (ids.isEmpty ? declared : ids).map { "\(item).\($0)" }
        }
        return [item]
    }

    /// The item id a node belongs to.
    func item(of node: String) -> String {
        if store.config.items[node] != nil { return node }
        return node.split(separator: ".", maxSplits: 1).first.map(String.init) ?? node
    }

    func model(for d: DisplayInfo) -> BarModel {
        let z = store.config.zones(displayName: d.name, builtin: d.builtin)
        func islands(_ zone: [[String]]?, _ name: String) -> [IslandModel] {
            (zone ?? []).enumerated().map { i, ids in
                IslandModel(key: "\(name)\(i):" + ids.joined(separator: "+"), nodes: ids.flatMap { nodes(of: $0) })
            }
        }
        let wide = d.frame.width >= store.config.bar.minCenterWidth
        return BarModel(left: islands(z.left, "L"), center: islands(z.center, "C"), right: islands(z.right, "R"), centerAllowed: wide)
    }

    /// Whether `node` should show at all: zen keeps only `zen.keep`; `display` filters bars.
    func isShown(_ node: String) -> Bool {
        let id = item(of: node)
        if zen, !store.config.zen.keep.contains(id) { return false }
        return true
    }

    private func isShown(_ node: String, on d: DisplayInfo) -> Bool {
        let id = item(of: node)
        guard isShown(node) else { return false }
        switch store.config.items[id]?.string("display", "all") ?? "all" {
        case "main": return d.isMain
        case "builtin": return d.builtin
        case "external": return !d.builtin
        case "all": return true
        case let name: return name == d.name
        }
    }

    func content(_ node: String, display: CGDirectDisplayID) -> ItemContent? {
        guard let d = displays.first(where: { $0.id == display }), isShown(node, on: d) else { return nil }
        var c = perDisplay[node]?[display] ?? contents[node]
        if let o = overrides[node] {
            let id = item(of: node)
            let visual = o.icon != nil || o.label != nil || o.detail != nil || o.graph != nil || o.iconColor != nil || o.labelColor != nil
            let kind = store.config.items[id]?.provider ?? "text"
            if visual || ["text", "script"].contains(kind) || c == nil {
                // Like sketchybar's --set: what `tip set` says wins until --reset.
                var base = ItemSpec(id: node)
                base.icon = store.config.items[id]?.string("icon")
                base.label = store.config.items[id]?.string("label") ?? (visual ? nil : c?.parts.textSummary)
                c = .from(base.merged(with: o), graph: graphs[node]?.values, gap: iconGap)
            } else if let d = o.drawing {
                c?.drawing = d
            }
        }
        return c
    }

    /// Items used by any bar right now (layout, zen, displays): their providers run.
    var visibleItems: Set<String> {
        var out = Set<String>()
        for d in displays {
            for isl in model(for: d).all {
                for n in isl.nodes where isShown(n, on: d) { out.insert(item(of: n)) }
            }
        }
        return out
    }

    private func syncProviders() {
        let visible = visibleItems
        for (id, cfg) in store.config.items {
            let kind = cfg.provider
            guard kind != "plugin", let cls = Provider.make(kind) else { continue }
            let options = ItemConfig(cfg.raw.mapValues { store.expanded($0) })
            if let p = providers[id] {
                if ObjectIdentifier(Swift.type(of: p)) != ObjectIdentifier(cls) {
                    p.stop()
                    providers[id] = cls.init(id: id, options: options, host: self)
                } else if p.options != options {
                    p.reconfigure(options)
                }
            } else {
                providers[id] = cls.init(id: id, options: options, host: self)
            }
            if visible.contains(id) { providers[id]?.start() } else { providers[id]?.stop() }
        }
        for (id, p) in providers where store.config.items[id] == nil || Provider.make(store.config.items[id]!.provider) == nil {
            p.stop()
            providers[id] = nil
            contents[id] = nil
            perDisplay[id] = nil
        }
        plugins.visibilityChanged(visible)
    }

    // MARK: ProviderHost

    func set(_ item: String, _ content: ItemContent, display: CGDirectDisplayID?) {
        if let display {
            guard perDisplay[item]?[display] != content else { return }
            perDisplay[item, default: [:]][display] = content
        } else {
            guard contents[item] != content else { return }
            contents[item] = content
        }
        markDirty(animate: true)
        if EventBus.shared.hasSubscribers { publish("itemChanged", ["item": item]) }
    }

    /// A plugin's or `tip set`'s spec for a node.
    func apply(_ spec: ItemSpec, node: String, persistentGraph: Bool = true) {
        if let g = spec.graph {
            var ring = graphs[node] ?? RingBuffer(capacity: Int((g.width ?? 42) / 1.5))
            if let v = g.values { ring = RingBuffer(capacity: max(v.count, 2)); v.forEach { ring.push($0) } }
            if let p = g.push { ring.push(p) }
            graphs[node] = ring
        }
        overrides[node] = (overrides[node] ?? ItemSpec(id: node)).merged(with: spec)
        markDirty(animate: true)
        if EventBus.shared.hasSubscribers { publish("itemChanged", ["item": node]) }
    }

    /// Plugin items keep their own state (not overrides of something else).
    func setPluginItem(_ spec: ItemSpec, node: String) {
        var merged = (pluginSpecs[node] ?? ItemSpec(id: node)).merged(with: spec)
        merged.graph = nil
        pluginSpecs[node] = merged
        if let g = spec.graph {
            var ring = graphs[node] ?? RingBuffer(capacity: Int((g.width ?? 42) / 1.5))
            if let v = g.values { ring = RingBuffer(capacity: max(v.count, 2)); v.forEach { ring.push($0) } }
            if let p = g.push { ring.push(p) }
            graphs[node] = ring
            pluginGraphSpec[node] = g
        }
        var full = merged
        full.graph = pluginGraphSpec[node]
        set(node, .from(full, graph: graphs[node]?.values, gap: iconGap), display: nil)
    }

    private var pluginSpecs: [String: ItemSpec] = [:]
    private var pluginGraphSpec: [String: ItemSpec.Graph] = [:]

    func clearOverride(_ node: String) {
        overrides[node] = nil
        markDirty()
    }

    func publish(_ event: String, _ data: [String: Any]) {
        EventBus.shared.publish(event, data)
    }

    /// A tip event to providers, plugins and subscribers.
    func broadcast(_ name: String, _ data: [String: Any]) {
        providers.values.forEach { if $0.running { $0.event(name, data) } }
        plugins.event(name, data)
        publish(name, data)
    }

    // MARK: Redraw

    func markDirty(animate: Bool = false) {
        animateNext = animateNext || animate
        guard !dirty else { return }
        dirty = true
        // Once per run-loop turn, however many items changed.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.redraw() }
        }
    }

    private func redraw() {
        dirty = false
        let animate = animateNext
        animateNext = false
        for (id, bar) in bars {
            guard let screen = screen(for: id) else { continue }
            bar.render(model(for: bar.display), manager: self, screen: screen, animate: animate)
        }
    }

    // MARK: Input

    func handle(_ trigger: Trigger, node: String, tag: String?, bar: Bar, modifiers: NSEvent.ModifierFlags) {
        let id = item(of: node)
        let cfg = store.config.items[id]
        let content = self.content(node, display: bar.display.id)
        // The content's own action (a plugin's `click`) first, then the provider, then config.
        let own = trigger == .click ? content?.click : trigger == .rightClick ? content?.rightClick : nil
        if let own, let a = Action.parse(own) { perform(a, item: node, bar: bar); return }
        if let p = providers[id], p.running, cfg?.string(trigger.configKey) == nil, p.handle(trigger, tag: tag, display: bar.display.id) { return }
        if let s = cfg?.string(trigger.configKey), let a = Action.parse(s) { perform(a, item: node, bar: bar); return }
        if cfg?.provider == "plugin" {
            plugins.action(node: node, item: id, trigger: trigger, tag: tag, modifiers: modifiers)
            return
        }
        // Default: an item with a popup opens it on click.
        if trigger == .click, content?.popup != nil || providers[id]?.popupRows() != nil { perform(.popup, item: node, bar: bar) }
        else if trigger == .rightClick, providers[id]?.popupRows() != nil { perform(.popup, item: node, bar: bar) }
    }

    func perform(_ action: Action, item: String?) { perform(action, item: item, bar: nil) }

    func perform(_ action: Action, item node: String?, bar: Bar?) {
        switch action {
        case .zen(let on): setZen(on ?? !zen)
        case .popup:
            guard let node else { return }
            let bar = bar ?? bars.values.first { $0.rect(of: node) != nil }
            guard let bar, let rect = bar.rect(of: node) else { return }
            let id = item(of: node)
            let rows = content(node, display: bar.display.id)?.popup.flatMap { $0.isEmpty ? nil : $0 }
                ?? providers[id]?.popupRows() ?? plugins.popupRows(node: node) ?? []
            popupNodeMemo = node
            popup.toggle(node: node, rows: rows, under: rect, bar: bar, style: style)
        case .toggleLabel:
            guard let node else { return }
            if expanded.contains(node) { expanded.remove(node) } else { expanded.insert(node) }
            markDirty(animate: true)
        case .open(let target):
            if target.hasPrefix("/") || target.hasPrefix("~") {
                NSWorkspace.shared.open(URL(fileURLWithPath: target.expandingTilde))
            } else if let url = URL(string: target), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else if let app = Icons.appURL(target) {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
        case .app(let name):
            if let url = Icons.appURL(name) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            else { Shell.run("open -a \(shellQuote(name))") }
        case .shell(let cmd): Shell.run(EnvFile.expand(cmd, store.env))
        case .paw(let cmd): PawClient.run(cmd)
        case .hop(let args):
            if let hop = Shell.which("hop") { Shell.run("\(shellQuote(hop)) \(args)") }
        case .tip(let cmd): (NSApp.delegate as? AppDelegate)?.tipCommand(cmd)
        case .media(let cmd):
            MediaProvider.send(["toggle": "toggle-play-pause", "play": "play", "pause": "pause", "next": "next-track", "previous": "previous-track"][cmd] ?? cmd)
        case .plugin:
            guard let node else { return }
            plugins.action(node: node, item: item(of: node), trigger: .click, tag: nil, modifiers: [])
        case .none: break
        }
    }

    private func popupRowPicked(_ row: PopupRow) {
        let node = popupNodeMemo
        if row.id != nil || row.action?.hasPrefix("plugin") == true {
            if let node { plugins.popupAction(node: node, row: row) }
        } else if let a = row.action, let action = Action.parse(a) {
            perform(action, item: node)
        }
    }

    private var popupNodeMemo: String?

    func setZen(_ on: Bool) {
        guard on != zen else { return }
        zen = on
        popup.close()
        syncProviders()
        markDirty(animate: true)
        publish("zenChanged", ["zen": on])
    }

    // MARK: Query

    func snapshot() -> [String: Any] {
        var bars: [[String: Any]] = []
        for d in displays {
            let m = model(for: d)
            func zone(_ islands: [IslandModel]) -> [[String: Any]] {
                islands.map { isl in
                    ["island": isl.key, "items": isl.nodes.compactMap { n -> [String: Any]? in
                        guard let c = content(n, display: d.id) else { return nil }
                        return ["id": n, "drawing": c.drawing && isShown(n), "text": c.parts.textSummary,
                                "frame": self.bars[d.id]?.rect(of: n).map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? NSNull()]
                    }]
                }
            }
            bars.append(["display": d.name, "id": d.id, "builtin": d.builtin, "main": d.isMain,
                         "left": zone(m.left), "center": zone(m.center), "right": zone(m.right)])
        }
        return ["bars": bars, "zen": zen, "theme": style.theme.id, "providers": providers.keys.sorted().map { ["id": $0, "running": providers[$0]!.running] },
                "plugins": plugins.status()]
    }

    func providerStatus() -> [(String, String, Bool)] {
        providers.keys.sorted().map { ($0, store.config.items[$0]?.provider ?? "?", providers[$0]!.running) }
    }
}

extension BarModel {
    var all: [IslandModel] { left + center + right }
}

extension Array where Element == Part {
    /// The text an item shows, for `tip query`.
    var textSummary: String {
        compactMap { p -> String? in
            switch p {
            case .text(let s, _): s
            case .stack(let t, let b, _): [t, b].textSummary
            case .group(let g): g.parts.textSummary
            case .icon(.text(let s), _, _, _): s
            default: nil
            }
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

extension BarManager {
    /// Every bar's layers, stacked top to bottom, into a PNG (`tip preview`), over a neutral
    /// backdrop so islands read as on a desktop.
    func preview(to url: URL) throws -> String {
        let list = displays.compactMap { d in bars[d.id].map { (d, $0) } }
        guard !list.isEmpty else { throw ConfigProblem("no bars") }
        let scale: CGFloat = 2
        let width = list.map { $0.1.view.bounds.width }.max() ?? 0
        let height = list.map { $0.1.view.bounds.height }.reduce(0, +)
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConfigProblem("no context") }
        ctx.scaleBy(x: scale, y: scale)
        let light = style.theme.light
        ctx.setFillColor(light ? CGColor(srgbRed: 0.80, green: 0.84, blue: 0.90, alpha: 1) : CGColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for (_, bar) in list {
            let h = bar.view.bounds.height
            y -= h
            ctx.saveGState()
            ctx.translateBy(x: 0, y: y)
            bar.view.layer?.render(in: ctx)
            ctx.restoreGState()
        }
        guard let img = ctx.makeImage() else { throw ConfigProblem("render failed") }
        let rep = NSBitmapImageRep(cgImage: img)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }
}
