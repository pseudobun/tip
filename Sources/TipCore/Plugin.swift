import Foundation

/// `plugin.json5` inside a plugin folder.
public struct PluginManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var summary: String?
    public var author: String?
    /// Lowest tip version it needs.
    public var tip: String?
    /// The program, relative to the folder.
    public var entry: String
    /// Items it may set, in the order an item config without `items` shows them.
    public var items: [ItemDecl]
    public var preferences: [Preference]
    /// tip events it wants (`system_woke`, `network_change`, `display_change`, `theme_change`,
    /// `front_app_switched`, custom `tip trigger` names).
    public var events: [String]
    /// Declared, shown in Settings, not enforced (same as hop).
    public var permissions: [String]
    /// "persistent" (default) or "on-demand": started when one of its items is shown.
    public var lifecycle: String

    public struct ItemDecl: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public init(id: String, kind: String = "item") { self.id = id; self.kind = kind }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "item"
        }
    }

    public struct Preference: Codable, Equatable, Sendable {
        public var id: String
        public var title: String?
        /// text | secret | toggle | number | choice | list
        public var type: String
        public var `default`: JSONValue?
        public var options: [String]?
        public var placeholder: String?
        public var help: String?
    }

    enum CodingKeys: String, CodingKey { case id, name, version, summary, author, tip, entry, items, preferences, events, permissions, lifecycle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        tip = try c.decodeIfPresent(String.self, forKey: .tip)
        entry = try c.decode(String.self, forKey: .entry)
        items = try c.decodeIfPresent([ItemDecl].self, forKey: .items) ?? []
        preferences = try c.decodeIfPresent([Preference].self, forKey: .preferences) ?? []
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        lifecycle = try c.decodeIfPresent(String.self, forKey: .lifecycle) ?? "persistent"
    }

    public static func decode(_ data: Data) throws -> PluginManifest {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let m = try decoder.decode(PluginManifest.self, from: data)
        if let problem = m.problem { throw ConfigProblem(problem) }
        return m
    }

    /// Why this manifest can't be used, or nil.
    public var problem: String? {
        if id.wholeMatch(of: /[a-z0-9]+(\.[a-z0-9-]+)+/) == nil { return "id “\(id)” is not reverse DNS in lower case" }
        if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") { return "entry “\(entry)” leaves the plugin folder" }
        if !["persistent", "on-demand"].contains(lifecycle) { return "lifecycle is persistent or on-demand" }
        for i in items where i.id.wholeMatch(of: /[A-Za-z0-9_.-]+/) == nil { return "item id “\(i.id)” has odd characters" }
        return nil
    }

    /// The preferences with their defaults, then `settings` on top.
    public func preferences(with settings: JSONValue?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for p in preferences { if let d = p.default { out[p.id] = d } }
        for (k, v) in settings?.object ?? [:] { out[k] = v }
        return out
    }
}

/// Compares "0.1.0-beta.3" style versions (numeric parts; a prerelease sorts before its release).
public enum Version {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ v: String) -> ([Int], String?) {
            let core = v.split(separator: "+")[0]
            let parts = core.split(separator: "-", maxSplits: 1)
            return (parts[0].split(separator: ".").map { Int($0) ?? 0 }, parts.count > 1 ? String(parts[1]) : nil)
        }
        let (na, pa) = split(a), (nb, pb) = split(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0, y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x.compare(y, options: .numeric)
        }
    }
}

/// What a plugin (or `tip set`) can change on one item. Every field is optional: a `set`
/// carries only what changed.
///
///     {"id": "btc", "icon": "sf:bitcoinsign", "iconColor": "chart3", "label": "$98,412",
///      "labelColor": "fg", "detail": "▲1.2%", "detailColor": "good", "size": "small", "drawing": true, "graph": {"push": 0.42},
///      "click": "open:https://…", "tooltip": "Bitcoin"}
///
/// `icon`: "sf:<SF Symbol>", "app:<bundle id or name>", "file:<path>" or plain text (a glyph).
/// Colours: a theme token (fg, muted, dim, accent, good, warn, bad, info, chart1…5) or "#rrggbb".
public struct ItemSpec: Codable, Equatable, Sendable {
    public var id: String
    public var icon: String?
    public var iconColor: String?
    public var label: String?
    public var labelColor: String?
    /// A small second label after the label ("▲1.2%").
    public var detail: String?
    public var detailColor: String?
    /// "small" (10.5 pt), "normal" or "large".
    public var size: String?
    public var bold: Bool?
    public var drawing: Bool?
    public var graph: Graph?
    public var click: String?
    public var rightClick: String?
    public var tooltip: String?
    /// Rows for this item's popup; non-nil makes a click open it.
    public var popup: [PopupRow]?

    public init(id: String) { self.id = id }

    public struct Graph: Codable, Equatable, Sendable {
        /// One new sample, 0…1.
        public var push: Double?
        /// Replace all samples.
        public var values: [Double]?
        public var width: Double?
        public var color: String?
    }

    /// `self` with the fields `other` sets.
    public func merged(with other: ItemSpec) -> ItemSpec {
        var s = self
        if let v = other.icon { s.icon = v }
        if let v = other.iconColor { s.iconColor = v }
        if let v = other.label { s.label = v }
        if let v = other.labelColor { s.labelColor = v }
        if let v = other.detail { s.detail = v }
        if let v = other.detailColor { s.detailColor = v }
        if let v = other.size { s.size = v }
        if let v = other.bold { s.bold = v }
        if let v = other.drawing { s.drawing = v }
        if let v = other.graph { s.graph = v }
        if let v = other.click { s.click = v }
        if let v = other.rightClick { s.rightClick = v }
        if let v = other.tooltip { s.tooltip = v }
        if let v = other.popup { s.popup = v }
        return s
    }

    /// From `tip set <item> key=value …` pairs.
    public static func from(pairs: [String], id: String) throws -> ItemSpec {
        var s = ItemSpec(id: id)
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else { throw ConfigProblem("“\(pair)” is not key=value") }
            let key = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
            switch key {
            case "icon": s.icon = value
            case "iconColor", "icon.color": s.iconColor = value
            case "label": s.label = value
            case "labelColor", "label.color", "color": s.labelColor = value
            case "detail": s.detail = value
            case "detailColor": s.detailColor = value
            case "size": s.size = value
            case "bold": s.bold = value == "true" || value == "on"
            case "drawing": s.drawing = !(value == "false" || value == "off" || value == "0")
            case "click": s.click = value
            case "rightClick": s.rightClick = value
            case "tooltip": s.tooltip = value
            case "push", "graph.push":
                guard let v = Double(value) else { throw ConfigProblem("push: “\(value)” is not a number") }
                s.graph = Graph(push: v)
            default:
                let known = ["icon", "iconColor", "label", "labelColor", "detail", "detailColor", "size", "bold", "drawing", "click", "rightClick", "tooltip", "push"]
                throw ConfigProblem("unknown key “\(key)”" + (Suggest.closest(key, among: known).map { " (did you mean \($0)?)" } ?? ""))
            }
        }
        return s
    }
}

/// One row in a popup: an icon, a label, an optional detail on the right and what a click does.
public struct PopupRow: Codable, Equatable, Sendable {
    public var icon: String?
    public var label: String
    public var detail: String?
    public var color: String?
    /// An Action string, or "plugin:<id>" to send `action` with this row's id to the plugin.
    public var action: String?
    public var id: String?
    /// A thin line instead of a row.
    public var separator: Bool?

    public init(icon: String? = nil, label: String, detail: String? = nil, color: String? = nil, action: String? = nil,
                id: String? = nil, separator: Bool? = nil) {
        self.icon = icon
        self.label = label
        self.detail = detail
        self.color = color
        self.action = action
        self.id = id
        self.separator = separator
    }

    public static let line = PopupRow(label: "", separator: true)
}

/// JSON-RPC 2.0 messages, one per line.
public struct RPCMessage: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?

    public struct RPCError: Codable, Equatable, Sendable {
        public var code: Int
        public var message: String
        public init(code: Int, message: String) { self.code = code; self.message = message }
    }

    public init(id: Int? = nil, method: String? = nil, params: JSONValue? = nil, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var d = (try? encoder.encode(self)) ?? Data("{}".utf8)
        d.append(0x0a)
        return d
    }

    public static func decode(_ line: Data) -> RPCMessage? { try? JSONDecoder().decode(RPCMessage.self, from: line) }

    /// The `items` a `set` notification carries.
    public var setItems: [ItemSpec] {
        guard method == "set", let items = params?["items"],
              let data = try? JSONEncoder().encode(items),
              let specs = try? JSONDecoder().decode([ItemSpec].self, from: data) else { return [] }
        return specs
    }
}

/// Limits for one plugin: a misbehaving one gets restarted with backoff, then turned off.
public struct PluginBudget: Equatable, Sendable {
    public static let maxSetsPerSecond = 30
    public static let maxMessageBytes = 64 * 1024
    public static let requestTimeout: TimeInterval = 15
    public static let backoff: [TimeInterval] = [1, 5, 30]

    /// Seconds to wait before restart number `attempt` (0-based); nil: give up.
    public static func delay(attempt: Int) -> TimeInterval? { attempt < backoff.count ? backoff[attempt] : nil }

    private var window: TimeInterval = 0
    private var count = 0
    public init() {}

    /// Whether a `set` at time `now` fits this second's budget.
    public mutating func allow(at now: TimeInterval) -> Bool {
        if now - window >= 1 { window = now; count = 0 }
        count += 1
        return count <= Self.maxSetsPerSecond
    }
}
