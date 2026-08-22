# task 21 (optional, FFI): ghostty-vt edges

PR title: `ghostty-vt: the surface muxd uses; build.rs does one thing; no stale header`

Depends on: 10. Out of the main plan by your call (FFI); listed because
each item is small and none touches `renderReattach`.

## Why

- `include/ghostty_vt.h` declares `ghostty_vt_terminal_dump_viewport`
  and `_dump_screen`, which do not exist in `zig/lib.zig`, and omits
  `_render_reattach` and `_cursor_pending_wrap`. Nothing reads it: the
  Rust side has its own `extern "C"` block; `build.rs:162-171` and
  `build.zig:123-129` only copy it around.
- `build.rs` is 273 lines to run one `zig build`: `ZigCacheDirs` wraps
  two paths with one caller; `find_zig` probes `zig version`, then
  `assert_zig_available` probes it again with a message about a flake
  that does not match what it checked; `apply_ghostty_system_cache` and
  `apply_zig_libc` are the same 11-line function; a `#[cfg(windows)]`
  symlink arm in a unix-only workspace; and `-Dtarget=x86_64-linux-musl`
  hardcoded for any musl build, wrong for spark (aarch64).
- `zig/lib.zig:6-23` `getIo()` is a 16-line atomic state machine that
  lazily builds a `std.Io.Threaded`, whose `init` installs process-wide
  SIGIO/SIGPIPE handlers inside muxd and is never deinit'd.
  `std.Io.Threaded.global_single_threaded.io()` is a comptime instance
  needing no allocator, no signal handlers and no deinit.
- Six of seven exports open with a null check on a pointer Rust stores
  as `NonNull`, and return codes the Rust side discards.

## Changes

- Delete `include/`, the include symlink farm in `build.rs`, the
  `rerun-if-changed` for it, and `include_step` in `build.zig`.
- `build.rs`: inline the cache dirs; delete `assert_zig_available`;
  one `flag_from_env(cmd, flag, var)`; `rerun-if-changed` from a loop;
  delete the windows arm; derive the musl target from
  `CARGO_CFG_TARGET_ARCH`. Target ≤ 120 lines.
- `lib.zig`: `getIo()` → `std.Io.Threaded.global_single_threaded.io()`;
  exports take `*TerminalHandle`; `feed`/`resize`/`cursor_position`
  return void (or resize propagates a real `Result` in Rust; pick one
  and make the Rust signature match).
- `src/lib.rs`: `fn take_bytes(ffi::Bytes) -> Vec<u8>` shared by
  `render_screen_bytes` and `row_texts`; one module-level SAFETY note.

## Keep

- `renderReattach` and its emission order untouched; the title-replay
  tests are the gate.
- `ReleaseFast` for the xcframework (CLAUDE.md build section) is
  unrelated to this crate's zig build but worth re-reading before
  touching `build.zig`.

## Done when

- `crates/ghostty-vt/include` does not exist; `build.rs` ≤ 120 lines;
  `zig/lib.zig` ≤ 300.
- `cargo test -p ghostty-vt -p muxd` passes on the Mac; `nix build
  .#muxd` succeeds for `aarch64-linux` (spark) and the musl target is
  `aarch64-linux-musl` in the build log.
