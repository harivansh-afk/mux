#!/usr/bin/env bash
# Launch a built Mux.app fully isolated from the daily setup:
#
#   - MUX_STATE_DIR: its own state.json / backups / app.log, so the real
#     state files are never read, rotated or overwritten (and the app
#     skips orphan-pty adoption entirely - it never touches the daily
#     daemon's or the remote hosts' ptys).
#   - MUXD_SOCKET: its own daemon on its own socket (mux-attach spawns
#     one on demand), so every pty it creates lives in a separate world.
#
# The daily app, its sessions and its daemon are untouched. Quitting the
# test app detaches as usual; its throwaway daemon keeps the test ptys
# until you kill it: pkill -f "muxd-dev-$(id -u).sock"
#
# Usage: scripts/run-dev.sh [path/to/Mux.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${1:-$ROOT/app/.build/Mux.app}"
[ -x "$BUNDLE/Contents/MacOS/Mux" ] || {
  echo "no app at $BUNDLE (run scripts/make-app.sh first)" >&2
  exit 1
}

exec env \
  MUX_STATE_DIR="$HOME/Library/Application Support/mux-dev" \
  MUXD_SOCKET="/tmp/muxd-dev-$(id -u).sock" \
  "$BUNDLE/Contents/MacOS/Mux"
