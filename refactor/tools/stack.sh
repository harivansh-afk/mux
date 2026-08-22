#!/usr/bin/env bash
# Stack every refactor/task-NN branch onto main in .worktrees/stack, build a
# side-by-side Mux.app that cannot touch the real one, and print how to run it.
#
#   refactor/tools/stack.sh            merge + build
#   refactor/tools/stack.sh run        launch the stacked app
#
# Isolation: a different bundle id (sh.harivan.mux.stack), its own muxd
# socket (MUXD_SOCKET), and its own state dir (MUX_STATE_DIR, a small
# override applied only on the stack branch). Your real mux, its daemon and
# its state.json are never read or written.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WT="$ROOT/.worktrees/stack"
SOCK="/tmp/muxd-stack-$(id -u).sock"
STATE="$HOME/.local/state/mux-stack"

if [ "${1:-}" = "run" ]; then
  APP="$WT/app/.build/Mux.app/Contents/MacOS/Mux"
  [ -x "$APP" ] || { echo "no stacked build; run $0 first" >&2; exit 1; }
  mkdir -p "$STATE"
  echo "launching $APP with MUXD_SOCKET=$SOCK MUX_STATE_DIR=$STATE"
  MUXD_SOCKET="$SOCK" MUX_STATE_DIR="$STATE" exec "$APP"
fi

cd "$ROOT"
git fetch -q origin
if [ ! -d "$WT" ]; then
  git worktree add -q "$WT" -b refactor/stack origin/main
fi
cd "$WT"
git checkout -q refactor/stack
git reset -q --hard origin/main

merged=()
skipped=()
for n in $(seq -w 1 21); do
  b="refactor/task-$n"
  git show-ref -q --verify "refs/remotes/origin/$b" || continue
  if git merge -q --no-edit "origin/$b" 2>/dev/null; then
    merged+=("$b")
  else
    git merge --abort
    skipped+=("$b")
  fi
done
echo "merged:  ${merged[*]:-none}"
echo "skipped (conflict, merge by hand in $WT): ${skipped[*]:-none}"

# State-dir override for side-by-side testing; lives only on the stack branch.
if ! grep -q MUX_STATE_DIR app/Sources/Mux/State/Snapshot.swift; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("app/Sources/Mux/State/Snapshot.swift")
s = p.read_text()
old = re.search(r"    static var url: URL \{\n(.*?)\n    \}\n", s, re.S)
assert old, "SnapshotStore.url not found"
new = '''    static var url: URL {
        if let dir = ProcessInfo.processInfo.environment["MUX_STATE_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return URL(fileURLWithPath: dir).appendingPathComponent("state.json")
        }
''' + old.group(1) + "\n    }\n"
p.write_text(s.replace(old.group(0), new))
PY
  git commit -qam "stack: MUX_STATE_DIR override for side-by-side testing (not for main)"
fi

[ -d app/GhosttyKit ] || cp -R "$ROOT/app/GhosttyKit" app/
./scripts/make-app.sh
# A distinct bundle id so LaunchServices treats it as another app.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier sh.harivan.mux.stack" app/.build/Mux.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleName mux-stack" app/.build/Mux.app/Contents/Info.plist
codesign --force --sign - app/.build/Mux.app 2>/dev/null || true
echo
echo "built: $WT/app/.build/Mux.app"
echo "run:   $0 run"
