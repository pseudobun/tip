import Foundation

/// `~/.config/tip/config.json5`. Every key is optional; a missing key keeps its default.
/// `items` and `layout` merge over the defaults key by key, so a config only names what it changes.
public struct TipConfig: Codable, Equatable, Sendable {
    /// og | og-light | modern | minimal | solarpunk | cyberpunk | follow-paw | follow-hop | a file in themes/.
    public var theme = "og"
    public var bar = Bar()
    public var island = Island()
    public var animation = Animation()
    /// Which islands go where. "default" applies everywhere; "builtin" (the notched laptop
    /// display), "external" and a display's name ("DELL U3223QE") override its zones.
    public var layout: [String: Zones] = Defaults.layout
    /// Item id → what it shows (a provider, a plugin's items or a script) and its options.
    public var items: [String: ItemConfig] = Defaults.items
    public var zen = Zen()
    public var plugins = Plugins()
    /// Start tip when you log in (only for the installed tip.app).
    public var openAtLogin = false
    public var updates = Updates()

    public init() {}

    public struct Bar: Codable, Equatable, Sendable {
        public var height = 40.0
        /// "top" or "bottom".
        public var position = "top"
        /// Space before the first and after the last island; 25/34 line up with paw's window edges.
        public var margin = Margin()
        public var yOffset = 0.0
        /// "none" (transparent) or "glass" (Liquid Glass behind the whole bar).
        public var material = "none"
        /// "all", "main", or display names; empty means all.
        public var displays: [String] = []
        /// Displays narrower than this (points) hide the center zone, like a notch does.
        public var minCenterWidth = 1800.0
        public init() {}

        public struct Margin: Codable, Equatable, Sendable {
            public var left = 25.0
            public var right = 34.0
            public init() {}
        }
    }

    public struct Island: Codable, Equatable, Sendable {
        public var height = 28.0
        /// nil: the theme's radius.
        public var radius: Double?
        /// Between islands.
        public var gap = 6.0
        /// Inside an island, before the first and after the last item.
        public var padding = 10.0
        /// Between items in one island.
        public var spacing = 10.0
        /// Between an item's icon and its label.
        public var iconGap = 5.0
        /// "solid" (theme fill) or "glass" (Liquid Glass).
        public var material = "solid"
        public init() {}
    }

    public struct Animation: Codable, Equatable, Sendable {
        public var enabled = true
        public var durationMs = 220.0
        /// linear | easeOutCubic | easeOutQuint | easeInOut | spring
        public var easing = "easeOutCubic"
        public init() {}
    }

    public struct Zen: Codable, Equatable, Sendable {
        /// Global hotkey that toggles zen mode, e.g. "ctrl+alt+z"; empty for none.
        public var hotkey = ""
        /// Items still shown in zen mode; everything else hides.
        public var keep: [String] = ["workspaces", "zoom", "clock", "media"]
        public init() {}
    }

    public struct Updates: Codable, Equatable, Sendable {
        /// Look for a new version once a day and download it in the background; it installs when tip quits.
        public var check = true
        /// Install as soon as it is downloaded (tip restarts by itself).
        public var automatic = false
        /// "stable", "beta" or "auto": beta when the running tip is one.
        public var channel = "auto"
        public init() {}

        public func wantsBeta(running version: String) -> Bool {
            switch channel {
            case "beta": true
            case "stable": false
            default: version.split(separator: "+")[0].contains("-")
            }
        }
    }

    /// `plugins: { disabled: ["…"], "com.you.thing": { …its preferences… } }`
    public struct Plugins: Codable, Equatable, Sendable {
        public var disabled: [String] = []
        /// Plugin id → its preferences.
        public var settings: [String: JSONValue] = [:]
        public init() {}

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
            disabled = raw["disabled"]?.strings ?? []
            settings = raw.filter { $0.key != "disabled" }
        }

        public func encode(to encoder: Encoder) throws {
            var all = settings
            all["disabled"] = .array(disabled.map(JSONValue.string))
            try all.encode(to: encoder)
        }
    }

    /// Left, center and right: islands, each a list of item ids drawn in one rounded group.
    public struct Zones: Codable, Equatable, Sendable {
        public var left: [[String]]?
        public var center: [[String]]?
        public var right: [[String]]?
        public init(left: [[String]]? = nil, center: [[String]]? = nil, right: [[String]]? = nil) {
            self.left = left
            self.center = center
            self.right = right
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case left, center, right }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func zone(_ k: CodingKeys) throws -> [[String]]? {
                guard c.contains(k) else { return nil }
                // An island is ["a", "b"]; a bare "a" is an island of one item.
                let raw = try c.decode([JSONValue].self, forKey: k)
                return raw.map { v in v.strings ?? [v.string].compactMap { $0 } }
            }
            left = try zone(.left)
            center = try zone(.center)
            right = try zone(.right)
        }

        /// `self` with `other`'s zones where it has them.
        public func merged(with other: Zones?) -> Zones {
            guard let other else { return self }
            return Zones(left: other.left ?? left, center: other.center ?? center, right: other.right ?? right)
        }

        public var all: [String] { (left ?? []).flatMap { $0 } + (center ?? []).flatMap { $0 } + (right ?? []).flatMap { $0 } }
    }

    /// What a display shows: "default", then "builtin" or "external", then its own name.
    public func zones(displayName: String, builtin: Bool) -> Zones {
        var z = layout["default"] ?? Defaults.layout["default"]!
        z = z.merged(with: layout[builtin ? "builtin" : "external"])
        z = z.merged(with: layout[displayName])
        return z
    }

    /// The effective items: every id the layout uses that is configured.
    public var usedItems: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for z in layout.values {
            for id in z.all where items[id] != nil && seen.insert(id).inserted { out.append(id) }
        }
        return out.sorted()
    }
}

/// One item's settings: what feeds it and its options, kept as JSON so each provider (and
/// plugin) reads its own keys. Common keys: provider, plugin, command, interval, click,
/// rightClick, scrollUp, scrollDown, icon, label, color, drawing, display, popup.
public struct ItemConfig: Codable, Equatable, Sendable {
    public var raw: [String: JSONValue]
    public init(_ raw: [String: JSONValue]) { self.raw = raw }

    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode([String: JSONValue].self) }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    public subscript(key: String) -> JSONValue? { raw[key] }

    /// The provider's name: `provider`, else "plugin" for `plugin`, "script" for `command`, "text".
    public var provider: String {
        if let p = raw["provider"]?.string { return p }
        if raw["plugin"] != nil { return "plugin" }
        if raw["command"] != nil { return "script" }
        return "text"
    }

    public func string(_ key: String, _ fallback: String) -> String { raw[key]?.string ?? fallback }
    public func string(_ key: String) -> String? { raw[key]?.string }
    public func double(_ key: String, _ fallback: Double) -> Double { raw[key]?.number ?? fallback }
    public func int(_ key: String, _ fallback: Int) -> Int { raw[key]?.int ?? fallback }
    public func bool(_ key: String, _ fallback: Bool) -> Bool { raw[key]?.bool ?? fallback }
    public func strings(_ key: String, _ fallback: [String] = []) -> [String] {
        raw[key]?.strings ?? raw[key]?.string.map { [$0] } ?? fallback
    }

    /// `self` with `other`'s keys on top.
    public func merged(with other: ItemConfig) -> ItemConfig {
        ItemConfig(raw.merging(other.raw) { $1 })
    }
}

// MARK: - Decoding with defaults

/// Decodes `key` if present, otherwise keeps the default.
struct Fields<K: CodingKey> {
    let c: KeyedDecodingContainer<K>
    func callAsFunction<T: Decodable>(_ key: K, _ value: inout T) throws {
        if let v = try c.decodeIfPresent(T.self, forKey: key) { value = v }
    }
}

extension TipConfig {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case theme, bar, island, animation, layout, items, zen, plugins, openAtLogin, updates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = Fields(c: c)
        try f(.theme, &theme); try f(.bar, &bar); try f(.island, &island); try f(.animation, &animation)
        try f(.zen, &zen); try f(.plugins, &plugins); try f(.openAtLogin, &openAtLogin); try f(.updates, &updates)
        // Layout and items merge over the defaults.
        if let l = try c.decodeIfPresent([String: Zones].self, forKey: .layout) {
            for (k, z) in l { layout[k] = (layout[k] ?? Zones()).merged(with: z) }
        }
        if let i = try c.decodeIfPresent([String: JSONValue].self, forKey: .items) {
            for (k, v) in i {
                switch v {
                case .null, .bool(false): items[k] = nil // `name: null` drops a default item
                case .object(let o):
                    // A new provider starts fresh; the same one keeps the default's options.
                    let base = items[k]
                    let sameKind = base.map { b in (o["provider"]?.string ?? o["plugin"].map { _ in "plugin" } ?? b.provider) == b.provider } ?? false
                    items[k] = sameKind ? base!.merged(with: ItemConfig(o)) : ItemConfig(o)
                default: throw DecodingError.typeMismatch(ItemConfig.self, .init(codingPath: [CodingKeys.items], debugDescription: "items.\(k) should be an object"))
                }
            }
        }
    }
}

extension TipConfig.Bar {
    enum CodingKeys: String, CodingKey, CaseIterable { case height, position, margin, yOffset, material, displays, minCenterWidth }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = Fields(c: c)
        try f(.height, &height); try f(.position, &position); try f(.margin, &margin); try f(.yOffset, &yOffset)
        try f(.material, &material); try f(.minCenterWidth, &minCenterWidth)
        if let s = try? c.decodeIfPresent(String.self, forKey: .displays) { displays = s == "all" ? [] : [s] }
        else { try f(.displays, &displays) }
    }
}

extension TipConfig.Bar.Margin {
    enum CodingKeys: String, CodingKey, CaseIterable { case left, right }
    public init(from decoder: Decoder) throws {
        let f = Fields(c: try decoder.container(keyedBy: CodingKeys.self))
        try f(.left, &left); try f(.right, &right)
    }
}

extension TipConfig.Island {
    enum CodingKeys: String, CodingKey, CaseIterable { case height, radius, gap, padding, spacing, iconGap, material }
    public init(from decoder: Decoder) throws {
        let f = Fields(c: try decoder.container(keyedBy: CodingKeys.self))
        try f(.height, &height); try f(.gap, &gap); try f(.padding, &padding); try f(.spacing, &spacing)
        try f(.iconGap, &iconGap); try f(.material, &material)
        radius = try f.c.decodeIfPresent(Double.self, forKey: .radius)
    }
}

extension TipConfig.Animation {
    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, durationMs, easing }
    public init(from decoder: Decoder) throws {
        let f = Fields(c: try decoder.container(keyedBy: CodingKeys.self))
        try f(.enabled, &enabled); try f(.durationMs, &durationMs); try f(.easing, &easing)
    }
}

extension TipConfig.Zen {
    enum CodingKeys: String, CodingKey, CaseIterable { case hotkey, keep }
    public init(from decoder: Decoder) throws {
        let f = Fields(c: try decoder.container(keyedBy: CodingKeys.self))
        try f(.hotkey, &hotkey); try f(.keep, &keep)
    }
}

extension TipConfig.Updates {
    enum CodingKeys: String, CodingKey, CaseIterable { case check, automatic, channel }
    public init(from decoder: Decoder) throws {
        let f = Fields(c: try decoder.container(keyedBy: CodingKeys.self))
        try f(.check, &check); try f(.automatic, &automatic); try f(.channel, &channel)
    }
}

// MARK: - Loading and checking

public struct ConfigProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum ConfigLoader {
    public static func decode(_ data: Data) throws -> TipConfig {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x09 || $0 == 0x0d }) { return TipConfig() }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        do {
            return try decoder.decode(TipConfig.self, from: data)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ConfigProblem(describe(ctx, fallback: "not valid JSON5", data: data))
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw ConfigProblem(describe(ctx, fallback: "expected \(type)", data: data))
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw ConfigProblem(describe(ctx, fallback: "missing \(type)", data: data))
        } catch {
            throw ConfigProblem(error.localizedDescription)
        }
    }

    static func describe(_ ctx: DecodingError.Context, fallback: String, data: Data) -> String {
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        var detail = ctx.debugDescription
        if let underlying = ctx.underlyingError as NSError?, let d = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
            detail = d
            // JSON5 errors carry a character offset: turn it into line:column.
            if let index = underlying.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                let (line, col) = position(of: index, in: data)
                detail += " (line \(line), column \(col))"
            }
        }
        if detail.isEmpty || detail.hasPrefix("The given data was not valid JSON") { detail = fallback }
        return path.isEmpty ? detail : "\(path): \(detail)"
    }

    static func position(of index: Int, in data: Data) -> (Int, Int) {
        var line = 1, col = 1
        for (i, b) in data.enumerated() {
            if i >= index { break }
            if b == 0x0a { line += 1; col = 1 } else if b & 0xc0 != 0x80 { col += 1 }
        }
        return (line, col)
    }

    /// Keys tip doesn't know (typos), as dotted paths with a suggestion.
    public static func unknownKeys(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else { return [] }
        var out: [String] = []
        let sections: [String: [String]] = [
            "bar": TipConfig.Bar.CodingKeys.allCases.map(\.rawValue),
            "island": TipConfig.Island.CodingKeys.allCases.map(\.rawValue),
            "animation": TipConfig.Animation.CodingKeys.allCases.map(\.rawValue),
            "zen": TipConfig.Zen.CodingKeys.allCases.map(\.rawValue),
            "updates": TipConfig.Updates.CodingKeys.allCases.map(\.rawValue),
        ]
        let top = TipConfig.CodingKeys.allCases.map(\.rawValue)
        func hint(_ k: String, _ among: [String]) -> String {
            Suggest.closest(k, among: among).map { " (did you mean \($0)?)" } ?? ""
        }
        for (k, v) in root.sorted(by: { $0.key < $1.key }) {
            guard top.contains(k) else { out.append(k + hint(k, top)); continue }
            if let known = sections[k], let dict = v as? [String: Any] {
                for sk in dict.keys.sorted() where !known.contains(sk) { out.append("\(k).\(sk)" + hint(sk, known)) }
            }
            if k == "layout", let dict = v as? [String: Any] {
                for (lk, lv) in dict.sorted(by: { $0.key < $1.key }) {
                    guard let zones = lv as? [String: Any] else { continue }
                    let known = TipConfig.Zones.CodingKeys.allCases.map(\.rawValue)
                    for zk in zones.keys.sorted() where !known.contains(zk) { out.append("layout.\(lk).\(zk)" + hint(zk, known)) }
                }
            }
            if k == "items", let dict = v as? [String: Any] {
                for (id, iv) in dict.sorted(by: { $0.key < $1.key }) {
                    guard let opts = iv as? [String: Any] else { continue }
                    let provider = (opts["provider"] as? String) ?? (opts["plugin"] != nil ? "plugin" : opts["command"] != nil ? "script" : "text")
                    guard let spec = ProviderCatalog.spec(provider) else { continue }
                    let known = spec.optionKeys + ProviderCatalog.common
                    for ok in opts.keys.sorted() where !known.contains(ok) { out.append("items.\(id).\(ok)" + hint(ok, known)) }
                }
            }
        }
        return out
    }

    /// Problems a valid file can still have: unknown providers, layout ids without items,
    /// values out of range.
    public static func warnings(_ c: TipConfig, customThemes: [String] = []) -> [String] {
        var w: [String] = []
        let themes = Themes.all.map(\.id) + Themes.follow + customThemes
        if !themes.contains(c.theme.lowercased()) {
            w.append("theme: “\(c.theme)” is not \(themes.joined(separator: ", "))")
        }
        for (name, z) in c.layout.sorted(by: { $0.key < $1.key }) {
            for id in z.all where c.items[id] == nil {
                let hint = Suggest.closest(id, among: Array(c.items.keys)).map { " (did you mean \($0)?)" } ?? ""
                w.append("layout.\(name): no item “\(id)”\(hint)")
            }
        }
        for (id, item) in c.items.sorted(by: { $0.key < $1.key }) {
            let p = item.provider
            if ProviderCatalog.spec(p) == nil {
                let hint = Suggest.closest(p, among: ProviderCatalog.all.map(\.id)).map { " (did you mean \($0)?)" } ?? ""
                w.append("items.\(id).provider: unknown provider “\(p)”\(hint)")
            }
            for key in ["click", "rightClick", "scrollUp", "scrollDown"] {
                if let a = item.string(key), Action.parse(a) == nil { w.append("items.\(id).\(key): “\(a)” is not an action") }
            }
            if p == "script", item.double("interval", 0) > 0, item.double("interval", 0) < 5 {
                w.append("items.\(id).interval: a script every \(item.double("interval", 0)) s forks a shell that often; consider a plugin")
            }
        }
        if !(20...80).contains(c.bar.height) { w.append("bar.height: \(c.bar.height) is outside 20…80") }
        if !(12...c.bar.height).contains(c.island.height) { w.append("island.height: \(c.island.height) is outside 12…bar.height") }
        if !["top", "bottom"].contains(c.bar.position) { w.append("bar.position: top or bottom") }
        if !["none", "glass"].contains(c.bar.material) { w.append("bar.material: none or glass") }
        if !["solid", "glass"].contains(c.island.material) { w.append("island.material: solid or glass") }
        if !Easing.names.contains(c.animation.easing) { w.append("animation.easing: \(Easing.names.joined(separator: ", "))") }
        if !["auto", "stable", "beta"].contains(c.updates.channel) { w.append("updates.channel: auto, stable or beta") }
        if !c.zen.hotkey.isEmpty, KeySpec.parse(c.zen.hotkey) == nil { w.append("zen.hotkey: “\(c.zen.hotkey)” is not a key") }
        return w
    }
}

/// Animation curves (paw's set).
public enum Easing {
    public static let names = ["linear", "easeOutCubic", "easeOutQuint", "easeInOut", "spring"]

    public static func value(_ name: String, _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch name {
        case "linear": return t
        case "easeOutQuint": return 1 - pow(1 - t, 5)
        case "easeInOut": return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case "spring": return 1 - exp(-7 * t) * cos(5 * t)
        default: return 1 - pow(1 - t, 3)
        }
    }

    /// Control points for a CAMediaTimingFunction approximating the curve.
    public static func bezier(_ name: String) -> (Double, Double, Double, Double) {
        switch name {
        case "linear": (0, 0, 1, 1)
        case "easeOutQuint": (0.22, 1, 0.36, 1)
        case "easeInOut": (0.65, 0, 0.35, 1)
        case "spring": (0.34, 1.36, 0.64, 1)
        default: (0.33, 1, 0.68, 1)
        }
    }
}
