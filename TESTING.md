# Manual testing

`just test` covers TipCore (config, themes, layout solver, protocol, formatting) and both SDKs.
These need a person and real hardware; run them before a release.

- [ ] **Notch**: on the built-in display, nothing draws under the notch; left islands that would
      reach it hide (the order stays), the center zone is empty.
- [ ] **Display hot-plug**: plug and unplug an external display; a bar appears and goes within a
      second, workspaces move to the right bar, `tip status` lists the displays.
- [ ] **Sleep / wake**: after waking, the clock is right at once, markets refresh within ~10 s,
      battery and network are current.
- [ ] **Cable plug**: plug Ethernet in and out, then an iPhone over USB: the network icon changes
      at once (cable, iPhone, Wi-Fi), the IP follows.
- [ ] **VPN**: bring WireGuard/Tailscale up and down: the lock appears and goes.
- [ ] **paw**: switch workspaces, move windows, zoom; quit paw and start it again: the islands
      empty and come back without restarting tip.
- [ ] **Media**: play, pause, skip in Music/Spotify/Brave; click controls; quit the player.
- [ ] **Theme switch**: hover each tile in Settings → Appearance (the bar previews), click one,
      `tip theme follow-paw` and change paw's theme.
- [ ] **Theme builder**: Customize… a theme, drag colour wells and sliders, the bar follows;
      delete it.
- [ ] **Zen**: click the clock, `tip zen`, the hotkey.
- [ ] **Broken config**: save a syntax error: a red dot, `tip config check` names line and column,
      the bar keeps working; fix it: the dot goes.
- [ ] **Plugins**: install the shell example, click it, right click it, `tip plugins disable`,
      kill its process (restarts with backoff).
- [ ] **Popups**: every item's popup opens under it, closes on a click elsewhere and on leaving it.
- [ ] **Budget**: `just bench` matches PERFORMANCE.md.
