#!/usr/bin/env bash
# Builds the plugin and packs com.pseudobun.tip.markets.tipplugin.zip: plugin.json5 + bin/.
# `tip plugins install ./com.pseudobun.tip.markets.tipplugin.zip --yes`; tip.app bundles it too.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release -q
id=$(sed -n 's/^ *id: *"\([^"]*\)".*/\1/p' plugin.json5 | head -1)
stage=$(mktemp -d)
mkdir -p "$stage/$id/bin"
cp plugin.json5 "$stage/$id/"
cp "$(swift build -c release --show-bin-path)/markets" "$stage/$id/bin/markets"
rm -f "$id.tipplugin.zip"
(cd "$stage" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$id" "$OLDPWD/$id.tipplugin.zip")
rm -rf "$stage"
echo "packed $id.tipplugin.zip"
