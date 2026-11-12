import AppKit
import CoreAudio
import TipCore

// MARK: - Front app

final class FrontAppProvider: Provider {
    private var observer: NSObjectProtocol?

    override func begin() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                     queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.show(app) }
        }
        show(NSWorkspace.shared.frontmostApplication)
    }

    override func end() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func show(_ app: NSRunningApplication?) {
        guard let app, let name = app.localizedName else { set(.hidden); return }
        let key = app.bundleIdentifier ?? app.bundleURL?.path ?? name
        let label: Part? = options.bool("showName", true)
            ? .text(Format.truncate(name, options.int("maxChars", 20)), TextStyle(size: 12, weight: .semibold, color: .fg)) : nil
        var c = ItemContent.iconLabel(.icon(.app(key), color: .fg, size: 16), label, gap: host.iconGap)
        c.tooltip = app.bundleIdentifier
        set(c)
        host.publish("front_app_switched", ["app": name, "bundleID": app.bundleIdentifier ?? ""])
    }

    override func popupRows() -> [PopupRow]? {
        guard let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName else { return nil }
        return [PopupRow(icon: "app:\(app.bundleIdentifier ?? name)", label: name, detail: app.bundleIdentifier),
                PopupRow(icon: "sf:eye.slash", label: "Hide \(name)", action: "shell:osascript -e 'tell application \"System Events\" to set visible of process \"\(name)\" to false'"),
                PopupRow(icon: "sf:xmark.circle", label: "Quit \(name)", action: "shell:osascript -e 'quit app \"\(name)\"'")]
    }
}

// MARK: - Media

/// Now playing from MediaRemote through one long-lived `media-control stream` (MediaRemote only
/// answers entitled clients since macOS 15.4; media-control's adapter is). No polling: the
/// stream reports changes. Controls on click.
final class MediaProvider: Provider {
    private var process: Process?
    private var info: [String: JSONValue] = [:]
    private var restarts = 0
    private var restartWork: DispatchWorkItem?

    override func begin() { launch() }

    override func end() {
        restartWork?.cancel()
        let p = process
        process = nil
        p?.terminate()
    }

    private func launch() {
        guard running else { return }
        guard let exe = Shell.which("media-control") else {
            Log.provider.notice("media: media-control is not installed (brew install media-control)")
            set(.hidden)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["stream", "--no-diff", "--no-artwork", "--debounce=250"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let box = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            var buffer = box.data
            defer { box.data = buffer }
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let msg = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(msg) } }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(p) } }
        }
        do { try p.run(); process = p } catch { Log.provider.error("media: \(error.localizedDescription, privacy: .public)") }
    }

    private func exited(_ p: Process) {
        guard running, process === p else { return }
        process = nil
        restarts += 1
        let delay = min(Double(restarts) * 2, 30)
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.launch() } }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func received(_ msg: JSONValue) {
        guard msg["type"]?.string == "data", let payload = msg["payload"]?.object else { return }
        restarts = 0
        if msg["diff"]?.bool == true { info.merge(payload) { $1 } } else { info = payload }
        show()
        host.publish("media_change", ["title": info["title"]?.string ?? "", "artist": info["artist"]?.string ?? "",
                                      "playing": info["playing"]?.bool ?? false])
    }

    private func show() {
        guard let title = info["title"]?.string, !title.isEmpty else { set(.hidden); return }
        let playing = info["playing"]?.bool ?? false
        if options.bool("hidePaused", false), !playing { set(.hidden); return }
        let artist = info["artist"]?.string ?? ""
        let text = Format.truncate(artist.isEmpty ? title : "\(artist) — \(title)", options.int("maxChars", 48))
        var parts: [Part] = []
        let controls = options.bool("controls", true)
        if controls {
            parts.append(.group(PartGroup(parts: [.symbol("backward.fill", .secondary, size: 11)], padding: 3, tag: "previous")))
            parts.append(.space(6))
        }
        parts.append(.group(PartGroup(parts: [.symbol(playing ? "pause.fill" : "play.fill", .accent, size: 12),
                                              .text(text, TextStyle(size: 12, weight: .medium, color: playing ? .fg : .secondary))],
                                      spacing: host.iconGap, tag: "toggle")))
        if controls {
            parts.append(.space(6))
            parts.append(.group(PartGroup(parts: [.symbol("forward.fill", .secondary, size: 11)], padding: 3, tag: "next")))
        }
        set(ItemContent(parts: parts, tooltip: [title, artist, info["album"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")))
    }

    override func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool {
        guard options.string(trigger.configKey) == nil else { return false }
        switch (trigger, tag) {
        case (.click, "previous"): Self.send("previous-track")
        case (.click, "next"): Self.send("next-track")
        case (.click, _): Self.send("toggle-play-pause")
        case (.scrollUp, _): Self.send("next-track")
        case (.scrollDown, _): Self.send("previous-track")
        default: return false
        }
        return true
    }

    static func send(_ command: String) {
        guard let exe = Shell.which("media-control") else { return }
        Shell.exec(exe, [command])
    }

    override func popupRows() -> [PopupRow]? {
        guard let title = info["title"]?.string else { return nil }
        var rows = [PopupRow(icon: "sf:music.note", label: title)]
        if let a = info["artist"]?.string, !a.isEmpty { rows.append(PopupRow(icon: "sf:person", label: a)) }
        if let a = info["album"]?.string, !a.isEmpty { rows.append(PopupRow(icon: "sf:square.stack", label: a)) }
        rows += [.line,
                 PopupRow(icon: "sf:backward.fill", label: "Previous", action: "media:previous"),
                 PopupRow(icon: "sf:playpause.fill", label: "Play / Pause", action: "media:toggle"),
                 PopupRow(icon: "sf:forward.fill", label: "Next", action: "media:next")]
        if let bundle = info["bundleIdentifier"]?.string { rows.append(PopupRow(icon: "app:\(bundle)", label: "Open Player", action: "open:\(bundle)")) }
        return rows
    }
}

/// Bytes read so far from a pipe; touched only by its serial readability handler.
final class LineBuffer: @unchecked Sendable { var data = Data() }

// MARK: - Homebrew

/// Outdated count from the cache the brew-refresh launchd job writes (running brew inside a bar
/// overflows its descriptors). Watches the file; kicks the job on click and every `interval`.
final class BrewProvider: Provider {
    private var watcher: FileWatcher?
    private var timer: Repeater?

    private var file: URL {
        let path = options.string("file", "~/.cache/tip/brew_outdated").expandingTilde
        let url = URL(fileURLWithPath: path)
        // Until the job writes tip's file, read sketchybar's.
        if !FileManager.default.fileExists(atPath: path) {
            let old = URL(fileURLWithPath: "~/.cache/sketchybar/brew_outdated".expandingTilde)
            if FileManager.default.fileExists(atPath: old.path) { return old }
        }
        return url
    }

    override func begin() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        watcher = FileWatcher(url: file) { [weak self] in self?.update() }
        let interval = options.double("interval", 3600)
        if interval > 0 { timer = Repeater(every: max(interval, 60), fireNow: false) { [weak self] in self?.refresh() } }
        update()
    }

    override func end() {
        watcher?.stop()
        watcher = nil
        timer?.invalidate()
    }

    private func refresh() {
        let cmd = options.string("refresh", "launchctl kickstart gui/$UID/sh.pseudobun.brew-refresh")
        if !cmd.isEmpty { Shell.run(cmd + " >/dev/null 2>&1") }
    }

    private func update() {
        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? "?"
        let (count, stale) = Format.brew(raw)
        let tone = Format.brewTone(count: count, stale: stale)
        let label: Part = count == 0 && !stale
            ? .symbol("checkmark", tone, size: 11, weight: .bold)
            : .text(raw.trimmingCharacters(in: .whitespacesAndNewlines), .bold(tone))
        var c = ItemContent.iconLabel(.symbol("mug.fill", tone, size: 14), label, gap: host.iconGap)
        c.tooltip = stale ? "The last brew refresh failed" : count.map { $0 == 0 ? "Up to date" : "\($0) outdated" } ?? "Unknown"
        set(c)
    }

    override func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool {
        guard trigger == .click, options.string("click") == nil else { return false }
        refresh()
        return true
    }

    override func popupRows() -> [PopupRow]? {
        [PopupRow(icon: "sf:arrow.clockwise", label: "Refresh", action: "shell:" + options.string("refresh", "launchctl kickstart gui/$UID/sh.pseudobun.brew-refresh")),
         PopupRow(icon: "sf:terminal", label: "brew upgrade in Terminal", action: "shell:osascript -e 'tell app \"Terminal\" to do script \"brew upgrade\"'")]
    }
}

// MARK: - Volume

/// Output volume and mute from CoreAudio property listeners; scrolling changes it.
final class VolumeProvider: Provider {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "tip.audio")

    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    override func begin() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.attach() } }
        }
        listener = block
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        attach()
    }

    override func end() {
        guard let listener else { return }
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, listener)
        detachDevice()
        self.listener = nil
    }

    private func detachDevice() {
        guard device != kAudioObjectUnknown, let listener else { return }
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var a = address(sel, kAudioDevicePropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, listener)
        }
    }

    private func attach() {
        guard running, let listener else { return }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        if id != device {
            detachDevice()
            device = id
            for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var b = address(sel, kAudioDevicePropertyScopeOutput)
                AudioObjectAddPropertyListenerBlock(device, &b, queue, listener)
            }
        }
        show()
    }

    private var volume: Float32 {
        get {
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) != noErr {
                a.mElement = 1
                AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v)
            }
            return v
        }
        set {
            var v = min(max(newValue, 0), 1)
            let size = UInt32(MemoryLayout<Float32>.size)
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
            if AudioObjectSetPropertyData(device, &a, 0, nil, size, &v) != noErr {
                for ch: UInt32 in [1, 2] {
                    a.mElement = ch
                    AudioObjectSetPropertyData(device, &a, 0, nil, size, &v)
                }
            }
        }
    }

    private var muted: Bool {
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m)
        return m != 0
    }

    private func show() {
        let v = volume, m = muted
        let symbol = m || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        let label: Part? = options.bool("label", true) ? .text("\(Int((v * 100).rounded()))%", TextStyle(size: 11, weight: .medium, color: .secondary)) : nil
        set(.iconLabel(.symbol(symbol, m ? .dim : .fg, size: 14), label, gap: host.iconGap))
    }

    override func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool {
        guard options.string(trigger.configKey) == nil else { return false }
        let step = Float32(options.double("step", 5) / 100)
        switch trigger {
        case .scrollUp: volume += step
        case .scrollDown: volume -= step
        case .click:
            var m: UInt32 = muted ? 0 : 1
            var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        default: return false
        }
        show()
        return true
    }
}
