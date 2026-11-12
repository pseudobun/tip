# tip plugins

tip's built-in items cover the system (clock, battery, network, CPU, media, paw's workspaces…).
Anything else is a **plugin**: a long-lived program, in any language, that tip starts and talks
to over stdin/stdout. tip draws everything; a plugin only says what its items show.

| | Built-in item | Plugin | Script item |
|---|---|---|---|
| Where | `Sources/tip/Providers` | a folder in Plugins/ | a line in config |
| Language | Swift, compiled in | anything (Swift and Rust SDKs) | shell |
| Runs | inside tip | its own process, idle when quiet | a fork per run |
| Cost | none | one process | one fork per `interval` (`tip doctor` warns) |

## The package

A release asset named `*.tipplugin.zip` (an `arm64` or `universal` one first when there are
several) holding a folder, or the archive root, with:

```
plugin.json5
bin/your-program
```

Symbolic links are refused. Installed plugins live in
`~/Library/Application Support/com.pseudobun.tip/Plugins/<id>`; bundled ones in
`tip.app/Contents/Resources/Plugins`. An installed plugin with a bundled one's id wins.

```sh
tip plugins install you/tip-weather --yes        # latest release
tip plugins install you/tip-weather@v1.2.0 --yes
tip plugins install ./dev.you.weather.tipplugin.zip --yes
tip plugins link ~/src/tip-weather               # a folder being developed (symlinked)
tip plugins remove dev.you.weather --yes
```

A running tip picks up installs, removals and rebuilt programs at once (it restarts a plugin whose
program changed).

## plugin.json5

```json5
{
  id: "dev.you.weather",        // reverse DNS, lower case, unique
  name: "Weather",
  version: "0.1.0",
  summary: "Temperature and a forecast popup.",
  author: "you",
  tip: "0.1.0",                 // lowest tip version
  entry: "bin/weather",         // the program, inside the folder
  items: [{ id: "temp" }, { id: "wind" }],          // in the order an item config shows them
  preferences: [
    // text | secret | toggle | number | choice | list; shown on Settings → Plugins
    { id: "city", title: "City", type: "text", default: "Maribor" },
    { id: "apiKey", title: "API key", type: "secret" },       // the login Keychain, never the config
    { id: "units", title: "Units", type: "choice", options: ["metric", "imperial"], default: "metric" },
  ],
  events: ["system_woke", "network_change"],                // tip events it wants
  permissions: ["network: api.weather.example"],            // shown, not enforced
  lifecycle: "persistent",      // or "on-demand": runs only while one of its items is shown
}
```

## Showing it

An item with `plugin` shows that plugin's items (all, or `items: [...]`) as nodes in one island:

```json5
items: { weather: { plugin: "dev.you.weather" } },
layout: { default: { right: [["weather"], ["clock"]] } },
plugins: { "dev.you.weather": { city: "Ljubljana", apiKey: "${WEATHER_KEY}" } },
```

The nodes are `weather.temp` and `weather.wind` (`tip query weather`, `tip click weather.temp`).

## The protocol

[JSON-RPC 2.0](https://www.jsonrpc.org/specification), one message per line. tip starts `entry`
with the plugin folder as working directory and a small environment: `PATH`, `HOME`, `USER`,
`LANG`, `TMPDIR`, `TIP_PLUGIN_ID`, `TIP_PLUGIN_DIR`, `TIP_VERSION`, `TIP_SOCKET`. stderr goes to
tip's log (`tip plugins logs <id>`, `just log`).

| tip → plugin | Params | Reply |
|---|---|---|
| `initialize` (request) | `protocolVersion`, `tipVersion`, `pluginID`, `preferences`, `theme {id, light}`, `displays` | `{items: [Item]}`: their first state |
| `event` | `name`, `data` | — |
| `action` | `item`, `trigger` (`click` `rightClick` `scrollUp` `scrollDown` `popup`), `tag`, `row`, `modifiers` | — |
| `popupOpen` | `item` (a popup opened without rows) | — |
| `preferencesChanged` | `preferences` | — |
| `shutdown` | — | exit |

| plugin → tip (notifications) | Params |
|---|---|
| `set` | `items: [Item]`: only the fields that changed |
| `popup` | `id` (item), `rows: [PopupRow]` |
| `log` | `message` |
| `run` | `action`: `open:<url>`, `app:<name>`, `media:…` (tip opens it; other actions are refused) |

An **Item** is `{id, icon?, iconColor?, label?, labelColor?, detail?, detailColor?, size?, bold?,
drawing?, graph?, click?, rightClick?, tooltip?, popup?}`:

- `icon`: `"sf:<SF Symbol>"`, `"app:<bundle id or app name>"`, `"file:<path>"` or text (`"Ξ"`).
- colours: a theme token (`fg`, `muted`, `dim`, `accent`, `good`, `warn`, `bad`, `info`,
  `chart1`…`chart5`) that follows theme switches, or `"#rrggbb"`.
- `detail`: a small second label after the label (the 24 h change next to a price).
- `size`: `small`, `normal` or `large`.
- `graph`: `{push: 0.42}` adds a sample (0…1), `{values: [...]}` replaces them; `width`, `color`.
- `click` / `rightClick`: a tip action run without asking the plugin (`"open:https://…"`); without
  one, the click arrives as `action`.
- `popup`: rows for the item's popup; a click then opens it.

A **PopupRow** is `{label, icon?, detail?, color?, action?, id?, separator?}`. A row with `action`
runs it; a row with only `id` comes back as `action` with `trigger: "popup"` and `row: <id>`.

### Limits

30 `set`s per second (the rest are dropped and counted in `tip status --json`), 64 KB per message,
15 s for `initialize`. A plugin that exits is restarted after 1, 5 and 30 seconds, then marked
failed until `tip plugins restart <id>` or a config change.

## SDKs

- **Swift**: `sdk/swift` (`TipPluginKit`). Implement `TipPlugin`, call `serve(plugin)`; callbacks
  run on the main queue, so `Timer`s and `URLSession` completions need no locking. Example: the
  bundled [markets plugin](../plugins/markets/Sources/Markets/main.swift).
- **Rust**: `sdk/rust/tip-plugin` (`serde` only, no async runtime). Implement `Plugin`; `tick` runs
  every `interval()`. Example: [`examples/plugins/hello-rust`](../examples/plugins/hello-rust/src/main.rs).
- **Anything else**: read lines, write lines.
  [`examples/plugins/shell-counter`](../examples/plugins/shell-counter/bin/counter) is POSIX shell.

Each example has a `pack.sh` that builds the program and writes `<id>.tipplugin.zip`.

## Trust

A plugin runs as you, with your files and network. tip spawns it as its own responsible process,
so it does **not** inherit tip's permissions; macOS asks for each in the plugin's name. Install
only plugins you trust; installing asks first.
