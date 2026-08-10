# mux workspace tasks

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
    ast-grep test
    ast-grep scan
    ./scripts/lint/no-cargo-path-dep.sh

# Fetch prebuilt GhosttyKit.xcframework + resources (run on the Mac)
ghosttykit:
    ./scripts/fetch-ghosttykit.sh

# Build the app (run on the Mac)
app:
    ./scripts/make-app.sh
