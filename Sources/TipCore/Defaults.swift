import Foundation

/// The bar tip draws with no config: today's sketchybar setup, island for island.
public enum Defaults {
    public static let layout: [String: TipConfig.Zones] = [
        "default": TipConfig.Zones(
            left: [["apple"], ["workspaces"], ["zoom"], ["front_app"], ["brew"]],
            center: [["media"]],
            right: [["markets"], ["cpu", "net", "battery"], ["clock"]]),
        // The notch sits where the center zone would be.
        "builtin": TipConfig.Zones(center: []),
    ]

    public static let items: [String: ItemConfig] = [
        "apple": ItemConfig(["provider": "apple"]),
        "workspaces": ItemConfig(["provider": "workspaces", "appsPerWorkspace": 6,
                                  "ignore": ["Screen Studio", "Raycast", "Dropover"]]),
        "zoom": ItemConfig(["provider": "zoom"]),
        "front_app": ItemConfig(["provider": "front_app"]),
        "brew": ItemConfig(["provider": "brew"]),
        "media": ItemConfig(["provider": "media", "maxChars": 48]),
        "clock": ItemConfig(["provider": "clock", "click": "zen"]),
        "battery": ItemConfig(["provider": "battery"]),
        "net": ItemConfig(["provider": "network", "click": "toggle-label"]),
        "cpu": ItemConfig(["provider": "cpu"]),
        "markets": ItemConfig(["plugin": "com.pseudobun.tip.markets"]),
    ]
}

/// What each provider is and the options it reads: drives Settings' item pages,
/// `tip config check` and the README's table.
public struct ProviderSpec: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public enum Kind: String, Sendable { case text, number, toggle, choice, list, rows }
        public let key: String
        public let kind: Kind
        public let fallback: JSONValue
        public let help: String
        public let choices: [String]
        public init(_ key: String, _ kind: Kind, _ fallback: JSONValue, _ help: String, choices: [String] = []) {
            self.key = key
            self.kind = kind
            self.fallback = fallback
            self.help = help
            self.choices = choices
        }
    }

    public let id: String
    public let name: String
    public let summary: String
    /// SF Symbol for Settings.
    public let symbol: String
    /// How it learns about changes, for `tip doctor` and the README.
    public let source: String
    public let options: [Option]

    public var optionKeys: [String] { options.map(\.key) }
}

public enum ProviderCatalog {
    /// Keys every item understands.
    public static let common = ["provider", "click", "rightClick", "scrollUp", "scrollDown", "icon", "iconColor", "label", "color",
                                "drawing", "display", "popup", "tooltip"]

    public static func spec(_ id: String) -> ProviderSpec? { all.first { $0.id == id } }

    public static let all: [ProviderSpec] = [
        ProviderSpec(id: "apple", name: "Apple menu", summary: "A logo whose popup holds shortcuts.", symbol: "apple.logo",
                     source: "static", options: [
                         .init("rows", .rows, .null, "Popup rows: [{icon, label, action}]; tip's own rows follow."),
                     ]),
        ProviderSpec(id: "workspaces", name: "Workspaces", summary: "paw's workspaces and their apps, per display.",
                     symbol: "square.grid.3x1.below.line.grid.1x2", source: "paw event stream (socket)", options: [
                         .init("appsPerWorkspace", .number, 6, "App icons per workspace."),
                         .init("ignore", .list, ["Screen Studio", "Raycast", "Dropover"], "Apps never shown."),
                         .init("showEmpty", .toggle, true, "Show workspaces without windows."),
                         .init("creator", .toggle, true, "A + that makes a new workspace."),
                         .init("iconSize", .number, 16, "App icon size (points)."),
                     ]),
        ProviderSpec(id: "zoom", name: "Zoom level", summary: "How far paw zoomed the workspace on this display.",
                     symbol: "plus.magnifyingglass", source: "paw event stream (socket)", options: []),
        ProviderSpec(id: "front_app", name: "Front app", summary: "The active app's icon and name.", symbol: "macwindow",
                     source: "NSWorkspace notifications", options: [
                         .init("maxChars", .number, 20, "Longer names end in …"),
                         .init("showName", .toggle, true, "Show the app's name next to its icon."),
                     ]),
        ProviderSpec(id: "brew", name: "Homebrew", summary: "Outdated formulae and casks, from a cache file.", symbol: "mug",
                     source: "file watcher", options: [
                         .init("file", .text, "~/.cache/tip/brew_outdated", "Count written by the brew-refresh job (\"12\", \"12!\" when stale)."),
                         .init("refresh", .text, "launchctl kickstart gui/$UID/sh.pseudobun.brew-refresh",
                               "Run on click and every `interval`; empty for none."),
                         .init("interval", .number, 3600, "Seconds between refreshes; 0 for none."),
                     ]),
        ProviderSpec(id: "media", name: "Now playing", summary: "Track and controls, from MediaRemote.", symbol: "music.note",
                     source: "media-control stream (one long-lived process)", options: [
                         .init("maxChars", .number, 48, "Longer titles end in …"),
                         .init("controls", .toggle, true, "Previous / next buttons."),
                         .init("hidePaused", .toggle, false, "Hide while paused (default: hide only when nothing is loaded)."),
                     ]),
        ProviderSpec(id: "clock", name: "Clock", summary: "Date and time, ticking on the minute.", symbol: "clock",
                     source: "timer aligned to the minute", options: [
                         .init("format", .text, "HH:mm", "Time (Unicode date pattern)."),
                         .init("dateFormat", .text, "EEE dd", "Date before the time; empty for none."),
                         .init("timeZone", .text, "", "Time zone id; empty for the system's."),
                     ]),
        ProviderSpec(id: "battery", name: "Battery", summary: "Charge and power source.", symbol: "battery.75percent",
                     source: "IOPowerSources notifications", options: [
                         .init("label", .choice, "percent", "What the label shows.", choices: ["percent", "time", "none"]),
                         .init("warnBelow", .number, 30, "Orange below this percent."),
                         .init("badBelow", .number, 20, "Red below this percent."),
                     ]),
        ProviderSpec(id: "network", name: "Network", summary: "Wi-Fi, cable, iPhone or offline, VPN, and the address.", symbol: "wifi",
                     source: "SystemConfiguration (SCDynamicStore)", options: [
                         .init("label", .choice, "collapsed", "The IP label: collapsed (click opens), shown or hidden.",
                               choices: ["collapsed", "shown", "hidden"]),
                         .init("vpn", .toggle, true, "Show a VPN when one carries IPv4."),
                     ]),
        ProviderSpec(id: "vpn", name: "VPN", summary: "A lock while a VPN tunnel is up.", symbol: "lock.shield",
                     source: "SystemConfiguration (SCDynamicStore)", options: [
                         .init("hideWhenOff", .toggle, true, "Hide without a tunnel."),
                     ]),
        ProviderSpec(id: "cpu", name: "CPU", summary: "Load, its graph and the busiest process.", symbol: "cpu",
                     source: "mach host_statistics (timer)", options: [
                         .init("interval", .number, 2, "Seconds between samples."),
                         .init("graph", .toggle, true, "Draw the load graph."),
                         .init("graphWidth", .number, 42, "Graph width (points)."),
                         .init("top", .toggle, true, "Name of the busiest process above the percent."),
                     ]),
        ProviderSpec(id: "memory", name: "Memory", summary: "Memory in use.", symbol: "memorychip",
                     source: "mach host_statistics64 (timer)", options: [
                         .init("interval", .number, 5, "Seconds between samples."),
                     ]),
        ProviderSpec(id: "disk", name: "Disk", summary: "Free space on a volume.", symbol: "internaldrive",
                     source: "URL resource values (timer)", options: [
                         .init("path", .text, "/", "Volume path."),
                         .init("interval", .number, 300, "Seconds between checks."),
                     ]),
        ProviderSpec(id: "volume", name: "Volume", summary: "Output volume and mute; scroll changes it.", symbol: "speaker.wave.2",
                     source: "CoreAudio property listeners", options: [
                         .init("label", .toggle, true, "Show the percent."),
                         .init("step", .number, 5, "Percent per scroll step."),
                     ]),
        ProviderSpec(id: "script", name: "Script", summary: "A shell command's output as the label.", symbol: "terminal",
                     source: "fork per run (interval or events)", options: [
                         .init("command", .text, "", "Run with /bin/sh -c; stdout is the label, or JSON {label, icon, color}."),
                         .init("interval", .number, 60, "Seconds between runs; 0 for events only."),
                         .init("on", .list, [], "tip events that run it again (system_woke, network_change, a `tip trigger` name)."),
                     ]),
        ProviderSpec(id: "plugin", name: "Plugin", summary: "Items a plugin process sets.", symbol: "puzzlepiece.extension",
                     source: "plugin process (JSON-RPC)", options: [
                         .init("plugin", .text, "", "Plugin id."),
                         .init("items", .list, [], "Its item ids to show, in order; empty for all."),
                     ]),
        ProviderSpec(id: "text", name: "Text", summary: "A fixed icon and label, changed with `tip set`.", symbol: "textformat",
                     source: "static", options: []),
    ]
}
