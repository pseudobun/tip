// Write tip plugins in Swift. A plugin is a long-lived program tip starts: it reads JSON-RPC
// messages from stdin, one per line, and sets its items by writing `set` notifications to
// stdout. tip draws everything; a plugin only says what its items show. See docs/plugins.md.
//
//     final class Hello: TipPlugin {
//         func initialize(_ tip: Tip, preferences: [String: JSONValue]) -> [Item] {
//             [Item("hello").icon("sf:hand.wave").label("hi")]
//         }
//     }
//     TipPluginKit.serve(Hello())

import Foundation

public let protocolVersion = 1

// MARK: - JSON

/// Any JSON value: preferences and event data.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}

// MARK: - Items

/// What one item shows. Only the fields you set are sent: a `set` changes just those.
/// Icons: "sf:<SF Symbol>", "app:<bundle id>", "file:<path>" or text. Colours: a theme token
/// (fg, muted, dim, accent, good, warn, bad, info, chart1…chart5) or "#rrggbb".
public struct Item: Codable, Equatable, Sendable {
    public var id: String
    public var icon: String?
    public var iconColor: String?
    public var label: String?
    public var labelColor: String?
    /// A small second label after the label ("▲1.2%").
    public var detail: String?
    public var detailColor: String?
    /// "small", "normal" or "large".
    public var size: String?
    public var bold: Bool?
    public var drawing: Bool?
    public var graph: Graph?
    /// A tip action ("open:https://…", "app:Calendar", "popup") run without asking the plugin.
    public var click: String?
    public var rightClick: String?
    public var tooltip: String?
    public var popup: [PopupRow]?

    public struct Graph: Codable, Equatable, Sendable {
        public var push: Double?
        public var values: [Double]?
        public var width: Double?
        public var color: String?
        public init(push: Double? = nil, values: [Double]? = nil, width: Double? = nil, color: String? = nil) {
            self.push = push
            self.values = values
            self.width = width
            self.color = color
        }
    }

    public init(_ id: String) { self.id = id }

    public func icon(_ s: String, color: String? = nil) -> Item { var i = self; i.icon = s; if let color { i.iconColor = color }; return i }
    public func label(_ s: String, color: String? = nil) -> Item { var i = self; i.label = s; if let color { i.labelColor = color }; return i }
    public func detail(_ s: String, color: String? = nil) -> Item { var i = self; i.detail = s; if let color { i.detailColor = color }; return i }
    public func size(_ s: String) -> Item { var i = self; i.size = s; return i }
    public func bold(_ on: Bool = true) -> Item { var i = self; i.bold = on; return i }
    public func drawing(_ on: Bool) -> Item { var i = self; i.drawing = on; return i }
    public func push(_ v: Double) -> Item { var i = self; i.graph = Graph(push: v); return i }
    public func click(_ action: String) -> Item { var i = self; i.click = action; return i }
    public func tooltip(_ s: String) -> Item { var i = self; i.tooltip = s; return i }
    public func popup(_ rows: [PopupRow]) -> Item { var i = self; i.popup = rows; return i }
}

public struct PopupRow: Codable, Equatable, Sendable {
    public var icon: String?
    public var label: String
    public var detail: String?
    public var color: String?
    /// A tip action, or nil to send `action` with this row's `id` to the plugin.
    public var action: String?
    public var id: String?
    public var separator: Bool?

    public init(_ label: String, icon: String? = nil, detail: String? = nil, action: String? = nil, id: String? = nil) {
        self.label = label
        self.icon = icon
        self.detail = detail
        self.action = action
        self.id = id
    }

    public static let line: PopupRow = { var r = PopupRow(""); r.separator = true; return r }()
}

// MARK: - The plugin

/// A click or scroll on one of your items (or a popup row).
public struct ActionEvent: Sendable {
    public let item: String
    /// "click", "rightClick", "scrollUp", "scrollDown" or "popup".
    public let trigger: String
    public let tag: String?
    /// The popup row's id, for `trigger == "popup"`.
    public let row: String?
    public let modifiers: [String]
}

/// Implement what you use; every method has a default.
public protocol TipPlugin: AnyObject {
    /// Once at start: the preferences (defaults, config and Keychain secrets merged). Return the
    /// items' first state.
    func initialize(_ tip: Tip, preferences: [String: JSONValue]) -> [Item]
    /// A tip event you listed in plugin.json5 `events`.
    func event(_ tip: Tip, name: String, data: JSONValue)
    func action(_ tip: Tip, _ action: ActionEvent)
    func preferencesChanged(_ tip: Tip, preferences: [String: JSONValue])
    /// A popup opened without rows: answer with `tip.popup(…)`.
    func popupOpen(_ tip: Tip, item: String)
    func shutdown(_ tip: Tip)
}

public extension TipPlugin {
    func event(_ tip: Tip, name: String, data: JSONValue) {}
    func action(_ tip: Tip, _ action: ActionEvent) {}
    func preferencesChanged(_ tip: Tip, preferences: [String: JSONValue]) {}
    func popupOpen(_ tip: Tip, item: String) {}
    func shutdown(_ tip: Tip) {}
}

/// Talks to tip. Thread-safe; writes are serialized.
public final class Tip: @unchecked Sendable {
    private let lock = NSLock()
    private let out: FileHandle
    public private(set) var tipVersion = ""
    public private(set) var pluginID = ""
    public private(set) var theme: (id: String, light: Bool) = ("og", false)

    init(out: FileHandle = .standardOutput) { self.out = out }

    /// Changes items (only the fields each sets).
    public func set(_ items: [Item]) {
        send(method: "set", params: ["items": items])
    }

    public func set(_ item: Item) { set([item]) }

    /// Rows for an item's popup.
    public func popup(_ item: String, rows: [PopupRow]) {
        send(method: "popup", params: PopupParams(id: item, rows: rows))
    }

    /// A line in tip's log (`tip plugins logs <id>`).
    public func log(_ message: String) { send(method: "log", params: ["message": message]) }

    /// Ask tip to open a URL or app (the plugin stays unprivileged).
    public func open(_ url: String) { send(method: "run", params: ["action": "open:\(url)"]) }

    private struct PopupParams: Encodable { let id: String; let rows: [PopupRow] }
    private struct Note<P: Encodable>: Encodable { let jsonrpc = "2.0"; let method: String; let params: P }
    private struct Reply<R: Encodable>: Encodable { let jsonrpc = "2.0"; let id: Int; let result: R }

    func send<P: Encodable>(method: String, params: P) { write(Note(method: method, params: params)) }
    func reply<R: Encodable>(_ id: Int, _ result: R) { write(Reply(id: id, result: result)) }

    private func write<T: Encodable>(_ v: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? enc.encode(v) else { return }
        data.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        try? out.write(contentsOf: data)
    }

    func configure(_ params: JSONValue?) {
        tipVersion = params?["tipVersion"]?.string ?? ""
        pluginID = params?["pluginID"]?.string ?? ""
        theme = (params?["theme"]?["id"]?.string ?? "og", params?["theme"]?["light"]?.bool ?? false)
    }
}

private struct Incoming: Decodable {
    let id: Int?
    let method: String?
    let params: JSONValue?
}

private struct InitResult: Encodable { let items: [Item] }

/// Runs the plugin: reads stdin on a background thread and calls the plugin on the main queue,
/// so timers and URLSession callbacks on the main queue need no locking. Never returns.
public func serve(_ plugin: TipPlugin) -> Never {
    nonisolated(unsafe) let plugin = plugin
    let tip = Tip()
    setvbuf(stdout, nil, _IONBF, 0)
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            guard let msg = try? JSONDecoder().decode(Incoming.self, from: Data(line.utf8)) else { continue }
            DispatchQueue.main.async { handle(msg, plugin, tip) }
        }
        // tip closed stdin: it quit or stopped us.
        DispatchQueue.main.async {
            plugin.shutdown(tip)
            exit(0)
        }
    }
    dispatchMain()
}

private func handle(_ msg: Incoming, _ plugin: TipPlugin, _ tip: Tip) {
    let p = msg.params
    func prefs(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
    switch msg.method {
    case "initialize":
        tip.configure(p)
        let items = plugin.initialize(tip, preferences: prefs(p?["preferences"]))
        if let id = msg.id { tip.reply(id, InitResult(items: items)) }
    case "event":
        plugin.event(tip, name: p?["name"]?.string ?? "", data: p?["data"] ?? .null)
    case "action":
        plugin.action(tip, ActionEvent(item: p?["item"]?.string ?? "", trigger: p?["trigger"]?.string ?? "click",
                                       tag: p?["tag"]?.string, row: p?["row"]?.string,
                                       modifiers: p?["modifiers"]?.array?.compactMap(\.string) ?? []))
    case "preferencesChanged":
        plugin.preferencesChanged(tip, preferences: prefs(p?["preferences"]))
    case "popupOpen":
        plugin.popupOpen(tip, item: p?["item"]?.string ?? "")
    case "shutdown":
        plugin.shutdown(tip)
        exit(0)
    default:
        if let id = msg.id { tip.reply(id, JSONValue.null) }
    }
}

// MARK: - Helpers

public enum Fmt {
    /// 98412.3 → "98,412".
    public static func thousands(_ n: Double, decimals: Int = 0) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
