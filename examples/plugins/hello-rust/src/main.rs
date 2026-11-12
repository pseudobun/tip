use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tip_plugin::{serve, Action, Item, Plugin, PopupRow, Prefs, Tip};

/// Seconds since boot, from `sysctl kern.boottime` (no fork: libc via std is enough here).
fn uptime() -> u64 {
    let out = std::process::Command::new("/usr/sbin/sysctl").args(["-n", "kern.boottime"]).output();
    let text = out.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    let sec = text.split("sec = ").nth(1).and_then(|s| s.split(',').next()).and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0);
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    now.saturating_sub(sec)
}

fn label(s: u64) -> String {
    let (d, h, m) = (s / 86400, (s % 86400) / 3600, (s % 3600) / 60);
    if d > 0 { format!("{d}d {h}h") } else { format!("{h}h {m:02}m") }
}

struct Uptime;

impl Plugin for Uptime {
    fn initialize(&mut self, _tip: &Tip, _prefs: &Prefs) -> Vec<Item> {
        vec![Item::new("uptime").icon("sf:clock.arrow.circlepath").icon_color("muted").label(label(uptime())).tooltip("Uptime")]
    }
    fn tick(&mut self, tip: &Tip) { tip.set(vec![Item::new("uptime").label(label(uptime()))]); }
    fn interval(&self) -> Option<Duration> { Some(Duration::from_secs(60)) }
    fn event(&mut self, tip: &Tip, _name: &str, _data: &serde_json::Value) { self.tick(tip) }
    fn action(&mut self, tip: &Tip, _a: &Action) {
        tip.popup("uptime", vec![PopupRow { label: format!("up {}", label(uptime())), icon: Some("sf:clock".into()), ..Default::default() }]);
    }
}

fn main() { serve(Uptime) }
