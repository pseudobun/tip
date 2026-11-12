import AppKit
import Security
import TipCore

/// An installed (or bundled) plugin folder.
struct InstalledPlugin {
    let manifest: PluginManifest
    let directory: URL
    let bundled: Bool
    /// `tip plugins link`: a symlink to a folder being developed.
    let linked: Bool
    /// When its program last changed: a reinstall restarts it.
    var stamp: Date? {
        (try? manifestEntry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    private var manifestEntry: URL { directory.appending(path: manifest.entry) }
}

/// Finds plugins, starts the ones the config uses, routes their `set`s to items and tip's events
/// and clicks to them, and keeps each within its budget.
@MainActor
final class PluginHost {
    weak var manager: BarManager?

    enum State: String { case stopped, running, backoff, failed, disabled }

    private final class Entry {
        let plugin: InstalledPlugin
        var process: PluginProcess?
        var state: State = .stopped
        var attempts = 0
        var budget = PluginBudget()
        var dropped = 0
        var lastError: String?
        var log: [String] = []
        var preferences: [String: JSONValue] = [:]
        var popups: [String: [PopupRow]] = [:]
        var restart: DispatchWorkItem?
        let stamp: Date?
        init(_ p: InstalledPlugin) { plugin = p; stamp = p.stamp }
    }

    private var entries: [String: Entry] = [:]
    private var watcher: FolderWatcher?

    nonisolated static var userFolder: URL {
        IPC.dir.appending(path: "Plugins", directoryHint: .isDirectory)
    }

    nonisolated static var bundledFolder: URL? {
        AppPaths.appBundle.resourceURL?.appending(path: "Plugins", directoryHint: .isDirectory)
    }

    /// Every plugin on disk: bundled first, then installed ones (which win on the same id).
    nonisolated static func discover() -> [InstalledPlugin] {
        var out: [String: InstalledPlugin] = [:]
        let fm = FileManager.default
        for (folder, bundled) in [(bundledFolder, true), (userFolder, false)] {
            guard let folder, let dirs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for dir in dirs {
                let linked = (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                let real = dir.resolvingSymlinksInPath()
                guard let data = try? Data(contentsOf: real.appending(path: "plugin.json5")),
                      let m = try? PluginManifest.decode(data) else { continue }
                out[m.id] = InstalledPlugin(manifest: m, directory: real, bundled: bundled, linked: linked)
            }
        }
        return out.values.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        watcher = FolderWatcher(folder: Self.userFolder) { [weak self] in
            guard let self, let m = self.manager else { return }
            self.sync(config: m.store.config, store: m.store)
            m.markDirty()
        }
    }

    func itemIDs(_ plugin: String) -> [String] {
        (entries[plugin]?.plugin ?? Self.discover().first { $0.manifest.id == plugin }).map { $0.manifest.items.filter { $0.kind == "item" }.map(\.id) } ?? []
    }

    /// Config item ids that show `plugin`.
    private func itemKeys(for plugin: String) -> [String] {
        guard let cfg = manager?.store.config else { return [] }
        return cfg.items.filter { $0.value.provider == "plugin" && $0.value.string("plugin") == plugin }.map(\.key).sorted()
    }

    /// Starts plugins the config uses, stops the rest, and hands changed preferences over.
    func sync(config: TipConfig, store: ConfigStore) {
        let found = Dictionary(Self.discover().map { ($0.manifest.id, $0) }, uniquingKeysWith: { $1 })
        let used = Set(config.items.values.filter { $0.provider == "plugin" }.compactMap { $0.string("plugin") })
        for (id, e) in entries where found[id] == nil || found[id]!.directory != e.plugin.directory || found[id]!.stamp != e.stamp
            || found[id]!.manifest != e.plugin.manifest {
            stop(e)
            entries[id] = nil
        }
        for (id, p) in found where entries[id] == nil { entries[id] = Entry(p) }
        for (id, e) in entries {
            let prefs = preferences(for: e.plugin, config: config, store: store)
            if config.plugins.disabled.contains(id) {
                stop(e)
                e.state = .disabled
                continue
            }
            if e.state == .disabled { e.state = .stopped }
            guard used.contains(id) else { stop(e); continue }
            if e.process?.isRunning == true {
                if prefs != e.preferences {
                    e.preferences = prefs
                    e.process?.notify("preferencesChanged", ["preferences": .object(prefs)])
                }
            } else if e.plugin.manifest.lifecycle == "persistent", e.state != .failed, e.state != .backoff {
                e.preferences = prefs
                launch(e)
            }
        }
        if let m = manager { visibilityChanged(m.visibleItems) }
    }

    /// On-demand plugins run only while one of their items is shown.
    func visibilityChanged(_ visible: Set<String>) {
        guard let cfg = manager?.store.config else { return }
        for (id, e) in entries where e.plugin.manifest.lifecycle == "on-demand" && !cfg.plugins.disabled.contains(id) {
            let shown = itemKeys(for: id).contains { visible.contains($0) }
            if shown, e.process?.isRunning != true, e.state == .stopped { launch(e) }
            if !shown, e.process?.isRunning == true { stop(e) }
        }
    }

    private func preferences(for p: InstalledPlugin, config: TipConfig, store: ConfigStore) -> [String: JSONValue] {
        var prefs = p.manifest.preferences(with: config.plugins.settings[p.manifest.id].map { store.expanded($0) })
        for pref in p.manifest.preferences where pref.type == "secret" {
            if let s = Keychain.read(plugin: p.manifest.id, key: pref.id) { prefs[pref.id] = .string(s) }
        }
        return prefs
    }

    private func launch(_ e: Entry) {
        let m = e.plugin.manifest
        let exe = e.plugin.directory.appending(path: m.entry)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            e.state = .failed
            e.lastError = "\(m.entry) is missing or not executable"
            Log.plugin.error("\(m.id, privacy: .public): \(e.lastError!, privacy: .public)")
            return
        }
        if let need = m.tip, Version.compare(AppPaths.version, need) == .orderedAscending, AppPaths.version != "dev" {
            e.state = .failed
            e.lastError = "needs tip \(need)"
            return
        }
        let proc = PluginProcess(id: m.id, directory: e.plugin.directory, executable: exe)
        proc.onMessage = { [weak self, weak e] msg in if let e { self?.received(msg, from: e) } }
        proc.onLog = { [weak e] line in
            guard let e else { return }
            Log.plugin.notice("\(m.id, privacy: .public): \(line, privacy: .public)")
            e.log.append(line)
            if e.log.count > 200 { e.log.removeFirst(e.log.count - 200) }
        }
        proc.onViolation = { [weak e] why in
            guard let e else { return }
            e.lastError = why
            Log.plugin.error("\(m.id, privacy: .public): \(why, privacy: .public)")
        }
        proc.onExit = { [weak self, weak e] status in
            guard let self, let e else { return }
            e.process = nil
            guard e.state == .running else { return }
            e.lastError = "exited (status \(status))"
            self.scheduleRestart(e)
        }
        do {
            try proc.start()
        } catch {
            e.lastError = "\(error)"
            scheduleRestart(e)
            return
        }
        e.process = proc
        e.state = .running
        guard let manager else { return }
        let theme = manager.style.theme
        let params: JSONValue = [
            "protocolVersion": 1, "tipVersion": .string(AppPaths.version), "pluginID": .string(m.id),
            "preferences": .object(e.preferences),
            "theme": ["id": .string(theme.id), "light": .bool(theme.light)],
            "displays": .array(manager.displays.map { ["name": .string($0.name), "builtin": .bool($0.builtin)] }),
        ]
        proc.request("initialize", params) { [weak self, weak e] reply in
            guard let self, let e else { return }
            if let err = reply.error {
                e.lastError = "initialize: \(err.message)"
                return
            }
            e.attempts = 0
            if let items = reply.result?["items"], let data = try? JSONEncoder().encode(items),
               let specs = try? JSONDecoder().decode([ItemSpec].self, from: data) {
                self.apply(specs, from: e)
            }
        }
    }

    private func scheduleRestart(_ e: Entry) {
        e.process = nil
        guard let delay = PluginBudget.delay(attempt: e.attempts) else {
            e.state = .failed
            Log.plugin.error("\(e.plugin.manifest.id, privacy: .public): gave up after \(e.attempts) restarts")
            return
        }
        e.attempts += 1
        e.state = .backoff
        let w = DispatchWorkItem { [weak self, weak e] in
            MainActor.assumeIsolated {
                guard let self, let e, e.state == .backoff else { return }
                e.state = .stopped
                if let m = self.manager { self.sync(config: m.store.config, store: m.store) }
            }
        }
        e.restart = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func stop(_ e: Entry) {
        e.restart?.cancel()
        let was = e.state
        e.state = .stopped
        e.process?.stop()
        e.process = nil
        if was == .failed { e.state = .failed }
    }

    func stopAll() { entries.values.forEach(stop) }

    /// Turns a failed plugin back on (after Settings or `tip plugins restart`).
    func restart(_ id: String) {
        guard let e = entries[id] else { return }
        stop(e)
        e.state = .stopped
        e.attempts = 0
        e.lastError = nil
        if let m = manager { sync(config: m.store.config, store: m.store) }
    }

    // MARK: Messages

    private func received(_ msg: RPCMessage, from e: Entry) {
        let id = e.plugin.manifest.id
        switch msg.method {
        case "set":
            guard e.budget.allow(at: Date().timeIntervalSince1970) else {
                e.dropped += 1
                if e.dropped % 100 == 1 { Log.plugin.notice("\(id, privacy: .public): over 30 sets/s; coalescing") }
                return
            }
            apply(msg.setItems, from: e)
        case "popup":
            guard let item = msg.params?["id"]?.string, let rows = msg.params?["rows"],
                  let data = try? JSONEncoder().encode(rows), let decoded = try? JSONDecoder().decode([PopupRow].self, from: data) else { return }
            e.popups[item] = decoded
        case "log":
            let text = msg.params?["message"]?.string ?? ""
            e.log.append(text)
            Log.plugin.notice("\(id, privacy: .public): \(text, privacy: .public)")
        case "run":
            // The plugin asks; tip opens (URLs and apps only: the plugin stays unprivileged).
            if let s = msg.params?["action"]?.string ?? msg.params?["open"]?.string.map({ "open:\($0)" }), let a = Action.parse(s) {
                switch a {
                case .open, .app, .media, .popup, .toggleLabel: manager?.perform(a, item: nil)
                default: Log.plugin.notice("\(id, privacy: .public): run \(s, privacy: .public) refused")
                }
            }
        default:
            break
        }
    }

    private func apply(_ specs: [ItemSpec], from e: Entry) {
        guard let manager else { return }
        let keys = itemKeys(for: e.plugin.manifest.id)
        let declared = Set(e.plugin.manifest.items.map(\.id))
        for spec in specs where declared.isEmpty || declared.contains(spec.id) {
            for key in keys { manager.setPluginItem(spec, node: "\(key).\(spec.id)") }
        }
    }

    // MARK: Input from tip

    func event(_ name: String, _ data: [String: Any]) {
        for e in entries.values where e.process?.isRunning == true && e.plugin.manifest.events.contains(name) {
            e.process?.notify("event", ["name": .string(name), "data": JSONValue(any: data)])
        }
    }

    private func entry(for item: String) -> Entry? {
        guard let id = manager?.store.config.items[item]?.string("plugin") else { return nil }
        return entries[id]
    }

    func action(node: String, item: String, trigger: Trigger, tag: String?, modifiers: NSEvent.ModifierFlags) {
        guard let e = entry(for: item), let p = e.process else { return }
        let sub = node.hasPrefix(item + ".") ? String(node.dropFirst(item.count + 1)) : node
        var mods: [JSONValue] = []
        if modifiers.contains(.command) { mods.append("cmd") }
        if modifiers.contains(.option) { mods.append("alt") }
        if modifiers.contains(.control) { mods.append("ctrl") }
        if modifiers.contains(.shift) { mods.append("shift") }
        p.notify("action", ["item": .string(sub), "trigger": .string(trigger.rawValue), "tag": tag.map(JSONValue.string) ?? .null,
                            "modifiers": .array(mods)])
    }

    func popupRows(node: String) -> [PopupRow]? {
        guard let item = manager?.item(of: node), let e = entry(for: item) else { return nil }
        let sub = node.hasPrefix(item + ".") ? String(node.dropFirst(item.count + 1)) : node
        if let rows = e.popups[sub] { return rows }
        e.process?.notify("popupOpen", ["item": .string(sub)])
        return nil
    }

    func popupAction(node: String, row: PopupRow) {
        guard let item = manager?.item(of: node), let e = entry(for: item) else { return }
        let sub = node.hasPrefix(item + ".") ? String(node.dropFirst(item.count + 1)) : node
        e.process?.notify("action", ["item": .string(sub), "trigger": "popup", "row": .string(row.id ?? row.label)])
    }

    // MARK: Status

    func status() -> [[String: Any]] {
        let used = Set(manager?.store.config.items.values.compactMap { $0.string("plugin") } ?? [])
        return entries.values.sorted { $0.plugin.manifest.id < $1.plugin.manifest.id }.map { e in
            ["id": e.plugin.manifest.id, "name": e.plugin.manifest.name, "version": e.plugin.manifest.version,
             "state": e.state.rawValue, "pid": e.process?.pid ?? 0, "used": used.contains(e.plugin.manifest.id),
             "bundled": e.plugin.bundled, "linked": e.plugin.linked, "path": e.plugin.directory.path,
             "error": e.lastError ?? "", "dropped": e.dropped]
        }
    }

    func logs(_ id: String) -> [String] { entries[id]?.log ?? [] }

    func manifest(_ id: String) -> InstalledPlugin? { entries[id]?.plugin }
    var all: [InstalledPlugin] { entries.values.map(\.plugin).sorted { $0.manifest.name < $1.manifest.name } }
    func state(_ id: String) -> State { entries[id]?.state ?? .stopped }
    func lastError(_ id: String) -> String? { entries[id]?.lastError }
}

/// Plugin secrets in the login Keychain, never in the config.
enum Keychain {
    static func service(_ plugin: String) -> String { "com.pseudobun.tip.plugin.\(plugin)" }

    static func read(plugin: String, key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(plugin),
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    @discardableResult
    static func write(plugin: String, key: String, value: String?) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(plugin),
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
