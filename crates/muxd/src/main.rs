//! muxd: the session daemon. Fork of ix-console
//! (ix/crates/vm/guest/console/agent, 4,289 LOC; ~2,500 LOC survive the fork).
//!
//! Keeps per-session: PTY master (AsyncFd, not spawn_blocking), child process,
//! and a headless ghostty-vt Terminal fed from the PTY. Sessions survive client
//! disconnect; reattach replays render_screen_bytes() (scrollback with per-cell
//! SGR, DEC modes, tabstops, pending-wrap; deliberately never the palette).
//!
//! Fork plan (M2):
//! - keep: manager.rs, session.rs, pty*.rs, io.rs, attach.rs, migrate.rs
//!   (SCM_RIGHTS live-PTY handoff for zero-downtime daemon upgrades)
//! - drop: service-init (OTel/Prometheus/Sentry/axum), vm-guest-* crates,
//!   guest passwd/PATH assumptions, local_open.rs
//! - fix: the attach race (render the screen dump AFTER installing the client
//!   channel; upstream test missed_output_causes_divergence proves the gap)
//! - fix: migrate.rs rebuilds an empty Terminal; carry a screen snapshot so
//!   scrollback survives daemon restarts too
//! - listen: unix socket (local) / TCP loopback+tailscale (remote), bearer
//!   token file re-read per connection (golden-restore friendly)
//! - macOS: rustix ptsname covers darwin (TIOCPTYGNAME); avoid $TMPDIR socket
//!   paths (104-byte sun_path limit) - use short /tmp paths

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().init();
    anyhow::bail!("muxd is M2 work: fork of ix-console. See docs/architecture.html");
}
