import AppKit
import TipCore
import Sparkle

/// Sparkle updates without Sparkle's windows: once a day tip looks at the appcast (SUFeedURL),
/// downloads a new version in the background and installs it when tip quits, or right away with
/// `tip update`, the menu, or `updates.automatic`. Only for a tip.app that
/// carries Sparkle and a public key, i.e. release builds.
///
/// A version waiting to install is written to `update.json` in tip's Application Support folder,
/// which hop reads to offer it (hop does the same for itself).
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking
        case installing(String)
        case available(String)
        case upToDate
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "idle"
            case .checking: return "checking"
            case .installing(let v): return "installing tip \(v); tip restarts"
            case .available(let v): return "tip \(v) is available"
            case .upToDate: return "tip \(AppPaths.version) is the newest version"
            case .failed(let e): return "update check failed: \(e)"
            }
        }
    }

    private(set) var state = State.idle
    /// A version found or downloaded that hasn't been installed yet.
    private(set) var pending: String?
    /// Runs when a check you started has an answer.
    var onResult: ((State) -> Void)?

    private var updater: SPUUpdater?
    private let driver = SilentUserDriver()
    private var config = TipConfig.Updates()
    /// Sparkle's "install the downloaded update now and relaunch".
    private var installNowHandler: (() -> Void)?
    /// `checkOnly` runs: look, don't install.
    private var probing = false
    private var found: String?

    var isAvailable: Bool { updater != nil }

    func start(_ config: TipConfig.Updates) {
        guard updater == nil, AppPaths.isAppBundle,
              let key = AppPaths.appBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty
        else { return }
        PendingUpdate.clearIfInstalled()
        pending = PendingUpdate.read()?.version
        driver.owner = self
        let u = SPUUpdater(hostBundle: AppPaths.appBundle, applicationBundle: AppPaths.appBundle, userDriver: driver, delegate: self)
        updater = u
        self.config = config
        apply(config)
        do { try u.start() } catch {
            Log.app.error("updater: \(error.localizedDescription, privacy: .public)")
            updater = nil
        }
    }

    func apply(_ config: TipConfig.Updates) {
        let switched = config.wantsBeta(running: AppPaths.version) != self.config.wantsBeta(running: AppPaths.version)
        self.config = config
        guard let u = updater else { return }
        // A new channel: look at it now rather than in up to a day.
        if switched, config.check, u.canCheckForUpdates { u.checkForUpdatesInBackground() }
        u.automaticallyChecksForUpdates = config.check
        // Always in the background; `automatic` decides whether it also installs right away.
        u.automaticallyDownloadsUpdates = config.check
        u.updateCheckInterval = 24 * 60 * 60
        if config.automatic, let installNowHandler { install(pending ?? "", installNowHandler) }
    }

    /// Menu, `tip update`, hop: install the newest version now, downloading it first if needed.
    func installNow() {
        guard let u = updater, state != .checking else { return }
        if case .installing = state { return }
        if let installNowHandler { install(pending ?? "", installNowHandler); return }
        guard u.canCheckForUpdates else { return }
        state = .checking
        u.checkForUpdates()
    }

    /// `tip update --check`: look without installing.
    func checkOnly() {
        guard let u = updater, state != .checking else { return }
        guard u.canCheckForUpdates else {
            // A downloaded update holds the cycle; it is the answer.
            if let pending { finish(.available(pending)) }
            return
        }
        state = .checking
        probing = true
        found = nil
        u.checkForUpdateInformation()
    }

    private func install(_ version: String, _ handler: () -> Void) {
        state = .installing(version)
        Log.app.info("updates: \(self.state.text, privacy: .public)")
        onResult?(state)
        handler()
    }

    private func finish(_ s: State) {
        state = s
        probing = false
        Log.app.info("updates: \(s.text, privacy: .public)")
        onResult?(s)
    }

    private func markPending(_ version: String, build: String) {
        pending = version
        PendingUpdate.write(.init(version: version, build: build))
    }

    // MARK: - From the user driver (main thread)

    func updateFound(_ item: SUAppcastItem, userInitiated: Bool) -> SPUUserUpdateChoice {
        if userInitiated || config.automatic {
            state = .installing(item.displayVersionString)
            onResult?(state)
            return .install
        }
        // A scheduled check that didn't download (Sparkle won't for some updates): offer it.
        markPending(item.displayVersionString, build: item.versionString)
        return .dismiss
    }

    func noUpdate() { if state == .checking { finish(.upToDate) } }

    func failed(_ error: Error) {
        if state == .checking || isInstalling { finish(.failed((error as NSError).localizedDescription)) }
    }

    private var isInstalling: Bool { if case .installing = state { return true } else { return false } }
}

// Sparkle calls its delegate and user driver on the main thread.
extension Updater: SPUUpdaterDelegate {
    /// Betas sit in the appcast's `beta` channel; stable versions in the default one.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        config.wantsBeta(running: AppPaths.version) ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if probing { found = item.displayVersionString }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        if probing { finish(.upToDate) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard probing else { return }
        if let found { finish(.available(found)) } else { finish(.failed(error.map { ($0 as NSError).localizedDescription } ?? "no answer")) }
    }

    /// Downloaded in the background: hold it until tip quits or someone asks for it.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let v = item.displayVersionString
        installNowHandler = immediateInstallHandler
        markPending(v, build: item.versionString)
        Log.app.info("updates: tip \(v, privacy: .public) downloaded")
        if config.automatic { install(v, immediateInstallHandler) }
        return true
    }
}

/// Sparkle's user interface, without any: every answer comes from `Updater`.
@MainActor
final class SilentUserDriver: NSObject {
    weak var owner: Updater?
}

extension SilentUserDriver: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Config decides; SUEnableAutomaticChecks keeps Sparkle from asking anyway.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(owner?.updateFound(appcastItem, userInitiated: state.userInitiated) ?? .dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.noUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    /// Only reached after an update was accepted (`updateFound` said install).
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}

/// `update.json` in the app's Application Support folder: the version waiting to install.
/// tip and hop write the same shape.
enum PendingUpdate {
    struct Info: Codable, Equatable {
        let version: String
        let build: String
    }

    static var url: URL { IPC.dir.appending(path: "update.json") }

    static func read() -> Info? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    static func write(_ info: Info) {
        try? FileManager.default.createDirectory(at: IPC.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: url, options: .atomic) }
    }

    /// Gone once this build (or a newer one) runs.
    static func clearIfInstalled() {
        guard let info = read() else { return }
        let current = Int(AppPaths.appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        if (Int(info.build) ?? 0) <= current { try? FileManager.default.removeItem(at: url) }
    }
}
