import AppKit
import TipCore

/// An item's popup: a panel in the island style under the item, a list of rows. Closes on a
/// click elsewhere, when the pointer leaves it, or on the item's click again.
@MainActor
final class PopupController {
    private(set) var node: String?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    var onAction: ((PopupRow) -> Void)?

    var isOpen: Bool { panel != nil }

    func toggle(node: String, rows: [PopupRow], under rect: CGRect, bar: Bar, style: Style) {
        if self.node == node { close(); return }
        show(node: node, rows: rows, under: rect, bar: bar, style: style)
    }

    func show(node: String, rows: [PopupRow], under rect: CGRect, bar: Bar, style: Style) {
        close()
        guard !rows.isEmpty else { return }
        self.node = node
        let view = PopupView(rows: rows, style: style) { [weak self] row in
            self?.close()
            self?.onAction?(row)
        }
        let size = view.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = view
        p.isReleasedWhenClosed = false
        // Under the item, left-aligned with it, kept on screen.
        let screenRect = bar.panel.convertToScreen(rect)
        let visible = bar.panel.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let below = bar.panel.frame.minY > visible.midY
        var x = screenRect.minX
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = below ? screenRect.minY - size.height - 6 : screenRect.maxY + 6
        p.setFrameOrigin(CGPoint(x: x, y: y))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        view.onExit = { [weak self] in self?.close() }
        let click: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if e.window === panel { return }
                // A click on the item itself toggles through the bar.
                if e.window === bar.panel, bar.node(at: bar.view.convert(e.locationInWindow, from: nil))?.node == node { return }
                self.close()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { click($0); return $0 }) { monitors.append(l) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        node = nil
    }
}

private final class PopupView: NSView {
    let rows: [PopupRow]
    let style: Style
    let pick: (PopupRow) -> Void
    var onExit: (() -> Void)?
    private var hover: Int?
    private var entered = false
    private let rowHeight: CGFloat = 26
    private let pad: CGFloat = 6

    init(rows: [PopupRow], style: Style, pick: @escaping (PopupRow) -> Void) {
        self.rows = rows
        self.style = style
        self.pick = pick
        super.init(frame: .zero)
        wantsLayer = true
        let l = layer!
        l.backgroundColor = style.palette.background.cg
        l.borderColor = style.palette.border.cg
        l.borderWidth = max(style.theme.borderWidth, 1)
        l.cornerRadius = min(style.radius + 1, 12)
        l.cornerCurve = .continuous
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func height(_ r: PopupRow) -> CGFloat { r.separator == true ? 9 : rowHeight }

    override var fittingSize: NSSize {
        var w: CGFloat = 180
        for r in rows where r.separator != true {
            let label = MainActor.assumeIsolated { Renderer.attributed(r.label, .label(), style).size().width }
            let detail = r.detail.map { d in MainActor.assumeIsolated { Renderer.attributed(d, .small(), style).size().width } } ?? 0
            w = max(w, 12 + 18 + 8 + label + (detail > 0 ? 24 + detail : 0) + 12)
        }
        return NSSize(width: min(ceil(w), 520), height: rows.map(height).reduce(0, +) + 2 * pad)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func index(at p: CGPoint) -> Int? {
        var y = pad
        for (i, r) in rows.enumerated() {
            let h = height(r)
            if p.y >= y, p.y < y + h { return r.separator == true ? nil : i }
            y += h
        }
        return nil
    }

    override func mouseEntered(with event: NSEvent) { entered = true }
    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
        if entered { onExit?() }
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let row = rows[i]
        if row.action != nil || row.id != nil { pick(row) }
    }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            var y = pad
            for (i, r) in rows.enumerated() {
                let h = height(r)
                defer { y += h }
                if r.separator == true {
                    style.color(.token(.border)).setFill()
                    NSRect(x: 10, y: y + 4, width: bounds.width - 20, height: 1).fill()
                    continue
                }
                let rect = NSRect(x: 4, y: y, width: bounds.width - 8, height: h)
                let actionable = r.action != nil || r.id != nil
                if hover == i, actionable {
                    style.color(.token(.muted)).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                }
                let tone = r.color.flatMap(Paint.parse)
                if let icon = r.icon {
                    drawIcon(Glyph.parse(icon), color: style.color(tone ?? .secondary), x: 12, midY: y + h / 2)
                }
                let label = Renderer.attributed(r.label, .label(actionable || tone == nil ? .fg : tone!), style)
                label.draw(at: NSPoint(x: 38, y: y + (h - label.size().height) / 2))
                if let d = r.detail {
                    let a = Renderer.attributed(d, .small(), style)
                    a.draw(at: NSPoint(x: bounds.width - 12 - a.size().width, y: y + (h - a.size().height) / 2))
                }
            }
        }
    }

    @MainActor private func drawIcon(_ g: Glyph, color: NSColor, x: CGFloat, midY: CGFloat) {
        switch g {
        case .symbol(let name, let w):
            guard let img = Icons.symbol(name, size: 13, weight: w, color: color) else { return }
            img.draw(in: NSRect(x: x + (18 - img.size.width) / 2, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .app(let key):
            Icons.app(key)?.draw(in: NSRect(x: x, y: midY - 9, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: nil)
        case .file(let path):
            NSImage(contentsOfFile: (path as NSString).expandingTildeInPath)?
                .draw(in: NSRect(x: x, y: midY - 9, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .text(let s):
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color])
            a.draw(at: NSPoint(x: x, y: midY - a.size().height / 2))
        }
    }
}
