import Foundation
import Testing
@testable import TipCore

@Suite struct ConfigTests {
    @Test func templateIsTheDefaults() throws {
        let c = try ConfigLoader.decode(Data(ConfigTemplate.text.utf8))
        #expect(c == TipConfig())
        #expect(ConfigLoader.unknownKeys(Data(ConfigTemplate.text.utf8)).isEmpty)
        #expect(ConfigLoader.warnings(c).isEmpty)
    }

    @Test func emptyFileIsDefaults() throws {
        #expect(try ConfigLoader.decode(Data("  \n".utf8)) == TipConfig())
        #expect(try ConfigLoader.decode(Data("{}".utf8)) == TipConfig())
    }

    @Test func missingOrBlankFileIsAnError() throws {
        // The app keeps its last good config instead of resetting to the defaults.
        #expect(throws: ConfigProblem("the config file is missing")) { try ConfigLoader.load(nil) }
        #expect(throws: ConfigProblem("the config file is empty")) { try ConfigLoader.load(Data(" \n\t".utf8)) }
        #expect(throws: ConfigProblem("the config file is empty")) { try ConfigLoader.load(Data()) }
        #expect(try ConfigLoader.load(Data("{}".utf8)) == TipConfig())
        #expect(try ConfigLoader.load(Data(#"{ theme: "nord" }"#.utf8)).theme == "nord")
        #expect(throws: ConfigProblem.self) { try ConfigLoader.load(Data("{ bar: ".utf8)) }
    }

    @Test func itemsMergeOverDefaults() throws {
        let c = try ConfigLoader.decode(Data("""
        { items: { clock: { format: "HH:mm:ss" }, media: null, uptime: { command: "uptime", interval: 60 } } }
        """.utf8))
        #expect(c.items["clock"]?.provider == "clock")
        #expect(c.items["clock"]?.string("format") == "HH:mm:ss")
        #expect(c.items["clock"]?.string("click") == "zen") // kept from the default
        #expect(c.items["media"] == nil)
        #expect(c.items["uptime"]?.provider == "script")
        #expect(c.items["cpu"] != nil)
    }

    @Test func newProviderStartsFresh() throws {
        let c = try ConfigLoader.decode(Data(#"{ items: { clock: { provider: "text", label: "hi" } } }"#.utf8))
        #expect(c.items["clock"]?.string("click") == nil)
    }

    @Test func layoutMergesPerZone() throws {
        let c = try ConfigLoader.decode(Data(#"{ layout: { default: { right: [["clock"]] }, "DELL U3223QE": { left: ["apple"] } } }"#.utf8))
        let z = c.zones(displayName: "DELL U3223QE", builtin: false)
        #expect(z.right == [["clock"]])
        #expect(z.left == [["apple"]])
        #expect(z.center == [["media"]])
        #expect(c.zones(displayName: "Built-in", builtin: true).center == [])
    }

    @Test func diagnostics() throws {
        let data = Data(#"{ them: "og", bar: { hieght: 30 }, items: { cpu: { provider: "cpu", intreval: 3 } } }"#.utf8)
        let unknown = ConfigLoader.unknownKeys(data)
        #expect(unknown.contains("them (did you mean theme?)"))
        #expect(unknown.contains("bar.hieght (did you mean height?)"))
        #expect(unknown.contains("items.cpu.intreval (did you mean interval?)"))
        let c = try ConfigLoader.decode(Data(#"{ theme: "nope", layout: { default: { left: [["clokc"]] } } }"#.utf8))
        let w = ConfigLoader.warnings(c)
        #expect(w.contains { $0.hasPrefix("theme:") })
        #expect(w.contains { $0.contains("no item “clokc”") })
    }

    @Test func glassIsOnByDefault() throws {
        #expect(TipConfig().glass)
        #expect(try ConfigLoader.decode(Data("{ glass: false }".utf8)).glass == false)
        // The old per-island switch still loads, is ignored, and says what replaced it.
        let data = Data(#"{ island: { material: "solid" } }"#.utf8)
        #expect(ConfigLoader.unknownKeys(data).isEmpty)
        let c = try ConfigLoader.decode(data)
        #expect(c.glass)
        #expect(ConfigLoader.warnings(c).contains { $0.hasPrefix("island.material:") })
    }

    @Test func badSyntaxHasALine() {
        #expect(throws: ConfigProblem.self) { try ConfigLoader.decode(Data("{\n  bar: { height: }\n}".utf8)) }
    }

    @Test func plugins() throws {
        let c = try ConfigLoader.decode(Data(#"{ plugins: { disabled: ["a.b"], "com.x.y": { k: 1 } } }"#.utf8))
        #expect(c.plugins.disabled == ["a.b"])
        #expect(c.plugins.settings["com.x.y"]?["k"]?.int == 1)
    }

    @Test func updatesChannel() {
        var u = TipConfig.Updates()
        #expect(u.wantsBeta(running: "0.1.0-beta.2+abc"))
        #expect(!u.wantsBeta(running: "0.2.0"))
        u.channel = "beta"
        #expect(u.wantsBeta(running: "0.2.0"))
    }
}

@Suite struct ConfigEditTests {
    @Test func replacesInPlaceKeepingComments() {
        let text = "{\n  // look\n  theme: \"og\", // here\n  bar: { height: 40 },\n}\n"
        let out = ConfigEdit.setting(["theme"], to: "\"modern\"", in: text)
        #expect(out == "{\n  // look\n  theme: \"modern\", // here\n  bar: { height: 40 },\n}\n")
        let h = ConfigEdit.setting(["bar", "height"], to: "32", in: text)
        #expect(h?.contains("bar: { height: 32 }") == true)
    }

    @Test func addsMissingKeys() throws {
        let text = "{\n  theme: \"og\",\n}\n"
        let out = try #require(ConfigEdit.setting(["items", "clock", "format"], to: "\"HH:mm\"", in: text))
        #expect(out.contains("items: { clock: { format: \"HH:mm\" } },"))
        let c = try ConfigLoader.decode(Data(out.utf8))
        #expect(c.items["clock"]?.string("format") == "HH:mm")
    }

    @Test func quotesOddKeys() {
        #expect(ConfigEdit.memberName("com.x.y") == "\"com.x.y\"")
        #expect(ConfigEdit.memberName("theme") == "theme")
    }

    @Test func removes() {
        let text = "{\n  theme: \"og\",\n  bar: { height: 40 },\n}\n"
        #expect(ConfigEdit.removing(["theme"], in: text) == "{\n  bar: { height: 40 },\n}\n")
        #expect(ConfigEdit.removing(["nope"], in: text) == text)
    }
}

@Suite struct ThemeTests {
    @Test func builtIns() {
        #expect(Themes.all.map(\.id) == ["og", "og-light", "modern", "minimal", "solarpunk", "cyberpunk"])
        #expect(Themes.og.palette.primary == ARGB(0xffea_d186))
        #expect(Themes.builtIn("OG")?.id == "og")
    }

    @Test func customThemeOverridesItsBase() throws {
        let file = try ThemeFile.decode(Data(##"{ name: "Nord", base: "modern", colors: { primary: "#88c0d0", prmary: "#000" }, radius: 4 }"##.utf8))
        let (t, issues) = file.theme(id: "nord", path: "/x/nord.json5")
        #expect(t.label == "Nord")
        #expect(t.palette.primary == ARGB(0xff88_c0d0))
        #expect(t.palette.card == Themes.modern.palette.card)
        #expect(t.radius == 4)
        #expect(t.font == "system")
        #expect(!t.isBuiltIn)
        #expect(issues == ["unknown colour \"prmary\", did you mean \"primary\"?"])
    }

    @Test func templateRoundTrips() throws {
        let text = ThemeFile.template(name: "Mine", from: Themes.cyberpunk)
        let (t, issues) = try ThemeFile.decode(Data(text.utf8)).theme(id: "mine", path: nil)
        #expect(issues.isEmpty)
        #expect(t.palette == Themes.cyberpunk.palette)
        #expect(t.font == Themes.cyberpunk.font)
        #expect(t.radius == Themes.cyberpunk.radius)
    }

    @Test func colours() {
        #expect(ARGB.parse("#ead186") == ARGB(0xffea_d186))
        #expect(ARGB.parse("#1d1d16eb") == ARGB(0xeb1d_1d16))
        #expect(ARGB.parse("0xeb1d1d16") == ARGB(0xeb1d_1d16))
        #expect(ARGB.parse("#fff") == ARGB(0xffff_ffff))
        #expect(ARGB.parse("nope") == nil)
        #expect(ARGB(0xeb1d_1d16).hex == "#1d1d16eb")
        #expect(Paint.parse("gold") == .accent)
        #expect(Paint.parse("chart3") == .token(.chart3))
        #expect(Paint.parse("#ff0000")?.resolve(Themes.og.palette) == ARGB(0xffff_0000))
        #expect(Paint.faded(.fg, 0.5).resolve(Themes.og.palette).a < 0.51)
    }

    @Test func slug() { #expect(ThemeFile.slug("My Theme!") == "my-theme") }
}

@Suite struct LayoutTests {
    func input(_ l: [Double], _ c: [Double], _ r: [Double], notch: ClosedRange<Double>? = nil, width: Double = 1000) -> LayoutSolver.Input {
        .init(width: width, marginLeft: 10, marginRight: 10, gap: 5, notch: notch, left: l, center: c, right: r)
    }

    @Test func placesZones() {
        let o = LayoutSolver.solve(input([100, 50], [80], [60, 40]))
        #expect(o.left == [10, 115])
        #expect(o.right == [885, 950])
        #expect(o.center == [460])
    }

    @Test func emptyIslandsTakeNoGap() {
        let o = LayoutSolver.solve(input([100, 0, 50], [], [0, 40]))
        #expect(o.left == [10, nil, 115])
        #expect(o.right == [nil, 950])
    }

    @Test func notchHidesCenterAndOverflow() {
        let o = LayoutSolver.solve(input([200, 200, 100], [80], [100, 100], notch: 400...600))
        #expect(o.center == [nil])
        #expect(o.left == [10, nil, nil]) // the second would cross 395
        #expect(o.right == [785, 890])
    }

    @Test func rightWinsOverLeft() {
        let o = LayoutSolver.solve(input([300, 300], [], [500], width: 900))
        #expect(o.right == [390])
        #expect(o.left == [10, nil])
    }

    @Test func centerHidesWhenCrowded() {
        let o = LayoutSolver.solve(input([400], [200], [300]))
        #expect(o.center == [nil])
        var narrow = input([10], [20], [10])
        narrow.centerAllowed = false
        #expect(LayoutSolver.solve(narrow).center == [nil])
    }
}

@Suite struct FormatTests {
    @Test func thousands() {
        #expect(Format.thousands(98412.3) == "98,412")
        #expect(Format.thousands(3412.456, decimals: 2) == "3,412.46")
        #expect(Format.thousands(-1234567) == "-1,234,567")
        #expect(Format.thousands(12) == "12")
    }

    @Test func nyse() {
        // Monday 10:00: open, 6 h to go
        #expect(Format.nyse(weekday: 1, minute: 600) == (true, 360))
        // Monday 8:00: opens in 1h30
        #expect(Format.nyse(weekday: 1, minute: 480) == (false, 90))
        // Friday 17:00 → Monday 9:30
        #expect(Format.nyse(weekday: 5, minute: 1020) == (false, 3 * 1440 - 1020 + 570))
        #expect(Format.countdown(minutes: 90) == "1h30m")
        #expect(Format.countdown(minutes: 2 * 1440 + 200) == "2d3h")
        #expect(Format.countdown(minutes: 7) == "7m")
    }

    @Test func tones() {
        #expect(Format.cpuTone(0.05) == .secondary)
        #expect(Format.cpuTone(0.5) == .warn)
        #expect(Format.battery(percent: 15, charging: false).tone == .bad)
        #expect(Format.battery(percent: 50, charging: true).symbol == "battery.100percent.bolt")
        #expect(Format.brew("12!") == (12, true))
        #expect(Format.brewTone(count: 0, stale: false) == .good)
        #expect(Format.brewTone(count: 40, stale: false) == .bad)
        #expect(Format.processName("com.apple.WebKit.WebContent") == "WebKit.Web…")
        #expect(Format.truncate("abcdef", 4) == "abc…")
    }

    @Test func ring() {
        var r = RingBuffer(capacity: 3)
        [1, 2, 3, 4].forEach { r.push($0) }
        #expect(r.values == [2, 3, 4])
        r.resize(2)
        #expect(r.values == [3, 4])
    }

    @Test func env() {
        let env = EnvFile.parse("# c\nexport ETH_API_KEY=\"abc\"\nX=1\nbad line\n")
        #expect(env == ["ETH_API_KEY": "abc", "X": "1"])
        #expect(EnvFile.expand("k=${ETH_API_KEY};${NOPE}", env) == "k=abc;")
    }
}

@Suite struct ActionAndPluginTests {
    @Test func actions() {
        #expect(Action.parse("zen") == .zen(nil))
        #expect(Action.parse("paw:workspace new") == .paw("workspace new"))
        #expect(Action.parse("https://x.y") == .open("https://x.y"))
        #expect(Action.parse("media:prev") == .media("previous"))
        #expect(Action.parse("bogus") == nil)
        #expect(KeySpec.parse("ctrl+alt+z")?.keyCode == 6)
        #expect(KeySpec.parse("ctrl+nope") == nil)
    }

    @Test func manifest() throws {
        let m = try PluginManifest.decode(Data("""
        { id: "com.pseudobun.tip.markets", name: "Markets", version: "0.1.0", entry: "bin/markets",
          items: [{ id: "btc" }, { id: "eth" }], preferences: [{ id: "symbols", type: "list", default: ["BTCUSDT"] }] }
        """.utf8))
        #expect(m.items.map(\.id) == ["btc", "eth"])
        #expect(m.lifecycle == "persistent")
        #expect(m.preferences(with: ["x": 1])["symbols"]?.strings == ["BTCUSDT"])
        #expect(throws: ConfigProblem.self) { try PluginManifest.decode(Data(#"{ id: "Bad", entry: "../x" }"#.utf8)) }
    }

    @Test func protocolSet() throws {
        let line = Data(#"{"jsonrpc":"2.0","method":"set","params":{"items":[{"id":"btc","label":"$1","graph":{"push":0.5}}]}}"#.utf8)
        let m = try #require(RPCMessage.decode(line))
        #expect(m.setItems.first?.label == "$1")
        #expect(m.setItems.first?.graph?.push == 0.5)
        let out = String(decoding: RPCMessage(id: 1, method: "initialize", params: ["a": 1]).line, as: UTF8.self)
        #expect(out == "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"a\":1}}\n")
    }

    @Test func specs() throws {
        let s = try ItemSpec.from(pairs: ["label=hi", "drawing=off", "push=0.3"], id: "x")
        #expect(s.label == "hi" && s.drawing == false && s.graph?.push == 0.3)
        #expect(throws: ConfigProblem.self) { try ItemSpec.from(pairs: ["lable=x"], id: "x") }
        let merged = ItemSpec(id: "x").merged(with: s)
        #expect(merged.label == "hi")
    }

    @Test func budget() {
        var b = PluginBudget()
        let allowed = (0..<40).filter { _ in b.allow(at: 100) }.count
        #expect(allowed == 30)
        let later = b.allow(at: 101.5)
        #expect(later)
        #expect(PluginBudget.delay(attempt: 3) == nil)
    }

    @Test func cliWords() {
        let words = ["trigger", "hello", #"{"x": 1}"#, "it's", ""]
        #expect(CLIWords.split(CLIWords.join(words)) == ["trigger", "hello", #"{"x": 1}"#, "it's"])
        #expect(CLIWords.split("set clock 'label=a b'") == ["set", "clock", "label=a b"])
    }

    @Test func versions() {
        #expect(Version.compare("0.1.0-beta.2", "0.1.0") == .orderedAscending)
        #expect(Version.compare("0.2.0", "0.1.9") == .orderedDescending)
        #expect(Version.compare("0.1.0-beta.10", "0.1.0-beta.9") == .orderedDescending)
    }
}
