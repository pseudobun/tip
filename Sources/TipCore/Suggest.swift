import Foundation

/// "Did you mean …?" for config keys, theme tokens and provider names.
public enum Suggest {
    /// The closest of `candidates` within a small edit distance, or nil.
    public static func closest(_ word: String, among candidates: [String]) -> String? {
        let w = word.lowercased()
        let scored = candidates.map { ($0, distance(w, $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let (best, d) = scored, d <= max(2, w.count / 3) else { return nil }
        return best
    }

    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
