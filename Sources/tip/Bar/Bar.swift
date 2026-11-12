import AppKit
import QuartzCore
import TipCore

/// One island to draw: the item nodes inside it, in order.
struct IslandModel: Equatable {
    let key: String
    let nodes: [String]
}

/// What a bar shows, decided by BarManager.
struct BarModel {
    var left: [IslandModel] = []
    var center: [IslandModel] = []
    var right: [IslandModel] = []
    var centerAllowed = true
}

/// A borderless panel along one display's top (or bottom) edge. Layer-backed, no SwiftUI: an
/// island is a CALayer with one sublayer per item, each item one cached bitmap. Clicks outside
/// items fall through to the windows below.
@MainActor
final class Bar {
    let display: DisplayInfo
    let panel: BarPanel
    let view: BarView
    private var islandLayers: [String: CALayer] = [:]
    private var glassViews: [String: NSView] = [:]
    private var itemLayers: [String: CALayer] = [:]
    /// Where each node sits (view coordinates), for clicks and popups.
    private(set) var hits: [(node: String, rect: CGRect, tags: [(String, CGRect)])] = []
    private var errorDot: CALayer?
    weak var manager: BarManager?

    init(display: DisplayInfo, screen: NSScreen) {
        self.display = display
        panel = BarPanel()
        view = BarView()
        view.bar = self
        panel.contentView = view
        view.layer = CALayer()
        view.wantsLayer = true
        view.layer?.masksToBounds = false
    }

    func place(on screen: NSScreen, config: TipConfig) {
        let h = config.bar.height
        let f = screen.frame
        let y = config.bar.position == "bottom" ? f.minY + config.bar.yOffset : f.maxY - h - config.bar.yOffset
        panel.setFrame(CGRect(x: f.minX, y: y, width: f.width, height: h), display: false)
        view.layer?.contentsScale = screen.backingScaleFactor
        panel.orderFrontRegardless()
    }

    /// The notch's x range in bar coordinates, if the display has one.
    static func notch(of screen: NSScreen) -> ClosedRange<Double>? {
        guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
        let lo = l.maxX - screen.frame.minX, hi = r.minX - screen.frame.minX
        return hi > lo ? lo...hi : nil
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Drawing

    func render(_ model: BarModel, manager m: BarManager, screen: NSScreen, animate: Bool) {
        let style = m.style
        let cfg = m.store.config
        let scale = screen.backingScaleFactor
        let h = CGFloat(cfg.bar.height)
        let ih = style.islandHeight
        let pad = CGFloat(cfg.island.padding), spacing = CGFloat(cfg.island.spacing)

        struct Measured { let island: IslandModel; let items: [(node: String, r: Renderer.Rendered, width: CGFloat)]; let width: CGFloat }
        func measure(_ islands: [IslandModel]) -> [Measured] {
            islands.map { isl in
                var items: [(String, Renderer.Rendered, CGFloat)] = []
                for node in isl.nodes {
                    guard let content = m.content(node, display: display.id), content.drawing, m.isShown(node) else { continue }
                    let r = Renderer.render(content, style: style, height: ih, scale: scale)
                    guard r.size.width > 0 else { continue }
                    let w = (content.collapsibleFrom != nil && !m.expanded.contains(node)) ? r.collapsedWidth : r.size.width
                    items.append((node, r, w))
                }
                let inner = items.map(\.2).reduce(0, +) + CGFloat(max(items.count - 1, 0)) * spacing
                return Measured(island: isl, items: items.map { ($0.0, $0.1, $0.2) }, width: items.isEmpty ? 0 : inner + 2 * pad)
            }
        }
        let left = measure(model.left), center = measure(model.center), right = measure(model.right)
        let solved = LayoutSolver.solve(.init(
            width: Double(view.bounds.width), marginLeft: cfg.bar.margin.left, marginRight: cfg.bar.margin.right, gap: cfg.island.gap,
            notch: display.builtin ? Bar.notch(of: screen) : nil, centerAllowed: model.centerAllowed,
            left: left.map { Double($0.width) }, center: center.map { Double($0.width) }, right: right.map { Double($0.width) }))

        CATransaction.begin()
        let motion = animate && cfg.animation.enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.setDisableActions(!motion)
        if motion {
            CATransaction.setAnimationDuration(cfg.animation.durationMs / 1000)
            let b = Easing.bezier(cfg.animation.easing)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: Float(b.0), Float(b.1), Float(b.2), Float(b.3)))
        }
        var seenIslands = Set<String>(), seenItems = Set<String>()
        var newHits: [(String, CGRect, [(String, CGRect)])] = []
        let y = (h - ih) / 2
        for (measured, xs) in [(left, solved.left), (center, solved.center), (right, solved.right)] {
            for (mi, x) in zip(measured, xs) {
                guard let x, mi.width > 0 else { continue }
                let key = mi.island.key
                seenIslands.insert(key)
                let isNew = islandLayers[key] == nil
                let layer = islandLayers[key] ?? makeIsland()
                islandLayers[key] = layer
                let frame = CGRect(x: CGFloat(x), y: y, width: mi.width, height: ih)
                if isNew {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.frame = frame
                    if motion { layer.opacity = 0 }
                    CATransaction.commit()
                    if motion { layer.opacity = 1 }
                } else {
                    layer.frame = frame
                }
                decorate(layer, style: style, material: cfg.island.material)
                syncGlass(key, frame: frame, style: style, on: cfg.island.material == "glass")
                var ix = pad
                for item in mi.items {
                    let ikey = key + "|" + item.node
                    seenItems.insert(ikey)
                    let fresh = itemLayers[ikey] == nil
                    let il = itemLayers[ikey] ?? makeItem(in: layer)
                    itemLayers[ikey] = il
                    if il.superlayer !== layer { layer.addSublayer(il) }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    il.contents = item.r.image
                    il.contentsScale = scale
                    if fresh { il.frame = CGRect(x: ix, y: 0, width: item.width, height: ih) }
                    CATransaction.commit()
                    il.frame = CGRect(x: ix, y: 0, width: item.width, height: ih)
                    let rect = CGRect(x: frame.minX + ix, y: frame.minY, width: item.width, height: ih)
                    let tags = item.r.hits.map { ($0.tag, $0.rect.offsetBy(dx: rect.minX, dy: rect.minY)) }
                    newHits.append((item.node, rect, tags))
                    ix += item.width + spacing
                }
            }
        }
        for (k, l) in islandLayers where !seenIslands.contains(k) {
            l.removeFromSuperlayer()
            islandLayers[k] = nil
            glassViews.removeValue(forKey: k)?.removeFromSuperview()
        }
        for (k, l) in itemLayers where !seenItems.contains(k) {
            l.removeFromSuperlayer()
            itemLayers[k] = nil
        }
        CATransaction.commit()
        hits = newHits
        updateErrorDot(m.store.error != nil, style: style)
        view.updateToolTips(newHits.compactMap { h in m.content(h.0, display: display.id)?.tooltip.map { (h.1, $0) } })
    }

    private func makeIsland() -> CALayer {
        let l = CALayer()
        l.cornerCurve = .continuous
        l.masksToBounds = false
        view.layer?.addSublayer(l)
        return l
    }

    private func makeItem(in island: CALayer) -> CALayer {
        let l = CALayer()
        l.contentsGravity = .left
        l.masksToBounds = true
        l.actions = ["contents": NSNull()]
        island.addSublayer(l)
        return l
    }

    private func decorate(_ l: CALayer, style: Style, material: String) {
        let glass = material == "glass"
        l.backgroundColor = glass ? style.palette.card.alpha(min(style.palette.card.a, 0.25)).cg : style.palette.card.cg
        l.borderColor = style.palette.border.cg
        l.borderWidth = style.theme.borderWidth
        l.cornerRadius = min(style.radius, style.islandHeight / 2)
        if style.theme.shadow {
            l.shadowColor = CGColor(gray: 0, alpha: 1)
            l.shadowOpacity = Float(style.theme.shadowOpacity)
            l.shadowRadius = style.theme.shadowRadius
            l.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            l.shadowOpacity = 0
        }
    }

    /// Liquid Glass behind an island (`island.material: "glass"`).
    private func syncGlass(_ key: String, frame: CGRect, style: Style, on: Bool) {
        guard on else {
            glassViews.removeValue(forKey: key)?.removeFromSuperview()
            return
        }
        let v: NSView
        if let existing = glassViews[key] { v = existing } else {
            let g = NSGlassEffectView()
            g.cornerRadius = min(style.radius, style.islandHeight / 2)
            view.addSubview(g, positioned: .below, relativeTo: nil)
            glassViews[key] = g
            v = g
        }
        v.frame = frame
    }

    /// A small red dot at the bar's left edge while the config file is broken.
    private func updateErrorDot(_ on: Bool, style: Style) {
        guard on else { errorDot?.removeFromSuperlayer(); errorDot = nil; return }
        if errorDot == nil {
            let d = CALayer()
            d.cornerRadius = 3.5
            view.layer?.addSublayer(d)
            errorDot = d
        }
        errorDot?.backgroundColor = style.palette.destructive.cg
        errorDot?.frame = CGRect(x: 8, y: view.bounds.midY - 3.5, width: 7, height: 7)
    }

    func node(at p: CGPoint) -> (node: String, tag: String?, rect: CGRect)? {
        for h in hits where h.rect.contains(p) {
            let tag = h.tags.first { $0.1.contains(p) }?.0
            return (h.node, tag, h.rect)
        }
        return nil
    }

    var debugLayers: [String] {
        islandLayers.map { "\($0.key) \($0.value.frame) op=\($0.value.opacity) super=\($0.value.superlayer != nil) subs=\($0.value.sublayers?.map { "\($0.frame)" } ?? [])" }
    }

    func rect(of node: String) -> CGRect? { hits.first { $0.node == node }?.rect }
}

final class BarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Routes clicks and scrolls to the item under the pointer; everything else falls through.
final class BarView: NSView, NSViewToolTipOwner {
    weak var bar: Bar?
    private var tipTags: [NSView.ToolTipTag] = []
    private var tipTexts: [Int: String] = [:]

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return MainActor.assumeIsolated { bar?.node(at: p) } != nil ? self : nil
    }

    private func dispatch(_ event: NSEvent, _ trigger: Trigger) {
        let p = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            guard let bar, let hit = bar.node(at: p) else { return }
            bar.manager?.handle(trigger, node: hit.node, tag: hit.tag, bar: bar, modifiers: event.modifierFlags)
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { dispatch(event, .click) }
    override func rightMouseUp(with event: NSEvent) { dispatch(event, .rightClick) }
    override func otherMouseUp(with event: NSEvent) { dispatch(event, .click) }

    private var scrollAccum: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        scrollAccum += d
        guard abs(scrollAccum) >= 1 else { return }
        dispatch(event, scrollAccum > 0 ? .scrollUp : .scrollDown)
        scrollAccum = 0
    }

    func updateToolTips(_ tips: [(CGRect, String)]) {
        removeAllToolTips()
        tipTexts = [:]
        for (i, t) in tips.enumerated() {
            tipTexts[i] = t.1
            addToolTip(t.0, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tipTexts[(Int(bitPattern: data) - 1)] ?? ""
    }
}
