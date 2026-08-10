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
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" 2>/dev/null || true
echo "built: $BUNDLE"
