import Foundation

/// Splits a CLI request back into words, honouring quotes.
public enum CLIWords {
    public static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == " " { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func join(_ words: [String]) -> String {
        words.map { w in
            guard w.isEmpty || w.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) else { return w }
            return w.contains("'") ? "\"" + w.replacingOccurrences(of: "\"", with: "'") + "\"" : "'" + w + "'"
        }.joined(separator: " ")
    }
}

