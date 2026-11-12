import AppKit
import TipCore

/// What an item draws, as data: providers and plugins describe it, the renderer turns it into
/// one bitmap per item. Equal content is never drawn twice.
struct ItemContent: Equatable {
    var parts: [Part] = []
    /// Shown at all (false: the item takes no room).
    var drawing = true
    var tooltip: String?
    /// Index of the first part that `toggle-label` hides; nil: nothing collapses.
    var collapsibleFrom: Int?
    /// Rows its popup shows; nil: no popup.
    var popup: [PopupRow]?
    /// Actions this content brings (a plugin's `click`), over the config's.
    var click: String?
    var rightClick: String?

    static let hidden = ItemContent(drawing: false)
}

enum Weight: String, Hashable {
    case regular, medium, semibold, bold

    var ns: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

struct TextStyle: Hashable {
    var size: CGFloat = 12
    var weight: Weight = .medium
    var color: Paint = .fg
    /// The theme's font (mono for most themes); false: the system font.
    var themed = true

    static func label(_ color: Paint = .fg) -> TextStyle { TextStyle(size: 12, weight: .medium, color: color) }
    static func bold(_ color: Paint = .fg, size: CGFloat = 12) -> TextStyle { TextStyle(size: size, weight: .bold, color: color) }
    static func small(_ color: Paint = .secondary) -> TextStyle { TextStyle(size: 10.5, weight: .medium, color: color) }
}

enum Glyph: Hashable {
    /// An SF Symbol by name.
    case symbol(String, Weight = .regular)
    /// Text: an emoji, a Nerd Font glyph, "Ξ".
    case text(String)
    /// An app's icon: bundle id, app name or .app path.
    case app(String)
    /// An image file.
    case file(String)

    /// "sf:wifi", "app:com.apple.Safari", "file:/x.png" or plain text.
    static func parse(_ s: String) -> Glyph {
        if s.hasPrefix("sf:") { return .symbol(String(s.dropFirst(3))) }
        if s.hasPrefix("app:") { return .app(String(s.dropFirst(4))) }
        if s.hasPrefix("file:") { return .file(String(s.dropFirst(5))) }
        return .text(s)
    }
}

indirect enum Part: Hashable {
    case icon(Glyph, color: Paint, size: CGFloat, alpha: CGFloat = 1)
    case text(String, TextStyle)
    /// Two lines, left aligned, in a fixed width (cpu: busiest process over the percent).
    case stack(top: Part, bottom: Part, width: CGFloat)
    /// Samples 0…1, oldest first, as a filled line in a framed box.
    case graph(values: [Double], width: CGFloat, color: Paint)
    case space(CGFloat)
    /// Parts drawn together, optionally on a pill, clickable as `tag`.
    case group(PartGroup)

    static func label(_ s: String, _ color: Paint = .fg) -> Part { .text(s, .label(color)) }
    static func symbol(_ name: String, _ color: Paint = .fg, size: CGFloat = 14, weight: Weight = .regular) -> Part {
        .icon(.symbol(name, weight), color: color, size: size)
    }
}

struct PartGroup: Hashable {
    var parts: [Part]
    var spacing: CGFloat = 5
    var fill: Paint?
    var radius: CGFloat = 7
    var padding: CGFloat = 0
    var height: CGFloat = 22
    var tag: String?
}

extension ItemContent {
    /// An icon and a label, the usual item.
    static func iconLabel(_ icon: Part?, _ label: Part?, gap: CGFloat = 5, collapsible: Bool = false) -> ItemContent {
        var parts: [Part] = []
        if let icon { parts.append(icon) }
        if let label {
            if icon != nil { parts.append(.space(gap)) }
            parts.append(label)
        }
        return ItemContent(parts: parts, collapsibleFrom: collapsible && icon != nil ? 1 : nil)
    }

    /// The content a plugin or `tip set` spec describes.
    static func from(_ s: ItemSpec, graph: [Double]?, gap: CGFloat) -> ItemContent {
        var parts: [Part] = []
        let iconColor = s.iconColor.flatMap(Paint.parse) ?? .fg
        let labelColor = s.labelColor.flatMap(Paint.parse) ?? .fg
        let small = s.size == "small", large = s.size == "large"
        if let icon = s.icon, !icon.isEmpty {
            parts.append(.icon(Glyph.parse(icon), color: iconColor, size: large ? 16 : small ? 12 : 14))
        }
        if let values = graph {
            if !parts.isEmpty { parts.append(.space(gap)) }
            parts.append(.graph(values: values, width: CGFloat(s.graph?.width ?? 42), color: s.graph?.color.flatMap(Paint.parse) ?? .token(.chart1)))
        }
        if let label = s.label, !label.isEmpty {
            if !parts.isEmpty { parts.append(.space(small ? 3 : gap)) }
            let style = TextStyle(size: small ? 10.5 : large ? 13 : 12, weight: s.bold == true ? .bold : .medium, color: labelColor)
            parts.append(.text(label, style))
        }
        if let detail = s.detail, !detail.isEmpty {
            if !parts.isEmpty { parts.append(.space(3)) }
            parts.append(.text(detail, TextStyle(size: 10.5, weight: .medium, color: s.detailColor.flatMap(Paint.parse) ?? .secondary)))
        }
        return ItemContent(parts: parts, drawing: s.drawing ?? true, tooltip: s.tooltip, popup: s.popup, click: s.click, rightClick: s.rightClick)
    }
}
