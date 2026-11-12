#!/usr/bin/env bash
# Packs dev.tip.shell-counter.tipplugin.zip (nothing to build).
set -euo pipefail
cd "$(dirname "$0")"
stage=$(mktemp -d)
mkdir -p "$stage/dev.tip.shell-counter"
cp -R plugin.json5 bin "$stage/dev.tip.shell-counter/"
rm -f dev.tip.shell-counter.tipplugin.zip
(cd "$stage" && ditto -c -k --norsrc --noextattr --noacl --keepParent dev.tip.shell-counter "$OLDPWD/dev.tip.shell-counter.tipplugin.zip")
rm -rf "$stage"
echo "packed dev.tip.shell-counter.tipplugin.zip"
