//! mux-attach: the stdio relay every remote pane runs.
//!
//! libghostty's only IO backend is `exec`, so Mux.app sets each pane's command
//! to `mux-attach <target>`. libghostty forks us against a real PTY; we bridge
//! raw-mode stdio to the lane-framed protocol. That gets correct key encoding,
//! resize (SIGWINCH -> ClientControl::Resize), and rendering for free, with no
//! ghostty fork.
//!
//! Targets (M2+):
//!   mux-attach local[:session]          unix socket to local muxd
//!   mux-attach host[:session]           TCP (tailscale/ssh -L) to remote muxd
//!   mux-attach ix:<vm>[:session]        M3: exec `ix shell`; M4: native QUIC
//!
//! Steal list from ix's shell client (ix/crates/ix/cli/.../interactive/terminal.rs):
//! - RawModeGuard with the full reset string on drop (SGR, cursor, scroll region,
//!   origin/wrap, all mouse modes, bracketed paste, OSC 104/110/111/112)
//! - detach keys Ctrl-] and Ctrl-A d, state machine safe across chunk boundaries
//! - resize by polling terminal size every 200ms (SIGWINCH coalesces during drags)
//! - blocking stdin on a dedicated cancellable thread
//! - OSC 52/7717 relay scanner, 2 MiB cap, open-rate gate

fn main() -> anyhow::Result<()> {
    let target = std::env::args().nth(1);
    anyhow::bail!(
        "mux-attach is M2 work; target {:?} not yet reachable. See docs/architecture.html",
        target
    );
}
