import Foundation

/// A colour as 0xAARRGGBB, written in config and theme files as "#rrggbb", "#rrggbbaa" or "0xAARRGGBB".
public struct ARGB: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var value: UInt32
    public init(_ value: UInt32) { self.value = value }

    public var a: Double { Double((value >> 24) & 0xff) / 255 }
    public var r: Double { Double((value >> 16) & 0xff) / 255 }
    public var g: Double { Double((value >> 8) & 0xff) / 255 }
    public var b: Double { Double(value & 0xff) / 255 }

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        func byte(_ x: Double) -> UInt32 { UInt32((min(max(x, 0), 1) * 255).rounded()) }
        value = byte(a) << 24 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    public func alpha(_ a: Double) -> ARGB { ARGB(r: r, g: g, b: b, a: a) }

    /// "#rgb", "#rgba", "#rrggbb", "#rrggbbaa" (the # is optional) or "0xAARRGGBB".
    public static func parse(_ text: String) -> ARGB? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x") {
            s.removeFirst(2)
            guard s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
            return ARGB(v)
        }
        if s.hasPrefix("#") { s.removeFirst() }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count <= 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 8 { return ARGB((v & 0xff) << 24 | v >> 8) }
        return ARGB(0xff00_0000 | v)
    }

    /// "#rrggbb", or "#rrggbbaa" when not opaque.
    public var hex: String {
        let rgb = String(format: "#%06x", value & 0xff_ffff)
        let alpha = (value >> 24) & 0xff
        return alpha == 0xff ? rgb : rgb + String(format: "%02x", alpha)
    }

    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(UInt32.self) { value = n; return }
        let s = try c.decode(String.self)
        guard let v = ARGB.parse(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "“\(s)” is not a colour (\"#rrggbb\", \"#rrggbbaa\" or \"0xAARRGGBB\")")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    /// Relative luminance (sRGB), 0…1.
    public var luminance: Double {
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// A colour named by role, resolved against the current theme at draw time, so a theme switch
/// recolours everything without providers knowing.
public enum Paint: Equatable, Hashable, Sendable, Codable {
    case token(Token)
    case rgb(ARGB)
    /// A token or colour at a given opacity.
    indirect case faded(Paint, Double)

    public enum Token: String, CaseIterable, Sendable, Codable {
        case background, card, muted, foreground, mutedForeground, border, ring, primary
        case good, warn, info, destructive, chart1, chart2, chart3, chart4, chart5
    }

    public static let fg = Paint.token(.foreground)
    public static let secondary = Paint.token(.mutedForeground)
    public static let dim = Paint.token(.ring)
    public static let accent = Paint.token(.primary)
    public static let good = Paint.token(.good)
    public static let warn = Paint.token(.warn)
    public static let bad = Paint.token(.destructive)
    public static let info = Paint.token(.info)

    /// "fg", "muted", "dim", "accent", "good", "warn", "bad", "info", a token name ("chart2") or a hex colour.
    public static func parse(_ text: String) -> Paint? {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "fg", "foreground", "text": return .fg
        case "muted", "secondary", "mutedforeground": return .secondary
        case "dim", "ring": return .dim
        case "accent", "primary", "gold": return .accent
        case "good", "green": return .good
        case "warn", "orange", "yellow": return .warn
        case "bad", "red", "destructive": return .bad
        case "info", "blue": return .info
        case "wave": return .token(.chart1)
        case "violet": return .token(.chart2)
        default: break
        }
        if let tok = Token.allCases.first(where: { $0.rawValue.lowercased() == t.lowercased() }) { return .token(tok) }
        return ARGB.parse(t).map(Paint.rgb)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let p = Paint.parse(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "“\(s)” is not a colour or theme token")
        }
        self = p
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .token(let t): try c.encode(t.rawValue)
        case .rgb(let v): try c.encode(v.hex)
        case .faded(let p, _): try p.encode(to: encoder)
        }
    }

    public func resolve(_ palette: Palette) -> ARGB {
        switch self {
        case .token(let t): palette[t]
        case .rgb(let v): v
        case .faded(let p, let a): p.resolve(palette).alpha(p.resolve(palette).a * a)
        }
    }
}
