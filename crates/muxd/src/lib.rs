//! muxd: the session daemon. Fork of ix-console (see docs/architecture.html
//! for the fork map). Keeps per-pty: PTY master (`AsyncFd`), child process,
//! and a headless ghostty-vt Terminal fed from the PTY. Ptys survive client
//! disconnect; reattach replays `render_screen_bytes()` (scrollback with
//! per-cell SGR, DEC modes, tabstops, pending-wrap; never the palette).
//!
//! Upstream bugs fixed in this fork (see manager.rs):
//! - the attach race (channel installed + dump rendered under one lock)
//! - slow clients are detached, never silently skipped
//!
//! Listeners, same protocol on both:
//! - per-uid 0600 unix socket at `/tmp/muxd-<uid>.sock` (short path:
//!   `sun_path` is 104 bytes on darwin), always on. Filesystem
//!   permissions are the auth boundary.
//! - QUIC on `--listen-quic <addr>`, opt in. Self-signed cert with an
//!   SPKI pin plus a bearer token (tls.rs) are the auth boundary.
//!
//! `muxd --upgrade` replaces a running daemon without killing a shell:
//! the successor inherits the live PTY fds plus a screen snapshot per
//! pty over `SCM_RIGHTS` (migrate.rs).
//!
//! The daemon is a binary; this library exists so integration tests can
//! drive the listeners in-process on ephemeral ports.

pub mod broker;
pub mod manager;
pub mod migrate;
pub mod pty;
pub mod quic;
pub mod server;
pub mod tls;
