#!/usr/bin/env bash
# Builds the plugin and packs <id>.tipplugin.zip: plugin.json5 + bin/. Attach the zip to a
# GitHub release and install it with: tip plugins install <owner>/<repo>
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release
id=$(sed -n 's/^ *id: *"\([^"]*\)".*/\1/p' plugin.json5 | head -1)
stage=$(mktemp -d)
mkdir -p "$stage/$id/bin"
cp plugin.json5 "$stage/$id/"
cp target/release/tip-uptime "$stage/$id/bin/tip-uptime"
rm -f "$id.tipplugin.zip"
(cd "$stage" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$id" "$OLDPWD/$id.tipplugin.zip")
rm -rf "$stage"
echo "packed $id.tipplugin.zip"
