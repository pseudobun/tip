import AppKit
import ServiceManagement
import TipCore

@main
enum Main {
    static func main() {
        // The app binary is also the CLI.
        CLI.runIfRequested(CommandLine.arguments)
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore()
    private(set) var bars: BarManager?
    private var server: IPC.Server?
    private let hotkey = Hotkey()
    private var lastConfig: TipConfig?
    let launched = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Style.registerFonts()
        store.start()
        let m = BarManager(store: store)
        bars = m
        m.plugins.start()
        m.start()
        store.onChange = { [weak self] in self?.configChanged() }
        configChanged()
        let srv = IPC.Server(handler: { [weak self] text in
            MainActor.assumeIsolated { self?.command(text) ?? ["error": "tip is quitting"] }
        }, subscribe: { [weak self] fd, request in
            MainActor.assumeIsolated {
                EventBus.shared.add(fd: fd, request: request, snapshot: self?.bars?.snapshot() ?? [:])
            }
        })
        do { try srv.start(); server = srv } catch { Log.app.error("ipc: \(String(describing: error), privacy: .public)") }
        Updater.shared.start(store.config.updates)
        Log.app.info("tip \(AppPaths.version, privacy: .public) started in \(Int(Date().timeIntervalSince(self.launched) * 1000)) ms")
    }

    func applicationWillTerminate(_ notification: Notification) {
        bars?.plugins.stopAll()
        EventBus.shared.closeAll()
        server?.stop()
    }

    private func configChanged() {
        guard let m = bars else { return }
        m.rebuild()
        let c = store.config
        hotkey.set(c.zen.hotkey) { [weak self] in self?.bars?.setZen(!(self?.bars?.zen ?? false)) }
        if lastConfig?.openAtLogin != c.openAtLogin { applyLoginItem(c.openAtLogin) }
        if lastConfig?.updates != c.updates { Updater.shared.apply(c.updates) }
        lastConfig = c
        m.publish("configReloaded", ["error": store.error ?? "", "warnings": store.warnings])
        SettingsWindowController.shared.configDidChange()
    }

    private func applyLoginItem(_ on: Bool) {
        guard AppPaths.isAppBundle, !AppPaths.isDev else { return }
        do {
            if on { try SMAppService.mainApp.register() } else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `tip:<command>` actions from items and popups.
    func tipCommand(_ text: String) {
        let reply = command(text)
        if let e = reply["error"] as? String, !e.isEmpty { Log.app.error("tip:\(text, privacy: .public): \(e, privacy: .public)") }
    }

    /// Requests from the CLI; returns the reply. Runs on the main thread.
    func command(_ text: String) -> [String: Any] {
        let (name, rest) = text.firstIndex(of: " ").map { (String(text[..<$0]), String(text[text.index(after: $0)...])) } ?? (text, "")
        guard let m = bars else { return ["error": "starting"] }
        switch name {
        case "status":
            return [IPC.jsonObjectKey: status()]
        case "query":
            return [IPC.jsonObjectKey: query(rest, m)]
        case "set":
            let words = CLIWords.split(rest)
            guard let item = words.first else { return ["error": "usage: set <item> key=value …"] }
            if words.count == 2, words[1] == "--reset" { m.clearOverride(item); return ["ok": true] }
            do {
                let spec = try ItemSpec.from(pairs: Array(words.dropFirst()), id: item)
                m.apply(spec, node: item)
            } catch { return ["error": "\(error)"] }
        case "trigger":
            let words = CLIWords.split(rest)
            guard let event = words.first else { return ["error": "usage: trigger <event> [json]"] }
            let json = words.dropFirst().joined(separator: " ")
            let data = json.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? ["value": json]
            m.broadcast(event, data)
            m.publish("trigger", ["name": event, "data": data])
        case "zen":
            switch rest {
            case "on": m.setZen(true)
            case "off": m.setZen(false)
            case "", "toggle": m.setZen(!m.zen)
            default: return ["error": "usage: zen [on|off|toggle]"]
            }
            return ["zen": m.zen]
        case "reload":
            store.load()
            return ["error": store.error ?? "", "warnings": store.warnings.joined(separator: "\n")]
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "settings":
            SettingsWindowController.shared.show(app: self, page: rest.isEmpty ? nil : rest)
        case "theme":
            if rest.isEmpty { return ["theme": m.style.theme.id] }
            guard store.allThemes.contains(where: { $0.id == rest.lowercased() }) || Themes.follow.contains(rest) else {
                return ["error": "no theme “\(rest)”: \((store.allThemes.map(\.id) + Themes.follow).joined(separator: ", "))"]
            }
            if let e = store.set(["theme"], literal: ConfigEdit.literal(rest.lowercased())) { return ["error": e] }
        case "plugins":
            let words = CLIWords.split(rest)
            switch words.first {
            case "logs": return ["logs": m.plugins.logs(words.dropFirst().first ?? "").joined(separator: "\n")]
            case "restart": m.plugins.restart(words.dropFirst().first ?? "")
            case "reload": m.plugins.sync(config: store.config, store: store); m.markDirty()
            default: return [IPC.jsonObjectKey: m.plugins.status()]
            }
        case "popup":
            m.perform(.popup, item: rest)
        case "click":
            let words = CLIWords.split(rest)
            guard let node = words.first, let bar = m.bars.values.first(where: { $0.rect(of: node) != nil }) else {
                return ["error": "no item “\(words.first ?? "")” on any bar"]
            }
            let trigger = words.count > 1 ? Trigger(rawValue: words[1]) ?? .click : .click
            m.handle(trigger, node: node, tag: words.count > 2 ? words[2] : nil, bar: bar, modifiers: [])
        case "update":
            guard Updater.shared.isAvailable else {
                return ["error": "this build has no updater (built from source?); brew upgrade --cask pseudobun/tap/tip"]
            }
            switch rest {
            case "check": Updater.shared.checkOnly()
            case "status": break
            default: Updater.shared.installNow()
            }
            return ["state": Updater.shared.state == .checking ? "checking" : "done", "message": Updater.shared.state.text,
                    "pending": Updater.shared.pending ?? ""]
        case "preview":
            let path = rest.isEmpty ? FileManager.default.temporaryDirectory.appending(path: "tip-preview.png").path : rest
            do { return ["path": try m.preview(to: URL(fileURLWithPath: path.expandingTilde))] } catch { return ["error": "\(error)"] }
        case "layers":
            return ["layers": m.bars.values.flatMap(\.debugLayers).joined(separator: "\n")]
        case "bench":
            return [IPC.jsonObjectKey: Bench.sample()]
        default:
            return ["error": "unknown command \(name)"]
        }
        return ["ok": true]
    }

    private func status() -> [String: Any] {
        guard let m = bars else { return [:] }
        return [
            "version": AppPaths.version, "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "config": store.url.path, "error": store.error ?? "", "warnings": store.warnings,
            "theme": m.style.theme.id, "zen": m.zen, "uptime": Int(Date().timeIntervalSince(launched)),
            "displays": m.displays.map { ["name": $0.name, "id": Int($0.id), "builtin": $0.builtin, "main": $0.isMain] },
            "providers": m.providerStatus().map { ["item": $0.0, "provider": $0.1, "running": $0.2] },
            "plugins": m.plugins.status(),
            "paw": PawClient.shared.connected ? "connected" : "not running",
            "subscribers": EventBus.shared.hasSubscribers,
            "memoryMB": Bench.footprintMB(),
            "permissions": Permissions.report(),
        ]
    }

    private func query(_ what: String, _ m: BarManager) -> Any {
        let snap = m.snapshot()
        guard !what.isEmpty, what != "bars" else { return snap }
        // One item: its content on every bar.
        var out: [[String: Any]] = []
        for bar in (snap["bars"] as? [[String: Any]]) ?? [] {
            for zone in ["left", "center", "right"] {
                for island in (bar[zone] as? [[String: Any]]) ?? [] {
                    for item in (island["items"] as? [[String: Any]]) ?? [] where (item["id"] as? String)?.hasPrefix(what) == true {
                        var i = item
                        i["display"] = bar["display"]
                        out.append(i)
                    }
                }
            }
        }
        return out
    }
}

/// `tip bench` / `tip status`: footprint and CPU of this process.
enum Bench {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : 0
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func wakeups() -> UInt64 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : 0
    }

    static func sample() -> [String: Any] {
        ["cpuSeconds": cpuSeconds(), "wakeups": wakeups(), "memoryMB": footprintMB(), "time": Date().timeIntervalSince1970]
    }
}

/// What tip may need, and whether it has it.
enum Permissions {
    static func report() -> [String: String] {
        ["accessibility": "not needed", "screenRecording": "not needed",
         "location": "only for the Wi-Fi name in the network popup",
         "calendars": "not used"]
    }
}
