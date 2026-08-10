#!/usr/bin/env bash
# Fetch prebuilt GhosttyKit.xcframework + resources (the muxy pattern:
# a CI job on a ghostty fork builds `zig build -Demit-xcframework` with
# ReleaseFast and publishes GhosttyKit.xcframework + GhosttyKit-resources.tar.gz
# as release assets; dev machines never need Zig).
#
# M1 setup: point REPO at our ghostty artifacts fork once its CI exists.
# Until then, build locally on the Mac:
#   git clone https://github.com/ghostty-org/ghostty && cd ghostty
#   zig build -Demit-xcframework -Dxcframework-target=native -Doptimize=ReleaseFast  # zig 0.16
#   cp -R macos/GhosttyKit.xcframework <this-repo>/app/GhosttyKit/
#
# -Doptimize=ReleaseFast is NOT optional. A Debug libghostty emits an os_log
# for every IO mailbox message; under heavy output (nvim scroll) the log
# backpressure stalls the IO thread for seconds and then floods the PTY with
# the queued writes - the terminal freezes, then jumps. Debug asserts also
# crash the app in ways the embedded sentry handler swallows silently.
# Verify a framework is release-mode: strings on libghostty-internal.a must
# NOT contain "mailbox message=".
# Also set GHOSTTY_RESOURCES_DIR at app launch: terminfo, shell integration,
# and TERM=xterm-ghostty break without it.
set -euo pipefail

REPO="${MUX_GHOSTTYKIT_REPO:-}"
if [[ -z "$REPO" ]]; then
  echo "MUX_GHOSTTYKIT_REPO not set; see comments in this script for the local build path." >&2
  exit 1
fi
DEST="$(dirname "$0")/../app/GhosttyKit"
mkdir -p "$DEST"
gh release download --repo "$REPO" --pattern 'GhosttyKit.xcframework.zip' --pattern 'GhosttyKit-resources.tar.gz' --dir "$DEST" --clobber
(cd "$DEST" && unzip -oq GhosttyKit.xcframework.zip && tar xzf GhosttyKit-resources.tar.gz)
echo "GhosttyKit ready in $DEST"
