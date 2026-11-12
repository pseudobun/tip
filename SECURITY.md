# Security

## Trust model

- **The socket.** `~/Library/Application Support/com.pseudobun.tip/tip.sock`, in a 0700 folder,
  created 0600. tip checks every peer's uid (`getpeereid`) and caps requests at 64 KB and
  subscribers at 64. Only your user can talk to tip.
- **The config is code.** Script items run shell commands, actions run `shell:` commands, and
  `${NAME}` pulls values from `~/.config/tip/.env`. Review config changes like code.
- **Plugins are code.** A plugin runs as you, with your files and network, like any program you
  download. tip spawns it as its own *responsible process* (it does not inherit tip's TCC grants),
  with a small environment (`PATH`, `HOME`, `TIP_PLUGIN_ID`, `TIP_PLUGIN_DIR`, `TIP_VERSION`,
  `TIP_SOCKET`). Its `run` requests are limited to opening URLs and apps. Installation asks first
  (`--yes` on the CLI, a dialog in Settings), refuses archives with symbolic links and checks the
  manifest. Declared permissions are shown, not enforced.
- **Secrets.** Plugin `secret` preferences live in the login Keychain
  (`com.pseudobun.tip.plugin.<id>`), never in the config. `.env` is read, never written back.
- **Updates.** Sparkle 2 with an EdDSA-signed appcast over HTTPS; release builds are signed with
  Developer ID and notarized.

## Reporting

Email urban@bunnys.cloud with details and steps to reproduce. Please don't open a public issue
for a vulnerability.
