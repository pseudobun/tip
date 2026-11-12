import Foundation

/// A theme's colours, by hop's token names (paw, hop and olympus-dashboard share them).
/// On the bar: `card` fills islands, `muted` marks the selected workspace, `foreground` and
/// `mutedForeground` are text, `ring` is dim text, `primary` the accent (the clock), `chart1…5`
/// categorical colours (graphs, markets), `background` popups.
public struct Palette: Equatable, Hashable, Sendable {
    public var background, card, muted, foreground, mutedForeground, border, ring, primary: ARGB
    public var good, warn, info, destructive: ARGB
    public var chart1, chart2, chart3, chart4, chart5: ARGB

    public static let keys = Paint.Token.allCases.map(\.rawValue)

    public subscript(token: Paint.Token) -> ARGB {
        get {
            switch token {
            case .background: background
            case .card: card
            case .muted: muted
            case .foreground: foreground
            case .mutedForeground: mutedForeground
            case .border: border
            case .ring: ring
            case .primary: primary
            case .good: good
            case .warn: warn
            case .info: info
            case .destructive: destructive
            case .chart1: chart1
            case .chart2: chart2
            case .chart3: chart3
            case .chart4: chart4
            case .chart5: chart5
            }
        }
        set {
            switch token {
            case .background: background = newValue
            case .card: card = newValue
            case .muted: muted = newValue
            case .foreground: foreground = newValue
            case .mutedForeground: mutedForeground = newValue
            case .border: border = newValue
            case .ring: ring = newValue
            case .primary: primary = newValue
            case .good: good = newValue
            case .warn: warn = newValue
            case .info: info = newValue
            case .destructive: destructive = newValue
            case .chart1: chart1 = newValue
            case .chart2: chart2 = newValue
            case .chart3: chart3 = newValue
            case .chart4: chart4 = newValue
            case .chart5: chart5 = newValue
            }
        }
    }
}

/// Everything a theme decides: colours, the bar's font and the islands' shape.
public struct BarTheme: Equatable, Sendable {
    public var id: String
    public var label: String
    public var summary: String
    public var light: Bool
    public var palette: Palette
    /// Labels and numbers: an installed family, "system" or "system-mono".
    public var font: String
    public var fontSize: Double
    /// Island corner radius (points).
    public var radius: Double
    public var borderWidth: Double
    public var shadow: Bool
    public var shadowOpacity: Double
    public var shadowRadius: Double
    /// Path of a custom theme's file; nil for built-in themes.
    public var file: String?
    /// The built-in theme a custom one starts from.
    public var base: String?

    public var isBuiltIn: Bool { file == nil }
}

public enum Themes {
    public static let follow = ["follow-paw", "follow-hop"]

    public static func builtIn(_ id: String) -> BarTheme? { all.first { $0.id == id.lowercased() } }

    public static let all: [BarTheme] = [og, ogLight, modern, minimal, solarpunk, cyberpunk]

    private static func palette(background: UInt32, card: UInt32, muted: UInt32, border: UInt32, fg: UInt32, mutedFg: UInt32,
                                ring: UInt32, primary: UInt32, good: UInt32, warn: UInt32, info: UInt32, bad: UInt32,
                                charts: [UInt32]) -> Palette {
        Palette(background: ARGB(background), card: ARGB(card), muted: ARGB(muted), foreground: ARGB(fg),
                mutedForeground: ARGB(mutedFg), border: ARGB(border), ring: ARGB(ring), primary: ARGB(primary),
                good: ARGB(good), warn: ARGB(warn), info: ARGB(info), destructive: ARGB(bad),
                chart1: ARGB(charts[0]), chart2: ARGB(charts[1]), chart3: ARGB(charts[2]), chart4: ARGB(charts[3]), chart5: ARGB(charts[4]))
    }

    /// Today's sketchybar look: olive-black islands, gold clock, wave-blue graph (olympus-dashboard's palette).
    public static let og = BarTheme(
        id: "og", label: "OG", summary: "Olive-black islands, gold accent, Geist Mono.", light: false,
        palette: palette(background: 0xf01d_1d16, card: 0xeb1d_1d16, muted: 0xff2b_2b22, border: 0x1aff_ffff,
                         fg: 0xfffb_fbf9, mutedFg: 0xffab_ab9c, ring: 0xff5f_5f52, primary: 0xffea_d186,
                         good: 0xff43_d58f, warn: 0xfffc_b52c, info: 0xff55_b8f8, bad: 0xffff_6467,
                         charts: [0xff86_98eb, 0xffac_79ff, 0xffea_d186, 0xff43_d58f, 0xffff_6467]),
        font: "Geist Mono", fontSize: 12, radius: 9, borderWidth: 1, shadow: false, shadowOpacity: 0.35, shadowRadius: 6)

    public static let ogLight = BarTheme(
        id: "og-light", label: "OG Light", summary: "The original, in daylight.", light: true,
        palette: palette(background: 0xf5fb_fbf9, card: 0xf2fb_fbf9, muted: 0xffe8_e8e3, border: 0x1f0c_0c09,
                         fg: 0xff0c_0c09, mutedFg: 0xff73_735e, ring: 0xffab_ab9c, primary: 0xff00_8236,
                         good: 0xff00_884b, warn: 0xffc2_7400, info: 0xff00_7abf, bad: 0xffdd_0000,
                         charts: [0xff00_7abf, 0xff7c_3aed, 0xff00_8236, 0xff00_884b, 0xffdd_0000]),
        font: "Geist Mono", fontSize: 12, radius: 9, borderWidth: 1, shadow: true, shadowOpacity: 0.18, shadowRadius: 6)

    public static let modern = BarTheme(
        id: "modern", label: "Modern", summary: "Warm charcoal, SF Pro, softer corners, clay accent.", light: false,
        palette: palette(background: 0xf826_2624, card: 0xf026_2624, muted: 0xff3a_3a37, border: 0x17ff_ffff,
                         fg: 0xfffa_f9f5, mutedFg: 0xffc2_c0b6, ring: 0xff76_746c, primary: 0xffd9_7757,
                         good: 0xff79_ce98, warn: 0xffe8_b45a, info: 0xff6b_a8ed, bad: 0xfff0_7a74,
                         charts: [0xff6b_a8ed, 0xffb3_8cf0, 0xffd9_7757, 0xff79_ce98, 0xfff0_7a74]),
        font: "system", fontSize: 12.5, radius: 12, borderWidth: 1, shadow: true, shadowOpacity: 0.3, shadowRadius: 8)

    public static let minimal = BarTheme(
        id: "minimal", label: "Minimal", summary: "Black glass, no border or shadow, white accent.", light: false,
        palette: palette(background: 0xe600_0000, card: 0xd900_0000, muted: 0x2eff_ffff, border: 0x00ff_ffff,
                         fg: 0xffff_ffff, mutedFg: 0xa6ff_ffff, ring: 0x59ff_ffff, primary: 0xffff_ffff,
                         good: 0xff8c_e0a8, warn: 0xffff_d27a, info: 0xffa0_c8ff, bad: 0xffff_8a80,
                         charts: [0xffff_ffff, 0xffc8_c8c8, 0xffff_ffff, 0xff8c_e0a8, 0xffff_8a80]),
        font: "system", fontSize: 12, radius: 6, borderWidth: 0, shadow: false, shadowOpacity: 0, shadowRadius: 0)

    public static let solarpunk = BarTheme(
        id: "solarpunk", label: "Solarpunk", summary: "Sunlit paper, moss and brass, DM Mono.", light: true,
        palette: palette(background: 0xf8ff_fcf1, card: 0xf5ff_fcf1, muted: 0xfff0_ecd7, border: 0xffda_d5b8,
                         fg: 0xff12_2d19, mutedFg: 0xff54_674a, ring: 0xff9a_a58c, primary: 0xff27_762f,
                         good: 0xff1c_7634, warn: 0xffb0_7a12, info: 0xff00_929f, bad: 0xffc5_2f15,
                         charts: [0xff00_929f, 0xff8a_5cbf, 0xffb0_7a12, 0xff1c_7634, 0xffc5_2f15]),
        font: "DM Mono", fontSize: 12, radius: 12, borderWidth: 1, shadow: true, shadowOpacity: 0.15, shadowRadius: 6)

    public static let cyberpunk = BarTheme(
        id: "cyberpunk", label: "Cyberpunk", summary: "Neon on night glass, square corners, Share Tech Mono.", light: false,
        palette: palette(background: 0xf00f_0c1d, card: 0xeb0f_0c1d, muted: 0xff1a_172c, border: 0x5900_d8e1,
                         fg: 0xffd8_f5f6, mutedFg: 0xff85_bbc9, ring: 0xff4a_5f78, primary: 0xfff3_25c4,
                         good: 0xff56_f487, warn: 0xfffc_ee0a, info: 0xff00_ebec, bad: 0xffff_3b6b,
                         charts: [0xff00_ebec, 0xfff3_25c4, 0xfffc_ee0a, 0xff56_f487, 0xffff_3b6b]),
        font: "Share Tech Mono", fontSize: 13, radius: 2, borderWidth: 1, shadow: true, shadowOpacity: 0.6, shadowRadius: 8)
}

// MARK: - Custom themes

/// A theme file in `~/.config/tip/themes/` (JSON5). Every key is optional: what is left out
/// comes from `base`, a built-in theme. `tip theme template` prints a commented one.
public struct ThemeFile: Codable, Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var base: String?
    public var light: Bool?
    /// Token (`Palette.keys`) → "#rrggbb" / "#rrggbbaa".
    public var colors: [String: String]?
    public var font: String?
    public var fontSize: Double?
    public var radius: Double?
    public var borderWidth: Double?
    public var shadow: Bool?
    public var shadowOpacity: Double?
    public var shadowRadius: Double?

    public init() {}

    public static func decode(_ data: Data) throws -> ThemeFile {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(ThemeFile.self, from: data)
    }

    /// The theme this file describes on top of its base, and what in it was ignored.
    public func theme(id: String, path: String?) -> (BarTheme, [String]) {
        var issues: [String] = []
        var base = Themes.og
        if let raw = self.base {
            if let b = Themes.builtIn(raw) { base = b } else { issues.append("base \"\(raw)\" is not a built-in theme, using \"og\"") }
        }
        var t = base
        t.id = id
        t.file = path ?? id
        t.base = base.id
        t.label = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? id
        t.summary = description ?? "Your theme, based on \(base.label)."
        if let light { t.light = light }
        for (key, value) in colors ?? [:] {
            guard let token = Paint.Token(rawValue: key) else {
                let hint = Suggest.closest(key, among: Palette.keys).map { ", did you mean \"\($0)\"?" } ?? ""
                issues.append("unknown colour \"\(key)\"\(hint)")
                continue
            }
            guard let c = ARGB.parse(value) else {
                issues.append("colors.\(key): \"\(value)\" is not a colour (\"#rrggbb\" or \"#rrggbbaa\")")
                continue
            }
            t.palette[token] = c
        }
        if let font = font?.trimmingCharacters(in: .whitespaces), !font.isEmpty { t.font = font }
        if let fontSize { t.fontSize = min(max(fontSize, 8), 20) }
        if let radius { t.radius = min(max(radius, 0), 20) }
        if let borderWidth { t.borderWidth = min(max(borderWidth, 0), 4) }
        if let shadow { t.shadow = shadow }
        if let shadowOpacity { t.shadowOpacity = min(max(shadowOpacity, 0), 1) }
        if let shadowRadius { t.shadowRadius = min(max(shadowRadius, 0), 30) }
        return (t, issues)
    }

    /// A commented theme file with every value of `theme` written out, ready to edit.
    public static func template(name: String, from theme: BarTheme) -> String {
        let p = theme.palette
        func line(_ token: Paint.Token, _ comment: String) -> String {
            "    \(token.rawValue): \"\(p[token].hex)\", // \(comment)"
        }
        func num(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%g", x) }
        return """
        // A tip theme (JSON5: comments and trailing commas are fine).
        // Keep it in ~/.config/tip/themes/: the file name is the theme's id, so `theme: "nord"` in
        // config.json5 picks nord.json5. Saved changes apply at once.
        {
          name: \(ConfigEdit.literal(name)),
          description: \(ConfigEdit.literal("Based on \(theme.label).")),
          // Every key left out comes from this built-in theme:
          // "og", "og-light", "modern", "minimal", "solarpunk" or "cyberpunk"
          base: \(ConfigEdit.literal(theme.base ?? theme.id)),
          light: \(theme.light),
          // "#rgb", "#rrggbb" or "#rrggbbaa"
          colors: {
        \(line(.background, "popups"))
        \(line(.card, "island fill"))
        \(line(.muted, "selected workspace, hover"))
        \(line(.foreground, "text"))
        \(line(.mutedForeground, "secondary text"))
        \(line(.border, "island border"))
        \(line(.ring, "dim text, empty workspaces"))
        \(line(.primary, "accent: clock, focused workspace"))
        \(line(.good, "healthy, charging, market up"))
        \(line(.warn, "needs attention"))
        \(line(.info, "in progress"))
        \(line(.destructive, "failed, low battery, market down"))
        \(line(.chart1, "graphs, VPN, ETH"))
        \(line(.chart2, "gas"))
        \(line(.chart3, "BTC"))
        \(line(.chart4, ""))
        \(line(.chart5, ""))
          },
          // An installed font family ("JetBrains Mono"), "system" or "system-mono". Font files
          // (.ttf, .otf) anywhere in the themes folder are loaded too.
          font: \(ConfigEdit.literal(theme.font)),
          fontSize: \(num(theme.fontSize)),
          // Islands
          radius: \(num(theme.radius)),
          borderWidth: \(num(theme.borderWidth)),
          shadow: \(theme.shadow),
          shadowOpacity: \(num(theme.shadowOpacity)),
          shadowRadius: \(num(theme.shadowRadius)),
        }

        """
    }

    /// "My Theme!" → "my-theme".
    public static func slug(_ text: String) -> String {
        let parts = text.lowercased().split { !($0.isLetter || $0.isNumber) }
        return parts.isEmpty ? "theme" : parts.joined(separator: "-")
    }
}

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}
