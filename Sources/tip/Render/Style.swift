import AppKit
import CoreText
import TipCore

/// The look in effect: the theme (built-in, custom or followed from paw/hop) plus the config's
/// island keys. Rebuilt when either changes; everything drawn reads it.
struct Style: Equatable {
    var theme: BarTheme
    var island: TipConfig.Island
    var barHeight: CGFloat
    /// Liquid Glass under islands and popups (`glass`).
    var glass = true

    var palette: Palette { theme.palette }
    var radius: CGFloat { CGFloat(island.radius ?? theme.radius) }
    var islandHeight: CGFloat { CGFloat(island.height) }

    /// What glass is tinted toward: the theme's fill. Liquid Glass only leans toward its tint, so
    /// on a bright desktop it stays light; `glassVeil` keeps the theme's text legible on it.
    func glassTint(_ fill: ARGB) -> NSColor { fill.ns }

    /// The theme's fill laid thinly over the glass: enough to carry the theme's colour and keep
    /// its text readable on any wallpaper, thin enough that the glass still shows.
    func glassVeil(_ fill: ARGB) -> CGColor { fill.alpha(fill.a * (theme.light ? 0.4 : 0.5)).cg }

    /// The glass matches the theme, not the system: dark glass under a dark theme's light text.
    var appearance: NSAppearance? { NSAppearance(named: theme.light ? .aqua : .darkAqua) }

    func color(_ p: Paint) -> NSColor { p.resolve(palette).ns }
    func cg(_ p: Paint) -> CGColor { p.resolve(palette).cg }

    func font(_ t: TextStyle) -> NSFont {
        t.themed ? Self.font(theme.font, size: t.size, weight: t.weight) : .systemFont(ofSize: t.size, weight: t.weight.ns)
    }

    // MARK: Fonts

    /// Whether `s` holds a private-use code point (a Nerd Font glyph).
    static func isNerd(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) || $0.value >= 0xF0000 }
    }

    private static var nerdFamily: String?? = .none

    /// An installed Nerd Font (GeistMono first, the theme's own), nil when there is none.
    static func nerdFont(size: CGFloat) -> NSFont? {
        if nerdFamily == nil {
            let families = NSFontManager.shared.availableFontFamilies
            nerdFamily = .some(["GeistMono Nerd Font", "Symbols Nerd Font", "Symbols Nerd Font Mono"].first(where: families.contains)
                ?? families.first { $0.contains("Nerd Font") && !$0.contains("Mono") && !$0.contains("Propo") }
                ?? families.first { $0.contains("Nerd Font") })
        }
        guard let family = nerdFamily ?? nil else { return nil }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    private static var registered = false
    private static var cache: [String: NSFont] = [:]

    /// The fonts in tip.app's Resources/Fonts (the themes' fonts) and in ~/.config/tip/themes/,
    /// for this process.
    static func registerFonts(extra: [URL] = []) {
        var urls = extra
        if !registered {
            registered = true
            for ext in ["ttf", "otf"] {
                urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
                urls += AppPaths.appBundle.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
            }
            // `swift run` from the repo: Resources/Fonts beside the package.
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/Fonts")
            if urls.isEmpty, let local = try? FileManager.default.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil) {
                urls += local.filter { ["ttf", "otf"].contains($0.pathExtension) }
            }
        }
        for url in Set(urls) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        cache.removeAll()
    }

    static func font(_ family: String, size: CGFloat, weight: Weight) -> NSFont {
        let key = "\(family)|\(size)|\(weight.rawValue)"
        if let f = cache[key] { return f }
        let f = makeFont(family, size: size, weight: weight)
        cache[key] = f
        return f
    }

    private static func makeFont(_ family: String, size: CGFloat, weight: Weight) -> NSFont {
        switch family.lowercased().replacingOccurrences(of: " ", with: "-") {
        case "system", "sf-pro": return .systemFont(ofSize: size, weight: weight.ns)
        case "system-mono", "sf-mono": return .monospacedSystemFont(ofSize: size, weight: weight.ns)
        default: break
        }
        let w: Int = switch weight { case .regular: 5; case .medium: 6; case .semibold: 8; case .bold: 9 }
        // Variable fonts (Geist Mono) answer the weight through their axis.
        if let base = NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            let wght: CGFloat = switch weight { case .regular: 400; case .medium: 500; case .semibold: 600; case .bold: 700 }
            let axes = (CTFontCopyVariationAxes(base) as? [[CFString: Any]]) ?? []
            if let axis = axes.first(where: { ($0[kCTFontVariationAxisNameKey] as? String)?.lowercased() == "weight" }),
               let id = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber {
                let desc = base.fontDescriptor.addingAttributes([
                    NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [id: wght],
                ])
                if let f = NSFont(descriptor: desc, size: size) { return f }
            }
            if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: w, size: size) { return f }
            return base
        }
        return .monospacedSystemFont(ofSize: size, weight: weight.ns)
    }
}

extension ARGB {
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

/// App icons and SF Symbols as images, cached by what and how big.
@MainActor
enum Icons {
    private static var apps: [String: NSImage] = [:]
    private static var bundleURLs: [String: URL?] = [:]

    /// The app's icon for a bundle id, an app name or an .app path.
    static func app(_ key: String) -> NSImage? {
        if let i = apps[key] { return i }
        guard let url = appURL(key) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        apps[key] = image
        return image
    }

    static func appURL(_ key: String) -> URL? {
        if let u = bundleURLs[key] { return u }
        var url: URL?
        if key.hasSuffix(".app") { url = URL(fileURLWithPath: (key as NSString).expandingTildeInPath) }
        else if key.contains("."), let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) { url = u }
        else if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == key }), let u = running.bundleURL { url = u }
        else {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
                        "/Applications/Utilities", "/System/Library/CoreServices"] {
                let candidate = URL(fileURLWithPath: dir).appending(path: key + ".app")
                if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
            }
        }
        bundleURLs[key] = url
        return url
    }

    static func symbol(_ name: String, size: CGFloat, weight: Weight, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight.ns).applying(.init(paletteColors: [color, color, color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// A bitmap drawn once at its device size, so drawing it again is a blit (no scaling from the
    /// 1024 px icon rep, no colour conversion, no symbol layout).
    struct Raster {
        let image: CGImage
        /// In points.
        let size: CGSize
    }

    private static var rasters: [String: Raster] = [:]

    static func rasterApp(_ key: String, points: CGFloat, scale: CGFloat) -> Raster? {
        let k = "a|\(key)|\(points)|\(scale)"
        if let r = rasters[k] { return r }
        guard let img = app(key), let r = rasterize(img, size: CGSize(width: points, height: points), scale: scale) else { return nil }
        rasters[k] = r
        return r
    }

    static func rasterSymbol(_ name: String, size: CGFloat, weight: Weight, color: NSColor, scale: CGFloat) -> Raster? {
        let c = ARGB(color)
        let k = "s|\(name)|\(size)|\(weight.rawValue)|\(c.r),\(c.g),\(c.b),\(c.a)|\(scale)"
        if let r = rasters[k] { return r }
        guard let img = symbol(name, size: size, weight: weight, color: color), let r = rasterize(img, size: img.size, scale: scale) else { return nil }
        rasters[k] = r
        return r
    }

    private static func rasterize(_ img: NSImage, size: CGSize, scale: CGFloat) -> Raster? {
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { Raster(image: $0, size: size) }
    }

    static func clear() {
        apps.removeAll()
        bundleURLs.removeAll()
        rasters.removeAll()
    }
}
