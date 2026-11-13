# Performance

tip sits on screen all day. It must cost nothing while nothing changes.

## Budgets (release build, `just bench`)

| Metric | Budget | Measured (olympus, one display, defaults) |
|---|---|---|
| Idle CPU, clock only changing | 0.0 %, ≤ 1 wakeup / 10 s outside the cpu item | — |
| Idle CPU, every default item | — | 0.17 % (the 2 s cpu sampler) |
| Footprint | ≤ 25 MB at rest | 22–25 MB |
| Processes spawned per hour at rest | 0 (excluding script items) | 0 (+1 brew-refresh kick per hour) |
| Launch → bar drawn | ≤ 200 ms | 290–306 ms from `open -a tip` to the socket answering |

## Rules

- **No `Process` on the main thread, ever.** Actions and script items run through `Shell` on a
  background queue; no built-in provider forks to read data.
- **Redraw only what changed, once per run-loop turn.** Providers call `set`; equal content is
  dropped; BarManager marks the bars dirty and redraws on the next turn, however many items changed.
- **One bitmap per item, cached.** The renderer draws an item's parts into one image, cached by
  (content, theme, scale), LRU within 2 MB of bitmaps (the cpu graph makes a new one every tick).
  App icons and SF Symbols are rasterized once at device size, so drawing them is a blit.
- **Hidden items stop their providers.** Zen mode, items not in the layout and items filtered off
  every display stop their timers and listeners; on-demand plugins stop too.
- **Event payloads only for subscribers.** `itemChanged` is encoded only when someone runs
  `tip subscribe`; encoding happens off the main thread.
- **Graphs are a ring buffer and one path.** No per-point layers.
- **Animations belong to the render server.** Island and slide layers use implicit CALayer
  actions; glass views and the popup card move by `transform`/`opacity` layer animations while the
  view jumps to its end frame. Never animate an `NSView` frame (`animator()` or
  `allowsImplicitAnimation`): AppKit steps those on the main thread every display frame, with a
  layout pass each time (measured: 1 % CPU, 100 wakeups / 10 s while one ran).
- **Plugins are budgeted.** 30 `set`/s (the rest coalesced), 64 KB per message, 15 s per request,
  restarts after 1, 5, 30 s, then off.

## Release build at rest

Measured on 2026-11-12 on olympus: Mac mini, Apple M4 Pro, 24 GB, macOS 27.2, one display
(3320 × 2040, Screen Sharing). The installed release builds from the beta casks ran together:
paw 0.1.0-beta.21, hop 0.1.0-beta.13 and tip 0.1.0-beta.1.

Idle counters come from `proc_pid_rusage` (CPU time, `ri_pkg_idle_wkups` + `ri_interrupt_wkups`,
`ri_phys_footprint`) over 120 s with nobody at the keyboard. CLI round trips are the median and
p90 of 50 runs after 10 warm-up runs, process start included; starting `/usr/bin/true` costs
1.4 ms on this machine.

All default items were on: workspaces, front app, brew, clock, CPU, network, markets (battery,
VPN and media hide themselves on a Mac mini with no VPN up and nothing playing).

| | |
|---|---|
| Idle CPU | 0.17 % (`tip bench 60`: 0.16 %) |
| Wakeups | 5.4 per 10 s (`tip bench 60`: 6.2) |
| Footprint | 22.3 MB (peak 23.1 MB; 25 MB after an hour) |
| Threads | 7 |
| markets plugin | 0.00 % CPU, 0.3 wakeups per 10 s, 5.0 MB |
| Zen mode (every provider stopped) | 0.007 % CPU, 2.2 wakeups per 10 s, 21.7 MB |
| App bundle / binary | 5.3 MB / 1.5 MB |
| `open -a tip` → socket answers | 290–306 ms (3 launches) |
| `tip status` | 8.6 ms p50, 9.4 ms p90 |
| `tip query clock` | 9.0 ms p50, 9.6 ms p90 |
| `tip query` (every item) | 9.4 ms p50, 10.3 ms p90 |

Nearly all the idle CPU is the CPU item's 2 s sampler; zen mode shows what is left.

## Liquid Glass (`glass: true`)

Measured on 2026-11-13 on olympus (same machine, display locked, default config of a fresh
`~/.config/tip-dev`), dev builds of beta before and after glass, each launched fresh and sampled
with `tip bench 60` after 10 s:

| | before (solid) | `glass: false` | `glass: true` |
|---|---|---|---|
| Idle CPU | 0.13–0.16 % | 0.13–0.17 % | 0.13–0.19 % |
| Wakeups | 5.2–6.2 per 10 s | 5.2–5.5 per 10 s | 5.5–5.8 per 10 s |
| Footprint | 20.1–20.2 MB | 21.0–21.5 MB | 23.4 MB |

Glass costs nothing at rest in tip: the glass is composited by the window server, and an idle
render (clock, cpu) leaves the glass views untouched. Its price is ~3 MB of footprint for the glass
views' layers, inside the 25 MB budget. Twelve island resizes in 3 s sampled with `sample` show no
main-thread animation stepping (`NSAnimationManager`: 0 frames).

## Known costs

- The cpu item lists every process (`proc_listallpids` + `proc_pid_rusage`) every 2 s for the
  busiest one: ~1–2 ms on a background queue. `top: false` skips it; a longer `interval` halves it.
- `media` keeps one `media-control stream` process (MediaRemote only answers entitled clients).
- `brew` kicks the `sh.pseudobun.brew-refresh` launchd job once an hour (`interval: 0` turns it off).
- Script items fork `/bin/sh` per run: `tip doctor` flags intervals under 30 s.
- Opening Settings loads AppKit's controls (~100+ MB while open, released when closed).
