import AppKit
import Darwin
import TipCore

/// Mach and libproc sampling, done on a background queue.
enum Sampler {
    /// Cumulative CPU ticks (user + system, total).
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Per-process CPU time (ns) by pid, with names.
    static func processTimes() -> [pid_t: (time: UInt64, name: String)] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [pid_t: (UInt64, String)] = [:]
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let t = (usage.ri_user_time + usage.ri_system_time) * UInt64(tb.numer) / UInt64(max(tb.denom, 1))
            out[pid] = (t, "")
        }
        return out
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    /// Memory in use (app + wired + compressed) and the total, in bytes.
    static func memory() -> (used: Double, total: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (used, Double(ProcessInfo.processInfo.physicalMemory))
    }
}

/// Load, a graph of it and the busiest process — the sketchybar cpu helper, without the helper.
final class CPUProvider: Provider {
    private var timer: DispatchSourceTimer?
    private var ring = RingBuffer(capacity: 42)
    private let queue = DispatchQueue(label: "tip.cpu", qos: .utility)
    // Touched only on `queue`.
    private nonisolated(unsafe) var last: (busy: UInt64, total: UInt64)?
    private nonisolated(unsafe) var lastProcs: [pid_t: (time: UInt64, name: String)] = [:]
    private nonisolated(unsafe) var lastTop: [pid_t: UInt64] = [:]
    private var topRows: [(String, Double)] = []

    override func begin() {
        let width = options.double("graphWidth", 42)
        ring.resize(Int(width / 1.5))
        let interval = max(options.double("interval", 2), 0.5)
        let wantTop = options.bool("top", true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in self?.sample(top: wantTop, interval: interval) }
        t.resume()
        timer = t
    }

    override func end() {
        timer?.cancel()
        timer = nil
    }

    private nonisolated func sample(top: Bool, interval: Double) {
        guard let now = Sampler.cpuTicks() else { return }
        defer { last = now }
        guard let prev = last, now.total > prev.total else { return }
        let load = Double(now.busy - prev.busy) / Double(now.total - prev.total)
        var busiest: [(String, Double)] = []
        if top {
            let procs = Sampler.processTimes()
            var deltas: [(pid_t, UInt64)] = []
            for (pid, v) in procs { if let p = lastProcs[pid], v.time > p.time { deltas.append((pid, v.time - p.time)) } }
            lastProcs = procs
            deltas.sort { $0.1 > $1.1 }
            let ns = interval * 1e9
            busiest = deltas.prefix(5).map { (Sampler.name($0.0), Double($0.1) / ns) }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.show(load, busiest) } }
    }

    private func show(_ load: Double, _ busiest: [(String, Double)]) {
        guard running else { return }
        ring.push(load)
        topRows = busiest
        let tone = Format.cpuTone(load)
        let percent = Part.text("\(Int((load * 100).rounded()))%", TextStyle(size: 11, weight: .bold, color: tone))
        let numbers: Part
        if options.bool("top", true) {
            let name = busiest.first.map { Format.processName($0.0) } ?? ""
            numbers = .stack(top: .text(name, TextStyle(size: 8.5, weight: .medium, color: .secondary)), bottom: percent, width: 58)
        } else {
            numbers = percent
        }
        var parts: [Part] = []
        if options.bool("graph", true) {
            parts += [.graph(values: ring.values, width: CGFloat(options.double("graphWidth", 42)), color: .token(.chart1)), .space(host.iconGap)]
        }
        parts.append(numbers)
        set(ItemContent(parts: parts, tooltip: busiest.first.map { "\($0.0): \(Int($0.1 * 100))%" }))
    }

    override func popupRows() -> [PopupRow]? {
        topRows.map { PopupRow(icon: "sf:gearshape.2", label: $0.0, detail: "\(Int(($0.1 * 100).rounded()))%") }
            + [PopupRow(icon: "sf:waveform.path.ecg", label: "Activity Monitor", action: "app:Activity Monitor")]
    }
}

final class MemoryProvider: Provider {
    private var timer: Repeater?

    override func begin() {
        timer = Repeater(every: max(options.double("interval", 5), 1)) { [weak self] in
            guard let self, let m = Sampler.memory() else { return }
            let pct = m.used / m.total
            var c = ItemContent.iconLabel(.symbol("memorychip", .fg, size: 14),
                                          .text("\(Int(pct * 100))%", TextStyle(size: 11, weight: .medium, color: Format.cpuTone(pct * 0.8))),
                                          gap: self.host.iconGap)
            c.tooltip = "\(Format.bytes(m.used)) of \(Format.bytes(m.total))"
            self.set(c)
        }
    }

    override func end() { timer?.invalidate() }
}

final class DiskProvider: Provider {
    private var timer: Repeater?
    private var mounts: [NSObjectProtocol] = []

    override func begin() {
        timer = Repeater(every: max(options.double("interval", 300), 10)) { [weak self] in self?.update() }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mounts.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } })
        }
    }

    override func end() {
        timer?.invalidate()
        mounts.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        mounts = []
    }

    private func update() {
        let url = URL(fileURLWithPath: options.string("path", "/"))
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage else { set(.hidden); return }
        var c = ItemContent.iconLabel(.symbol("internaldrive", .fg, size: 14),
                                      .text(Format.bytes(Double(free)), TextStyle(size: 11, weight: .medium, color: .secondary)), gap: host.iconGap)
        c.tooltip = "\(Format.bytes(Double(free))) free of \(Format.bytes(Double(v.volumeTotalCapacity ?? 0)))"
        set(c)
    }
}
