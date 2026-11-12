import Foundation

enum AppPaths {
    /// tip.app's bundle id; `com.pseudobun.tip` for a bare `swift run`.
    static let bundleID: String = appBundle.bundleIdentifier ?? "com.pseudobun.tip"

    /// A dev build (`just dev`): `com.pseudobun.tip.dev`, own data, no login item, no updates.
    static var isDev: Bool { bundleID.hasSuffix(".dev") }

    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appending(path: bundleID, directoryHint: .isDirectory)
    }()

    /// tip.app, also when the CLI runs through a symlink (/opt/homebrew/bin/tip).
    static let appBundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)))
        guard length > 0 else { return .main }
        let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { return .main }
        return Bundle(url: app) ?? .main
    }()

    static var executablePath: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    static var isAppBundle: Bool { appBundle.bundleURL.pathExtension == "app" }

    static var version: String {
        appBundle.object(forInfoDictionaryKey: "TipVersion") as? String
            ?? appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
