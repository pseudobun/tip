import AppKit
import TipCore

/// The Apple logo; its popup holds shortcuts (config `rows`) and tip's own.
final class AppleProvider: Provider {
    override func begin() {
        var c = ItemContent(parts: [.symbol(options.string("icon").map { $0.hasPrefix("sf:") ? String($0.dropFirst(3)) : $0 } ?? "apple.logo",
                                            options.string("color").flatMap(Paint.parse) ?? .fg, size: 15, weight: .bold)])
        c.popup = []
        set(c)
    }

    static let defaultRows: [PopupRow] = [
        PopupRow(icon: "sf:gearshape", label: "System Settings", action: "app:System Settings"),
        PopupRow(icon: "sf:waveform.path.ecg", label: "Activity Monitor", action: "app:Activity Monitor"),
        PopupRow(icon: "sf:lock", label: "Lock Screen", action: "shell:pmset displaysleepnow"),
    ]

    override func popupRows() -> [PopupRow]? {
        var rows = Self.defaultRows
        if let custom = options["rows"], let data = try? JSONEncoder().encode(custom),
           let decoded = try? JSONDecoder().decode([PopupRow].self, from: data) { rows = decoded }
        return rows + [.line,
                       PopupRow(icon: "sf:slider.horizontal.3", label: "tip Settings…", action: "tip:settings"),
                       PopupRow(icon: "sf:arrow.clockwise", label: "Reload tip", action: "tip:reload"),
                       PopupRow(icon: "sf:power", label: "Quit tip", action: "tip:quit")]
    }

    override func handle(_ trigger: Trigger, tag: String?, display: CGDirectDisplayID) -> Bool {
        guard trigger == .click, options.string("click") == nil else { return false }
        host.perform(.popup, item: id)
        return true
    }
}

/// A fixed icon and label from config; `tip set` changes it at runtime.
final class TextProvider: Provider {
    override func begin() {
        var spec = ItemSpec(id: id)
        spec.icon = options.string("icon")
        spec.iconColor = options.string("iconColor")
        spec.label = options.string("label")
        spec.labelColor = options.string("color")
        set(.from(spec, graph: nil, gap: host.iconGap))
    }
}

/// Date and time, redrawn on the minute (on the second when the format shows seconds), on wake
/// and when the clock or time zone changes.
final class ClockProvider: Provider {
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let date = DateFormatter()
    private let time = DateFormatter()

    override func begin() {
        for f in [date, time] {
            f.locale = Locale.current
            if let tz = options.string("timeZone"), !tz.isEmpty { f.timeZone = TimeZone(identifier: tz) }
        }
        date.dateFormat = options.string("dateFormat", "EEE dd")
        time.dateFormat = options.string("format", "HH:mm")
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }
        tick()
    }

    override func end() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    override func event(_ name: String, _ data: [String: Any]) { if name == "system_woke" { tick() } }

    private var seconds: Bool { time.dateFormat.contains("s") }

    private func tick() {
        let now = Date()
        var parts: [Part] = []
        let d = date.dateFormat.isEmpty ? "" : date.string(from: now)
        if !d.isEmpty { parts += [.text(d, TextStyle(size: 11.5, weight: .medium, color: .secondary)), .space(6)] }
        parts.append(.text(time.string(from: now), .bold(.accent, size: 13)))
        set(ItemContent(parts: parts, tooltip: DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .short)))
        // Next boundary, so the minute flips on time without polling.
        let unit: TimeInterval = seconds ? 1 : 60
        let next = (floor(now.timeIntervalSince1970 / unit) + 1) * unit + 0.05
        timer?.invalidate()
        let t = Timer(fire: Date(timeIntervalSince1970: next), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = seconds ? 0.05 : 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func popupRows() -> [PopupRow]? {
        let now = Date()
        let cal = Calendar(identifier: .iso8601)
        let f = DateFormatter()
        f.dateStyle = .full
        var rows = [PopupRow(icon: "sf:calendar", label: f.string(from: now)),
                    PopupRow(icon: "sf:number", label: "Week \(cal.component(.weekOfYear, from: now))",
                             detail: "day \(cal.ordinality(of: .day, in: .year, for: now) ?? 0)")]
        for zone in options.strings("zones") {
            guard let tz = TimeZone(identifier: zone) else { continue }
            let z = DateFormatter()
            z.timeZone = tz
            z.dateFormat = "HH:mm"
            rows.append(PopupRow(icon: "sf:globe", label: zone.split(separator: "/").last.map(String.init) ?? zone, detail: z.string(from: now)))
        }
        rows.append(PopupRow(icon: "sf:calendar.badge.clock", label: "Open Calendar", action: "app:Calendar"))
        return rows
    }
}

/// A shell command's output as the label: every `interval` seconds and on `on` events.
/// stdout is the label, or JSON `{label, icon, iconColor, labelColor, drawing}`.
final class ScriptProvider: Provider {
    private var timer: Repeater?
    private var runningCommand = false

    override func begin() {
        let interval = options.double("interval", 60)
        if interval > 0 { timer = Repeater(every: max(interval, 1)) { [weak self] in self?.run() } } else { run() }
    }

    override func end() {
        timer?.invalidate()
        timer = nil
    }

    override func event(_ name: String, _ data: [String: Any]) {
        if options.strings("on").contains(name) { run() }
    }

    private func run() {
        guard !runningCommand, let host = host as? BarManager, let command = options.string("command") else { return }
        runningCommand = true
        let cmd = host.store.env.isEmpty ? command : EnvFile.expand(command, host.store.env)
        Shell.run(cmd) { [weak self] out, _ in
            guard let self, self.running else { return }
            self.runningCommand = false
            var spec = ItemSpec(id: self.id)
            if out.hasPrefix("{"), let s = try? JSONDecoder().decode(ItemSpec.self, from: Data(("{\"id\":\"\(self.id)\"," + out.dropFirst()).utf8)) {
                spec = s
            } else {
                spec.label = out
            }
            spec.icon = spec.icon ?? self.options.string("icon")
            spec.iconColor = spec.iconColor ?? self.options.string("iconColor")
            spec.labelColor = spec.labelColor ?? self.options.string("color")
            self.set(.from(spec, graph: nil, gap: self.host.iconGap))
        }
    }
}
