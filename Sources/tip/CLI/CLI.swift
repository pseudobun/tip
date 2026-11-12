import AppKit
import TipCore

/// `tip <command>`: the app binary doubles as its CLI. Exit codes: 0 ok, 1 error or not running,
/// 10 an update is available (`update --check`), 64 usage.
enum CLI {
    static let commands: [String: ([String]) -> Int32] = [
        "help": { _ in help() }, "--help": { _ in help() }, "-h": { _ in help() },
        "version": { _ in print(AppPaths.version); return 0 }, "--version": { _ in print(AppPaths.version); return 0 },
        "status": status, "query": query, "set": set, "trigger": trigger, "subscribe": subscribe,
        "zen": { args in simple("zen " + (args.first ?? "toggle")) },
        "reload": reload, "quit": { _ in simple("quit") },
        "settings": { args in simple((["settings"] + args.prefix(1)).joined(separator: " ")) },
        "click": { args in args.isEmpty ? usage("tip click <item> [click|rightClick|scrollUp|scrollDown] [tag]") : (request("click " + CLIWords.join(args)) == nil ? 1 : 0) },
        "popup": { args in args.isEmpty ? usage("tip popup <item>") : simple("popup \(args[0])") },
        "config": config, "plugins": plugins, "plugin": plugins, "theme": theme, "themes": theme,
        "preview": { args in
            let out = URL(fileURLWithPath: (args.first ?? "tip-preview.png").expandingTilde, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
            guard let r = request("preview \(out)", timeout: 10) else { return 1 }
            print(r["path"] as? String ?? out)
            return 0
        },
        "doctor": doctor, "bench": bench, "update": update,
    ]

    static func runIfRequested(_ argv: [String]) {
        guard argv.count > 1 else { return }
        // Launch arguments macOS passes to apps (-NSDocumentRevisionsDebugMode, -psn_…) are not commands.
        if argv[1].hasPrefix("-"), commands[argv[1]] == nil { return }
        let code: Int32
        if let command = commands[argv[1]] {
            code = command(Array(argv.dropFirst(2)))
        } else {
            fputs("tip: unknown command \(argv[1])" + (Suggest.closest(argv[1], among: Array(commands.keys)).map { " (did you mean \($0)?)" } ?? "") + "\n", stderr)
            code = 64
        }
        fflush(stdout)
        exit(code)
    }

    static func help() -> Int32 {
        print("""
        tip: a fast, native menu bar — islands, themes and plugins.
        Usage: tip <command> [options]

          status [--json]            running, version, displays, providers, plugins, memory
          query [item] [--json]      what every bar shows (an item id narrows it)
          set <item> key=value…      change an item until tip restarts: icon label color iconColor
                                     drawing size bold click tooltip push (a graph sample); --reset
          trigger <event> [json]     send a custom event to plugins and script items (`on`)
          subscribe [events…] [--reconnect] [--exec <cmd>]
                                     JSON lines, a snapshot first; events: \(EventBus.names.joined(separator: " "))
          zen [on|off|toggle]        hide everything but zen.keep
          popup <item>               open or close an item's popup
          click <item> [trigger] [tag]   as if clicked (trigger: click rightClick scrollUp scrollDown)
          reload                     read the config again and print problems
          config path|check|show|get <key>|set <key> <json5>|template|edit
          theme [list|<name>|new <name> [--from <theme>]|template|path]
          plugins list|install <owner/repo[@tag]|url|zip|dir> [--yes]|link <dir>|remove <id>
                  |enable <id>|disable <id>|logs <id>|restart <id>|set <id> <key> <value>
          doctor                     costly or broken setups: script intervals, plugins, config
          bench [seconds]            idle CPU, wakeups and memory of the running tip (default 60 s)
          preview [out.png]          render every bar (stacked) to a PNG
          settings [page]            open Settings (general, appearance, layout, items, plugins, permissions, about)
          update [--check]           install the newest version now; --check only looks (exit 10: one is available)
          quit | version | help
        """)
        return 0
    }

    static func usage(_ text: String) -> Int32 {
        fputs("usage: \(text)\n", stderr)
        return 64
    }

    // MARK: Talking to the app

    static func request(_ command: String, timeout: TimeInterval = 5) -> [String: Any]? {
        switch IPC.send(command, timeout: timeout) {
        case .success(let r):
            if let e = r["error"] as? String, !e.isEmpty, r["warnings"] == nil {
                fputs("tip: \(e)\n", stderr)
                return nil
            }
            return r
        case .failure(.notRunning):
            fputs("tip is not running (open -a tip)\n", stderr)
            return nil
        case .failure(.failed(let why)):
            fputs("tip: \(why)\n", stderr)
            return nil
        }
    }

    static func simple(_ command: String) -> Int32 {
        guard let r = request(command) else { return 1 }
        if let z = r["zen"] as? Bool { print(z ? "zen on" : "zen off") }
        return 0
    }

    static func json(_ r: [String: Any]) -> Any? {
        (r["json"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    static func status(_ args: [String]) -> Int32 {
        guard let r = request("status"), let s = json(r) as? [String: Any] else { return 1 }
        if args.contains("--json") { print(r["json"] as? String ?? ""); return 0 }
        print("tip \(s["version"] ?? "?") (pid \(s["pid"] ?? "?"), up \(s["uptime"] ?? 0) s, \(s["memoryMB"] ?? 0) MB)")
        print("config   \(s["config"] ?? "")")
        if let e = s["error"] as? String, !e.isEmpty { print("error    \(e)") }
        for w in (s["warnings"] as? [String]) ?? [] { print("warning  \(w)") }
        print("theme    \(s["theme"] ?? "")\(s["zen"] as? Bool == true ? "  (zen)" : "")")
        print("paw      \(s["paw"] ?? "")")
        for d in (s["displays"] as? [[String: Any]]) ?? [] {
            print("display  \(d["name"] ?? "")\(d["builtin"] as? Bool == true ? " (built-in)" : "")\(d["main"] as? Bool == true ? " (main)" : "")")
        }
        let providers = (s["providers"] as? [[String: Any]]) ?? []
        print("items    " + providers.map { "\($0["item"] ?? "")\($0["running"] as? Bool == true ? "" : " (off)")" }.joined(separator: ", "))
        for p in (s["plugins"] as? [[String: Any]]) ?? [] {
            let err = (p["error"] as? String).flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            print("plugin   \(p["id"] ?? "") \(p["version"] ?? "") \(p["state"] ?? "")\(err)")
        }
        return (s["error"] as? String ?? "").isEmpty ? 0 : 1
    }

    static func query(_ args: [String]) -> Int32 {
        let item = args.first { !$0.hasPrefix("-") } ?? ""
        guard let r = request("query \(item)") else { return 1 }
        if args.contains("--json") || true, let text = r["json"] as? String {
            if args.contains("--json") { print(text); return 0 }
        }
        guard let obj = json(r) else { return 1 }
        if let list = obj as? [[String: Any]] {
            for i in list { print("\(i["display"] ?? "")  \(i["id"] ?? "")  \(i["text"] ?? "")\(i["drawing"] as? Bool == false ? "  (hidden)" : "")") }
        } else if let snap = obj as? [String: Any] {
            for bar in (snap["bars"] as? [[String: Any]]) ?? [] {
                print("\(bar["display"] ?? "")")
                for zone in ["left", "center", "right"] {
                    let islands = (bar[zone] as? [[String: Any]]) ?? []
                    let text = islands.map { isl in ((isl["items"] as? [[String: Any]]) ?? []).filter { $0["drawing"] as? Bool != false }
                        .map { "\($0["id"] ?? "")=\($0["text"] ?? "")" }.joined(separator: " ") }.filter { !$0.isEmpty }
                    print("  \(zone.padding(toLength: 7, withPad: " ", startingAt: 0)) " + text.map { "[\($0)]" }.joined(separator: " "))
                }
            }
        }
        return 0
    }

    static func set(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { return usage("tip set <item> key=value … | tip set <item> --reset") }
        return request("set " + CLIWords.join(args)) == nil ? 1 : 0
    }

    static func trigger(_ args: [String]) -> Int32 {
        guard let event = args.first else { return usage("tip trigger <event> [json]") }
        return request("trigger " + CLIWords.join([event] + args.dropFirst())) == nil ? 1 : 0
    }

    static func reload(_ args: [String]) -> Int32 {
        guard let r = request("reload") else { return 1 }
        let e = r["error"] as? String ?? "", w = r["warnings"] as? String ?? ""
        if !e.isEmpty { print("error: \(e)") }
        if !w.isEmpty { print(w) }
        if e.isEmpty, w.isEmpty { print("ok") }
        return e.isEmpty ? 0 : 1
    }

    static func subscribe(_ args: [String]) -> Int32 {
        var events: [String] = [], reconnect = false, exec: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--reconnect": reconnect = true
            case "--exec": i += 1; exec = i < args.count ? args[i] : nil
            default: events += args[i].split(separator: ",").map(String.init)
            }
            i += 1
        }
        let request = events.isEmpty ? "subscribe" : "subscribe " + events.joined(separator: ",")
        setvbuf(stdout, nil, _IOLBF, 0)
        while true {
            let end = IPC.stream(request) { line in
                guard let exec else { print(line); return }
                let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", exec]
                var env = ProcessInfo.processInfo.environment
                env["TIP_EVENT"] = obj["event"] as? String ?? ""
                env["TIP_SEQ"] = "\(obj["seq"] ?? 0)"
                env["TIP_DATA"] = (obj["data"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                p.environment = env
                try? p.run()
                p.waitUntilExit()
            }
            guard reconnect else {
                if case .notRunning = end { fputs("tip is not running\n", stderr) }
                return 1
            }
            sleep(1)
        }
    }

    static func update(_ args: [String]) -> Int32 {
        let check = args.contains("--check")
        guard var r = request(check ? "update check" : "update") else { return 1 }
        // A check is asynchronous: wait for its answer.
        for _ in 0..<60 where (r["state"] as? String) == "checking" {
            usleep(500_000)
            guard let next = request("update status") else { return 1 }
            r = next
        }
        print(r["message"] as? String ?? "")
        return check && (r["message"] as? String ?? "").contains("available") ? 10 : 0
    }

    static func bench(_ args: [String]) -> Int32 {
        let seconds = Double(args.first ?? "") ?? 60
        guard let a = request("bench"), let s0 = json(a) as? [String: Any] else { return 1 }
        print("sampling the running tip for \(Int(seconds)) s …")
        Thread.sleep(forTimeInterval: seconds)
        guard let b = request("bench"), let s1 = json(b) as? [String: Any] else { return 1 }
        let dt = (s1["time"] as? Double ?? 0) - (s0["time"] as? Double ?? 0)
        let cpu = ((s1["cpuSeconds"] as? Double ?? 0) - (s0["cpuSeconds"] as? Double ?? 0)) / max(dt, 1) * 100
        let wakes = Double((s1["wakeups"] as? Int ?? 0) - (s0["wakeups"] as? Int ?? 0)) / max(dt, 1) * 10
        print(String(format: "cpu      %.3f %%", cpu))
        print(String(format: "wakeups  %.1f per 10 s", wakes))
        print("memory   \(s1["memoryMB"] ?? 0) MB (footprint)")
        return 0
    }
}
