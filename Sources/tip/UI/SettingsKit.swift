import AppKit

/// The Settings window's look: System Settings' (the bar's look is the theme). Same as paw's.
enum SettingsTheme {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let background = NSColor.windowBackgroundColor
    static let card = dynamic(light: NSColor(white: 1, alpha: 0.55), dark: NSColor(white: 1, alpha: 0.045))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07))

    static func sans(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: w) }
    static func mono(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: w) }

    /// System Settings' icon: a white SF Symbol on a rounded square of `color`.
    static func tile(_ symbol: String, _ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let r = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: size * 0.225, yRadius: size * 0.225)
            let base = color.usingColorSpace(.sRGB) ?? color
            NSGradient(starting: base.blended(withFraction: 0.18, of: .white) ?? base,
                       ending: base.blended(withFraction: 0.08, of: .black) ?? base)?.draw(in: path, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .medium).applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A grouped section, as in System Settings: rows on a rounded fill, separated by hairlines.
final class Card: NSView {
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        SettingsTheme.card.setFill()
        path.fill()
        SettingsTheme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func add(_ row: NSView) {
        if !stack.arrangedSubviews.isEmpty { stack.addArrangedSubview(Hairline(inset: 16)) }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

final class Hairline: NSView {
    private let vertical: Bool
    private let inset: CGFloat

    init(vertical: Bool = false, inset: CGFloat = 0) {
        self.vertical = vertical
        self.inset = inset
        super.init(frame: .zero)
        if vertical { widthAnchor.constraint(equalToConstant: 1).isActive = true } else { heightAnchor.constraint(equalToConstant: 1).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.insetBy(dx: vertical ? 0 : inset, dy: 0).fill()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if !vertical, let stack = superview as? NSStackView { widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
}

/// Target-action as a closure.
final class Handler: NSObject {
    let action: (Any?) -> Void
    init(_ action: @escaping (Any?) -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action(sender) }
}

/// Builders for rows: a title and help on the left, a control on the right.
@MainActor
final class Rows {
    private(set) var handlers: [Handler] = []
    static let textWidth: CGFloat = 300

    func handler(_ f: @escaping (Any?) -> Void) -> Handler {
        let h = Handler(f)
        handlers.append(h)
        return h
    }

    func reset() { handlers = [] }

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = SettingsTheme.sans(size, weight)
        l.textColor = color
        l.isSelectable = false
        return l
    }

    func text(_ title: String, _ help: String?) -> NSView {
        let t = label(title)
        guard let help, !help.isEmpty else { return t }
        let h = label(help, size: 11, color: .secondaryLabelColor)
        let s = NSStackView(views: [t, h])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        h.preferredMaxLayoutWidth = Self.textWidth
        h.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth).isActive = true
        return s
    }

    func row(_ title: String, _ help: String? = nil, _ control: NSView?) -> NSView {
        var views = [text(title, help)]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if let control { views.append(control) }
        let r = NSStackView(views: views)
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        return r
    }

    func toggle(_ on: Bool, _ change: @escaping (Bool) -> Void) -> NSSwitch {
        let s = NSSwitch()
        s.state = on ? .on : .off
        s.controlSize = .small
        let h = handler { sender in change((sender as? NSSwitch)?.state == .on) }
        s.target = h
        s.action = #selector(Handler.fire(_:))
        return s
    }

    func popup(_ options: [String], _ selected: String, titles: [String]? = nil, _ change: @escaping (String) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles ?? options)
        if let i = options.firstIndex(of: selected) { p.selectItem(at: i) }
        let h = handler { sender in
            guard let p = sender as? NSPopUpButton, p.indexOfSelectedItem >= 0 else { return }
            change(options[p.indexOfSelectedItem])
        }
        p.target = h
        p.action = #selector(Handler.fire(_:))
        return p
    }

    func field(_ value: String, width: CGFloat = 220, placeholder: String? = nil, mono: Bool = false, _ commit: @escaping (String) -> Void) -> NSTextField {
        let f = NSTextField(string: value)
        f.placeholderString = placeholder
        f.font = mono ? SettingsTheme.mono(12) : SettingsTheme.sans(13)
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        let h = handler { sender in commit((sender as? NSTextField)?.stringValue ?? "") }
        f.target = h
        f.action = #selector(Handler.fire(_:))
        return f
    }

    /// `field` with an app picker button beside it. A pick fills the field (`multiple`: appends to
    /// its comma-separated list) and commits it like a finished edit; typing still works.
    func appField(_ field: NSTextField, multiple: Bool) -> NSStackView {
        let pick = AppPicker.button { b in
            let current = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            AppPicker.show(from: b, multiple: multiple, exclude: multiple ? Set(current) : []) { apps in
                let names = apps.map(\.name)
                field.stringValue = (multiple ? current + names : [names[0]]).joined(separator: ", ")
                if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
            }
        }
        let s = NSStackView(views: [field, pick])
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    func number(_ value: Double, range: ClosedRange<Double>, step: Double = 1, _ change: @escaping (Double) -> Void) -> NSView {
        let f = NSTextField(string: Self.fmt(value))
        f.font = SettingsTheme.mono(12)
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let stepper = NSStepper()
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.doubleValue = value
        stepper.valueWraps = false
        let hf = handler { sender in
            guard let v = Double((sender as? NSTextField)?.stringValue ?? "") else { return }
            let c = min(max(v, range.lowerBound), range.upperBound)
            stepper.doubleValue = c
            change(c)
        }
        f.target = hf
        f.action = #selector(Handler.fire(_:))
        let hs = handler { sender in
            let v = (sender as? NSStepper)?.doubleValue ?? value
            f.stringValue = Self.fmt(v)
            change(v)
        }
        stepper.target = hs
        stepper.action = #selector(Handler.fire(_:))
        let s = NSStackView(views: [f, stepper])
        s.spacing = 4
        return s
    }

    func slider(_ value: Double, range: ClosedRange<Double>, width: CGFloat = 160, _ change: @escaping (Double) -> Void) -> NSSlider {
        let s = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.isContinuous = false
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        let h = handler { sender in change((sender as? NSSlider)?.doubleValue ?? value) }
        s.target = h
        s.action = #selector(Handler.fire(_:))
        return s
    }

    func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let h = handler { _ in action() }
        let b = NSButton(title: title, target: h, action: #selector(Handler.fire(_:)))
        b.bezelStyle = .rounded
        return b
    }

    func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = spacing
        s.alignment = .centerY
        return s
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
}
