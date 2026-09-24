# Validation log

## 2026-09-24 — automatic remote audio

Tested base: `d15664af21d16c9505d835562519808dc71d050d`, with the uncommitted
`feat/automatic-audio` changes: protocol v13 provider/acquisition messages,
connection-bound attachment ownership, Linux device acquisition and lifetime,
Mac provider supervision and hardware locking, app preference/menu lifecycle,
ALSA handshake timeout, regression harness and documentation. The implementation
and this record are committed together. No running app, daemon or NixOS
configuration was changed.

Hosts: Spark, Linux 6.17.13 aarch64; MacBook, arm64 macOS. Mac compilation and
tests used an isolated source copy at
`/Users/rathi/Library/Caches/mux-automatic-review-20260924`. The existing cached
GhosttyKit framework supplied the Swift binary dependency.

Raw logs are retained locally under ignored
`results/2026-09-24-automatic-audio/` in the implementation worktree. They are
not published artifacts. The logs include Rust, Mac Swift, both audio harnesses,
terminal regression tests and base-versus-change lint output.

### Commands and outcomes

- `nix develop .#muxd --command bash -c 'export PATH=/home/rathi/.local/share/rustup/toolchains/1.96.1-aarch64-unknown-linux-gnu/bin:$PATH; export CARGO_TARGET_DIR=target/ci; cargo clippy --workspace --all-targets && cargo test --workspace'`: passed on Spark (129 tests, plus empty doc-test targets). A subsequent `cargo build -p muxd -p mux-attach` and Clippy check passed for the final Linux implementation.
- With `HISTFILE=/dev/null` and `CARGO_TARGET_DIR` pointing to that absolute
  `target/ci` directory, `uv run python scripts/test-muxd-{e2e,upgrade,expiry,quic-e2e,audio,audio-auto}.py`
  (each script separately): all six passed. Expiry measured 60.101 seconds
  across daemon upgrade; reopened and ordinarily detached terminals survived.
- On Mac, the same Nix development shell and Rust 1.96.1 from
  `/Users/rathi/.local/share/rustup/toolchains/1.96.1-aarch64-apple-darwin/bin`:
  `cargo clippy --workspace --all-targets` and
  `cargo test -p muxd --lib audio::automatic` passed (four tests). These use
  synthetic hardware to test idle registration, competing ownership, closing
  route handoff, hardware failure, disconnect cleanup and re-registration.
- `swift test --package-path app --scratch-path /Users/rathi/Library/Caches/mux-build/swift-build`
  on Mac: app compiled and all 39 tests passed.
- `nix build .#alsa-plugin --no-link --json`: passed, output
  `/nix/store/imjh4f758b51sss4rkj011ln15akbwbc-mux-alsa-0.1.0`.
- `cargo fmt --check`, `git diff --check`, Rust/Cargo astlog scans and
  `lint/astlog/check.sh`: passed. SwiftFormat 0.62.1 passes on all changed Swift
  files. The full Swift formatting/lint gates do not pass, as detailed below.

### Failures, corrections and inherited findings

Initial builds mixed the Nix shell's Rust 1.97.1 with the pinned 1.96.1 Clippy
driver and failed with incompatible crate metadata. Selecting 1.96.1 explicitly
and a separate `target/ci` directory fixed the environment; final checks passed.
The first isolated Mac build used a stale GhosttyKit cache path; pointing its
symlink at the current cached framework fixed that build dependency.

The first workspace test exposed an outdated golden protocol-version byte;
the fixture now reflects v13. During audio harness development, a stale acquire
received EOF instead of its remote rejection because the broker took its local
media lock too early. The broker now forwards rejection before attempting that
lock; stale request and busy-owner regressions pass. A fixture cleanup race
with shell history was fixed by disabling history in its disposable homes.

Base lint was independently run against a fresh archive of the exact base
revision. SwiftLint 0.65.0 reports 17 findings on base and 16 on this change,
with no new findings. Both revisions have the same two astlog Swift failures
in unchanged `PaneSearchBar.swift` (ad hoc fonts at lines 36 and 45).
Full SwiftFormat also reports pre-existing formatting findings in untouched
files; the changed Swift files pass. Those unrelated files were left intact.
See `base-*` and `change-*` lint logs and `swiftformat.log` for evidence.

### Supported conclusions and remaining acceptance

The real-daemon audio harness covers automatic acquisition from verified
process ancestry, concurrent hardened capture/playback opens, readiness before
device acknowledgement, two-way PCM, connection and pane isolation, ownership
handoff, busy/stale rejection, provider loss/re-registration, new panes,
attachment replacement, failed acquisition/retry and terminal survival.
Native Mac tests cover provider control behavior with an injected driver;
the production CoreAudio path compiled successfully.

This session did not install the new app/daemon or run a physical microphone
and speaker conversation through the new automatic flow. That live acceptance
remains required after updating both ends to protocol v13. Existing tests of
the original explicit hardware bridge are separate evidence. No inference
provider, Devin voice entitlement, acoustic quality or latency guarantee is
established by these checks. CI, review, merge and deployment are separate
from these local results and were not accepted by this record.
