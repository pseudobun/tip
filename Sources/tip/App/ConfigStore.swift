import AppKit
import TipCore

/// Loads `~/.config/tip/config.json5` (writes the template on first launch), `.env` beside it and
/// the themes in `themes/`; watches all three and reloads on save. A broken file keeps the last
/// good config and shows a red dot on the bar. Writes go through ConfigEdit, comments kept.
@MainActor
final class ConfigStore {
    private(set) var config = TipConfig()
    private(set) var error: String?
    private(set) var warnings: [String] = []
    private(set) var env: [String: String] = [:]
    private(set) var customThemes: [BarTheme] = []
    private(set) var themeIssues: [String] = []
    /// paw's / hop's theme id, for `follow-paw` / `follow-hop`.
    private(set) var followed: [String: String] = [:]
    var onChange: (() -> Void)?
    let url: URL
    private var watchers: [FileWatcher] = []
    private var themeWatcher: FolderWatcher?

    /// `$TIP_CONFIG` overrides the location; a dev build uses `~/.config/tip-dev`.
    nonisolated static var defaultURL: URL {
        if let o = ProcessInfo.processInfo.environment["TIP_CONFIG"], !o.isEmpty {
            return URL(fileURLWithPath: o.expandingTilde)
        }
        let dir = AppPaths.isDev ? ".config/tip-dev" : ".config/tip"
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "\(dir)/config.json5")
    }

    var folder: URL { url.deletingLastPathComponent() }
    var themesFolder: URL { folder.appending(path: "themes", directoryHint: .isDirectory) }
    var envURL: URL { folder.appending(path: ".env") }

    init(url: URL = ConfigStore.defaultURL) {
        self.url = url
        load(notify: false)
    }

    func start() {
        if !FileManager.default.fileExists(atPath: url.path) { writeTemplate() }
        load(notify: false)
        watchers = [FileWatcher(url: url) { [weak self] in self?.load() },
                    FileWatcher(url: envURL) { [weak self] in self?.load() }]
        for other in [Self.pawConfig, Self.hopConfig] {
            watchers.append(FileWatcher(url: other) { [weak self] in self?.load() })
        }
        themeWatcher = FolderWatcher(folder: themesFolder) { [weak self] in self?.load() }
    }

    func load(notify: Bool = true) {
        env = EnvFile.parse((try? String(contentsOf: envURL, encoding: .utf8)) ?? "")
        loadThemes()
        followed = ["follow-paw": Self.theme(in: Self.pawConfig, path: ["appearance", "theme"]),
                    "follow-hop": Self.theme(in: Self.hopConfig, path: ["general", "theme"])].compactMapValues { $0 }
        let raw = (try? Data(contentsOf: url)) ?? Data()
        do {
            config = try ConfigLoader.decode(raw)
            error = nil
            warnings = ConfigLoader.unknownKeys(raw).map { "unknown key \($0)" }
                + ConfigLoader.warnings(config, customThemes: customThemes.map(\.id)) + themeIssues
        } catch {
            self.error = "\(error)"
            Log.app.error("config: \(self.error ?? "", privacy: .public)")
        }
        if notify { onChange?() }
    }

    private func loadThemes() {
        var themes: [BarTheme] = []
        var issues: [String] = []
        var fonts: [URL] = []
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: themesFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = file.pathExtension.lowercased()
            if ["ttf", "otf", "ttc"].contains(ext) { fonts.append(file); continue }
            guard ["json5", "json"].contains(ext) else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            if Themes.builtIn(id) != nil || Themes.follow.contains(id) {
                issues.append("themes/\(file.lastPathComponent): \"\(id)\" is a built-in theme, rename the file")
                continue
            }
            do {
                let (t, problems) = try ThemeFile.decode(Data(contentsOf: file)).theme(id: id, path: file.path)
                themes.append(t)
                issues += problems.map { "themes/\(file.lastPathComponent): \($0)" }
            } catch {
                issues.append("themes/\(file.lastPathComponent): not valid JSON5")
            }
        }
        if !fonts.isEmpty { Style.registerFonts(extra: fonts) }
        customThemes = themes.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        themeIssues = issues
    }

    /// Every theme Settings offers: built-in first, then the user's.
    var allThemes: [BarTheme] { Themes.all + customThemes }

    /// The theme `id` names (following paw or hop when asked); OG for one tip doesn't know.
    func theme(_ id: String) -> BarTheme {
        var id = id.lowercased()
        if let followedID = followed[id] { id = followedID.lowercased() }
        return Themes.builtIn(id) ?? customThemes.first { $0.id == id } ?? Themes.og
    }

    /// The config's values with `${NAME}` from .env filled in (plugin preferences, script commands).
    func expanded(_ v: JSONValue) -> JSONValue { EnvFile.expand(v, env) }

    // MARK: Writing

    /// Sets `path` to `literal` (JSON5 source) in the file, keeping everything else. Refuses a
    /// write that would leave the file unreadable.
    @discardableResult
    func set(_ path: [String], literal: String) -> String? {
        edit { ConfigEdit.setting(path, to: literal, in: $0) }
    }

    @discardableResult
    func remove(_ path: [String]) -> String? {
        edit { ConfigEdit.removing(path, in: $0) }
    }

    private func edit(_ change: (String) -> String?) -> String? {
        if !FileManager.default.fileExists(atPath: url.path) { writeTemplate() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "cannot read \(url.path)" }
        guard let out = change(text) else { return "cannot edit the config: it is not a JSON5 object" }
        do { _ = try ConfigLoader.decode(Data(out.utf8)) } catch { return "not saved: \(error)" }
        do {
            // Through symlinks (a dotfiles repo): write the file the link points at.
            let target = url.resolvingSymlinksInPath()
            try out.write(to: target, atomically: true, encoding: .utf8)
        } catch { return error.localizedDescription }
        load()
        return nil
    }

    private func writeTemplate() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ConfigTemplate.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("config template: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Themes on disk

    /// Writes a new theme file from `base` and returns its id.
    func createTheme(named name: String, from base: BarTheme) throws -> String {
        try FileManager.default.createDirectory(at: themesFolder, withIntermediateDirectories: true)
        var stem = ThemeFile.slug(name), n = 1
        while FileManager.default.fileExists(atPath: themesFolder.appending(path: "\(stem).json5").path)
            || Themes.builtIn(stem) != nil {
            n += 1
            stem = "\(ThemeFile.slug(name))-\(n)"
        }
        try ThemeFile.template(name: name, from: base).write(to: themesFolder.appending(path: "\(stem).json5"), atomically: true, encoding: .utf8)
        load()
        return stem
    }

    /// Sets one key of a custom theme's file (ConfigEdit, comments kept).
    func setTheme(_ theme: BarTheme, _ path: [String], literal: String) -> String? {
        guard let file = theme.file else { return "built-in themes can't be edited; make a copy" }
        let url = URL(fileURLWithPath: file)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let out = ConfigEdit.setting(path, to: literal, in: text) else { return "cannot edit \(url.lastPathComponent)" }
        do { try out.write(to: url, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        load()
        return nil
    }

    // MARK: paw and hop

    static let pawConfig = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/paw/config.json5")
    static let hopConfig = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/hop/config.json5")

    private static func theme(in url: URL, path: [String]) -> String? {
        guard let data = try? Data(contentsOf: url),
              var node = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) else { return nil }
        for key in path {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return node as? String
    }
}

/// Calls `onChange` (debounced) when anything in a folder changes; a missing folder is
/// watched from its parent until it appears.
@MainActor
final class FolderWatcher {
    let folder: URL
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    init(folder: URL, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onChange = onChange
        rewatch()
    }

    private func rewatch() {
        sources.forEach { $0.cancel() }
        sources = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else {
            if let s = source(folder.deletingLastPathComponent().path, [.write]) { sources.append(s) }
            return
        }
        if let s = source(folder.path, [.write, .rename, .delete]) { sources.append(s) }
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            if let s = source(file.path, [.write, .extend, .rename, .delete]) { sources.append(s) }
        }
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            rewatch()
            onChange()
        }
    }
}
