#!/usr/bin/env bash
# Builds tip.app from the SwiftPM binary, bundles the markets plugin, and signs it.
# Usage: scripts/bundle.sh [out_dir]
# env: TIP_VERSION (default: from VERSION, plus the commit when not on its tag),
#      TIP_BUILD (CFBundleVersion, which Sparkle compares; default: commit count), TIP_BUNDLE_ID,
#      TIP_SIGN_IDENTITY, TIP_TIMESTAMP=1 (secure timestamp, for notarization),
#      TIP_DEV=1 (a dev build: "tip Dev", com.pseudobun.tip.dev, no updates; see just dev)
# Signing: TIP_SIGN_IDENTITY if set, else a "Developer ID Application" or "Apple Development"
# identity, else the self-signed "tip Local Signing" certificate (just local-cert), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-build.noindex}"
name=tip
bundle_id="${TIP_BUNDLE_ID:-com.pseudobun.tip}"
if [ "${TIP_DEV:-}" = 1 ]; then
  name="tip Dev"
  bundle_id="${TIP_BUNDLE_ID:-com.pseudobun.tip.dev}"
  TIP_SPARKLE_PUBLIC_KEY="" TIP_FEED_URL="-"
fi
base="$(tr -d '[:space:]' < VERSION)"
if [ -z "${TIP_VERSION:-}" ]; then
  commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ "$(git describe --tags --exact-match 2>/dev/null)" = "v$base" ] && git diff --quiet HEAD 2>/dev/null; then
    TIP_VERSION="$base"
  else
    TIP_VERSION="$base+$commit$(git diff --quiet HEAD 2>/dev/null || echo .dirty)"
  fi
fi
version="$TIP_VERSION"
short="${version%%+*}"
build="${TIP_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
[[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "bad version: $version" >&2; exit 1; }
[[ "$build" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "bad build number: $build" >&2; exit 1; }

arch_flags=""; for a in ${TIP_ARCHS:-arm64}; do arch_flags="$arch_flags --arch $a"; done
swift build -c release $arch_flags -q -Xlinker -dead_strip
bin_dir="$(swift build -c release $arch_flags -Xlinker -dead_strip --show-bin-path)"
sparkle="$(find "$bin_dir" "$bin_dir/PackageFrameworks" -maxdepth 1 -name Sparkle.framework 2>/dev/null | head -1)"
[ -n "$sparkle" ] || { echo "Sparkle.framework not found in $bin_dir" >&2; exit 1; }
# EdDSA key that signs updates (private half: the SPARKLE_PRIVATE_KEY secret and olympus' keychain, account "tip").
sparkle_key="${TIP_SPARKLE_PUBLIC_KEY-4WvZKUleRShEusDyhdMZI8l5WyDvxjU/1A+dvimWeac=}"
feed="${TIP_FEED_URL:-https://raw.githubusercontent.com/pseudobun/tip/appcast/appcast.xml}"
[ "$feed" = "-" ] && feed=""
xml() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }

app="$out/tip.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/tip" "$app/Contents/MacOS/tip"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
strip -x "$app/Contents/MacOS/tip"
cp Resources/AppIcon.icns Resources/symbol.svg "$app/Contents/Resources/"
cp -R Resources/Fonts "$app/Contents/Resources/"

# Bundled plugins: built from plugins/<name>, laid out as an installed plugin.
for dir in plugins/*/; do
  [ -f "$dir/plugin.json5" ] || continue
  id=$(sed -n 's/^ *id: *"\([^"]*\)".*/\1/p' "$dir/plugin.json5" | head -1)
  entry=$(sed -n 's/^ *entry: *"\([^"]*\)".*/\1/p' "$dir/plugin.json5" | head -1)
  (cd "$dir" && swift build -c release $arch_flags -q)
  pbin="$(cd "$dir" && swift build -c release $arch_flags --show-bin-path)"
  dest="$app/Contents/Resources/Plugins/$id"
  mkdir -p "$dest/$(dirname "$entry")"
  cp "$dir/plugin.json5" "$dest/"
  cp "$pbin/$(basename "$entry")" "$dest/$entry"
  strip -x "$dest/$entry"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$(xml "$bundle_id")</string>
  <key>CFBundleName</key><string>$(xml "$name")</string>
  <key>CFBundleDisplayName</key><string>$(xml "$name")</string>
  <key>CFBundleExecutable</key><string>tip</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml "$short")</string>
  <key>CFBundleVersion</key><string>$(xml "$build")</string>
  <key>TipVersion</key><string>$(xml "$version")</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>tip shows the Wi-Fi network's name in the network popup.</string>
  <key>SUFeedURL</key><string>$(xml "$feed")</string>
  <key>SUPublicEDKey</key><string>$(xml "$sparkle_key")</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSHumanReadableCopyright</key><string>© Urban Vidovič</string>
</dict>
</plist>
PLIST

ts="--timestamp=none"; [ "${TIP_TIMESTAMP:-}" = 1 ] && ts="--timestamp"
identity="${TIP_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  identity="$( { echo "$ids" | grep '"Developer ID Application'; echo "$ids" | grep '"Apple Development'; } | awk 'NR == 1 {print $2}' || true)"
fi
if [ -z "$identity" ] && security find-identity -p codesigning 2>/dev/null | grep -q "tip Local Signing"; then
  identity="tip Local Signing"
fi
# Inside out: plugins, Sparkle's helpers, the framework, then the app. Hardened runtime only with a
# Developer ID (its library validation refuses a framework signed without a Team ID).
sign() {
  local id="$1" fw="$app/Contents/Frameworks/Sparkle.framework" rt=""
  case "$id" in "Developer ID"*) rt="--options runtime" ;; esac
  for exe in "$app"/Contents/Resources/Plugins/*/bin/*; do
    [ -f "$exe" ] && { codesign --force $rt $2 -s "$id" "$exe" || return 1; }
  done
  codesign --force $rt $2 -s "$id" "$fw/Versions/B/Autoupdate" &&
    codesign --force $rt $2 -s "$id" "$fw/Versions/B/Updater.app" &&
    codesign --force $rt $2 -s "$id" "$fw" &&
    codesign --force $rt $2 -s "$id" "$app"
}
if [ -n "$identity" ] && err="$(sign "$identity" "$ts" 2>&1)"; then
  echo "signed: $identity"
else
  [ -n "$identity" ] && echo "signing with $identity failed ($(echo "$err" | grep -v 'replacing existing' | tail -1)); ad-hoc instead" >&2
  [ -n "${TIP_SIGN_IDENTITY:-}" ] && [ "${TIP_TIMESTAMP:-}" = 1 ] && { echo "release signing failed" >&2; exit 1; }
  sign - "" >/dev/null
  echo "signed: ad-hoc"
fi
codesign --verify --deep --strict "$app"
echo "built: $app ($version)"
