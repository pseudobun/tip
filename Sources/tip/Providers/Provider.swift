import AppKit
import TipCore

enum Trigger: String {
    case click, rightClick, scrollUp, scrollDown

    var configKey: String { rawValue }
}

/// A display a bar sits on.
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let builtin: Bool
    let frame: CGRect
    let isMain: Bool
}

/// What providers can reach: their item's content, events, actions and the displays.
@MainActor
protocol ProviderHost: AnyObject {
    /// Sets an item's content; `display` for per-display content (workspaces), nil for every bar.
    func set(_ item: String, _ content: ItemContent, display: CGDirectDisplayID?)
    func publish(_ event: String, _ data: [String: Any])
    func perform(_ action: Action, item: String?)
    var style: Style { get }
    var displays: [DisplayInfo] { get }
    var iconGap: CGFloat { get }
}

/// One configured item's data source. Started when an item that uses it is shown on some
/// display, stopped when none is (zen mode, removed from the layout).
@MainActor
class Provider {
    let id: String
    private(set) var options: ItemConfig
    unowned let host: ProviderHost
    private(set) var running = false

    required init(id: String, options: ItemConfig, host: ProviderHost) {
        self.id = id
        self.options = options
        self.host = host
    }

    final func start() {
        guard !running else { return }
        running = true
        begin()
    }

    final func stop() {
        guard running else { return }
        running = false
        end()
    }

    /// Options changed: the default restarts.
    func reconfigure(_ options: ItemConfig) {
        self.options = options
        if running { end(); begin() }
    }

    /// Start watching / timers.
    func begin() {}
    /// Stop everything begin started.
    func end() {}
    /// A click on the item (`tag`: the group under the pointer). true: handled, skip the config's action.
    func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool { false }
    /// Rows for the item's popup, built when it opens; nil: no popup of its own.
    func popupRows() -> [PopupRow]? { nil }
    /// A tip event (system_woke, network_change, display_change, theme_change, custom triggers).
    func event(_ name: String, _ data: [String: Any]) {}

    func set(_ content: ItemContent, display: CGDirectDisplayID? = nil) { host.set(id, content, display: display) }

    static func make(_ kind: String) -> Provider.Type? {
        switch kind {
        case "apple": AppleProvider.self
        case "text": TextProvider.self
        case "clock": ClockProvider.self
        case "script": ScriptProvider.self
        case "battery": BatteryProvider.self
        case "network": NetworkProvider.self
        case "vpn": VPNProvider.self
        case "cpu": CPUProvider.self
        case "memory": MemoryProvider.self
        case "disk": DiskProvider.self
        case "front_app": FrontAppProvider.self
        case "media": MediaProvider.self
        case "brew": BrewProvider.self
        case "volume": VolumeProvider.self
        case "workspaces": WorkspacesProvider.self
        case "zoom": ZoomProvider.self
        default: nil
        }
    }
}

/// Runs shell commands off the main thread (actions, script items): never blocks the bar.
enum Shell {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        return env
    }()

    /// `/bin/sh -c command`; `done` gets stdout (trimmed) and the exit status on the main thread.
    static func run(_ command: String, timeout: TimeInterval = 30, done: (@MainActor (String, Int32) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.environment = environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { done?("", -1) } }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { done?(text, status) } }
        }
    }

    /// Runs a program with arguments, no shell.
    static func exec(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = environment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    static func which(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

/// A timer that fires on the main actor; invalidate to stop.
@MainActor
final class Repeater {
    private var timer: Timer?

    init(every interval: TimeInterval, tolerance: Double = 0.1, fireNow: Bool = true, _ block: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        t.tolerance = interval * tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if fireNow { block() }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}
