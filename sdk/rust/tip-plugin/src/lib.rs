//! Write tip menu bar plugins in Rust.
//!
//! A plugin is a long-lived program tip starts: it reads JSON-RPC 2.0 messages from stdin, one
//! per line, and changes its items by writing `set` notifications to stdout. tip draws
//! everything. No async runtime: `serve` runs one loop that also calls `tick` on a timer.
//!
//! ```no_run
//! use tip_plugin::{serve, Item, Plugin, Prefs, Tip};
//! use std::time::Duration;
//!
//! struct Hello(u32);
//! impl Plugin for Hello {
//!     fn initialize(&mut self, _tip: &Tip, _prefs: &Prefs) -> Vec<Item> {
//!         vec![Item::new("count").icon("sf:number").label("0")]
//!     }
//!     fn tick(&mut self, tip: &Tip) {
//!         self.0 += 1;
//!         tip.set(vec![Item::new("count").label(self.0.to_string())]);
//!     }
//!     fn interval(&self) -> Option<Duration> { Some(Duration::from_secs(10)) }
//! }
//! fn main() { serve(Hello(0)) }
//! ```

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::io::{BufRead, Write};
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant};

pub const PROTOCOL_VERSION: u32 = 1;

/// Preferences: defaults from plugin.json5, then the config, then Keychain secrets.
pub type Prefs = Map<String, Value>;

/// What one item shows; only the fields you set are sent.
/// Icons: "sf:<SF Symbol>", "app:<bundle id>", "file:<path>" or text. Colours: a theme token
/// (fg, muted, dim, accent, good, warn, bad, info, chart1…chart5) or "#rrggbb".
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bold: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drawing: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub graph: Option<Graph>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub click: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tooltip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub popup: Option<Vec<PopupRow>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Graph {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub push: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub values: Option<Vec<f64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PopupRow {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// A tip action, or None to send `action` with this row's `id` to the plugin.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

impl Item {
    pub fn new(id: impl Into<String>) -> Self { Item { id: id.into(), ..Default::default() } }
    pub fn icon(mut self, s: impl Into<String>) -> Self { self.icon = Some(s.into()); self }
    pub fn icon_color(mut self, s: impl Into<String>) -> Self { self.icon_color = Some(s.into()); self }
    pub fn label(mut self, s: impl Into<String>) -> Self { self.label = Some(s.into()); self }
    pub fn label_color(mut self, s: impl Into<String>) -> Self { self.label_color = Some(s.into()); self }
    pub fn detail(mut self, s: impl Into<String>) -> Self { self.detail = Some(s.into()); self }
    pub fn size(mut self, s: impl Into<String>) -> Self { self.size = Some(s.into()); self }
    pub fn bold(mut self, on: bool) -> Self { self.bold = Some(on); self }
    pub fn drawing(mut self, on: bool) -> Self { self.drawing = Some(on); self }
    pub fn push(mut self, v: f64) -> Self { self.graph = Some(Graph { push: Some(v), ..Default::default() }); self }
    pub fn click(mut self, action: impl Into<String>) -> Self { self.click = Some(action.into()); self }
    pub fn tooltip(mut self, s: impl Into<String>) -> Self { self.tooltip = Some(s.into()); self }
}

/// A click, scroll or popup row on one of your items.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Action {
    pub item: String,
    /// "click", "rightClick", "scrollUp", "scrollDown" or "popup".
    pub trigger: String,
    pub tag: Option<String>,
    pub row: Option<String>,
    #[serde(default)]
    pub modifiers: Vec<String>,
}

/// Talks to tip: every call writes one line to stdout.
pub struct Tip {
    out: Mutex<Box<dyn Write + Send>>,
}

impl Tip {
    pub fn new(out: Box<dyn Write + Send>) -> Self { Tip { out: Mutex::new(out) } }

    fn write(&self, v: Value) {
        let mut line = serde_json::to_vec(&v).unwrap_or_default();
        line.push(b'\n');
        if let Ok(mut out) = self.out.lock() {
            let _ = out.write_all(&line);
            let _ = out.flush();
        }
    }

    fn notify(&self, method: &str, params: Value) {
        self.write(json!({"jsonrpc": "2.0", "method": method, "params": params}));
    }

    /// Changes items (only the fields each sets).
    pub fn set(&self, items: Vec<Item>) { self.notify("set", json!({ "items": items })); }
    pub fn popup(&self, item: &str, rows: Vec<PopupRow>) { self.notify("popup", json!({"id": item, "rows": rows})); }
    pub fn log(&self, message: &str) { self.notify("log", json!({ "message": message })); }
    /// Ask tip to open a URL or app.
    pub fn open(&self, url: &str) { self.notify("run", json!({ "action": format!("open:{url}") })); }
}

/// Implement what you use; every method has a default.
pub trait Plugin {
    fn initialize(&mut self, tip: &Tip, prefs: &Prefs) -> Vec<Item>;
    fn event(&mut self, _tip: &Tip, _name: &str, _data: &Value) {}
    fn action(&mut self, _tip: &Tip, _action: &Action) {}
    fn preferences_changed(&mut self, _tip: &Tip, _prefs: &Prefs) {}
    fn popup_open(&mut self, _tip: &Tip, _item: &str) {}
    /// Called every `interval()`.
    fn tick(&mut self, _tip: &Tip) {}
    fn interval(&self) -> Option<Duration> { None }
    fn shutdown(&mut self, _tip: &Tip) {}
}

#[derive(Deserialize)]
struct Incoming {
    id: Option<i64>,
    method: Option<String>,
    #[serde(default)]
    params: Value,
}

/// Handles one message; false when the plugin should exit.
pub fn handle<P: Plugin>(plugin: &mut P, tip: &Tip, line: &str) -> bool {
    let Ok(msg) = serde_json::from_str::<Incoming>(line) else { return true };
    let prefs = |v: &Value| v.get("preferences").and_then(|p| p.as_object()).cloned().unwrap_or_default();
    match msg.method.as_deref() {
        Some("initialize") => {
            let items = plugin.initialize(tip, &prefs(&msg.params));
            if let Some(id) = msg.id {
                tip.write(json!({"jsonrpc": "2.0", "id": id, "result": {"items": items}}));
            }
        }
        Some("event") => {
            let name = msg.params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            plugin.event(tip, name, msg.params.get("data").unwrap_or(&Value::Null));
        }
        Some("action") => {
            if let Ok(a) = serde_json::from_value::<Action>(msg.params) { plugin.action(tip, &a); }
        }
        Some("preferencesChanged") => plugin.preferences_changed(tip, &prefs(&msg.params)),
        Some("popupOpen") => plugin.popup_open(tip, msg.params.get("item").and_then(|v| v.as_str()).unwrap_or("")),
        Some("shutdown") => {
            plugin.shutdown(tip);
            return false;
        }
        _ => {
            if let Some(id) = msg.id { tip.write(json!({"jsonrpc": "2.0", "id": id, "result": null})); }
        }
    }
    true
}

/// Runs the plugin until tip closes stdin or says `shutdown`.
pub fn serve<P: Plugin>(mut plugin: P) {
    let tip = Tip::new(Box::new(std::io::stdout()));
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line { Ok(l) => { if tx.send(l).is_err() { break } } Err(_) => break }
        }
    });
    let mut next = plugin.interval().map(|d| Instant::now() + d);
    loop {
        let wait = next.map(|n| n.saturating_duration_since(Instant::now())).unwrap_or(Duration::from_secs(3600));
        match rx.recv_timeout(wait) {
            Ok(line) => { if !handle(&mut plugin, &tip, &line) { return } }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => { plugin.shutdown(&tip); return }
        }
        if let Some(n) = next {
            if Instant::now() >= n {
                plugin.tick(&tip);
                next = plugin.interval().map(|d| Instant::now() + d);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[derive(Clone, Default)]
    struct Buf(Arc<Mutex<Vec<u8>>>);
    impl Write for Buf {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> { self.0.lock().unwrap().extend_from_slice(b); Ok(b.len()) }
        fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
    }

    struct P;
    impl Plugin for P {
        fn initialize(&mut self, _: &Tip, prefs: &Prefs) -> Vec<Item> {
            vec![Item::new("a").label(prefs.get("x").and_then(|v| v.as_str()).unwrap_or("?"))]
        }
    }

    #[test]
    fn initialize_replies_with_items() {
        let buf = Buf::default();
        let tip = Tip::new(Box::new(buf.clone()));
        assert!(handle(&mut P, &tip, r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"preferences":{"x":"hi"}}}"#));
        let out = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
        assert!(out.contains(r#""id":1"#));
        assert!(out.contains(r#""label":"hi""#));
        assert!(!handle(&mut P, &tip, r#"{"jsonrpc":"2.0","method":"shutdown"}"#));
    }

    #[test]
    fn item_skips_unset_fields() {
        let v = serde_json::to_string(&Item::new("x").icon("sf:star").push(0.5)).unwrap();
        assert_eq!(v, r#"{"id":"x","icon":"sf:star","graph":{"push":0.5}}"#);
    }
}
