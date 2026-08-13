#!/usr/bin/env bash
# Assemble Mux.app from the SwiftPM build (run on the Mac).
# Usage: scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$ROOT/app"
GHOSTTY_SRC="${GHOSTTY_SRC:-$HOME/src/ghostty}"

cd "$APPDIR"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mux"
BUNDLE="$APPDIR/.build/Mux.app"

# muxd + mux-attach: the session daemon and the relay every pane runs.
# ghostty-vt's build shim needs zig 0.16 and a ghostty source checkout.
export GHOSTTY_SOURCE_DIR="${GHOSTTY_SOURCE_DIR:-$GHOSTTY_SRC/src}"
if ! command -v zig >/dev/null && [ -d "$HOME/tools/zig-0.16.0" ]; then
  export PATH="$HOME/tools/zig-0.16.0:$PATH"
fi
(cd "$ROOT" && cargo build --release -p muxd -p mux-attach)

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Mux"
cp "$ROOT/target/release/muxd" "$ROOT/target/release/mux-attach" "$BUNDLE/Contents/MacOS/"

# App icon (regenerate from scripts/make-icon.swift if the committed .icns is
# missing, so the source of truth is the generator, not a binary blob).
ICNS="$APPDIR/Assets/Mux.icns"
if [ ! -f "$ICNS" ]; then
  ICONSET="$(mktemp -d)/Mux.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
  mkdir -p "$APPDIR/Assets"
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$BUNDLE/Contents/Resources/Mux.icns"

# Ghostty runtime resources. GHOSTTY_RESOURCES_DIR points at Resources/ghostty,
# but the terminfo db lives at the SIBLING path Resources/terminfo (ghostty
# derives it as resources_dir/../terminfo). Missing terminfo = TERM broken =
# "'xterm-ghostty': unknown terminal type" and garbled zle redraws.
if [ -d "$GHOSTTY_SRC/zig-out/share/ghostty" ]; then
  cp -R "$GHOSTTY_SRC/zig-out/share/ghostty" "$BUNDLE/Contents/Resources/ghostty"
  cp -R "$GHOSTTY_SRC/zig-out/share/terminfo" "$BUNDLE/Contents/Resources/terminfo"
else
  echo "warning: $GHOSTTY_SRC/zig-out/share/ghostty not found; run zig build in the ghostty checkout" >&2
fi

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>sh.harivan.mux</string>
  <key>CFBundleName</key><string>mux</string>
  <key>CFBundleExecutable</key><string>Mux</string>
  <key>CFBundleIconFile</key><string>Mux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with the stable local dev identity if it exists (scripts/dev-sign-setup.sh),
# else fall back to ad-hoc. The stable identity is what lets a one-time TCC grant
# (Documents/Full Disk access) survive rebuilds, so the app launches by
# double-click instead of hanging on a privacy gate it can never satisfy.
DEV_KEYCHAIN="$HOME/Library/Keychains/mux-dev.keychain-db"
# No -v: a self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED), which -v
# filters out, but codesign signs with it fine and TCC keys on the stable
# identity regardless of trust.
if security find-identity -p codesigning "$DEV_KEYCHAIN" 2>/dev/null | grep -q "mux-dev"; then
  codesign --force --deep --sign "mux-dev" --keychain "$DEV_KEYCHAIN" "$BUNDLE"
  echo "signed with mux-dev"
else
  codesign --force --sign - "$BUNDLE" 2>/dev/null || true
  echo "ad-hoc signed (run scripts/dev-sign-setup.sh for a stable identity)"
fi
echo "built: $BUNDLE"
