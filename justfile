# mux workspace tasks

default: test

test:
    cargo test --workspace

check:
    cargo clippy --workspace --all-targets

# Everything CI gates on (swiftlint/swiftformat via brew; cargo-audit runs in CI only)
lint: check
    cargo fmt --check
    ast-grep test
    ast-grep scan
    ./scripts/lint/no-cargo-path-dep.sh
    swiftformat --lint app/Sources
    swiftlint lint --strict --quiet app/Sources

# Fetch prebuilt GhosttyKit.xcframework + resources (run on the Mac)
ghosttykit:
    ./scripts/fetch-ghosttykit.sh

# Build the app (run on the Mac)
app:
    cd app && xcodebuild -scheme Mux build
