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
///
/// With `glass` on, each island also gets an `NSGlassEffectView` under it, all in one
/// `NSGlassEffectContainerView` (one batched pass in the window server). Glass views move with
/// their island through implicit Core Animation, so nothing runs on tip's side while they animate.
@MainActor
final class Bar {
    let display: DisplayInfo
    let panel: BarPanel
    let view: BarView
    /// Holds the islands' glass, under `view`.
    private let glassHost = NSGlassEffectContainerView()
    private let glassContent = NSView()
    /// Glass behind the whole bar (`bar.material: "glass"`).
    private var barGlass: NSGlassEffectView?
    private var islandLayers: [String: CALayer] = [:]
    private var glassViews: [String: NSGlassEffectView] = [:]
    private var itemLayers: [String: CALayer] = [:]
    /// Sliding highlights by item layer key and index, under their item.
    private var slideLayers: [String: [CALayer]] = [:]
    /// Where each node sits (view coordinates), for clicks and popups.
    private(set) var hits: [(node: String, rect: CGRect, tags: [(String, CGRect)])] = []
    private var errorDot: CALayer?
    weak var manager: BarManager?

    init(display: DisplayInfo, screen: NSScreen) {
        self.display = display
        panel = BarPanel()
        view = BarView()
        view.bar = self
        let root = BarRootView()
        root.wantsLayer = true
        root.bar = view
        panel.contentView = root
        glassHost.contentView = glassContent
        glassHost.autoresizingMask = [.width, .height]
        root.addSubview(glassHost)
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        view.layer = CALayer()
        view.wantsLayer = true
        view.layer?.masksToBounds = false
    }

    func place(on screen: NSScreen, config: TipConfig) {
        let h = config.bar.height
        let f = screen.frame
        let y = config.bar.position == "bottom" ? f.minY + config.bar.yOffset : f.maxY - h - config.bar.yOffset
        panel.setFrame(CGRect(x: f.minX, y: y, width: f.width, height: h), display: false)
        let root = panel.contentView!
        glassHost.frame = root.bounds
        glassContent.frame = root.bounds
        view.frame = root.bounds
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

    func render(_ model: BarModel, manager m: BarManager, screen: NSScreen, animate: BarManager.Motion) {
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
        let ms = animate == .content ? min(cfg.animation.contentMs, cfg.animation.durationMs) : cfg.animation.durationMs
        let motionAllowed = cfg.animation.enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motion = animate != .none && ms > 0 && motionAllowed
        CATransaction.setDisableActions(!motion)
        if motion {
            CATransaction.setAnimationDuration(ms / 1000)
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
                let bare = mi.items.allSatisfy { item in
                    cfg.island.bare.contains(item.node) || cfg.island.bare.contains(String(item.node.prefix { $0 != "." }))
                }
                let glass = !bare && style.glass
                decorate(layer, style: style, material: bare ? "bare" : glass ? "glass" : "solid")
                syncGlass(key, frame: frame, style: style, on: glass, motion: motion ? timing(ms) : nil)
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
                    syncSlides(ikey, item.r.slides, x: ix, island: layer, below: il, glide: motionAllowed, ms: cfg.animation.durationMs)
                    let rect = CGRect(x: frame.minX + ix, y: frame.minY, width: item.width, height: ih)
                    let tags = item.r.hits.map { ($0.tag, $0.rect.offsetBy(dx: rect.minX, dy: rect.minY)) }
                    newHits.append((item.node, rect, tags))
                    ix += item.width + spacing
                }
            }
        }
        for (k, l) in islandLayers where !seenIslands.contains(k) {
            islandLayers[k] = nil
            let g = glassViews.removeValue(forKey: k)
            leave(l, glass: g, motion: motion ? timing(ms) : nil)
        }
        syncBarGlass(on: cfg.bar.material == "glass" && style.glass, style: style)
        for (k, ls) in slideLayers where !seenItems.contains(k) {
            ls.forEach { $0.removeFromSuperlayer() }
            slideLayers[k] = nil
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

    /// The render's motion as an NSAnimationContext needs it.
    private func timing(_ ms: Double) -> (Double, CAMediaTimingFunction) {
        let b = Easing.bezier(manager?.store.config.animation.easing ?? "easeOutCubic")
        return (ms / 1000, CAMediaTimingFunction(controlPoints: Float(b.0), Float(b.1), Float(b.2), Float(b.3)))
    }

    /// An island going away: with motion it fades and its glass shrinks into it, then both go.
    private func leave(_ l: CALayer, glass g: NSGlassEffectView?, motion: (Double, CAMediaTimingFunction)?) {
        guard let motion else {
            l.removeFromSuperlayer()
            g?.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        CATransaction.commit()
        guard let g else { return }
        guard let gl = g.layer else { g.removeFromSuperview(); return }
        Morph.run(gl, from: Self.seed(g.frame), to: g.frame, fade: .out, motion) { g.removeFromSuperview() }
    }

    /// Where a glass island grows from and shrinks into: a pill at its middle, so the glass
    /// swells into place like a drop rather than popping in.
    private static func seed(_ r: CGRect) -> CGRect {
        let w = min(r.width, max(r.height, r.width * 0.6))
        return CGRect(x: r.midX - w / 2, y: r.minY + r.height * 0.1, width: w, height: r.height * 0.8)
    }

    private func makeIsland() -> CALayer {
        let l = CALayer()
        l.cornerCurve = .continuous
        l.masksToBounds = false
        view.layer?.addSublayer(l)
        return l
    }

    /// Places an item's sliding highlights; a moved one glides there over `ms`, a new one appears.
    private func syncSlides(_ key: String, _ slides: [Renderer.Slide], x: CGFloat, island: CALayer, below item: CALayer,
                            glide: Bool, ms: Double) {
        var layers = slideLayers[key] ?? []
        while layers.count > slides.count { layers.removeLast().removeFromSuperlayer() }
        for (i, s) in slides.enumerated() {
            let frame = s.rect.offsetBy(dx: x, dy: 0)
            let fresh = i >= layers.count
            if fresh {
                let l = CALayer()
                l.cornerCurve = .continuous
                layers.append(l)
            }
            let l = layers[i]
            if l.superlayer !== island { island.insertSublayer(l, below: item) }
            CATransaction.begin()
            if fresh || !glide || l.frame == frame {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(ms / 1000)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1))
            }
            l.frame = frame
            l.backgroundColor = s.color
            l.cornerRadius = s.radius
            CATransaction.commit()
        }
        slideLayers[key] = layers
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
        if material == "bare" {
            l.backgroundColor = nil
            l.borderWidth = 0
            l.shadowOpacity = 0
            return
        }
        let glass = material == "glass"
        // Glass brings its own fill, rim and shadow; the theme's border stays (a neon edge is
        // part of cyberpunk) but at half strength so it sits on the glass's own rim.
        l.backgroundColor = glass ? style.glassVeil(style.palette.card) : style.palette.card.cg
        l.borderColor = glass ? style.palette.border.alpha(style.palette.border.a * 0.5).cg : style.palette.border.cg
        l.borderWidth = style.theme.borderWidth
        l.cornerRadius = min(style.radius, style.islandHeight / 2)
        if style.theme.shadow, !glass {
            l.shadowColor = CGColor(gray: 0, alpha: 1)
            l.shadowOpacity = Float(style.theme.shadowOpacity)
            l.shadowRadius = style.theme.shadowRadius
            l.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            l.shadowOpacity = 0
        }
    }

    /// Liquid Glass under an island (`glass: true`). A new one swells from a pill at the island's
    /// middle; a moved or resized one glides with its island. Both are Core Animation on the
    /// glass view's layer: the window server runs them, tip only sets the end state.
    private func syncGlass(_ key: String, frame: CGRect, style: Style, on: Bool, motion: (Double, CAMediaTimingFunction)?) {
        guard on else {
            glassViews.removeValue(forKey: key)?.removeFromSuperview()
            return
        }
        let g: NSGlassEffectView
        var fresh = false
        if let existing = glassViews[key] { g = existing } else {
            g = NSGlassEffectView()
            glassContent.addSubview(g)
            glassViews[key] = g
            fresh = true
        }
        let radius = min(style.radius, style.islandHeight / 2)
        if g.cornerRadius != radius { g.cornerRadius = radius }
        let tint = style.glassTint(style.palette.card)
        if g.tintColor != tint { g.tintColor = tint }
        let appearance = style.appearance
        if g.appearance?.name != appearance?.name { g.appearance = appearance }
        if fresh {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            g.frame = frame
            CATransaction.commit()
            if let motion, let l = g.layer { Morph.run(l, from: Self.seed(frame), to: frame, fade: .in, motion) }
            return
        }
        let old = g.frame
        guard old != frame else { return }
        // The view jumps to its new frame and its layer glides there from the old one (a
        // transform animation). Animating the view's frame instead would have AppKit step it,
        // with a layout pass, on the main thread every display frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.frame = frame
        CATransaction.commit()
        if let motion, let l = g.layer { Morph.run(l, from: old, to: frame, fade: nil, motion) }
    }


    /// One glass strip behind the whole bar (`bar.material: "glass"`), outside the container so
    /// it does not merge with the islands' glass.
    private func syncBarGlass(on: Bool, style: Style) {
        guard on else { barGlass?.removeFromSuperview(); barGlass = nil; return }
        if barGlass == nil {
            let g = NSGlassEffectView()
            g.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(g, positioned: .below, relativeTo: glassHost)
            barGlass = g
        }
        guard let g = barGlass, let root = panel.contentView else { return }
        if g.frame != root.bounds { g.frame = root.bounds }
        g.cornerRadius = 0
        let tint = style.glassTint(style.palette.background)
        if g.tintColor != tint { g.tintColor = tint }
        if g.appearance?.name != style.appearance?.name { g.appearance = style.appearance }
    }

    /// For `tip preview`: glass is drawn by the window server, so a layer snapshot cannot see
    /// it. Islands get their glass tint as a plain fill while `body` renders.
    func withGlassAsFill(_ body: () -> Void) {
        let glassy = islandLayers.filter { glassViews[$0.key] != nil }
        let tint = manager.map { $0.style.palette.card.alpha($0.style.palette.card.a * 0.8).cg }
        let veil = manager.map { $0.style.glassVeil($0.style.palette.card) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, l) in glassy { l.backgroundColor = tint }
        CATransaction.commit()
        body()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, l) in glassy { l.backgroundColor = veil }
        CATransaction.commit()
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

/// Render-server animations for views whose layers AppKit owns (glass, the popup card): the
/// view sits at its final frame and its layer is transformed from where it was (or swells from
/// a seed), so no frame is stepped on the main thread.
enum Morph {
    enum Fade { case `in`, out }

    static func run(_ l: CALayer, from: CGRect, to frame: CGRect, fade: Fade?, _ motion: (Double, CAMediaTimingFunction),
                    done: (() -> Void)? = nil) {
        guard frame.width > 0, frame.height > 0 else { done?(); return }
        // Layer-backed views anchor at their origin: scale, then shift onto `from`.
        var t = CATransform3DMakeTranslation(from.minX - frame.minX, from.minY - frame.minY, 0)
        t = CATransform3DScale(t, from.width / frame.width, from.height / frame.height, 1)
        let moved = NSValue(caTransform3D: t), home = NSValue(caTransform3D: CATransform3DIdentity)
        let out = fade == .out
        let shape = CABasicAnimation(keyPath: "transform")
        shape.fromValue = out ? home : moved
        shape.toValue = out ? moved : home
        var parts: [CAAnimation] = [shape]
        if let fade {
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = fade == .in ? 0 : 1
            o.toValue = fade == .in ? 1 : 0
            parts.append(o)
        }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = motion.0
        group.timingFunction = motion.1
        if out {
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        l.add(group, forKey: "tip.morph")
        CATransaction.commit()
    }
}

/// The panel's content: the glass container under the bar view. Hit testing goes to the bar view
/// only, so glass never takes a click.
final class BarRootView: NSView {
    weak var bar: BarView?
    override func hitTest(_ point: NSPoint) -> NSView? { bar?.hitTest(convert(point, from: superview)) }
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
