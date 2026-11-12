# tip — architecture

> The plan tip was built from (2026-11-12). Where the code and this differ, the code wins; open
> questions at the end were decided as: workspaces without paw hide (no private Spaces API, no
> permissions); media uses Homebrew `media-control stream`; the theme is tip's own with
> `follow-paw` / `follow-hop` opt-in; plugins come from GitHub release zips.

> A fast, native macOS menu bar replacement. Third sibling of **paw** (tiling WM) and **hop** (launcher): standalone, same conventions, complementary when they are present.

Status: plan, 2026-11-12. Replaces the current SketchyBar + SbarLua setup in `~/.dotfiles/sketchybar`.

---

## 1. What tip should achieve

### Goals

1. **Zero cost at rest.** 0 % idle CPU, ≤ 1 wakeup / 10 s with no changing items, ≤ 25 MB footprint. No process is spawned in steady state; every built-in item is event-driven from a native API.
2. **Plugins in any language.** A plugin is a long-lived process that speaks JSON-RPC 2.0 over stdio (same protocol shape as hop). Swift and Rust SDKs, but plain shell/Python/Node work too.
3. **Same feel as paw and hop.** One `config.json5`, AppKit Settings window that writes the file, single binary that is also the CLI, Unix-socket IPC, same themes, tokens, fonts, justfile, release pipeline.
4. **Standalone.** tip runs on a Mac with neither paw nor hop. When they are installed it shows their state through their *public* interfaces only (CLI / socket / event stream), never through shared code or private coupling.
5. **Feature parity with today's bar** (section 13) on day one of switching, then better: real popups, per-display layouts, notch-aware layout, smooth animation.
6. **Scriptable.** Everything visible can be read and changed from the CLI (`tip set`, `tip query --json`, `tip subscribe`), so agents can drive it as they drive paw and hop.

### Non-goals

- SketchyBar CLI or Lua compatibility. A one-time migration (section 13) instead of a compat layer.
- Replacing the system menu bar's app menus. tip draws over/next to it like SketchyBar; the user hides the system bar with macOS' own "Automatically hide and show the menu bar".
- A plugin store. Plugins install from a GitHub release zip, like hop.
- Intel / macOS < 26.

### Why not just keep SketchyBar

The SketchyBar core is already cheap (0.1 % idle). The cost is the model: every update forks `sh` + a tool + `sketchybar --set`, and every data source is a poll. Measured today: `media-control` + `jq` every 3 s (~57k spawns/day, now fixed with a stream bridge), `scutil` every 20 s, `curl` + `date` every 60 s, `osascript` blocking the Lua loop, 79 MB RSS. tip moves the data sources in-process and makes external plugins long-lived.

---

## 2. Principles taken from paw and hop

| Rule | Source |
|---|---|
| The file is the source of truth; Settings edits the file in place, keeping comments | hop `Core/ConfigEdit.swift`, paw `UI/SettingsWindow.swift` |
| Every key optional, defaults in code, commented template written on first launch, `examples/config.json5` checked in CI | paw `PawCore/ConfigTemplate.swift` |
| Broken file keeps the last good config; diagnostics with line/column and "did you mean" | hop `Core/ConfigDiagnostics.swift` |
| The app binary is the CLI; `--json` everywhere; exit 0 / 1 / 10 (update) / 64 (usage) | both |
| 0600 Unix socket in `~/Library/Application Support/<bundle id>/`, peer uid check, rate limit | paw `App/IPC.swift`, hop `SECURITY.md` |
| Event stream as JSON lines, first line a `snapshot` | paw `App/Events.swift` |
| Main thread never waits on another process or app; redraw only on change, coalesced once per run-loop turn | both `PERFORMANCE.md` |
| Pure logic in a target without AppKit, unit tested with Swift Testing | paw `PawCore` |
| `just dev` builds a separate "tip Dev" with its own bundle id, data and socket | both justfiles |

---

## 3. Relationship to paw and hop

tip knows nothing about paw or hop at compile time. Integration is done by **providers that talk to public interfaces** and switch themselves off when the other app isn't there.

| Feature | Without paw/hop | With paw | With hop |
|---|---|---|---|
| Workspaces island | macOS Spaces via `CGSCopyManagedDisplaySpaces` (read-only) or hidden | `paw subscribe --json` socket stream: workspaces, windows, zoom, app colours | — |
| Front app colour | icon average colour, computed and cached by tip | `paw color <app>` reply, if available | — |
| Click actions | `open`, AppleScript, shell | `paw workspace N`, `paw layout …` | `hop <command>` (e.g. open clipboard, notes) |
| Theme | tip's own setting | can follow paw's theme (`paw theme --json` + theme event) when `theme: "follow-paw"` | or follow hop's |

Rules:

- Integration lives in `Providers/Paw` and `Providers/Hop`, each a normal provider behind the same protocol as any other. Deleting the folder must leave a working app.
- Discovery: socket path existence + `version` handshake. No polling for the other app: watch its socket folder with `DispatchSource` and connect when the socket appears (covers "paw started after tip").
- Version contract: tip pins the minimum event-stream schema it understands; on mismatch it logs once and disables that provider.
- The other direction is equally loose: paw/hop never need to know tip exists. tip publishes its own `tip subscribe` stream should they ever want it.

---

## 4. Process and module architecture

```
tip.app
├── TipCore        (pure Swift, no AppKit) model, layout solver, config, diff, protocol types
├── tip            (executable, AppKit) bars, rendering, providers, IPC, Settings, CLI
├── TipPluginKit         (Swift package, separate) plugin SDK for Swift
└── sdk/rust/tip-plugin  plugin SDK for Rust (serde only)
```

- Build: SwiftPM package like paw (simpler CI, no xcodeproj churn), Swift 6, `defaultIsolation(MainActor)` + strict concurrency like hop. Pure types `nonisolated`, blocking work `@concurrent`.
- Target: **macOS 26, arm64**, hardened runtime, Developer ID. `.accessory` activation policy (no Dock icon), login item via `SMAppService`.
- Folders in `Sources/tip/`: `App`, `Bar`, `Render`, `Providers/<Name>`, `Plugins`, `IPC`, `CLI`, `UI/Settings`, `Support`.

### Threads

| Work | Where |
|---|---|
| Model mutation, layout, layer updates | MainActor, coalesced: changes mark items dirty, one `CATransaction` per run-loop turn (`CFRunLoopObserver` before waiting) |
| Providers' system callbacks (SCDynamicStore, IOKit, NWPathMonitor) | their own serial queue; post value snapshots to MainActor |
| Plugin process I/O | one `DispatchIO` reader per plugin on a background queue; decode JSON off-main |
| IPC socket, event encoding | background queue; payloads built only when there are subscribers |
| HTTP (markets, weather) | `URLSession` with `waitsForConnectivity`, ETag where available |

### Data model (`TipCore`)

```swift
struct Item {            // smallest drawable unit
  let id: String         // "net", "cpu.graph", "plugin.weather.temp"
  var icon: Glyph?       // .symbol("wifi") | .text("󰈀", font) | .image(appBundleID / path)
  var label: StyledText?
  var graph: Graph?      // ring buffer, drawn as one CAShapeLayer path
  var progress: Double?  // battery / volume bars
  var badge: Badge?
  var style: ItemStyle   // padding, colours, font overrides (all theme-token based)
  var drawing: Bool
  var actions: [Trigger: Action]   // click, rightClick, scroll, hover
  var popup: PopupID?
}

struct Island {          // rounded group ("bracket") — first-class, not a hack
  let id: String
  var items: [Item.ID]
  var style: IslandStyle // fill, border, radius, material (.solid | .glass)
}

struct BarLayout {       // per display
  var left: [Island.ID]; var center: [Island.ID]; var right: [Island.ID]
}
```

SketchyBar's edge-spacer / zero-width-frame / inset tricks disappear: islands own their padding and background, graphs own their frame.

### Rendering

- One borderless `NSPanel` per display (`.statusBar` level, `canJoinAllSpaces`, `fullScreenAuxiliary`, ignores mouse outside item rects via `hitTest`). Recreated only on `NSApplication.didChangeScreenParametersNotification`.
- **Layer-backed, no SwiftUI in the bar.** Each item = one `CALayer` with sublayers for icon, label, graph. Text pre-shaped with CoreText into `CATextLayer`-free bitmaps cached by (string, font, colour, scale); SF Symbols rendered via `NSImage(systemSymbolName:)` at the exact point size and cached (no PUA code points, no "find the glyph" hunting).
- Layout solver in `TipCore`: measures items, places islands into left / center / right zones, avoids the notch using `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. When center content does not fit beside the notch it moves into a configurable fallback zone or hides — no hard-coded `notch_width`.
- Animations: `CABasicAnimation` / `CASpringAnimation` with paw's easing set (`easeOutCubic`, `easeOutQuint`, spring `1 − e^{−7t}·cos 5t`), `durationMs` configurable, everything instant under Reduce Motion.
- Popups: `NSPanel` anchored to the item, same island style, content is a list of rows (`Item`s again) or, for built-ins only, a native AppKit view (calendar month, network details). Close on click outside / Escape / mouse exit (configurable).

---

## 5. Built-in providers (native, event-driven)

| Provider | API | Wakes on |
|---|---|---|
| `clock` | `Timer` aligned to the next minute (or second if the format has seconds); `NSSystemClockDidChange`, timezone change | minute boundary |
| `battery` | `IOPSNotificationCreateRunLoopSource`, `IOPSCopyPowerSourcesInfo` | power source change |
| `network` | `SCDynamicStore` keys `State:/Network/Global/IPv4`, `State:/Network/Interface/*/IPv4`; interface kind from `SCNetworkInterfaceGetInterfaceType` (Wi-Fi, Ethernet, iPhone USB, Thunderbolt) | link / address change — fixes "cable plug has no event" |
| `vpn` | `SCNetworkConnection` status for every VPN service in the current set (WireGuard, Tailscale, IPSec); names from the service | connect / disconnect |
| `wifi` details (popup only) | `CWWiFiClient` — SSID needs Location permission, so only requested when the user enables SSID display | on popup open |
| `cpu` | `host_processor_info` delta, per-process top via `proc_pid_rusage` (only while the item is visible) | configurable interval, default 2 s |
| `memory` | `host_statistics64` | interval |
| `disk` | `URLResourceKey.volumeAvailableCapacityForImportantUsage` | 5 min + volume mount events |
| `media` | MediaRemote. Since macOS 15.4 MediaRemote only answers entitled clients; use the same adapter trick `media-control` uses (load `MediaRemote.framework` inside a `/usr/bin/perl` helper) as a **bundled long-lived helper**, not per-poll. Fallback: built-in `media-control stream` bridge if the helper breaks on a macOS update. | now-playing change |
| `front_app` | `NSWorkspace.didActivateApplicationNotification` | app switch |
| `volume`, `mic` | CoreAudio property listeners on default device | volume / mute / device change |
| `bluetooth` (optional) | `IOBluetooth` connection notifications | connect / disconnect |
| `calendar` (optional) | EventKit `EKEventStoreChanged`; next event countdown | store change + minute tick |
| `brew` | reads the JSON written by the existing `sh.pseudobun.brew-refresh` launchd job; watches the file | file change |
| `markets`, `weather` | `URLSession`, interval from config, paused while asleep / offline (`NWPathMonitor`) | interval |
| `paw` (integration) | paw socket event stream | paw events |
| `hop` (integration) | hop CLI for actions only | — |

Each provider:
- declares the item ids and fields it fills;
- starts only when at least one configured item uses it, and stops when none is visible on any display (`updates: "when_shown"` is the default, as in SketchyBar);
- has a fixture-driven unit test in `TipCoreTests` for its parsing / state machine.

---

## 6. Plugin system

Three tiers, cheapest first:

| Tier | What | Cost | Use for |
|---|---|---|---|
| Built-in provider | Swift in the app | none | everything in section 5 |
| **Process plugin** | long-lived executable, JSON-RPC 2.0 over stdio | one process, idle when quiet | anything custom, any language |
| Script item | `command` + `interval` or `on` events; stdout = label (or JSON) | one fork per run — flagged in `tip doctor` | quick one-offs, migration |

### Process plugin package

Same as hop: `*.tipplugin.zip` from a GitHub release, containing `plugin.json5`, `bin/<exe>`, optional `icon.png`; symlinks refused. Also loadable from a local folder in dev (`tip plugins link <dir>`).

```json5
// plugin.json5
{
  id: "com.pseudobun.tip.weather",
  name: "Weather",
  version: "0.1.0",
  tip: "0.1.0",                // minimum tip version
  entry: "bin/weather",
  items: [                       // items this plugin may create; user places them in config
    { id: "temp", kind: "item" },
    { id: "forecast", kind: "popup" },
  ],
  preferences: [                 // rendered in Settings, same types as hop
    { id: "city", type: "text", default: "Maribor" },
    { id: "apiKey", type: "secret" },
    { id: "units", type: "choice", options: ["metric", "imperial"] },
  ],
  events: ["system_woke", "network_change"],   // tip events the plugin wants
  permissions: ["network"],      // declared, shown in Settings, not enforced (same as hop)
  lifecycle: "persistent",       // or "on-demand": started when an item becomes visible / clicked
}
```

### Protocol (JSON-RPC 2.0, one message per line)

tip → plugin

| Method | When |
|---|---|
| `initialize` `{tipVersion, preferences, theme, displays}` | start; reply lists initial items |
| `event` `{name, data}` | a subscribed event fired (`system_woke`, `network_change`, `display_change`, `theme_change`, custom `tip trigger` events) |
| `action` `{item, trigger, modifiers, button}` | click / scroll / hover |
| `popupOpen` / `popupClose` `{popup}` | lazy popup content |
| `preferencesChanged` | Settings edit |
| `shutdown` | quit, disable, sleep (on-demand plugins) |

plugin → tip (notifications)

| Method | Meaning |
|---|---|
| `set` `{items: [{id, icon, label, color, drawing, graph: {push: 0.42}, badge}]}` | partial update; only changed fields; tip diffs and coalesces |
| `popup` `{id, rows: [...]}` | popup content |
| `log` `{level, message}` | goes to unified log under `com.pseudobun.tip.plugin.<id>` |
| `run` `{command}` | ask tip to open a URL / app (tip executes, plugin stays unprivileged) |

Rules:
- Items are namespaced `plugin.<id>.<item>`; a plugin can only touch its own.
- Per-plugin budgets: max 30 `set`/s (excess coalesced), max 64 KB per message, request timeout 15 s. Violations logged, plugin restarted with backoff (1 s, 5 s, 30 s, then disabled + Settings warning).
- Plugins run as their own responsible process (no inherited TCC grants), env limited to `TIP_PLUGIN_ID`, `TIP_PLUGIN_DIR`, `TIP_VERSION`, `TIP_SOCKET`.
- stderr → tip log.
- SDKs: `TipPluginKit` (Swift) and `tip-plugin` (Rust), each with an example and `pack.sh`. A 20-line shell example in `examples/plugins/shell-counter` shows that no SDK is required.

---

## 7. Config

`~/.config/tip/config.json5` (`TIP_CONFIG` overrides). Every key optional; template written on first launch; hot reload through a debounced (200 ms) file + folder watcher; a broken file keeps the last good config and shows a red dot on the bar + diagnostics in `tip config check`.

```json5
{
  // Look ------------------------------------------------------------------
  theme: "og",                    // og | og-light | modern | solarpunk | cyberpunk | minimal | follow-paw | follow-hop
  bar: {
    height: 40,
    position: "top",
    margin: { left: 25, right: 34 },  // line up with paw's window edges
    material: "none",               // none | glass (Liquid Glass behind the whole bar)
    displays: "all",                // all | main | ["DELL U3223QE", ...]
  },
  island: { height: 28, radius: 9, gap: 6, padding: 5, material: "solid" }, // solid | glass
  animation: { durationMs: 220, easing: "easeOutCubic" },

  // Layout per display kind; ids refer to items below -------------------------
  layout: {
    default: {
      left:   [["apple"], ["workspaces"], ["front_app"], ["brew"]],
      center: [["media"]],                        // dropped automatically beside a notch
      right:  [["clock"], ["battery", "vpn", "net", "cpu"], ["markets"]],
    },
    "builtin": { center: [] },
  },

  // Items -------------------------------------------------------------------
  items: {
    clock:   { provider: "clock", format: "EEE d  HH:mm" },
    battery: { provider: "battery", label: "percent", warnBelow: 30, badBelow: 20 },
    net:     { provider: "network", label: "onClick" },     // icon = cable / wifi / iphone / offline
    vpn:     { provider: "vpn", hideWhenOff: true },
    cpu:     { provider: "cpu", graph: { width: 42 }, top: true, interval: 2 },
    media:   { provider: "media", maxChars: 48 },
    workspaces: { provider: "paw.workspaces", appsPerWorkspace: 6, ignore: ["Raycast", "Dropover"] },
    front_app:  { provider: "front_app", color: "paw" },    // paw | icon | none
    brew:    { provider: "brew", file: "~/.cache/brew-outdated.json" },
    markets: { provider: "plugin", plugin: "com.pseudobun.tip.markets" },
    uptime:  { command: "uptime | awk '{print $3}'", interval: 300 },   // script item
  },

  // Zen mode, hotkeys -------------------------------------------------------
  zen: { hotkey: "ctrl+opt+z", keep: ["workspaces", "clock"] },

  plugins: { "com.pseudobun.tip.markets": { symbols: ["BTCUSDT", "ETHUSDT"], apiKey: "${ETH_API_KEY}" } },
}
```

- Secrets: `${NAME}` from `~/.config/tip/.env` (gitignored; sops `.env.enc` committed in dotfiles), never written back expanded; plugin `secret` preferences stored in Keychain (hop's `Keychain.swift` pattern).
- `themes/*.json5` for user themes, same token names as hop.
- Settings window: AppKit, 880×620, sidebar categories **General · Appearance · Layout · Items · Plugins · Permissions · About**. Layout tab = drag islands/items between zones per display with a live preview strip. Edits go through a `ConfigEdit` equivalent (comment- and layout-preserving, symlink-safe), validated as you type (error → not saved, warning → saved + shown).

---

## 8. CLI and IPC

Single binary (`/opt/homebrew/bin/tip` via cask `binary` stanza; `tip-dev` for dev builds). Socket `~/Library/Application Support/com.pseudobun.tip/tip.sock`, 0700 dir / 0600 socket, peer uid check, ≤ 50 req/s.

| Command | Purpose |
|---|---|
| `tip status [--json]` | running, version, displays, providers on/off, plugin states, idle CPU sample |
| `tip query [item\|island\|bar] [--json]` | current state (replaces `sketchybar --query`) |
| `tip set <item> key=value …` | change an item at runtime (scripts, agents); not persisted |
| `tip trigger <event> [--data json]` | custom events for plugins / script items |
| `tip subscribe [events…] [--reconnect] [--exec cmd]` | JSON-lines stream, first line `snapshot` (paw format: `{"seq","ts","event","data"}`) |
| `tip zen [on\|off\|toggle]` | zen mode |
| `tip reload` | re-read config |
| `tip config path\|check\|show\|get\|set\|template\|format` | as hop |
| `tip plugins list\|install <url>\|link <dir>\|remove\|logs <id>` | plugin management |
| `tip theme list\|set` | themes |
| `tip doctor` | flags costly setups: script items with short intervals, plugins over budget, missing permissions |
| `tip bench` | records idle CPU / wakeups / RSS for 60 s (same idea as `just bench`) |
| `tip update [--check]`, `tip version` | Sparkle |

Exit codes: 0 ok, 1 error / not running, 3 dry run, 10 update available, 64 usage.

---

## 9. Design

- **Themes:** the shared set — OG (default), OG Light, Modern, Solarpunk, Cyberpunk, Minimal — with hop's token names: `background card muted foreground mutedForeground border ring primary good warn info destructive chart1…chart5` + `wash(alpha)`. OG for tip = today's bar palette (`island #1d1d16 / 0.92`, `border white 10 %`, `fg #fbfbf9`, `muted #abab9c`, `dim #5f5f52`, gold `#ead186`, wave `#8698eb`), which already matches olympus-dashboard and paw's gold accent.
- **Islands:** paw's CALayer island style (`UI/Style.swift`): fill, 1 px border, continuous corners, optional soft shadow; radius from theme (9 default, 2 cyberpunk, 12 modern). Optional `glass` material via `NSGlassEffectView` like hop's panels.
- **Type:** bundled Geist Mono (labels, numbers), Outfit (popup titles), theme fonts (DM Mono, Share Tech Mono) with OFL files, registered per process with `CTFontManagerRegisterFontsForURL`. hop's scale: label mono 11/500, meta 12, body 14. Numbers always tabular.
- **Icons:** SF Symbols by name (`"wifi"`, `"cable.connector"`, `"lock.shield.fill"`), Nerd Font glyphs allowed, app icons from bundle id (cached at drawn size). App icons for workspaces via `NSWorkspace.icon(forFile:)` instead of a 30 KB icon-font map.
- **Motion:** 180–220 ms, paw easings, label width expand/collapse on click (today's network label), graph scrolls without re-layout. Reduce Motion → instant.
- **App icon:** Icon Composer `.icon`, dark gradient like hop, glyph = a horizontal bar with three island pills. `docs/assets/{logo.svg, preview.png, social-preview.png}`.

---

## 10. Performance budgets (release build, measured with `just bench`)

| Metric | Budget | Today (SketchyBar) |
|---|---|---|
| Idle CPU (no media, clock only changing) | 0.0 %, ≤ 1 wakeup / 10 s outside the cpu item | 0.1 % + spawned processes |
| Footprint | ≤ 25 MB at rest, 3 displays | 79 MB + 12 MB lua + helpers |
| Processes spawned per hour at rest | 0 (excluding user script items) | hundreds |
| Item update → pixels | p99 ≤ 4 ms main-thread | — |
| Launch → bar drawn | ≤ 200 ms | ~1–2 s (Lua config + helper make) |
| Display change re-layout | ≤ 50 ms | — |

Rules (in `PERFORMANCE.md` from day one, with a "Known costs" section):
- No `Process` on the main thread, ever; no `Process` in any built-in provider.
- Redraw only dirty layers, one `CATransaction` per run-loop turn.
- Hidden items (zen, other display, `drawing: false`) stop their provider work.
- Event payloads encoded only when a subscriber exists.
- Text and symbol bitmaps cached by (content, font, colour, scale), LRU 512.
- Graphs: one `CGPath` rebuild per sample, ring buffer, no per-point layers.

---

## 11. Permissions

| Need | Permission | Requested |
|---|---|---|
| Bar drawing, clock, battery, network, vpn, cpu, front app, audio | none | — |
| Wi-Fi SSID | Location | only when SSID display enabled |
| Calendar item | Calendars | only when configured |
| Media | none (adapter helper) | — |
| Workspaces (paw) | none for tip; paw holds Accessibility | — |

A "Permissions" Settings tab like hop's onboarding; `tip status` reports each grant. Accessibility is **not** needed — a deliberate difference from paw.

---

## 12. Packaging, release, repo

Copy paw/hop verbatim, rename:

- Repo `pseudobun/tip`, MIT, README structure as paw/hop (logo, tagline, badges, Install → Permissions → Check it works, Updates, Uninstall, Building, Features, Config, Plugins, CLI, Development, Releasing, Contributing, License).
- `justfile`: `build test dev undev uninstall local-cert bench examples log release-zip release` — `dev` builds "tip Dev" (`com.pseudobun.tip.dev`) into `~/Applications`, links `tip-dev`, own socket and config dir (`~/.config/tip-dev` unless `TIP_CONFIG`).
- `VERSION` + release-please (simple, beta prerelease, feat/fix/perf/revert), `CHANGELOG.md`; beta channel like hop (`tip@beta` cask, appcast `beta` channel).
- GitHub Actions on `macos-26`: test, gitleaks, template ↔ `examples/config.json5` check, cask-template check; release: sign, notarize (`notarytool` + ASC API key), staple, Sparkle 2 EdDSA, appcast branch, tap update in `pseudobun/homebrew-tap`.
- `SECURITY.md` with the trust model: socket peer check, plugins are code, config is code (script items run shell).
- `TESTING.md` manual checklist (notch, display hot-plug, sleep/wake, VPN toggle, cable plug, theme switch, zen).
- Dotfiles: `~/.dotfiles/tip` → `~/.config/tip`, `.env.enc` via sops; bootstrap installs the cask and removes the SketchyBar service.

---

## 13. Migration from the current SketchyBar config

| Today (`~/.dotfiles/sketchybar`) | tip |
|---|---|
| `items/apple.lua` (popup: prefs, activity, lock) | `apple` built-in with popup rows |
| `items/spaces.lua` + `paw subscribe --exec sketchybar --trigger` bridge | `paw.workspaces` provider over paw's socket; no bridge process |
| `items/front_app.lua` + `paw color` per switch | `front_app` provider, colour from paw stream or icon |
| `items/brew.lua` + `plugins/brew_refresh.sh` launchd | keep launchd job, `brew` provider watches its output file |
| `items/media.lua` + `plugins/media_stream.sh` | `media` provider (bundled adapter helper) |
| `items/clock.lua` incl. zen click | `clock` + `zen` built-in |
| `items/system.lua` battery / net / vpn / cpu helper (C, mach) | `battery`, `network`, `vpn`, `cpu` providers; no helper binary |
| `items/markets.lua` (binance, etherscan, NYSE countdown) | `markets` process plugin (Rust or Swift) — first real plugin, dogfoods the SDK |
| `env.local.sh.enc` | `~/.config/tip/.env.enc` |
| `helpers/app_icons.lua` (icon font map) | dropped; real app icons |

Run both in parallel during M3 (tip on the external display only) before removing SketchyBar.

---

## 14. Milestones

| # | Scope | Done when |
|---|---|---|
| M0 | Repo skeleton from paw: Package.swift, justfile, CI, release pipeline dry run, Settings window shell, config load / template / check / watch, socket + `status` | `just dev` runs, `tip-dev status --json` answers |
| M1 | Bar panels per display, notch-aware layout solver (unit tested), islands, items, themes, fonts, `query` / `set` | static items render on all 3 displays identically to today's look |
| M2 | Native providers: clock, battery, network, vpn, cpu (+ graph), front_app, volume; popups; zen; animations | `just bench` meets section 10 budgets |
| M3 | paw provider (workspaces), media helper, brew provider; `subscribe`, `trigger` | daily-driver parity on sanctum; SketchyBar off |
| M4 | Process plugins: manifest, lifecycle, protocol, budgets, Settings Plugins tab, Swift + Rust SDKs, markets plugin | markets runs as a plugin; shell example works |
| M5 | Script items, `doctor`, Layout editor in Settings, theme follow-paw/hop, calendar/bluetooth/weather | first public beta via `tip@beta` cask |

---

## 15. Open questions

1. Workspaces without paw: show macOS Spaces read-only (private CGS API, may break) or simply hide the island?
2. Should tip also offer a `paw`-style left-click workspace switch for plain macOS Spaces (needs Accessibility or private API) — or keep tip permission-free?
3. Media adapter: bundle the perl/MediaRemote helper ourselves (maintenance on each macOS update) or depend on Homebrew `media-control`?
4. Theme default: own setting with `follow-paw` opt-in (planned), or follow paw automatically when present?
5. Plugin distribution: GitHub-release zips only (like hop), or also a curated list in the tip repo?
6. ~~Name~~ — decided: `tip`, installed only via `pseudobun/tap/tip` like paw and hop (a Homebrew cask `tip` by someone else exists; irrelevant with the tap). Bundle id `com.pseudobun.tip`.
