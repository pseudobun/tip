import AppKit
import TipCore

/// An item's popup: a panel in the island style under the item, a list of rows. Closes on a
/// click elsewhere, when the pointer leaves it, or on the item's click again.
///
/// Its card is Liquid Glass (`glass: true`) or the theme's solid fill. Opening, the card swells
/// down from the item's edge while the rows fade in; the hover highlight glides between rows.
/// All of it is implicit Core Animation, run by the window server: no timers in tip.
@MainActor
final class PopupController {
    private(set) var node: String?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    var onAction: ((PopupRow) -> Void)?
    var animation = TipConfig.Animation()

    /// Duration and curve when motion is on and Reduce Motion is off.
    private var motion: (Double, CAMediaTimingFunction)? {
        guard animation.enabled, animation.durationMs > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        let b = Easing.bezier(animation.easing)
        return (min(animation.durationMs, 400) / 1000, CAMediaTimingFunction(controlPoints: Float(b.0), Float(b.1), Float(b.2), Float(b.3)))
    }

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
        // Glass draws its own shadow; a window shadow would outline the card's final shape
        // while it is still swelling.
        p.hasShadow = !style.glass
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let radius = min(style.radius + 1, 12)
        let card: NSView
        if style.glass {
            let g = NSGlassEffectView()
            g.cornerRadius = radius
            g.tintColor = style.glassTint(style.palette.background)
            g.appearance = style.appearance
            let veil = NSView()
            veil.wantsLayer = true
            veil.layer?.backgroundColor = style.glassVeil(style.palette.background)
            veil.layer?.cornerRadius = radius
            veil.layer?.cornerCurve = .continuous
            g.contentView = veil
            card = g
        } else {
            card = NSView()
            card.wantsLayer = true
            let l = card.layer!
            l.backgroundColor = style.palette.background.cg
            l.borderColor = style.palette.border.cg
            l.borderWidth = max(style.theme.borderWidth, 1)
            l.cornerRadius = radius
            l.cornerCurve = .continuous
        }
        card.frame = root.bounds
        root.addSubview(card)
        view.frame = root.bounds
        root.addSubview(view)
        p.contentView = root
        p.isReleasedWhenClosed = false
        // Under the item, left-aligned with it, kept on screen.
        let screenRect = bar.panel.convertToScreen(rect)
        let visible = bar.panel.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let below = bar.panel.frame.minY > visible.midY
        var x = screenRect.minX
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = below ? screenRect.minY - size.height - 6 : screenRect.maxY + 6
        p.setFrameOrigin(CGPoint(x: x, y: y))
        if let motion {
            // The card starts as a strip at the edge facing the item and swells to full size
            // while the rows fade in. Layer animations only: the animator proxy would step
            // frames on the main thread.
            let h = min(size.height, 30)
            let strip = CGRect(x: 0, y: below ? size.height - h : 0, width: size.width, height: h)
            p.orderFrontRegardless()
            if let l = card.layer { Morph.run(l, from: strip, to: root.bounds, fade: nil, motion) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = motion.0
            fade.timingFunction = motion.1
            root.layer?.add(fade, forKey: "tip.open")
        } else {
            p.orderFrontRegardless()
        }
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
        if let p = panel {
            if motion != nil, let l = p.contentView?.layer {
                // A quick fade, then gone; the next popup does not wait for it.
                p.ignoresMouseEvents = true
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.1
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                CATransaction.begin()
                CATransaction.setCompletionBlock { p.orderOut(nil); p.close() }
                l.add(fade, forKey: "tip.close")
                CATransaction.commit()
            } else {
                p.orderOut(nil)
                p.close()
            }
        }
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
    /// The hover highlight: one layer under the rows that glides to the hovered row, so moving
    /// the pointer never redraws text.
    private let highlight = CALayer()
    private let ink = PopupInk()

    init(rows: [PopupRow], style: Style, pick: @escaping (PopupRow) -> Void) {
        self.rows = rows
        self.style = style
        self.pick = pick
        super.init(frame: .zero)
        wantsLayer = true
        highlight.backgroundColor = style.color(.token(.muted)).cgColor
        highlight.cornerRadius = 6
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        highlight.zPosition = -1
        layer!.addSublayer(highlight)
        ink.owner = self
        ink.autoresizingMask = [.width, .height]
        addSubview(ink)
        setFrameSize(fittingSize)
        ink.frame = bounds
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
        if i != hover { hover = i; moveHighlight() }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        moveHighlight()
        if entered { onExit?() }
    }

    /// Glides the highlight to the hovered actionable row, or fades it out.
    private func moveHighlight() {
        var y = pad
        var target: CGRect?
        for (i, r) in rows.enumerated() {
            let h = height(r)
            if i == hover, r.action != nil || r.id != nil { target = CGRect(x: 4, y: y, width: bounds.width - 8, height: h) }
            y += h
        }
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1))
        if let target {
            // Appearing: in place, only fading in; moving between rows: gliding.
            let wasHidden = highlight.opacity == 0
            if wasHidden || !motion {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                highlight.frame = flipped(target)
                CATransaction.commit()
            } else {
                highlight.frame = flipped(target)
            }
            highlight.opacity = 1
        } else {
            highlight.opacity = 0
        }
        CATransaction.commit()
    }

    /// Rows count from the top; the layer may not be flipped like this view.
    private func flipped(_ r: CGRect) -> CGRect {
        layer?.isGeometryFlipped == true ? r : CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let row = rows[i]
        if row.action != nil || row.id != nil { pick(row) }
    }

    fileprivate func drawRows() {
        MainActor.assumeIsolated {
            var y = pad
            for r in rows {
                let h = height(r)
                defer { y += h }
                if r.separator == true {
                    style.color(.token(.border)).setFill()
                    NSRect(x: 10, y: y + 4, width: bounds.width - 20, height: 1).fill()
                    continue
                }
                let actionable = r.action != nil || r.id != nil
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

/// Draws the popup's rows once; the hover highlight lives in a layer under it.
private final class PopupInk: NSView {
    weak var owner: PopupView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawRows() }
}
