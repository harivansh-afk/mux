//! muxd: the session daemon. Fork of ix-console (see docs/architecture.html
//! for the fork map). Keeps per-pty: PTY master (AsyncFd), child process,
//! and a headless ghostty-vt Terminal fed from the PTY. Ptys survive client
//! disconnect; reattach replays render_screen_bytes() (scrollback with
//! per-cell SGR, DEC modes, tabstops, pending-wrap; never the palette).
//!
//! Upstream bugs fixed in this fork (see manager.rs):
//! - the attach race (channel installed + dump rendered under one lock)
//! - slow clients are detached, never silently skipped
//!
//! Listener: per-uid 0600 unix socket at /tmp/muxd-<uid>.sock (short path:
//! sun_path is 104 bytes on darwin). Token auth returns with TCP in M3;
//! SCM_RIGHTS live-fd self-upgrade (migrate.rs upstream) is M2.5.

mod manager;
mod pty;
mod server;

use anyhow::Result;

fn socket_path_from_args() -> std::path::PathBuf {
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--socket" {
            if let Some(path) = args.next() {
                return path.into();
            }
        }
    }
    mux_proto::peer::socket_path(nix::unistd::getuid().as_raw())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    // The daemon must not die with a client mid-write.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    let socket = socket_path_from_args();
    server::serve(manager::Manager::default(), &socket).await
}
