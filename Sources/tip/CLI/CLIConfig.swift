import AppKit
import TipCore

/// `tip config`, `tip theme`, `tip plugins`, `tip doctor`: these edit or read files directly
/// (the running tip picks changes up by watching them), so they also work while tip is quit.
extension CLI {
    @MainActor static var store: ConfigStore { ConfigStore() }

    static func config(_ args: [String]) -> Int32 {
        MainActor.assumeIsolated {
            let s = store
            switch args.first ?? "path" {
            case "path": print(s.url.path)
            case "template": print(ConfigTemplate.text, terminator: "")
            case "check":
                if let e = s.error { print("error: \(e)"); return 1 }
                s.warnings.forEach { print("warning: \($0)") }
                if s.warnings.isEmpty { print("ok") }
            case "show":
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: (try? enc.encode(s.config)) ?? Data(), as: UTF8.self))
            case "get":
                guard args.count == 2 else { return usage("tip config get <dotted.key>") }
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? enc.encode(s.config), var node = try? JSONSerialization.jsonObject(with: data) else { return 1 }
                for key in args[1].split(separator: ".") {
                    guard let d = node as? [String: Any], let next = d[String(key)] else { fputs("no key \(args[1])\n", stderr); return 1 }
                    node = next
                }
                let out = (try? JSONSerialization.data(withJSONObject: node, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
                print(String(decoding: out, as: UTF8.self))
            case "set":
                guard args.count >= 3 else { return usage("tip config set <dotted.key> <json5 value>  (e.g. tip config set bar.height 36)") }
                let literal = args[2...].joined(separator: " ")
                let value = JSONValue.parse(loose: literal)
                if let e = s.set(path(args[1]), literal: value.literal) { fputs("tip: \(e)\n", stderr); return 1 }
                s.warnings.forEach { print("warning: \($0)") }
            case "unset", "remove":
                guard args.count == 2 else { return usage("tip config unset <dotted.key>") }
                if let e = s.remove(path(args[1])) { fputs("tip: \(e)\n", stderr); return 1 }
            case "edit":
                NSWorkspace.shared.open(s.url)
            default:
                return usage("tip config path|check|show|get <key>|set <key> <value>|unset <key>|template|edit")
            }
            return 0
        }
    }

    /// "items.clock.format" → path; quoted segments keep dots ("plugins.\"com.x.y\".k").
    static func path(_ dotted: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in dotted {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == ".", !quoted { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        return out
    }

    static func theme(_ args: [String]) -> Int32 {
        MainActor.assumeIsolated {
            let s = store
            switch args.first {
            case nil, "list":
                for t in s.allThemes {
                    let mark = t.id == s.config.theme.lowercased() ? "*" : " "
                    print("\(mark) \(t.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(t.label) — \(t.summary)\(t.isBuiltIn ? "" : " (\(t.file ?? ""))")")
                }
                for f in Themes.follow { print("\(f == s.config.theme ? "*" : " ") \(f)") }
            case "template":
                print(ThemeFile.template(name: "My Theme", from: Themes.og), terminator: "")
            case "path":
                print(s.themesFolder.path)
            case "new":
                guard args.count >= 2 else { return usage("tip theme new <name> [--from <theme>]") }
                var name = args[1], from = s.theme(s.config.theme)
                if let i = args.firstIndex(of: "--from"), i + 1 < args.count { from = s.theme(args[i + 1]) }
                if name.isEmpty { name = "My Theme" }
                do {
                    let id = try s.createTheme(named: name, from: from)
                    print(s.themesFolder.appending(path: "\(id).json5").path)
                    print("use it: tip theme \(id)")
                } catch { fputs("tip: \(error.localizedDescription)\n", stderr); return 1 }
            case let name?:
                guard s.allThemes.contains(where: { $0.id == name.lowercased() }) || Themes.follow.contains(name) else {
                    fputs("no theme “\(name)”" + (Suggest.closest(name, among: s.allThemes.map(\.id)).map { " (did you mean \($0)?)" } ?? "") + "\n", stderr)
                    return 1
                }
                if let e = s.set(["theme"], literal: ConfigEdit.literal(name.lowercased())) { fputs("tip: \(e)\n", stderr); return 1 }
                print("theme: \(name)")
            }
            return 0
        }
    }

    static func plugins(_ args: [String]) -> Int32 {
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            let running = request("plugins").flatMap { json($0) as? [[String: Any]] }
            let states = Dictionary((running ?? []).compactMap { p in (p["id"] as? String).map { ($0, p) } }, uniquingKeysWith: { $1 })
            if rest.contains("--json") {
                let list = PluginHost.discover().map { p -> [String: Any] in
                    var d: [String: Any] = ["id": p.manifest.id, "name": p.manifest.name, "version": p.manifest.version,
                                            "path": p.directory.path, "bundled": p.bundled, "linked": p.linked,
                                            "items": p.manifest.items.map(\.id)]
                    d["state"] = states[p.manifest.id]?["state"] ?? "not loaded"
                    return d
                }
                let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            for p in PluginHost.discover() {
                let st = states[p.manifest.id]
                let source = p.bundled ? "bundled" : p.linked ? "linked" : "installed"
                let err = (st?["error"] as? String).flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
                print("\(p.manifest.id)  \(p.manifest.version)  \(source)  \(st?["state"] ?? "not loaded")\(err)")
                print("    items: \(p.manifest.items.map(\.id).joined(separator: ", "))  \(p.directory.path)")
            }
        case "install":
            guard let source = rest.first(where: { !$0.hasPrefix("-") }) else { return usage("tip plugins install <owner/repo[@tag]|url|zip|dir> [--yes]") }
            if !rest.contains("--yes") {
                print("A plugin is a program that runs as you, with your files and network. Install \(source)? Run again with --yes.")
                return 3
            }
            do {
                let m = try PluginInstaller.install(source)
                print("installed \(m.name) \(m.version) (\(m.id)); items: \(m.items.map(\.id).joined(separator: ", "))")
                print("show it: tip config set items.\(m.id.split(separator: ".").last ?? "plugin") '{ plugin: \"\(m.id)\" }' and add it to layout")
            } catch { fputs("tip: \(error)\n", stderr); return 1 }
        case "link":
            guard let dir = rest.first else { return usage("tip plugins link <dir>") }
            do {
                let m = try PluginInstaller.link(URL(fileURLWithPath: dir.expandingTilde))
                print("linked \(m.id) → \(dir)")
            } catch { fputs("tip: \(error)\n", stderr); return 1 }
        case "remove", "uninstall":
            guard let id = rest.first else { return usage("tip plugins remove <id> [--yes]") }
            guard rest.contains("--yes") else { print("Remove \(id)? Run again with --yes."); return 3 }
            do { try PluginInstaller.remove(id); print("removed \(id)") } catch { fputs("tip: \(error)\n", stderr); return 1 }
        case "enable", "disable":
            guard let id = rest.first else { return usage("tip plugins \(sub) <id>") }
            return MainActor.assumeIsolated {
                let s = store
                var list = s.config.plugins.disabled.filter { $0 != id }
                if sub == "disable" { list.append(id) }
                if let e = s.set(["plugins", "disabled"], literal: ConfigEdit.literal(list)) { fputs("tip: \(e)\n", stderr); return 1 }
                print("\(id) \(sub)d")
                return 0
            }
        case "set":
            guard rest.count >= 3 else { return usage("tip plugins set <id> <key> <value>   (a secret: value - reads stdin into the Keychain)") }
            let (id, key) = (rest[0], rest[1])
            let manifest = PluginHost.discover().first { $0.manifest.id == id }?.manifest
            if manifest?.preferences.first(where: { $0.id == key })?.type == "secret" {
                let value = rest[2] == "-" ? (readLine() ?? "") : rest[2]
                Keychain.write(plugin: id, key: key, value: value)
                _ = request("plugins reload")
                print("saved \(key) in the Keychain")
                return 0
            }
            return MainActor.assumeIsolated {
                if let e = store.set(["plugins", id, key], literal: JSONValue.parse(loose: rest[2...].joined(separator: " ")).literal) {
                    fputs("tip: \(e)\n", stderr)
                    return 1
                }
                return 0
            }
        case "logs":
            guard let id = rest.first, let r = request("plugins logs \(id)") else { return 1 }
            print(r["logs"] as? String ?? "")
        case "restart":
            guard let id = rest.first else { return usage("tip plugins restart <id>") }
            return request("plugins restart \(id)") == nil ? 1 : 0
        default:
            return usage("tip plugins list|install|link|remove|enable|disable|set|logs|restart")
        }
        return 0
    }

    /// Costly or broken setups.
    static func doctor(_ args: [String]) -> Int32 {
        MainActor.assumeIsolated {
            let s = store
            var problems = 0
            func say(_ ok: Bool, _ text: String) {
                print("\(ok ? "✓" : "!") \(text)")
                if !ok { problems += 1 }
            }
            say(s.error == nil, s.error.map { "config: \($0)" } ?? "config reads")
            for w in s.warnings { say(false, w) }
            for (id, item) in s.config.items.sorted(by: { $0.key < $1.key }) where item.provider == "script" {
                let iv = item.double("interval", 60)
                say(iv == 0 || iv >= 30, "script item \(id): a shell every \(Int(iv)) s (\(Int(3600 / max(iv, 1))) forks an hour)")
            }
            let used = Set(s.config.items.values.compactMap { $0.string("plugin") })
            let found = Set(PluginHost.discover().map(\.manifest.id))
            for id in used.sorted() { say(found.contains(id), "plugin \(id) \(found.contains(id) ? "is installed" : "is used but not installed (tip plugins install …)")") }
            if s.config.items.values.contains(where: { $0.provider == "media" }) {
                say(Shell.which("media-control") != nil, "media needs media-control (brew install media-control)")
            }
            let paw = PawClient.socketPaths.contains { FileManager.default.fileExists(atPath: $0) }
            print("\(paw ? "✓" : "·") paw \(paw ? "is running: workspaces come from its socket" : "is not running: the workspaces island stays empty")")
            if let r = request("status"), let st = json(r) as? [String: Any] {
                print("✓ tip \(st["version"] ?? "") running, \(st["memoryMB"] ?? 0) MB")
                for p in (st["plugins"] as? [[String: Any]]) ?? [] where ["failed", "backoff"].contains(p["state"] as? String ?? "") {
                    say(false, "plugin \(p["id"] ?? "") \(p["state"] ?? ""): \(p["error"] ?? "")")
                }
            } else {
                print("· tip is not running")
            }
            if SketchyBar.running { say(false, "sketchybar is still running: brew services stop sketchybar") }
            return problems == 0 ? 0 : 1
        }
    }
}

enum SketchyBar {
    static var running: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == "sketchybar" }
            || FileManager.default.fileExists(atPath: "/tmp/sketchybar_\(NSUserName()).lock") && pgrep("sketchybar")
    }

    private static func pgrep(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
