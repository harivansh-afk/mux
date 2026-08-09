# mux workspace tasks

default: test

test:
    cargo test --workspace

check:
    cargo clippy --workspace --all-targets

# Fetch prebuilt GhosttyKit.xcframework + resources (run on the Mac)
ghosttykit:
    ./scripts/fetch-ghosttykit.sh

# Build the app (run on the Mac)
app:
    cd app && xcodebuild -scheme Mux build
