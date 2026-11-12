import AppKit
import TipCore

/// The Appearance page: the theme picker (hover previews on the real bar, click switches), the
/// custom theme builder (edits a file in ~/.config/tip/themes/ live) and the island keys.
extension SettingsController {
    func appearancePage() {
        let c = store.config
        let current = c.theme.lowercased()
        let tiles = store.allThemes.map { t in
            ThemeTile(theme: t, selected: t.id == current) { [unowned self] hovering in
                bars.previewTheme = hovering ? t : nil
            } pick: { [unowned self] in
                bars.previewTheme = nil
                write(["theme"], ConfigEdit.literal(t.id))
            }
        }
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 14
        grid.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        for i in stride(from: 0, to: tiles.count, by: 3) {
            var row = Array(tiles[i..<min(i + 3, tiles.count)]) as [NSView]
            while row.count < 3 { row.append(NSView()) }
            let r = NSStackView(views: row)
            r.spacing = 14
            r.distribution = .fillEqually
            grid.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: grid.widthAnchor, constant: -32).isActive = true
        }
        let follow = rows.popup(["", "follow-paw", "follow-hop"], Themes.follow.contains(current) ? current : "",
                                titles: ["Own theme", "Follow paw's theme", "Follow hop's theme"]) { [unowned self] v in
            write(["theme"], ConfigEdit.literal(v.isEmpty ? store.theme(c.theme).id : v))
        }
        section("Theme", [grid, rows.row("Follow", "Use paw's or hop's theme whenever it changes there.", follow)],
                footer: "Hover a theme to see it on the bar; click to use it.")
        themeBuilder()
        section("Islands", [
            rows.row("Island height", nil, rows.number(c.island.height, range: 12...c.bar.height) { [unowned self] v in write(["island", "height"], Rows.fmt(v)) }),
            rows.row("Corner radius", "Empty: the theme's (\(Rows.fmt(store.theme(c.theme).radius))).",
                     rows.field(c.island.radius.map(Rows.fmt) ?? "", width: 60, placeholder: "theme", mono: true) { [unowned self] v in
                         if let n = Double(v) { write(["island", "radius"], Rows.fmt(n)) } else { _ = store.remove(["island", "radius"]) }
                     }),
            rows.row("Gap between islands", nil, rows.number(c.island.gap, range: 0...40) { [unowned self] v in write(["island", "gap"], Rows.fmt(v)) }),
            rows.row("Padding", "Inside an island, at its ends.", rows.number(c.island.padding, range: 0...40) { [unowned self] v in write(["island", "padding"], Rows.fmt(v)) }),
            rows.row("Spacing", "Between items in an island.", rows.number(c.island.spacing, range: 0...40) { [unowned self] v in write(["island", "spacing"], Rows.fmt(v)) }),
            rows.row("Material", "Glass: Liquid Glass behind each island.", rows.popup(["solid", "glass"], c.island.material, titles: ["Solid", "Glass"]) { [unowned self] v in
                write(["island", "material"], ConfigEdit.literal(v))
            }),
        ])
    }

    // MARK: Theme builder

    private func themeBuilder() {
        let theme = store.theme(store.config.theme)
        var views: [NSView] = []
        let actions = rows.hstack([
            rows.button(theme.isBuiltIn ? "Customize…" : "Duplicate…") { [unowned self] in newTheme(from: theme) },
            rows.button("Import…") { [unowned self] in importTheme() },
            rows.button("Folder") { [unowned self] in
                try? FileManager.default.createDirectory(at: store.themesFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(store.themesFolder)
            },
        ])
        views.append(rows.row(theme.isBuiltIn ? "Make your own" : "Editing \(theme.label)",
                              theme.isBuiltIn ? "Copies \(theme.label) into a theme file you can change here or in an editor."
                                  : (theme.file ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"), actions))
        guard !theme.isBuiltIn else {
            section("Theme builder", views)
            return
        }
        let names: [Paint.Token: String] = [
            .background: "Popups", .card: "Island fill", .muted: "Highlight", .foreground: "Text", .mutedForeground: "Secondary text",
            .border: "Border", .ring: "Dim text", .primary: "Accent", .good: "Good", .warn: "Warn", .info: "Info", .destructive: "Bad",
            .chart1: "Chart 1 (graph, ETH)", .chart2: "Chart 2 (gas)", .chart3: "Chart 3 (BTC)", .chart4: "Chart 4", .chart5: "Chart 5",
        ]
        // Colours two per row.
        let tokens = Paint.Token.allCases
        for i in stride(from: 0, to: tokens.count, by: 2) {
            let pair = tokens[i..<min(i + 2, tokens.count)].map { token -> NSView in
                let well = NSColorWell(style: .minimal)
                well.color = theme.palette[token].ns
                well.widthAnchor.constraint(equalToConstant: 44).isActive = true
                let h = rows.handler { [unowned self] sender in
                    guard let w = sender as? NSColorWell else { return }
                    themeWrite(theme, ["colors", token.rawValue], ConfigEdit.literal(ARGB(w.color).hex))
                }
                well.target = h
                well.action = #selector(Handler.fire(_:))
                let label = rows.label(names[token] ?? token.rawValue, size: 12)
                let hex = rows.label(theme.palette[token].hex, size: 10, color: .tertiaryLabelColor)
                hex.font = SettingsTheme.mono(10)
                let text = NSStackView(views: [label, hex])
                text.orientation = .vertical
                text.alignment = .leading
                text.spacing = 0
                let s = rows.hstack([well, text], spacing: 10)
                s.widthAnchor.constraint(equalToConstant: 240).isActive = true
                return s
            }
            let r = rows.hstack(pair, spacing: 24)
            r.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
            views.append(r)
        }
        let families = ["system", "system-mono"] + NSFontManager.shared.availableFontFamilies.filter {
            NSFont(name: $0, size: 12)?.isFixedPitch ?? false || ["Geist Mono", "DM Mono", "Share Tech Mono", "Outfit"].contains($0)
        }
        views.append(rows.row("Font", "Labels and numbers. Mono fonts keep numbers from jumping.",
                              rows.popup(families.contains(theme.font) ? families : [theme.font] + families, theme.font) { [unowned self] v in
                                  themeWrite(theme, ["font"], ConfigEdit.literal(v), now: true)
                              }))
        views.append(rows.row("Font size", nil, rows.number(theme.fontSize, range: 8...20, step: 0.5) { [unowned self] v in
            themeWrite(theme, ["fontSize"], Rows.fmt(v), now: true)
        }))
        views.append(rows.row("Corner radius", nil, rows.slider(theme.radius, range: 0...16) { [unowned self] v in
            themeWrite(theme, ["radius"], Rows.fmt(v.rounded()), now: true)
        }))
        views.append(rows.row("Border width", nil, rows.slider(theme.borderWidth, range: 0...3) { [unowned self] v in
            themeWrite(theme, ["borderWidth"], Rows.fmt((v * 2).rounded() / 2), now: true)
        }))
        views.append(rows.row("Shadow", nil, rows.toggle(theme.shadow) { [unowned self] on in themeWrite(theme, ["shadow"], ConfigEdit.literal(on), now: true) }))
        views.append(rows.row("Light", "Light themes get light popups and previews.", rows.toggle(theme.light) { [unowned self] on in
            themeWrite(theme, ["light"], ConfigEdit.literal(on), now: true)
        }))
        views.append(rows.row("Delete theme", "Moves the file to the Trash and goes back to \(Themes.builtIn(theme.base ?? "og")?.label ?? "OG").",
                              rows.button("Delete…") { [unowned self] in deleteTheme(theme) }))
        section("Theme builder", views, footer: "Changes save to the theme file as you make them; the bar follows at once.")
    }

    /// Colour wells fire continuously: write once they settle.
    private func themeWrite(_ theme: BarTheme, _ path: [String], _ literal: String, now: Bool = false) {
        pendingThemeWrite?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let e = self.store.setTheme(theme, path, literal: literal) { self.alert("Not saved", e) }
            }
        }
        pendingThemeWrite = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.25), execute: w)
    }

    private func newTheme(from base: BarTheme) {
        let a = NSAlert()
        a.messageText = "New theme"
        a.informativeText = "Starts as a copy of \(base.label)."
        let f = NSTextField(string: "My \(base.label)")
        f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            do {
                let id = try self.store.createTheme(named: f.stringValue.isEmpty ? "My Theme" : f.stringValue, from: base)
                self.write(["theme"], ConfigEdit.literal(id))
            } catch { self.alert("Not created", error.localizedDescription) }
        }
    }

    private func importTheme() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.json, .init(filenameExtension: "json5")!, .font]
        p.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK else { return }
            try? FileManager.default.createDirectory(at: self.store.themesFolder, withIntermediateDirectories: true)
            for url in p.urls {
                if url.pathExtension.lowercased().hasPrefix("json"), (try? ThemeFile.decode(Data(contentsOf: url))) == nil {
                    self.alert("Not imported", "\(url.lastPathComponent) is not a theme file")
                    continue
                }
                let target = self.store.themesFolder.appending(path: url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: url, to: target) }
            }
            self.store.load()
        }
    }

    private func deleteTheme(_ theme: BarTheme) {
        guard let file = theme.file else { return }
        let a = NSAlert()
        a.messageText = "Delete \(theme.label)?"
        a.informativeText = "\(URL(fileURLWithPath: file).lastPathComponent) goes to the Trash."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: file), resultingItemURL: nil)
            self.write(["theme"], ConfigEdit.literal(theme.base ?? "og"))
        }
    }
}

/// One theme: a little bar in its colours over a desktop, its name under it.
final class ThemeTile: NSView {
    let theme: BarTheme
    private let selected: Bool
    private let hover: (Bool) -> Void
    private let pick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private static let thumbHeight: CGFloat = 64

    init(theme: BarTheme, selected: Bool, hover: @escaping (Bool) -> Void, pick: @escaping () -> Void) {
        self.theme = theme
        self.selected = selected
        self.hover = hover
        self.pick = pick
        super.init(frame: .zero)
        toolTip = theme.summary
        heightAnchor.constraint(equalToConstant: Self.thumbHeight + 26).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(theme.label) theme")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; hover(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; hover(false) }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { pick() } }

    override func draw(_ dirtyRect: NSRect) {
        let p = theme.palette
        let thumb = CGRect(x: 3, y: 3, width: bounds.width - 6, height: Self.thumbHeight - 6)
        if selected || hovering {
            let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: -3, dy: -3), xRadius: 11, yRadius: 11)
            ring.lineWidth = selected ? 3 : 2
            (selected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            ring.stroke()
        }
        let desk = NSBezierPath(roundedRect: thumb, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        desk.addClip()
        let top = theme.light ? NSColor(srgbRed: 0.80, green: 0.84, blue: 0.90, alpha: 1) : NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1)
        let bottom = theme.light ? NSColor(srgbRed: 0.93, green: 0.90, blue: 0.86, alpha: 1) : NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: thumb, angle: 90)
        let family = theme.font
        let font = { (size: CGFloat, w: Weight) in Style.font(family, size: size, weight: w) }
        func island(_ r: CGRect) {
            let path = NSBezierPath(roundedRect: r, xRadius: min(theme.radius * 0.6, r.height / 2), yRadius: min(theme.radius * 0.6, r.height / 2))
            p.card.ns.setFill()
            path.fill()
            if theme.borderWidth > 0 {
                p.border.ns.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
        }
        let h: CGFloat = 18, y = thumb.minY + 8
        // Workspaces: 1 focused on a highlight, 2 3 dim.
        let ws = CGRect(x: thumb.minX + 8, y: y, width: 54, height: h)
        island(ws)
        p.muted.ns.setFill()
        NSBezierPath(roundedRect: CGRect(x: ws.minX + 3, y: y + 3, width: 18, height: h - 6), xRadius: 3, yRadius: 3).fill()
        for (i, (n, c)) in [("1", p.primary), ("2", p.ring), ("3", p.ring)].enumerated() {
            NSAttributedString(string: n, attributes: [.font: font(9, .bold), .foregroundColor: c.ns])
                .draw(at: CGPoint(x: ws.minX + 9 + CGFloat(i) * 16, y: y + 3.5))
        }
        // Clock: muted date, accent time.
        let clock = CGRect(x: thumb.maxX - 70, y: y, width: 62, height: h)
        island(clock)
        NSAttributedString(string: "Thu", attributes: [.font: font(8, .medium), .foregroundColor: p.mutedForeground.ns])
            .draw(at: CGPoint(x: clock.minX + 6, y: y + 4.5))
        NSAttributedString(string: "13:52", attributes: [.font: font(9, .bold), .foregroundColor: p.primary.ns])
            .draw(at: CGPoint(x: clock.minX + 25, y: y + 3.5))
        // A graph line in chart1.
        let g = CGRect(x: thumb.minX + 8, y: y + h + 8, width: thumb.width - 16, height: 14)
        let line = NSBezierPath()
        for i in 0...20 {
            let pt = CGPoint(x: g.minX + CGFloat(i) / 20 * g.width, y: g.maxY - (0.5 + 0.4 * sin(Double(i) / 2.5)) * g.height)
            if i == 0 { line.move(to: pt) } else { line.line(to: pt) }
        }
        p.chart1.ns.setStroke()
        line.lineWidth = 1.2
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        NSAttributedString(string: theme.label + (theme.isBuiltIn ? "" : " ✎"), attributes: [
            .font: SettingsTheme.sans(12, selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor, .paragraphStyle: para,
        ]).draw(in: CGRect(x: 0, y: Self.thumbHeight + 4, width: bounds.width, height: 18))
    }
}
