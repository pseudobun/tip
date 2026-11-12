# tip: build, test and run a dev build next to the release one. Signing is picked by
# scripts/bundle.sh (Developer ID / Apple Development identity → "tip Local Signing" → ad-hoc).
#
# The release tip comes from Homebrew (brew install --cask pseudobun/tap/tip): /Applications/tip.app,
# com.pseudobun.tip, CLI `tip`. `just dev` builds "tip Dev" (com.pseudobun.tip.dev, own socket, config
# in ~/.config/tip-dev unless TIP_CONFIG, no updates) into ~/Applications, quits the release tip and
# starts the dev one; `just undev` goes back. `tip` finds whichever runs; `tip-dev` is the dev CLI.

dev_app := env("HOME") / "Applications/tip Dev.app"
dev_cli := "/opt/homebrew/bin/tip-dev"
release_id := "com.pseudobun.tip"
local_identity := "tip Local Signing"
launch_agent := env("HOME") / "Library/LaunchAgents/com.pseudobun.tip.plist"

default: build

# Debug build (.build/debug/tip)
build:
    swift build

# Unit tests: TipCore, the Swift plugin SDK, the Rust plugin SDK
test:
    swift test
    swift test --package-path sdk/swift
    cd sdk/rust/tip-plugin && cargo test -q

# Release-configuration tip.app into ./build.noindex (.noindex keeps Spotlight from listing a second tip)
bundle:
    scripts/bundle.sh build.noindex

# Build "tip Dev", quit the release tip and run the dev one instead
dev:
    TIP_DEV=1 scripts/bundle.sh build.noindex/dev
    @just _quit
    rm -rf "{{dev_app}}"
    mkdir -p "$(dirname "{{dev_app}}")"
    cp -R "build.noindex/dev/tip Dev.app" "{{dev_app}}"
    ln -sf "{{dev_app}}/Contents/MacOS/tip" "{{dev_cli}}"
    open "{{dev_app}}"
    @echo "running {{dev_app}} (CLI: tip-dev); just undev goes back to the release tip"

# Quit the dev build and start the release tip again
undev:
    @just _quit
    open -b {{release_id}}

# Build the release configuration and run it as /Applications/tip.app (before the cask exists)
install:
    scripts/bundle.sh build.noindex
    @just _quit
    rm -rf /Applications/tip.app
    cp -R build.noindex/tip.app /Applications/tip.app
    ln -sf /Applications/tip.app/Contents/MacOS/tip /opt/homebrew/bin/tip
    open /Applications/tip.app

# Remove the dev build
uninstall:
    @just _quit
    rm -rf "{{dev_app}}" "{{dev_cli}}"
    -open -b {{release_id}}

_quit:
    -tip quit 2>/dev/null; tip-dev quit 2>/dev/null; true
    @for i in $(seq 1 30); do pgrep -f 'MacOS/tip$' >/dev/null || break; sleep 0.1; done
    -pkill -f 'MacOS/tip$'

# Self-signed code-signing certificate (stable signature across rebuilds)
local-cert:
    #!/usr/bin/env bash
    set -euo pipefail
    if security find-identity -p codesigning | grep -q "{{local_identity}}"; then echo "already in keychain"; exit 0; fi
    d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
    printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ext\n[dn]\nCN={{local_identity}}\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > "$d/c.cnf"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/k.pem" -out "$d/c.pem" -days 3650 -config "$d/c.cnf" 2>/dev/null
    legacy=$(openssl version | grep -q LibreSSL || echo -legacy)
    openssl pkcs12 -export $legacy -inkey "$d/k.pem" -in "$d/c.pem" -out "$d/c.p12" -passout pass:tip
    security import "$d/c.p12" -k ~/Library/Keychains/login.keychain-db -P tip -T /usr/bin/codesign
    echo "created {{local_identity}}"

# Start the release tip at login with launchd (KeepAlive) instead of the openAtLogin login item
launchd:
    mkdir -p "$(dirname "{{launch_agent}}")"
    cp examples/com.pseudobun.tip.plist "{{launch_agent}}"
    -launchctl bootout gui/$(id -u) "{{launch_agent}}" 2>/dev/null
    @just _quit
    launchctl bootstrap gui/$(id -u) "{{launch_agent}}"
    @echo "loaded {{launch_agent}}"

# Build every plugin in plugins/ and examples/plugins/ into .tipplugin.zip files
plugins:
    for p in plugins/*/pack.sh examples/plugins/*/pack.sh; do "$p"; done

# Link plugins/<name> into the running tip for development (rebuild, then `tip plugins restart <id>`)
plugin-dev name="markets":
    #!/usr/bin/env bash
    set -euo pipefail
    dir=plugins/{{name}}
    id=$(sed -n 's/^ *id: *"\([^"]*\)".*/\1/p' $dir/plugin.json5 | head -1)
    (cd $dir && swift build -c release -q)
    stage=build.noindex/plugins/$id
    mkdir -p $stage/bin
    cp $dir/plugin.json5 $stage/
    cp "$(cd $dir && swift build -c release --show-bin-path)/{{name}}" $stage/bin/
    .build/debug/tip plugins link $stage || tip plugins link $stage
    tip plugins restart $id 2>/dev/null || true

# Render every bar to a PNG (needs a running tip)
preview out="build.noindex/preview.png":
    mkdir -p "$(dirname "{{out}}")"
    tip preview "{{out}}"

# Regenerate examples/config.json5 and examples/theme.json5
examples: build
    .build/debug/tip config template > examples/config.json5
    .build/debug/tip theme template > examples/theme.json5

# Follow tip's log (plugins: category == "plugin")
log:
    log stream --level info --predicate 'subsystem BEGINSWITH "com.pseudobun.tip"'

# Re-render Resources/AppIcon.icns from Resources/icon/tip-icon.svg
icon:
    swift scripts/make-icon.swift

# Idle CPU, wakeups and memory of the running tip over 60 s
bench seconds="60":
    tip bench {{seconds}}

# Release build zipped into build.noindex/release (CI signs and notarizes it)
release-zip:
    scripts/bundle.sh build.noindex/release
    cd build.noindex/release && ditto -c -k --sequesterRsrc --keepParent tip.app "tip-$(tr -d '[:space:]' < ../../VERSION)-macos.zip"

# Build and publish a version by hand (normally release-please does this when its PR merges)
release tag=("v" + `tr -d '[:space:]' < VERSION`):
    gh workflow run release.yml -f tag={{tag}}
    @echo "started; gh run watch to follow it"
