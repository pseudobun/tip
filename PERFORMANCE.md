# Performance

tip sits on screen all day. It must cost nothing while nothing changes.

## Budgets (release build, `just bench`)

| Metric | Budget | Measured (olympus, one display, defaults) |
|---|---|---|
| Idle CPU, clock only changing | 0.0 %, ≤ 1 wakeup / 10 s outside the cpu item | — |
| Idle CPU, every default item | — | ~0.3 % (the 2 s cpu sampler) |
| Footprint | ≤ 25 MB at rest | 16 MB |
| Processes spawned per hour at rest | 0 (excluding script items) | 0 (+1 brew-refresh kick per hour) |
| Launch → bar drawn | ≤ 200 ms | logged at start (`just log`) |

## Rules

- **No `Process` on the main thread, ever.** Actions and script items run through `Shell` on a
  background queue; no built-in provider forks to read data.
- **Redraw only what changed, once per run-loop turn.** Providers call `set`; equal content is
  dropped; BarManager marks the bars dirty and redraws on the next turn, however many items changed.
- **One bitmap per item, cached.** The renderer draws an item's parts into one image, cached by
  (content, theme, scale), LRU 512. An unchanged item costs a dictionary lookup.
- **Hidden items stop their providers.** Zen mode, items not in the layout and items filtered off
  every display stop their timers and listeners; on-demand plugins stop too.
- **Event payloads only for subscribers.** `itemChanged` is encoded only when someone runs
  `tip subscribe`; encoding happens off the main thread.
- **Graphs are a ring buffer and one path.** No per-point layers.
- **Plugins are budgeted.** 30 `set`/s (the rest coalesced), 64 KB per message, 15 s per request,
  restarts after 1, 5, 30 s, then off.

## Known costs

- The cpu item lists every process (`proc_listallpids` + `proc_pid_rusage`) every 2 s for the
  busiest one: ~1–2 ms on a background queue. `top: false` skips it; a longer `interval` halves it.
- `media` keeps one `media-control stream` process (MediaRemote only answers entitled clients).
- `brew` kicks the `sh.pseudobun.brew-refresh` launchd job once an hour (`interval: 0` turns it off).
- Script items fork `/bin/sh` per run: `tip doctor` flags intervals under 30 s.
- Opening Settings loads AppKit's controls (~100+ MB while open, released when closed).
