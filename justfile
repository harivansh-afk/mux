# mux workspace tasks

# github.com/indexable-inc/index, the source of `astlog`. Bump deliberately:
# a rule that loads here must load in CI.
ASTLOG_REV := "55b2f75e4e595314bc7441368ab19c346b152616"

default: test

test:
    cargo test --workspace

check:
    cargo clippy --workspace --all-targets

# Attach, SIGKILL the client, reattach, replay: runs against a throwaway
# HOME and a private socket, never the daemon you are living in.
e2e:
    cargo build -p muxd -p mux-attach
    python3 scripts/test-muxd-e2e.py

# `muxd --upgrade` adopts a live pty from the running daemon: same
# isolation as `e2e`, same promise about your own daemon.
upgrade-test:
    cargo build -p muxd -p mux-attach
    python3 scripts/test-muxd-upgrade.py

# Everything CI gates on (Swift steps need the toolchain; see .forgejo/workflows/ci.yml)
lint: check
    cargo fmt --check
    astlog scan lint/astlog/rust.astlog crates
    astlog scan lint/astlog/swift.astlog app/Sources
    astlog scan lint/astlog/cargo.astlog Cargo.toml crates/*/Cargo.toml
    lint/astlog/check.sh

# The lint engine: Datalog over tree-sitter, from the index monorepo. Pinned
# by revision so a rule that passes here passes in CI.
#
# `cargo install --git <url> astlog` does NOT work and is not a shortcut worth
# retrying: astlog is a member of a virtual workspace, and cargo will not
# select a member from a git source (checked with and without --rev and
# --locked; all three fail with "could not find astlog with version *").
# Cloning first and installing by path is the working form.
astlog-install:
    #!/usr/bin/env bash
    set -euo pipefail
    src="${XDG_CACHE_HOME:-$HOME/.cache}/mux/astlog-{{ASTLOG_REV}}"
    if [ ! -d "$src" ]; then
        rm -rf "$src.tmp"
        git clone -q https://github.com/indexable-inc/index "$src.tmp"
        git -C "$src.tmp" checkout -q {{ASTLOG_REV}}
        mv "$src.tmp" "$src"
    fi
    cargo install --locked --path "$src/packages/astlog/cli"

# Fetch prebuilt GhosttyKit.xcframework + resources (run on the Mac)
ghosttykit:
    ./scripts/fetch-ghosttykit.sh

# Build the app (run on the Mac)
app:
    ./scripts/make-app.sh

# Two-daemon QUIC broker e2e (hermetic, loopback)
quic-e2e:
    cargo build -p muxd -p mux-attach
    python3 scripts/test-muxd-quic-e2e.py
