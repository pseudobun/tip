import Foundation

/// Small pure helpers the providers and plugins share (and tests pin down).
public enum Format {
    /// 98412.3 → "98,412"; with decimals "98,412.30".
    public static func thousands(_ n: Double, decimals: Int = 0) -> String {
        let s = String(format: "%.\(decimals)f", n)
        let parts = s.split(separator: ".", maxSplits: 1)
        var int = String(parts[0])
        let negative = int.hasPrefix("-")
        if negative { int.removeFirst() }
        var out = ""
        for (i, ch) in int.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (negative ? "-" : "") + String(out.reversed()) + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// `text` cut to `max` characters, the last one an ellipsis.
    public static func truncate(_ text: String, _ max: Int) -> String {
        guard max > 0, text.count > max else { return text }
        return String(text.prefix(max - 1)) + "…"
    }

    /// The busiest process's name as the cpu item shows it: without "com.apple.", at most 11
    /// characters.
    public static func processName(_ name: String, max: Int = 11) -> String {
        var n = name
        if n.hasPrefix("com.apple.") { n.removeFirst("com.apple.".count) }
        return truncate(n, max)
    }

    /// Minutes as "2d3h", "4h05m" or "17m".
    public static func countdown(minutes: Int) -> String {
        let m = Swift.max(minutes, 0)
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return String(format: "%dh%02dm", h, mm) }
        return "\(mm)m"
    }

    /// NYSE regular session (9:30–16:00 New York, Mon–Fri): open now, and minutes until it
    /// closes (open) or opens (closed). `weekday` 1 = Monday … 7 = Sunday (ISO), `minute` of the day.
    public static func nyse(weekday: Int, minute: Int) -> (open: Bool, minutesLeft: Int) {
        let open = 9 * 60 + 30, close = 16 * 60
        if weekday <= 5, minute >= open, minute < close { return (true, close - minute) }
        let ahead: Int
        if weekday <= 4, minute >= close { ahead = 1 }
        else if weekday == 5, minute >= close { ahead = 3 }
        else if weekday == 6 { ahead = 2 }
        else if weekday == 7 { ahead = 1 }
        else { ahead = 0 }
        let left = ahead == 0 ? open - minute : ahead * 1440 - minute + open
        return (false, Swift.max(left, 0))
    }

    /// The cpu label's tone: ≥70 % bad, ≥30 % warn, ≥10 % accent, else secondary.
    public static func cpuTone(_ load: Double) -> Paint {
        load >= 0.7 ? .bad : load >= 0.3 ? .warn : load >= 0.1 ? .accent : .secondary
    }

    /// Battery symbol and tone for a percent.
    public static func battery(percent: Int, charging: Bool, warnBelow: Int = 30, badBelow: Int = 20) -> (symbol: String, tone: Paint) {
        if charging { return ("battery.100percent.bolt", .good) }
        switch percent {
        case ..<badBelow: return ("battery.0percent", .bad)
        case ..<warnBelow: return ("battery.25percent", .warn)
        case ..<60: return ("battery.50percent", .fg)
        case ..<90: return ("battery.75percent", .fg)
        default: return ("battery.100percent", .fg)
        }
    }

    /// The brew cache file: "12", "12!" (the last refresh failed), "?" or garbage.
    public static func brew(_ raw: String) -> (count: Int?, stale: Bool) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stale = s.hasSuffix("!")
        return (Int(s.replacingOccurrences(of: "!", with: "")), stale)
    }

    /// Tone for an outdated count: 0 good, <10 fg, <30 warn, else bad; stale or unknown bad.
    public static func brewTone(count: Int?, stale: Bool) -> Paint {
        guard let n = count, !stale else { return .bad }
        return n == 0 ? .good : n < 10 ? .fg : n < 30 ? .warn : .bad
    }

    /// "1.2 GB" style sizes.
    public static func bytes(_ n: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = n, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }
}

/// A fixed-size ring of samples (the cpu graph): pushing is O(1), no allocation.
public struct RingBuffer: Equatable, Sendable {
    public private(set) var storage: [Double]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) { storage = Array(repeating: 0, count: max(capacity, 1)) }

    public var capacity: Int { storage.count }

    public mutating func push(_ v: Double) {
        storage[head] = v
        head = (head + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    /// Oldest first.
    public var values: [Double] {
        (0..<count).map { storage[(head - count + $0 + storage.count * 2) % storage.count] }
    }

    public mutating func resize(_ capacity: Int) {
        guard capacity != storage.count else { return }
        let old = values.suffix(capacity)
        self = RingBuffer(capacity: capacity)
        old.forEach { push($0) }
    }
}

/// `~/.config/tip/.env`: KEY=value lines for `${KEY}` in the config. Never written back expanded.
public enum EnvFile {
    public static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else { continue }
            env[key] = value
        }
        return env
    }

    /// Replaces `${NAME}` with its value (empty when unknown) in every string.
    public static func expand(_ value: JSONValue, _ env: [String: String]) -> JSONValue {
        switch value {
        case .string(let s): .string(expand(s, env))
        case .array(let a): .array(a.map { expand($0, env) })
        case .object(let o): .object(o.mapValues { expand($0, env) })
        default: value
        }
    }

    public static func expand(_ s: String, _ env: [String: String]) -> String {
        guard s.contains("${") else { return s }
        return s.replacing(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/) { m in env[String(m.output.1)] ?? "" }
    }
}
