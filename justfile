# mux workspace tasks

default: test

test:
    cargo test --workspace

check:
    cargo clippy --workspace --all-targets

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
