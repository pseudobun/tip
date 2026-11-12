import Foundation

/// What a click, right click or scroll does, written as a string in config:
///
///     "zen" | "zen on" | "zen off"     zen mode
///     "popup"                           toggle the item's popup
///     "toggle-label"                    show / hide the item's label (animated)
///     "open:<url or path>"              open a URL, file or app bundle
///     "app:<App Name>"                  open (or focus) an app by name
///     "shell:<command>"                 /bin/sh -c, off the main thread
///     "paw:<command>"                   a paw command over its socket ("paw:workspace new")
///     "hop:<args>"                      the hop CLI ("hop:clipboard")
///     "tip:<command>"                   tip itself: reload, settings [page], quit, theme <name>
///     "media:toggle|next|previous"      media keys
///     "plugin"                          send it to the item's plugin (the default for plugin items)
///     "none"
public enum Action: Equatable, Sendable {
    case zen(Bool?)
    case popup
    case toggleLabel
    case open(String)
    case app(String)
    case shell(String)
    case paw(String)
    case hop(String)
    case tip(String)
    case media(String)
    case plugin
    case none

    public static func parse(_ text: String) -> Action? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let colon = t.firstIndex(of: ":"), !t.hasPrefix("http") {
            let kind = t[..<colon].lowercased()
            let rest = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            switch kind {
            case "open": return .open(rest)
            case "app": return .app(rest)
            case "shell", "sh", "exec": return .shell(rest)
            case "paw": return .paw(rest)
            case "hop": return .hop(rest)
            case "tip": return .tip(rest)
            case "media":
                let cmd = rest.lowercased()
                return ["toggle", "play", "pause", "next", "previous", "prev"].contains(cmd) ? .media(cmd == "prev" ? "previous" : cmd) : nil
            default: return nil
            }
        }
        switch t.lowercased() {
        case "zen", "zen toggle": return .zen(nil)
        case "zen on": return .zen(true)
        case "zen off": return .zen(false)
        case "popup": return .popup
        case "toggle-label", "label": return .toggleLabel
        case "plugin": return .plugin
        case "none", "": return Action.none
        default:
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return .open(t) }
            return nil
        }
    }

    public var text: String {
        switch self {
        case .zen(let on): on.map { $0 ? "zen on" : "zen off" } ?? "zen"
        case .popup: "popup"
        case .toggleLabel: "toggle-label"
        case .open(let s): "open:\(s)"
        case .app(let s): "app:\(s)"
        case .shell(let s): "shell:\(s)"
        case .paw(let s): "paw:\(s)"
        case .hop(let s): "hop:\(s)"
        case .tip(let s): "tip:\(s)"
        case .media(let s): "media:\(s)"
        case .plugin: "plugin"
        case .none: "none"
        }
    }
}

/// A hotkey such as "ctrl+alt+z": modifiers and one key.
public struct KeySpec: Equatable, Hashable, Sendable {
    public var cmd = false, alt = false, ctrl = false, shift = false
    public var key: String

    public static func parse(_ text: String) -> KeySpec? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var s = KeySpec(key: key)
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": s.cmd = true
            case "alt", "opt", "option", "⌥": s.alt = true
            case "ctrl", "control", "⌃": s.ctrl = true
            case "shift", "⇧": s.shift = true
            case "hyper": s.cmd = true; s.alt = true; s.ctrl = true; s.shift = true
            default: return nil
            }
        }
        guard keyCodes[key] != nil else { return nil }
        return s
    }

    public var keyCode: UInt32? { Self.keyCodes[key] }

    /// ANSI key codes (Carbon kVK_*).
    public static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
            "f11": 103, "f12": 111,
        ]
        m["home"] = 115; m["end"] = 119; m["pageup"] = 116; m["pagedown"] = 121
        return m
    }()
}
