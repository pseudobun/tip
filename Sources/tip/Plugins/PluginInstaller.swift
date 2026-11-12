import Foundation
import TipCore

/// Installs `*.tipplugin.zip` from a GitHub release, a URL or a local file; links a folder for
/// development. Runs in the CLI (or off the main thread in Settings): a running tip picks up the
/// change by watching its Plugins folder.
enum PluginInstaller {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// `owner/repo`, `owner/repo@v1.2.0`, `github.com/owner/repo`, a zip URL, a .zip or a folder.
    static func install(_ source: String) throws -> PluginManifest {
        let fm = FileManager.default
        let expanded = source.expandingTilde
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            return isDir.boolValue ? try copyFolder(URL(fileURLWithPath: expanded)) : try installZip(URL(fileURLWithPath: expanded))
        }
        if source.hasPrefix("https://"), source.hasSuffix(".zip") {
            return try installZip(download(URL(string: source)!))
        }
        let (repo, tag) = try parseRepo(source)
        let api = tag.map { "https://api.github.com/repos/\(repo)/releases/tags/\($0)" } ?? "https://api.github.com/repos/\(repo)/releases/latest"
        let data = try fetch(URL(string: api)!)
        guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]] else { throw Failure("\(repo): no release") }
        let zips = assets.filter { ($0["name"] as? String)?.hasSuffix(".tipplugin.zip") == true }
        let pick = zips.first { ($0["name"] as? String)?.contains("arm64") == true || ($0["name"] as? String)?.contains("universal") == true } ?? zips.first
        guard let url = (pick?["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure("\(repo): the release has no .tipplugin.zip")
        }
        return try installZip(download(url))
    }

    static func parseRepo(_ s: String) throws -> (String, String?) {
        var t = s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "github.com/", with: "")
        if t.hasSuffix("/") { t.removeLast() }
        let parts = t.split(separator: "@", maxSplits: 1)
        let repo = String(parts[0])
        guard repo.wholeMatch(of: #/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/#) != nil else { throw Failure("“\(s)” is not owner/repo, a URL or a file") }
        return (repo, parts.count > 1 ? String(parts[1]) : nil)
    }

    /// Symlinks a plugin folder into Plugins/ (`tip plugins link`).
    static func link(_ dir: URL) throws -> PluginManifest {
        let m = try manifest(in: dir)
        let target = PluginHost.userFolder.appending(path: m.id)
        try FileManager.default.createDirectory(at: PluginHost.userFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: dir.absoluteURL.standardizedFileURL)
        return m
    }

    static func remove(_ id: String) throws {
        let target = PluginHost.userFolder.appending(path: id)
        guard FileManager.default.fileExists(atPath: target.path) || (try? target.checkResourceIsReachable()) == false else {
            throw Failure("\(id) is not installed (bundled plugins can't be removed; disable them instead)")
        }
        try FileManager.default.removeItem(at: target)
    }

    private static func manifest(in dir: URL) throws -> PluginManifest {
        guard let data = try? Data(contentsOf: dir.appending(path: "plugin.json5")) else { throw Failure("no plugin.json5 in \(dir.path)") }
        do { return try PluginManifest.decode(data) } catch { throw Failure("plugin.json5: \(error)") }
    }

    private static func installZip(_ zip: URL) throws -> PluginManifest {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "tip-plugin-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("cannot unpack \(zip.lastPathComponent)") }
        // The archive root, or its one folder.
        var root = tmp
        if !fm.fileExists(atPath: tmp.appending(path: "plugin.json5").path) {
            let dirs = (try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                .filter { $0.lastPathComponent != "__MACOSX" }
            guard dirs.count == 1 else { throw Failure("the zip holds no plugin.json5") }
            root = dirs[0]
        }
        return try copyFolder(root)
    }

    private static func copyFolder(_ dir: URL) throws -> PluginManifest {
        let fm = FileManager.default
        let m = try manifest(in: dir)
        // Symlinks could point anywhere: refused, as in hop.
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw Failure("\(url.lastPathComponent) is a symbolic link; refused")
            }
        }
        let exe = dir.appending(path: m.entry)
        guard fm.fileExists(atPath: exe.path) else { throw Failure("\(m.entry) is missing") }
        try fm.createDirectory(at: PluginHost.userFolder, withIntermediateDirectories: true)
        let target = PluginHost.userFolder.appending(path: m.id)
        let staging = PluginHost.userFolder.appending(path: ".\(m.id).new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: dir, to: staging)
        chmod(staging.appending(path: m.entry).path, 0o755)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
        return m
    }

    private static func fetch(_ url: URL) throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("tip-plugin-installer", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(Failure("no answer"))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { result = .failure(err) }
            else if let http = resp as? HTTPURLResponse, http.statusCode >= 300 { result = .failure(Failure("\(url.host ?? ""): HTTP \(http.statusCode)")) }
            else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    private static func download(_ url: URL) throws -> URL {
        let data = try fetch(url)
        let file = FileManager.default.temporaryDirectory.appending(path: "tip-\(UUID().uuidString).zip")
        try data.write(to: file)
        return file
    }
}
