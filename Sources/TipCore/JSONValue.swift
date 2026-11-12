import Foundation

/// Any JSON value: item options, plugin preferences and protocol payloads.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
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
    public var int: Int? { number.map { Int($0) } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var strings: [String]? { array?.compactMap(\.string) }

    /// A Foundation value (for JSONSerialization).
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    /// From a Foundation value (JSONSerialization output).
    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .string("\(any!)")
        }
    }

    /// Compact JSON text.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// JSON5 source for a value, as ConfigEdit writes it: bare keys, spaces after commas.
    public var literal: String {
        switch self {
        case .array(let a): "[" + a.map(\.literal).joined(separator: ", ") + "]"
        case .object(let o):
            o.isEmpty ? "{}" : "{ " + o.keys.sorted().map { "\(ConfigEdit.memberName($0)): \(o[$0]!.literal)" }.joined(separator: ", ") + " }"
        default: json
        }
    }

    /// Parses `text` as a JSON5 value; plain words that aren't JSON become strings (`tip set clock label=hi`).
    public static func parse(loose text: String) -> JSONValue {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        if let v = try? decoder.decode(JSONValue.self, from: data) { return v }
        return .string(text)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(nilLiteral: ()) { self = .null }
}
