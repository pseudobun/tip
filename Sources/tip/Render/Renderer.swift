import AppKit
import TipCore

/// Turns an item's parts into one bitmap at the display's scale, plus where its clickable
/// groups are. Results are cached by (content, style, scale), so an unchanged item costs nothing.
@MainActor
enum Renderer {
    struct Rendered {
        let image: CGImage?
        let size: CGSize
        /// Width with the collapsible tail hidden.
        let collapsedWidth: CGFloat
        /// Tagged groups, in the item's coordinates (origin bottom left).
        let hits: [(tag: String, rect: CGRect)]
    }

    private struct Key: Hashable {
        let parts: [Part]
        let collapsible: Int?
        let theme: String
        let palette: Palette
        let font: String
        let height: CGFloat
        let scale: CGFloat
    }

    private static var cache: [Key: Rendered] = [:]
    private static var order: [Key] = []
    static let limit = 512

    static func render(_ content: ItemContent, style: Style, height: CGFloat, scale: CGFloat) -> Rendered {
        let key = Key(parts: content.parts, collapsible: content.collapsibleFrom, theme: style.theme.id, palette: style.palette,
                      font: style.theme.font, height: height, scale: scale)
        if let r = cache[key] { return r }
        let r = draw(content, style: style, height: height, scale: scale)
        cache[key] = r
        order.append(key)
        if order.count > limit {
            let drop = order.removeFirst()
            cache[drop] = nil
        }
        return r
    }

    static func clear() {
        cache.removeAll()
        order.removeAll()
    }

    // MARK: Measuring

    static func width(_ part: Part, _ style: Style) -> CGFloat {
        switch part {
        case .icon(let g, _, let size, _): return glyphSize(g, size: size, style: style).width
        case .text(let s, let t): return ceil(attributed(s, t, style).size().width)
        case .stack(_, _, let w): return w
        case .graph(_, let w, _): return w + 6
        case .space(let w): return w
        case .group(let g):
            let inner = g.parts.map { width($0, style) }
            return inner.reduce(0, +) + CGFloat(max(g.parts.count - 1, 0)) * spacingTotal(g) + 2 * g.padding
        }
    }

    private static func spacingTotal(_ g: PartGroup) -> CGFloat { g.spacing }

    static func attributed(_ s: String, _ t: TextStyle, _ style: Style) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: style.font(t), .foregroundColor: style.color(t.color), .ligature: 1,
        ])
    }

    private static func glyphSize(_ g: Glyph, size: CGFloat, style: Style) -> CGSize {
        switch g {
        case .symbol(let name, let w):
            if let img = Icons.symbol(name, size: size, weight: w, color: .white) { return img.size }
            return CGSize(width: size, height: size)
        case .text(let s):
            let a = attributed(s, TextStyle(size: size, weight: .regular, color: .fg), style)
            return a.size()
        case .app, .file:
            return CGSize(width: size + 2, height: size + 2)
        }
    }

    // MARK: Drawing

    private static func draw(_ content: ItemContent, style: Style, height: CGFloat, scale: CGFloat) -> Rendered {
        let widths = content.parts.map { width($0, style) }
        let total = ceil(widths.reduce(0, +))
        let collapsed = content.collapsibleFrom.map { ceil(widths.prefix($0).reduce(0, +)) } ?? total
        guard total > 0 else { return Rendered(image: nil, size: .zero, collapsedWidth: 0, hits: []) }
        let size = CGSize(width: total, height: height)
        let px = (Int(ceil(total * scale)), Int(ceil(height * scale)))
        guard let ctx = CGContext(data: nil, width: px.0, height: px.1, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Rendered(image: nil, size: size, collapsedWidth: collapsed, hits: [])
        }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        var hits: [(String, CGRect)] = []
        var x: CGFloat = 0
        for (part, w) in zip(content.parts, widths) {
            draw(part, at: x, width: w, midY: height / 2, style: style, ctx: ctx, hits: &hits)
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
        return Rendered(image: ctx.makeImage(), size: size, collapsedWidth: collapsed, hits: hits)
    }

    private static func draw(_ part: Part, at x: CGFloat, width w: CGFloat, midY: CGFloat, style: Style, ctx: CGContext,
                             hits: inout [(String, CGRect)]) {
        switch part {
        case .icon(let g, let paint, let size, let alpha):
            drawGlyph(g, x: x, midY: midY, size: size, color: style.color(paint), alpha: alpha, style: style)
        case .text(let s, let t):
            let a = attributed(s, t, style)
            let f = style.font(t)
            // Centre on the cap height so mixed fonts share a baseline feel.
            let y = midY - (f.ascender + f.descender) / 2
            a.draw(at: CGPoint(x: x, y: y + f.descender))
        case .stack(let top, let bottom, _):
            draw(top, at: x, width: width(top, style), midY: midY + 6, style: style, ctx: ctx, hits: &hits)
            draw(bottom, at: x, width: width(bottom, style), midY: midY - 5, style: style, ctx: ctx, hits: &hits)
        case .graph(let values, let gw, let paint):
            let frame = CGRect(x: x, y: midY - 8.5, width: gw + 6, height: 17)
            let box = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            style.color(.faded(.fg, 0.05)).setFill()
            box.fill()
            style.color(.faded(.fg, 0.10)).setStroke()
            box.lineWidth = 1
            box.stroke()
            let plot = CGRect(x: x + 3, y: midY - 5.5, width: gw, height: 11)
            guard values.count > 1 else { return }
            let step = plot.width / CGFloat(max(values.count - 1, 1))
            let line = NSBezierPath()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: plot.minX + CGFloat(i) * step, y: plot.minY + CGFloat(min(max(v, 0), 1)) * plot.height)
                if i == 0 { line.move(to: p) } else { line.line(to: p) }
            }
            let fill = line.copy() as! NSBezierPath
            fill.line(to: CGPoint(x: plot.minX + CGFloat(values.count - 1) * step, y: plot.minY))
            fill.line(to: CGPoint(x: plot.minX, y: plot.minY))
            fill.close()
            style.color(.faded(paint, 0.22)).setFill()
            fill.fill()
            style.color(paint).setStroke()
            line.lineWidth = 1.2
            line.lineJoinStyle = .round
            line.stroke()
        case .space:
            break
        case .group(let g):
            let rect = CGRect(x: x, y: midY - g.height / 2, width: w, height: g.height)
            if let fill = g.fill {
                style.color(fill).setFill()
                NSBezierPath(roundedRect: rect, xRadius: min(g.radius, g.height / 2), yRadius: min(g.radius, g.height / 2)).fill()
            }
            if let tag = g.tag { hits.append((tag, rect)) }
            var cx = x + g.padding
            for (i, p) in g.parts.enumerated() {
                let pw = width(p, style)
                draw(p, at: cx, width: pw, midY: midY, style: style, ctx: ctx, hits: &hits)
                cx += pw + (i < g.parts.count - 1 ? g.spacing : 0)
            }
        }
    }

    private static func drawGlyph(_ g: Glyph, x: CGFloat, midY: CGFloat, size: CGFloat, color: NSColor, alpha: CGFloat, style: Style) {
        switch g {
        case .symbol(let name, let w):
            guard let img = Icons.symbol(name, size: size, weight: w, color: color) else { return }
            img.draw(in: CGRect(x: x, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: alpha)
        case .text(let s):
            let a = attributed(s, TextStyle(size: size, weight: .regular, color: .rgb(ARGB(color))), style)
            let sz = a.size()
            a.draw(at: CGPoint(x: x, y: midY - sz.height / 2))
        case .app(let key):
            guard let img = Icons.app(key) else { return }
            let s = size + 2
            img.draw(in: CGRect(x: x, y: midY - s / 2, width: s, height: s), from: .zero, operation: .sourceOver, fraction: alpha)
        case .file(let path):
            guard let img = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath) else { return }
            let s = size + 2
            img.draw(in: CGRect(x: x, y: midY - s / 2, width: s, height: s), from: .zero, operation: .sourceOver, fraction: alpha)
        }
    }
}
