//! muxd's entry point: parse the listener flags, then run them. The
//! daemon itself lives in the library next door (lib.rs).
//!
//! Usage:
//!   muxd [--socket PATH] [--listen-quic ADDR] [--upgrade]
//!
//! The unix socket is always on; `--listen-quic` additionally exposes
//! the same protocol to the network (`ADDR` is `<ip>:<port>` or a bare
//! `<ip>`, which takes the default QUIC port).
//!
//! `--upgrade` replaces a running daemon without killing a shell: the
//! new process inherits the live PTY fds plus a screen snapshot per pty
//! over `SCM_RIGHTS` (migrate.rs), then takes the socket.

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use muxd::{manager, migrate, quic, server};

struct Args {
    socket: PathBuf,
    listen_quic: Option<SocketAddr>,
    upgrade: bool,
}

fn parse_args() -> Result<Args> {
    let mut socket = None;
    let mut listen_quic = None;
    let mut upgrade = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" => {
                socket = Some(PathBuf::from(args.next().context("--socket needs a path")?));
            }
            "--listen-quic" => {
                let value = args.next().context("--listen-quic needs an address")?;
                listen_quic = Some(parse_listen(&value)?);
            }
            "--upgrade" => upgrade = true,
            other => bail!("unknown argument {other:?}"),
        }
    }
    Ok(Args {
        socket: socket
            .unwrap_or_else(|| mux_proto::peer::socket_path(nix::unistd::getuid().as_raw())),
        listen_quic,
        upgrade,
    })
}

fn parse_listen(value: &str) -> Result<SocketAddr> {
    if let Ok(addr) = value.parse::<SocketAddr>() {
        return Ok(addr);
    }
    let ip: IpAddr = value
        .parse()
        .with_context(|| format!("bad --listen-quic address {value:?}"))?;
    Ok(SocketAddr::new(ip, mux_proto::peer::DEFAULT_QUIC_PORT))
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

    let args = parse_args()?;
    let manager = manager::Manager::default();

    // Adopt first: the predecessor owns the socket until it hands over.
    if args.upgrade {
        migrate::adopt_from_predecessor(&manager).await;
    }
    let listener = server::bind(&args.socket).await?;
    // Only the daemon that owns the socket publishes itself as the one a
    // successor should ask for a handoff.
    migrate::write_pidfile()?;
    migrate::spawn_handoff_task(manager.clone());

    // The QUIC listener is a second door onto the same ptys: it shares
    // the manager and runs beside the socket, never instead of it. When
    // it was asked for, its death is the daemon's death: a muxd that
    // silently serves only its unix socket looks healthy to a supervisor
    // while every remote pane dials a closed port. Exiting instead lets
    // Restart=on-failure retry until the bind succeeds (in practice the
    // failure is at startup - a stale port holder - before any pty
    // exists).
    match args.listen_quic {
        Some(addr) => {
            let quic = quic::serve(manager.clone(), addr);
            let unix = server::serve(manager, listener);
            tokio::select! {
                r = quic => r.context("quic listener stopped"),
                r = unix => r,
            }
        }
        None => server::serve(manager, listener).await,
    }
}
