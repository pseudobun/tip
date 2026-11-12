import Foundation
import TipPluginKit

/// BTC/ETH price and 24 h change (Binance), ETH base fee (Etherscan), NYSE open/close countdown.
/// One process, one URLSession, a timer; nothing forks. Offline: keeps the last values.
final class Markets: TipPlugin {
    private var tip: Tip!
    private var prefs: [String: JSONValue] = [:]
    private var timer: Timer?
    private var bell: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private var key: String { prefs["etherscanKey"]?.string ?? "" }
    private var interval: Double { max(prefs["interval"]?.number ?? 60, 15) }

    func initialize(_ tip: Tip, preferences: [String: JSONValue]) -> [Item] {
        self.tip = tip
        prefs = preferences
        schedule()
        return initial()
    }

    private func chart(_ symbol: String) -> String {
        (prefs["chartURL"]?.string ?? "https://www.tradingview.com/chart/?symbol=BINANCE:{symbol}").replacingOccurrences(of: "{symbol}", with: symbol)
    }

    private func initial() -> [Item] {
        let items = [
            Item("btc").icon("sf:bitcoinsign", color: "chart3").label("–").click("open:" + chart("BTCUSDT")).tooltip("Bitcoin"),
            Item("eth").icon("Ξ", color: "chart1").label("–").click("open:" + chart("ETHUSDT")).tooltip("Ether"),
            Item("gas").icon("sf:fuelpump.fill", color: "chart2").label("–").click("open:https://etherscan.io/gastracker")
                .tooltip("ETH base fee (gwei)").drawing(!key.isEmpty),
            Item("nyse").icon("sf:building.columns.fill", color: "dim").label("").drawing(prefs["nyse"]?.bool ?? true),
        ]
        return items
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = interval * 0.1
        // The bell flips on the minute.
        bell?.invalidate()
        let now = Date().timeIntervalSince1970
        let next = Date(timeIntervalSince1970: (floor(now / 60) + 1) * 60 + 0.1)
        bell = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.nyse() }
        RunLoop.main.add(bell!, forMode: .common)
        DispatchQueue.main.async { self.refresh() }
    }

    func refresh() {
        prices()
        gas()
        nyse()
    }

    func event(_ tip: Tip, name: String, data: JSONValue) {
        // Give the network a moment after waking.
        DispatchQueue.main.asyncAfter(deadline: .now() + (name == "system_woke" ? 10 : 2)) { self.refresh() }
    }

    func preferencesChanged(_ tip: Tip, preferences: [String: JSONValue]) {
        prefs = preferences
        tip.set(initial().filter { ["gas", "nyse"].contains($0.id) }.map { Item($0.id).drawing($0.drawing ?? true) })
        schedule()
    }

    private func get(_ url: String, _ done: @escaping (Any) -> Void) {
        guard let u = URL(string: url) else { return }
        session.dataTask(with: u) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return }
            DispatchQueue.main.async { done(obj) }
        }.resume()
    }

    private func prices() {
        get("https://api.binance.com/api/v3/ticker/24hr?symbols=%5B%22BTCUSDT%22,%22ETHUSDT%22%5D") { [weak self] obj in
            guard let self, let list = obj as? [[String: Any]] else { return }
            var out: [Item] = []
            for t in list {
                guard let sym = t["symbol"] as? String, let price = Double(t["lastPrice"] as? String ?? ""),
                      let pct = Double(t["priceChangePercent"] as? String ?? "") else { continue }
                let id = sym == "BTCUSDT" ? "btc" : sym == "ETHUSDT" ? "eth" : nil
                guard let id else { continue }
                out.append(Item(id).label("$" + Fmt.thousands(price))
                    .detail((pct >= 0 ? "▲" : "▼") + String(format: "%.1f%%", abs(pct)), color: pct >= 0 ? "good" : "bad"))
            }
            if !out.isEmpty { self.tip.set(out) }
        }
    }

    private func gas() {
        guard !key.isEmpty else { return }
        get("https://api.etherscan.io/v2/api?chainid=1&module=gastracker&action=gasoracle&apikey=\(key)") { [weak self] obj in
            guard let self, let r = (obj as? [String: Any])?["result"] as? [String: Any],
                  let fee = Double(r["suggestBaseFee"] as? String ?? "") else { return }
            self.tip.set(Item("gas").label(String(format: fee < 10 ? "%.2f" : "%.0f", fee)).drawing(true))
        }
    }

    /// NYSE regular session, 9:30–16:00 New York, Mon–Fri.
    private func nyse() {
        guard prefs["nyse"]?.bool ?? true else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date()
        let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
        let dow = ((c.weekday ?? 1) + 5) % 7 + 1 // ISO: 1 = Monday … 7 = Sunday
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let (open, left) = Self.session(weekday: dow, minute: minute)
        tip.set(Item("nyse").icon("sf:building.columns.fill", color: open ? "good" : "dim")
            .label(Self.countdown(left), color: open ? "good" : "muted")
            .tooltip(open ? "NYSE open, closes in \(Self.countdown(left))" : "NYSE closed, opens in \(Self.countdown(left))"))
    }

    static func session(weekday: Int, minute: Int) -> (Bool, Int) {
        let open = 9 * 60 + 30, close = 16 * 60
        if weekday <= 5, minute >= open, minute < close { return (true, close - minute) }
        let ahead: Int
        if weekday <= 4, minute >= close { ahead = 1 }
        else if weekday == 5, minute >= close { ahead = 3 }
        else if weekday == 6 { ahead = 2 }
        else if weekday == 7 { ahead = 1 }
        else { ahead = 0 }
        return (false, max(ahead == 0 ? open - minute : ahead * 1440 - minute + open, 0))
    }

    static func countdown(_ m: Int) -> String {
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return String(format: "%dh%02dm", h, mm) }
        return "\(mm)m"
    }
}

serve(Markets())
