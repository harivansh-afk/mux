# Validation

## 2026-09-24 — automatic remote audio

Base: `d15664af21d16c9505d835562519808dc71d050d`. Tested on Spark
(Linux 6.17.13, aarch64) and MacBook (arm64 macOS) with the uncommitted
`feat/automatic-audio` changes. Raw logs are retained in ignored
`results/2026-09-24-automatic-audio/` in the implementation worktree.

Before simplification, Rust workspace tests, all six daemon harnesses,
four Mac provider tests and 39 Swift tests passed. The new tests and their
injection wrapper were subsequently removed at the user's request; the existing
tests remain. The final provider uses Tokio's `JoinSet` for reader cleanup.
Final Rust Clippy/build checks run on both hosts using `nix develop .#muxd`,
Rust 1.96.1 and `CARGO_TARGET_DIR=target/ci`; results are recorded in
`final-linux.log` and `final-mac.log`. The Nix ALSA plugin build passed.

Initial retries corrected mixed Rust compiler metadata, a stale local
GhosttyKit path, the protocol-version golden byte and a fixture history-file
cleanup race. The broker now returns remote rejection before taking its local
media lock. Exact-base comparison established inherited Swift lint failures:
17 versus 16 SwiftLint findings, two unchanged architecture-lint findings in
`PaneSearchBar.swift`, and eight versus seven files needing SwiftFormat.
Changed Swift files and Rust formatting/architecture lint pass.

These are local build and synthetic transport results. CI is disabled for this
repository. The new automatic flow has not been installed or accepted with a
physical microphone/speaker conversation; prior explicit-bridge hardware
validation is separate. Merge, Nix pinning and deployment are separate steps.
