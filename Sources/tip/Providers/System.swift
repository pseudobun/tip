import AppKit
import CoreWLAN
import IOKit.ps
import SystemConfiguration
import TipCore

// MARK: - Battery

/// Charge and source from IOPowerSources; redrawn only when the power source reports a change.
final class BatteryProvider: Provider {
    private var source: CFRunLoopSource?
    private static weak var active: BatteryProvider?

    struct Reading: Equatable {
        var percent: Int
        var charging: Bool
        var onAC: Bool
        var minutesLeft: Int?
    }

    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let left = d[kIOPSTimeToEmptyKey] as? Int
            return Reading(percent: cur * 100 / max, charging: (d[kIOPSIsChargingKey] as? Bool) ?? false || ac, onAC: ac,
                           minutesLeft: (left ?? -1) > 0 ? left : nil)
        }
        return nil
    }

    override func begin() {
        Self.active = self
        let src = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { BatteryProvider.active?.update() }
        }, nil)?.takeRetainedValue()
        if let src { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }
        source = src
        update()
    }

    override func end() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    override func event(_ name: String, _ data: [String: Any]) { if name == "system_woke" { update() } }

    private func update() {
        guard let r = Self.read() else { set(.hidden); return }
        let (symbol, tone) = Format.battery(percent: r.percent, charging: r.charging,
                                            warnBelow: options.int("warnBelow", 30), badBelow: options.int("badBelow", 20))
        let label: String? = switch options.string("label", "percent") {
        case "none": nil
        case "time": r.minutesLeft.map { Format.countdown(minutes: $0) } ?? "\(r.percent)%"
        default: "\(r.percent)%"
        }
        var c = ItemContent.iconLabel(.symbol(symbol, tone, size: 15), label.map { .text($0, TextStyle(size: 11, weight: .medium, color: .secondary)) },
                                      gap: host.iconGap)
        c.tooltip = r.onAC ? "On power adapter" : r.minutesLeft.map { "\(Format.countdown(minutes: $0)) left" } ?? "On battery"
        set(c)
        host.publish("power_source_change", ["percent": r.percent, "charging": r.charging])
    }

    override func popupRows() -> [PopupRow]? {
        guard let r = Self.read() else { return nil }
        return [PopupRow(icon: "sf:battery.100percent", label: "\(r.percent)%", detail: r.charging ? "charging" : "on battery"),
                PopupRow(icon: "sf:clock", label: r.onAC ? "Power adapter" : "Time left",
                         detail: r.minutesLeft.map { Format.countdown(minutes: $0) } ?? "—"),
                PopupRow(icon: "sf:gearshape", label: "Battery Settings…", action: "open:x-apple.systempreferences:com.apple.Battery-Settings.extension")]
    }
}

// MARK: - Network

/// The network state as SCDynamicStore reports it: the primary interface, its kind and IPv4, and
/// whether a VPN tunnel (a utun interface carrying IPv4) is up. Shared by `network` and `vpn`.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    enum Kind: String { case wifi, ethernet, iphone, thunderbolt, other, offline }

    struct State: Equatable {
        var kind: Kind = .offline
        var interface: String?
        var ip: String?
        var router: String?
        var vpn: [String] = [] // utun interfaces with IPv4
        var vpnAddress: String?
    }

    private(set) var state = State()
    private var store: SCDynamicStore?
    private var listeners: [ObjectIdentifier: (State) -> Void] = [:]
    private let queue = DispatchQueue(label: "tip.network")

    func add(_ owner: AnyObject, _ onChange: @escaping (State) -> Void) {
        listeners[ObjectIdentifier(owner)] = onChange
        if store == nil { start() }
        onChange(state)
    }

    func remove(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
        if listeners.isEmpty { stop() }
    }

    private func start() {
        var ctx = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let s = SCDynamicStoreCreate(nil, "tip" as CFString, { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { NetworkMonitor.shared.refresh() } }
        }, &ctx) else { return }
        let keys = ["State:/Network/Global/IPv4"] as CFArray
        let patterns = ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(s, keys, patterns)
        SCDynamicStoreSetDispatchQueue(s, queue)
        store = s
        refresh()
    }

    private func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
    }

    func refresh() {
        guard let store else { return }
        let next = Self.read(store)
        guard next != state else { return }
        state = next
        for l in listeners.values { l(next) }
        (NSApp.delegate as? AppDelegate)?.bars?.broadcast("network_change", ["kind": next.kind.rawValue, "ip": next.ip ?? "", "vpn": !next.vpn.isEmpty])
    }

    private static func read(_ store: SCDynamicStore) -> State {
        var st = State()
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String
        st.router = global?["Router"] as? String
        // Tunnels: macOS keeps idle utuns around; only those with IPv4 count (as scutil --nwi).
        let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/utun[0-9]+/IPv4" as CFString) as? [String]) ?? []
        for key in keys.sorted() {
            let v = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
            if let addrs = v?["Addresses"] as? [String], let a = addrs.first {
                let name = key.split(separator: "/")[3]
                st.vpn.append(String(name))
                if st.vpnAddress == nil { st.vpnAddress = a }
            }
        }
        // The primary may be a tunnel; the physical interface is the first non-utun one with IPv4.
        var physical = primary.flatMap { $0.hasPrefix("utun") ? nil : $0 }
        if physical == nil {
            let all = (SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/en[0-9]+/IPv4" as CFString) as? [String]) ?? []
            physical = all.sorted().first.map { String($0.split(separator: "/")[3]) }
        }
        guard let iface = physical else { return st }
        let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(iface)/IPv4" as CFString) as? [String: Any]
        st.interface = iface
        st.ip = (v4?["Addresses"] as? [String])?.first
        guard st.ip != nil else { return st }
        st.kind = kind(of: iface)
        return st
    }

    private static func kind(of bsd: String) -> Kind {
        for iface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard (SCNetworkInterfaceGetBSDName(iface) as String?) == bsd else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? ""
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
            if name.localizedCaseInsensitiveContains("iphone") { return .iphone }
            if name.localizedCaseInsensitiveContains("thunderbolt") { return .thunderbolt }
            if type == (kSCNetworkInterfaceTypeEthernet as String) { return .ethernet }
            return .other
        }
        return bsd.hasPrefix("en") ? .ethernet : .other
    }

    static func symbol(_ k: Kind) -> String {
        switch k {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .iphone: "iphone"
        case .thunderbolt: "bolt.horizontal"
        case .other: "network"
        case .offline: "wifi.slash"
        }
    }
}

/// Wi-Fi / cable / iPhone / offline, a lock while a VPN is up, and the address (collapsed until
/// clicked, as today). Event-driven: a cable plug or VPN toggle changes it at once.
final class NetworkProvider: Provider {
    override func begin() { NetworkMonitor.shared.add(self) { [weak self] s in self?.show(s) } }
    override func end() { NetworkMonitor.shared.remove(self) }

    private func show(_ s: NetworkMonitor.State) {
        let vpn = options.bool("vpn", true) && !s.vpn.isEmpty
        let symbol = vpn ? "lock.shield.fill" : NetworkMonitor.symbol(s.kind)
        let tone: Paint = vpn ? .token(.chart1) : s.kind == .offline ? .dim : .fg
        let text = vpn ? "VPN" : (s.ip ?? "offline")
        let mode = options.string("label", "collapsed")
        let label: Part? = mode == "hidden" ? nil : .text(text, TextStyle(size: 11, weight: .medium, color: .secondary))
        var c = ItemContent.iconLabel(.symbol(symbol, tone, size: 15), label, gap: host.iconGap, collapsible: mode == "collapsed")
        c.tooltip = vpn ? "VPN \(s.vpn.joined(separator: ", ")) · \(s.vpnAddress ?? "")" : [s.interface, s.ip].compactMap { $0 }.joined(separator: " · ")
        set(c)
    }

    override func popupRows() -> [PopupRow]? {
        let s = NetworkMonitor.shared.state
        var rows = [PopupRow(icon: "sf:\(NetworkMonitor.symbol(s.kind))", label: s.kind.rawValue.capitalized, detail: s.interface ?? "—")]
        if s.kind == .wifi, let ssid = CWWiFiClient.shared().interface()?.ssid() {
            rows.append(PopupRow(icon: "sf:wifi", label: ssid, detail: "SSID"))
        }
        rows.append(PopupRow(icon: "sf:number", label: s.ip ?? "no address", detail: "IPv4", action: s.ip.map { "shell:printf %s \($0) | pbcopy" }))
        if let r = s.router { rows.append(PopupRow(icon: "sf:point.3.connected.trianglepath.dotted", label: r, detail: "router")) }
        for v in s.vpn { rows.append(PopupRow(icon: "sf:lock.shield.fill", label: v, detail: s.vpnAddress, color: "chart1")) }
        rows.append(PopupRow(icon: "sf:gearshape", label: "Network Settings…", action: "open:x-apple.systempreferences:com.apple.Network-Settings.extension"))
        return rows
    }
}

/// A lock and the tunnel's name while a VPN is up.
final class VPNProvider: Provider {
    override func begin() {
        NetworkMonitor.shared.add(self) { [weak self] s in
            guard let self else { return }
            if s.vpn.isEmpty {
                self.set(self.options.bool("hideWhenOff", true) ? .hidden : .iconLabel(.symbol("lock.open", .dim, size: 14), nil))
            } else {
                var c = ItemContent.iconLabel(.symbol("lock.shield.fill", .token(.chart1), size: 14),
                                              .text("VPN", TextStyle(size: 11, weight: .medium, color: .secondary)), gap: self.host.iconGap)
                c.tooltip = s.vpn.joined(separator: ", ")
                self.set(c)
            }
        }
    }

    override func end() { NetworkMonitor.shared.remove(self) }
}
