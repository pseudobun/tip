import AppKit
import TipCore

/// paw over its public socket: one `subscribe` connection (a snapshot first, then events) and a
/// `query` when an event doesn't carry the workspaces. tip knows nothing else about paw; without
/// it the workspaces and zoom islands stay empty, and they fill in when paw starts.
@MainActor
final class PawClient {
    static let shared = PawClient()

    struct Window: Equatable {
        var app: String
        var focused: Bool
    }

    struct Workspace: Equatable {
        var name: String
        var displayID: CGDirectDisplayID
        var focused: Bool
        var visible: Bool
        var zoom: Int
        var windows: [Window]
    }

    private(set) var workspaces: [Workspace] = []
    private(set) var connected = false
    private var listeners: [ObjectIdentifier: () -> Void] = [:]
    private var generation = 0
    private var retry: DispatchWorkItem?
    private var dirWatch: DispatchSourceFileSystemObject?

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The release paw's socket, then a dev build's.
    static var socketPaths: [String] {
        ["com.pseudobun.paw", "com.pseudobun.paw.dev"].map { dir.appending(path: "\($0)/paw.sock").path }
    }

    func add(_ owner: AnyObject, _ onChange: @escaping () -> Void) {
        listeners[ObjectIdentifier(owner)] = onChange
        if listeners.count == 1 { connect() }
        onChange()
    }

    func remove(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
        if listeners.isEmpty { disconnect() }
    }

    /// Runs a paw command (`workspace 3`) off the main thread.
    nonisolated static func run(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            for path in socketPaths {
                if case .success = IPC.send("run \(command)", timeout: 3, socketPath: path) { return }
            }
        }
    }

    private func disconnect() {
        generation += 1
        retry?.cancel()
        dirWatch?.cancel()
        dirWatch = nil
        connected = false
    }

    private func connect() {
        generation += 1
        let gen = generation
        retry?.cancel()
        guard let path = Self.socketPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            waitForPaw()
            return
        }
        Thread.detachNewThread { [weak self] in
            var got = false
            var last: [Workspace] = []
            var focused: String?
            _ = IPC.stream("subscribe snapshot,workspaceChanged,windowsChanged,windowFocused,zoomChanged,displaysChanged,setupChanged",
                           socketPath: path) { line in
                got = true
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
                let data = obj["data"] as? [String: Any]
                var list = data?["workspaces"] as? [[String: Any]]
                // Focus moving inside the focused workspace changes nothing tip draws: no query.
                if list == nil, obj["event"] as? String == "windowFocused", let ws = data?["workspace"] as? String {
                    if ws == focused { return }
                    // Focus moved to another workspace: draw it now from what we know (no query
                    // round trip); paw's workspaceChanged follows with the full state.
                    if let target = last.first(where: { $0.name == ws }) {
                        // paw's shape: the visible workspace carries its display, hidden ones 0.
                        // A hidden target comes up on the focused display, replacing what showed there.
                        let display = target.visible ? target.displayID : (last.first(where: \.focused)?.displayID ?? 0)
                        let patched = last.map { w in
                            var w = w
                            w.focused = w.name == ws
                            if w.name == ws { w.visible = true; w.displayID = display }
                            else if !target.visible, w.visible, w.displayID == display { w.visible = false; w.displayID = 0 }
                            return w
                        }
                        last = patched
                        focused = ws
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(patched, gen: gen) } }
                        return
                    }
                }
                if list == nil, case .success(let r) = IPC.send("query", timeout: 3, socketPath: path),
                   let json = r["json"] as? String {
                    list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
                }
                guard let list else { return }
                let parsed = Self.parse(list)
                last = parsed
                focused = parsed.first(where: \.focused)?.name
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(parsed, gen: gen) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.connected = false
                    // paw quit or restarted: try again soon, then wait for its socket.
                    self.scheduleRetry(after: got ? 0.5 : 2)
                }
            }
        }
    }

    private func update(_ ws: [Workspace], gen: Int) {
        guard gen == generation else { return }
        connected = true
        guard ws != workspaces else { return }
        workspaces = ws
        listeners.values.forEach { $0() }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// No socket yet: watch paw's folder (no polling) and connect when the socket appears;
    /// a slow retry covers a folder that doesn't exist yet.
    private func waitForPaw() {
        if !workspaces.isEmpty {
            workspaces = []
            listeners.values.forEach { $0() }
        }
        dirWatch?.cancel()
        dirWatch = nil
        let folder = Self.dir.appending(path: "com.pseudobun.paw").path
        let fd = open(folder, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            s.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.dirWatch?.cancel()
                    self?.dirWatch = nil
                    self?.scheduleRetry(after: 0.3)
                }
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            dirWatch = s
        }
        scheduleRetry(after: 30)
    }

    nonisolated static func parse(_ list: [[String: Any]]) -> [Workspace] {
        list.map { w in
            let windows = (w["windows"] as? [[String: Any]] ?? []).map {
                Window(app: $0["app"] as? String ?? "", focused: $0["focused"] as? Bool ?? false)
            }
            return Workspace(name: w["name"] as? String ?? "\(w["id"] ?? "?")",
                             displayID: CGDirectDisplayID((w["displayID"] as? Int) ?? 0),
                             focused: w["focused"] as? Bool ?? false, visible: w["visible"] as? Bool ?? false,
                             zoom: w["zoom"] as? Int ?? 0, windows: windows)
        }
    }

    /// The display a workspace shows on: its own, else the one with the focused workspace.
    func display(of ws: Workspace, among displays: [DisplayInfo]) -> CGDirectDisplayID {
        if ws.displayID != 0, displays.contains(where: { $0.id == ws.displayID }) { return ws.displayID }
        if let f = workspaces.first(where: { $0.focused && $0.displayID != 0 }), displays.contains(where: { $0.id == f.displayID }) {
            return f.displayID
        }
        return displays.first(where: \.isMain)?.id ?? displays.first?.id ?? 0
    }
}

/// paw's workspaces on each display: the number (gold when focused), the apps on it as their
/// real icons (faded off the focused one), the visible one on a highlight, and a + for a new one.
final class WorkspacesProvider: Provider {
    override func begin() { PawClient.shared.add(self) { [weak self] in self?.show() } }
    override func end() { PawClient.shared.remove(self) }
    override func event(_ name: String, _ data: [String: Any]) { if name == "display_change" { show() } }

    private func show() {
        let paw = PawClient.shared
        guard !paw.workspaces.isEmpty else {
            for d in host.displays { set(.hidden, display: d.id) }
            return
        }
        let ignore = Set(options.strings("ignore", ["Screen Studio", "Raycast", "Dropover"]))
        let perWorkspace = options.int("appsPerWorkspace", 6)
        let size = CGFloat(options.double("iconSize", 16))
        let showEmpty = options.bool("showEmpty", true)
        for d in host.displays {
            var parts: [Part] = []
            for ws in paw.workspaces where paw.display(of: ws, among: host.displays) == d.id {
                var seen = Set<String>()
                let apps = ws.windows.map(\.app).filter { !$0.isEmpty && !ignore.contains($0) && seen.insert($0).inserted }.prefix(perWorkspace)
                if apps.isEmpty, !showEmpty, !ws.visible { continue }
                var inner: [Part] = [.space(5), .text(ws.name, .bold(ws.focused ? .accent : .dim))]
                if !apps.isEmpty {
                    inner.append(.space(3))
                    inner += apps.map { Part.icon(.app($0), color: .fg, size: size, alpha: ws.focused ? 1 : 0.55) }
                }
                inner.append(.space(apps.isEmpty ? 5 : 4))
                if !parts.isEmpty { parts.append(.space(2)) }
                parts.append(.group(PartGroup(parts: inner, spacing: 2, fill: ws.visible ? .token(.muted) : nil, radius: 7, height: 22, tag: ws.name, slide: true)))
            }
            if options.bool("creator", true) {
                parts.append(.space(2))
                parts.append(.group(PartGroup(parts: [.symbol("plus", .secondary, size: 11, weight: .semibold)], padding: 5, height: 22, tag: "+")))
            }
            set(ItemContent(parts: parts), display: d.id)
        }
    }

    override func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool {
        guard let tag else { return false }
        switch (trigger, tag) {
        case (.click, "+"): PawClient.run("workspace new")
        case (.click, _): PawClient.run("workspace \(tag)")
        case (.rightClick, "+"): return false
        case (.rightClick, _): PawClient.run("workspace \(tag); workspace close")
        case (.scrollUp, _): PawClient.run("workspace prev")
        case (.scrollDown, _): PawClient.run("workspace next")
        }
        return true
    }
}

/// How far paw zoomed the visible workspace in, per display; hidden when not zoomed.
final class ZoomProvider: Provider {
    override func begin() { PawClient.shared.add(self) { [weak self] in self?.show() } }
    override func end() { PawClient.shared.remove(self) }

    private func show() {
        let paw = PawClient.shared
        for d in host.displays {
            let ws = paw.workspaces.first { $0.visible && $0.zoom > 0 && paw.display(of: $0, among: host.displays) == d.id }
            guard let ws else { set(.hidden, display: d.id); continue }
            set(.iconLabel(.symbol("plus.magnifyingglass", .accent, size: 11, weight: .semibold), .text("\(ws.zoom)", .bold(.accent)),
                           gap: host.iconGap), display: d.id)
        }
    }

    override func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool {
        switch trigger {
        case .click, .scrollDown: PawClient.run("zoom out")
        case .scrollUp: PawClient.run("zoom in")
        default: return false
        }
        return true
    }
}

