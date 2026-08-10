//! muxd's entry point: parse the listener flags, then run them. The
//! daemon itself lives in the library next door (lib.rs).
//!
//! Usage:
//!   muxd [--socket PATH]

use anyhow::Result;
use muxd::{manager, server};

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
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    // The daemon must not die with a client mid-write, nor with the
    // terminal that happened to birth it.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }

    let socket = socket_path_from_args();
    server::serve(manager::Manager::default(), &socket).await
}
