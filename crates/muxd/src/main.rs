//! muxd's entry point: parse the listener flags, then run them. The
//! daemon itself lives in the library next door (lib.rs).
//!
//! Usage:
//!   muxd [--socket PATH] [--listen-quic ADDR] [--upgrade]
//!   muxd upgrade [-- daemon flags]   replace the running daemon, keep its ptys
//!        [--authorized-tokens PATH]
//!   muxd ls [alias] [--json]   one JSON object per pty
//!   muxd watch [alias] [--json] one JSON object per pty, then per change
//!   muxd kill [host|local]:<name>
//!   muxd probe <alias>         check a host, one JSON line, exit 1 on failure
//!   muxd upgrade               replace the running daemon with this binary
//!   muxd client-digest         print this user's client token digest and exit
//!
//! The queries dial the local socket (`MUXD_SOCKET`, else the per-uid
//! default) exactly as a pane does, so `ls` and `probe` see what the
//! panes see. `probe` relays a `List` to `alias` through this daemon's
//! broker, which exercises dial, pin, token and protocol version in one
//! call, and prints one line for Mux.app to read:
//!
//! ```text
//! {"alias":"spark","ok":true,"rtt_ms":12,"ptys":2}
//! {"alias":"spark","ok":false,"class":"token-rejected","error":"..."}
//! ```
//!
//! `class` is the reply's `ErrorKind`; `rtt_ms` covers request to reply
//! only, never the connect that may precede it. `probe local` asks this
//! machine's own daemon, starting one if none answers.
//!
//! `upgrade` starts this binary as the running daemon's successor
//! (`--upgrade`, below) and prints the same line once the new daemon
//! answers, `rtt_ms` covering the whole handoff. Mux.app runs it at
//! launch when `probe local` reports `version-mismatch`: the daemon
//! outlives the app, so the first launch after an install meets the
//! previous build's.
//!
//! The unix socket is always on; `--listen-quic` additionally exposes
//! the same protocol to the network (`ADDR` is `<ip>:<port>` or a bare
//! `<ip>`, which takes the default QUIC port).
//!
//! `--authorized-tokens` enrolls clients other than this machine's own:
//! one `sha256:<64 hex>` digest per line. Digests are not secrets, so
//! the file is deployable by configuration management (nix/module.nix)
//! and no token ever crosses machines.
//!
//! `muxd client-digest` is that enrollment from the client's side: one
//! printed line, generated on first use, that the host's config lists.
//!
//! `--upgrade` replaces a running daemon without killing a shell: the
//! new process inherits the live PTY fds plus a screen snapshot per pty
//! over `SCM_RIGHTS` (migrate.rs), then takes the socket.

use std::io::Write as _;
use std::net::{IpAddr, SocketAddr};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use mux_proto::frame;
use mux_proto::peer::{self, ErrorKind, OpenError, OpenMode, OpenReply, OpenRequest, Opened};
use muxd::{manager, migrate, paths, quic, server, systemd, tls};

struct Args {
    socket: PathBuf,
    listen_quic: Option<SocketAddr>,
    authorized_tokens: Option<PathBuf>,
    upgrade: bool,
}

fn parse_args() -> Result<Args> {
    let mut socket = None;
    let mut listen_quic = None;
    let mut authorized_tokens = None;
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
            "--authorized-tokens" => {
                let value = args.next().context("--authorized-tokens needs a path")?;
                authorized_tokens = Some(PathBuf::from(value));
            }
            "--upgrade" => upgrade = true,
            other => bail!("unknown argument {other:?}"),
        }
    }
    Ok(Args {
        socket: socket.unwrap_or_else(paths::control_socket),
        listen_quic,
        authorized_tokens,
        upgrade,
    })
}

/// Enrollment: this client's token digest, one line on stdout. The token
/// is generated when this is its first use, so the answer is always
/// something the host can enroll.
fn client_digest() -> Result<()> {
    let token = tls::load_or_generate_token(&paths::client_token())?;
    println!("{}", tls::digest_line(&token));
    Ok(())
}

// ------------------------------------------------------------- queries

/// The local socket, starting a daemon when nothing answers. A query
/// that reported "no ptys" merely because the daemon had not come up yet
/// would lose exactly the sessions startup recovery exists to find.
fn connect() -> Result<UnixStream> {
    let path = paths::control_socket();
    if let Ok(stream) = UnixStream::connect(&path) {
        return Ok(stream);
    }
    if std::env::var_os("MUXD_NO_AUTOSTART").is_some() {
        bail!("muxd is unavailable at {}", path.display());
    }
    spawn_daemon(&path, &[])?;
    // A double-spawn race resolves by itself: the loser exits on
    // "already running" and we only need the socket to answer.
    for _ in 0..100 {
        std::thread::sleep(Duration::from_millis(20));
        if let Ok(stream) = UnixStream::connect(&path) {
            return Ok(stream);
        }
    }
    bail!("muxd did not come up on {}", path.display())
}

/// Start this binary as a daemon on `path`, plus `flags`, in a session of
/// its own: it must outlive the shell that ran the query and its
/// controlling tty, or their teardown SIGHUPs it away.
fn spawn_daemon(path: &Path, flags: &[String]) -> Result<()> {
    let exe = std::env::current_exe().context("locate muxd")?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("--socket")
        .arg(path)
        .args(flags)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    unsafe {
        use std::os::unix::process::CommandExt as _;
        cmd.pre_exec(|| {
            nix::unistd::setsid()
                .map(|_| ())
                .map_err(std::io::Error::from)
        });
    }
    cmd.spawn().context("spawn muxd")?;
    Ok(())
}

fn query(target: Option<String>, mode: OpenMode) -> OpenRequest {
    OpenRequest {
        version: peer::PROTOCOL_VERSION,
        // No pty is created, so no size is meaningful.
        cols: 0,
        rows: 0,
        term: None,
        token: None,
        target,
        mode,
    }
}

/// One handshake: write the request, read the reply off lane 0.
fn exchange(stream: &mut UnixStream, request: &OpenRequest) -> Result<OpenReply> {
    frame::write_message(stream, &peer::encode(request)).context("send request")?;
    stream.flush()?;
    let Some((_lane, payload)) = frame::read_lane(stream)? else {
        bail!("daemon closed without a reply");
    };
    peer::decode_open_reply(&payload).context("decode reply")
}

fn ask(target: Option<String>, mode: OpenMode) -> Result<Opened> {
    exchange(&mut connect()?, &query(target, mode))?.map_err(|e| anyhow::anyhow!("{e}"))
}

/// `local` is this machine's daemon, which the wire spells as no target.
fn host(alias: &str) -> Option<String> {
    (alias != "local").then(|| alias.to_string())
}

/// `local:<name>` or `<host-alias>:<name>`; a `local` target is None,
/// which is what the daemon calls itself.
fn parse_target(target: &str) -> Result<(Option<String>, String)> {
    match target.split_once(':') {
        Some(("local", name)) if !name.is_empty() => Ok((None, name.to_string())),
        Some((host, name)) if !host.is_empty() && !name.is_empty() => {
            Ok((Some(host.to_string()), name.to_string()))
        }
        _ => bail!("target must be [host|local]:<name>, got {target:?}"),
    }
}

/// One JSON object per pty. `--json` names the only format there is; it
/// is accepted so the call site reads as what it gets.
fn ls(args: &[String]) -> Result<()> {
    let mut alias = None;
    for arg in args {
        match arg.as_str() {
            "--json" => {}
            flag if flag.starts_with('-') => bail!("unknown flag {flag:?}"),
            alias_arg => alias = host(alias_arg),
        }
    }
    match ask(alias, OpenMode::List)? {
        Opened::Listed { ptys } => {
            for pty in ptys {
                println!("{}", serde_json::to_string(&pty).context("encode pty")?);
            }
            Ok(())
        }
        other => bail!("unexpected reply: {other:?}"),
    }
}

/// One JSON object per line: every pty now, then each change, until the
/// daemon goes away. What the app holds open per daemon.
fn watch(args: &[String]) -> Result<()> {
    let mut alias = None;
    for arg in args {
        match arg.as_str() {
            "--json" => {}
            flag if flag.starts_with('-') => bail!("unknown flag {flag:?}"),
            host => alias = Some(host.to_string()),
        }
    }
    let mut stream = connect()?;
    match exchange(&mut stream, &query(alias, OpenMode::Watch))?
        .map_err(|e| anyhow::anyhow!("{e}"))?
    {
        Opened::Watching => {}
        other => bail!("unexpected reply: {other:?}"),
    }
    let mut out = std::io::stdout().lock();
    while let Some((_lane, payload)) = frame::read_lane(&mut stream)? {
        let event = peer::decode::<peer::PtyEvent>(&payload).context("decode event")?;
        serde_json::to_writer(&mut out, &event).context("encode event")?;
        out.write_all(b"\n")?;
        out.flush()?;
    }
    Ok(())
}

fn close(target: &str) -> Result<()> {
    let (host, name) = parse_target(target)?;
    match ask(host, OpenMode::Close { name })? {
        Opened::Closed { expires_at_ms } => {
            println!("{expires_at_ms}");
            Ok(())
        }
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn kill(target: &str) -> Result<()> {
    let (host, name) = parse_target(target)?;
    match ask(host, OpenMode::Kill { name })? {
        Opened::Killed { existed } => {
            if !existed {
                eprintln!("no such pty");
            }
            Ok(())
        }
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn terminal_control(command: &str, args: &[String]) -> Result<()> {
    use std::io::Read as _;
    let [target] = args else {
        bail!("usage: muxd {command} [host|local]:<name>");
    };
    let (host, name) = parse_target(target)?;
    let mode = match command {
        "inspect" => OpenMode::Inspect { name },
        "observe" => OpenMode::Observe { name },
        "input" => {
            let mut data = String::new();
            std::io::stdin().take(65537).read_to_string(&mut data)?;
            if data.len() > 65536 {
                bail!("input JSON is too large");
            }
            OpenMode::Input {
                name,
                input: serde_json::from_str(&data).context("input JSON")?,
            }
        }
        _ => bail!("unknown control command"),
    };
    let mut stream = connect()?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let opened = exchange(&mut stream, &query(host, mode))?.map_err(|e| anyhow::anyhow!("{e}"))?;
    match opened {
        Opened::Inspected { snapshot } => println!("{}", serde_json::to_string(&snapshot)?),
        Opened::InputWritten { .. } => println!("{}", serde_json::to_string(&opened)?),
        Opened::Observing => {
            stream.set_read_timeout(None)?;
            let mut out = std::io::stdout().lock();
            while let Some((lane, payload)) = frame::read_lane(&mut stream)? {
                if lane != frame::OUT_LANE_EVENTS {
                    bail!("unexpected observation lane: {lane}");
                }
                let snapshot: peer::PtySnapshot = peer::decode(&payload)?;
                serde_json::to_writer(&mut out, &snapshot)?;
                out.write_all(b"\n")?;
                out.flush()?;
            }
        }
        other => bail!("unexpected reply: {other:?}"),
    }
    Ok(())
}

/// One line of `muxd probe` output. A struct, not a `json!` literal:
/// serde writes the fields in declaration order, and that order is what
/// the module doc promises.
#[derive(serde::Serialize)]
struct Probe<'a> {
    alias: &'a str,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    rtt_ms: Option<u128>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ptys: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    class: Option<ErrorKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
}

/// Relay a `List` to `alias` and time the round trip; print the result
/// and answer with the process exit code. Connecting is outside the
/// timing: it may start the local daemon, which says nothing about the
/// host being probed.
fn probe(alias: &str) -> i32 {
    let measured = connect().and_then(|mut stream| {
        let request = query(host(alias), OpenMode::List);
        let started = Instant::now();
        Ok((exchange(&mut stream, &request)?, started.elapsed()))
    });
    let answer = match measured {
        Ok((Ok(Opened::Listed { ptys }), rtt)) => Ok((ptys.len(), rtt)),
        Ok((Ok(other), _)) => Err(OpenError::new(
            ErrorKind::Other,
            format!("unexpected reply: {other:?}"),
        )),
        Ok((Err(e), _)) => Err(e),
        Err(e) => Err(OpenError::new(ErrorKind::Other, format!("{e:#}"))),
    };
    report(alias, &answer)
}

/// Give the handoff this long, then report failure. Under Mux.app's 10s
/// helper watchdog so the answer lands; a real handoff takes well under
/// a second (the predecessor renders its screens and writes one message).
const UPGRADE_TIMEOUT: Duration = Duration::from_secs(8);
const UPGRADE_POLL: Duration = Duration::from_millis(50);

/// Replace the running daemon with this binary: start it as the
/// successor (`--upgrade`, migrate.rs) and wait for the socket to answer
/// at this protocol version.
///
/// The wait never spawns a daemon. Between the predecessor's exit and
/// the successor's bind the socket is dead, and a fresh muxd raced in
/// there takes the socket from the successor, together with every pty
/// it just adopted.
fn upgrade(args: &[String]) -> i32 {
    let path = paths::control_socket();
    let started = Instant::now();
    let flags = match successor_flags(args) {
        Ok(flags) => flags,
        Err(e) => {
            return report(
                "local",
                &Err(OpenError::new(ErrorKind::Other, format!("{e:#}"))),
            )
        }
    };
    let answer = spawn_daemon(&path, &flags)
        .map_err(|e| OpenError::new(ErrorKind::Other, format!("{e:#}")))
        .and_then(|()| {
            let mut last = OpenError::new(ErrorKind::Unreachable, "nothing answered");
            while started.elapsed() < UPGRADE_TIMEOUT {
                std::thread::sleep(UPGRADE_POLL);
                let Ok(mut stream) = UnixStream::connect(&path) else {
                    continue;
                };
                match exchange(&mut stream, &query(None, OpenMode::List)) {
                    Ok(Ok(Opened::Listed { ptys })) => return Ok((ptys.len(), started.elapsed())),
                    Ok(Ok(other)) => {
                        return Err(OpenError::new(
                            ErrorKind::Other,
                            format!("unexpected reply: {other:?}"),
                        ))
                    }
                    // The predecessor still serving, or closing under us:
                    // the handoff is in flight.
                    Ok(Err(e)) => last = e,
                    Err(e) => last = OpenError::new(ErrorKind::Other, format!("{e:#}")),
                }
            }
            Err(OpenError::new(
                last.kind,
                format!(
                    "no daemon at v{} after {UPGRADE_TIMEOUT:?}; last answer: {}",
                    peer::PROTOCOL_VERSION,
                    last.detail
                ),
            ))
        });
    report("local", &answer)
}

/// `--upgrade`, then whatever follows `--`: the flags the successor daemon
/// runs with (`--listen-quic`, `--authorized-tokens`), which a supervisor
/// passes through so the replacement serves what the original did.
fn successor_flags(args: &[String]) -> Result<Vec<String>> {
    let mut flags = vec!["--upgrade".to_string()];
    match args {
        [] => {}
        [dashes, rest @ ..] if dashes == "--" => flags.extend(rest.iter().cloned()),
        [other, ..] => bail!("usage: muxd upgrade [-- daemon flags], got {other:?}"),
    }
    Ok(flags)
}

/// Print one `Probe` line for `answer` and turn it into an exit code.
fn report(alias: &str, answer: &Result<(usize, Duration), OpenError>) -> i32 {
    let line = Probe {
        alias,
        ok: answer.is_ok(),
        rtt_ms: answer.as_ref().ok().map(|(_, rtt)| rtt.as_millis()),
        ptys: answer.as_ref().ok().map(|&(ptys, _)| ptys),
        class: answer.as_ref().err().map(|e| e.kind),
        error: answer.as_ref().err().map(|e| e.detail.as_str()),
    };
    // Plain data: encoding cannot fail.
    println!("{}", serde_json::to_string(&line).unwrap_or_default());
    i32::from(answer.is_err())
}

// -------------------------------------------------------------- daemon

/// Log to stderr AND `~/.local/state/muxd/muxd.log`. The daemon runs
/// detached with stderr on /dev/null, so the file is the only record of
/// the pty lifecycle; stderr still serves foreground runs and tests. A
/// log that cannot be opened degrades to stderr-only rather than
/// refusing to serve sessions.
fn init_logging() {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    let filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into());
    let file = {
        let path = paths::daemon_log();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok()
    };
    let file_layer = file.map(|f| {
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_writer(std::sync::Mutex::new(f))
    });
    tracing_subscriber::registry()
        .with(filter)
        .with(file_layer)
        .with(tracing_subscriber::fmt::layer().with_writer(std::io::stderr))
        .init();
}

/// `--upgrade` adopts whichever daemon answers the migrate socket, then
/// binds `socket`. The two are overridden independently (`--socket` or
/// `MUXD_SOCKET`; `MUXD_MIGRATE_SOCKET`), and overriding one without the
/// other is never a sandbox, it is a stale `export MUXD_SOCKET` from a
/// harness run: the successor would take the user's ptys off the default
/// migrate socket and serve them on a path no pane dials, each pane's
/// mux-attach would reconnect on the default, find nothing, respawn an
/// empty daemon, and get a fresh shell. Either both point at a sandbox or
/// neither does.
fn check_upgrade_sockets(socket: &Path, migrate: &Path, uid: u32) -> Result<()> {
    let socket_is_default = socket == peer::socket_path(uid);
    let migrate_is_default = migrate == paths::default_migrate_socket(uid);
    if socket_is_default != migrate_is_default {
        let (which, path) = if socket_is_default {
            ("MUXD_MIGRATE_SOCKET", migrate)
        } else {
            ("MUXD_SOCKET", socket)
        };
        bail!(
            "--upgrade refused: {which} points at {} while the other socket is the per-uid default",
            path.display()
        );
    }
    Ok(())
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
    init_logging();

    // Subcommands before flags: each answers on stdout and exits.
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("client-digest") => return client_digest(),
        Some("ls") => return ls(&args[1..]),
        Some("watch") => return watch(&args[1..]),
        Some(command @ ("inspect" | "observe" | "input")) => {
            return terminal_control(command, &args[1..])
        }
        Some("close") => {
            return close(
                args.get(1)
                    .context("usage: muxd close [host|local]:<name>")?,
            )
        }
        Some("kill") => {
            return kill(
                args.get(1)
                    .context("usage: muxd kill [host|local]:<name>")?,
            )
        }
        Some("probe") => {
            let alias = args.get(1).context("usage: muxd probe <alias>")?;
            std::process::exit(probe(alias));
        }
        Some("upgrade") => std::process::exit(upgrade(&args[1..])),
        _ => {}
    }

    // The daemon must not die with a client mid-write, nor with the
    // terminal that happened to birth it.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }

    let args = parse_args()?;
    let manager = manager::Manager::default();

    // Adopt first: the predecessor owns the socket until it hands over.
    // Under systemd, say so before asking: the predecessor's exit must
    // read as the main process being replaced, not the service ending.
    if args.upgrade {
        let migrate = paths::migrate_socket();
        check_upgrade_sockets(&args.socket, &migrate, nix::unistd::getuid().as_raw())?;
        systemd::notify(&format!("MAINPID={}", std::process::id()));
        migrate::adopt_from_predecessor(&manager, &args.socket).await;
    }
    let listener = server::bind(&args.socket).await?;
    migrate::spawn_handoff_task(manager.clone());
    systemd::notify("READY=1");

    // The QUIC listener is a second door onto the same ptys: it shares
    // the manager and runs beside the socket, never instead of it. When
    // it was asked for, its death is the daemon's death: a muxd that
    // silently serves only its unix socket looks healthy to a supervisor
    // while every remote pane dials a closed port. Neither arm below can
    // answer Ok, so this exits nonzero however the listeners end, and
    // Restart=on-failure retries until the bind succeeds (in practice the
    // failure is at startup - a stale port holder - before any pty
    // exists).
    match args.listen_quic {
        Some(addr) => {
            let quic = quic::serve(manager.clone(), addr, args.authorized_tokens.as_deref());
            let unix = server::serve(manager, listener);
            tokio::select! {
                r = quic => r.context("quic listener stopped"),
                r = unix => r,
            }
        }
        None => server::serve(manager, listener).await,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_successor_runs_with_the_flags_after_the_dashes() {
        let args = |v: &[&str]| v.iter().map(ToString::to_string).collect::<Vec<_>>();
        assert_eq!(super::successor_flags(&[]).unwrap(), args(&["--upgrade"]));
        assert_eq!(
            super::successor_flags(&args(&["--", "--listen-quic", "0.0.0.0:4433"])).unwrap(),
            args(&["--upgrade", "--listen-quic", "0.0.0.0:4433"])
        );
        assert!(super::successor_flags(&args(&["--listen-quic"])).is_err());
    }

    use super::*;

    #[test]
    fn upgrade_runs_when_both_sockets_are_default_or_both_overridden() {
        let socket = peer::socket_path(501);
        let migrate = paths::default_migrate_socket(501);
        assert!(check_upgrade_sockets(&socket, &migrate, 501).is_ok());
        let sandbox = Path::new("/tmp/muxup-x/d.sock");
        let sandbox_migrate = Path::new("/tmp/muxup-x/m.sock");
        assert!(check_upgrade_sockets(sandbox, sandbox_migrate, 501).is_ok());
    }

    #[test]
    fn upgrade_refuses_one_overridden_socket_and_names_it() {
        let migrate = paths::default_migrate_socket(501);
        let err = check_upgrade_sockets(Path::new("/tmp/stale.sock"), &migrate, 501).unwrap_err();
        assert!(
            err.to_string()
                .contains("MUXD_SOCKET points at /tmp/stale.sock"),
            "{err}"
        );
        let socket = peer::socket_path(501);
        let err = check_upgrade_sockets(&socket, Path::new("/tmp/stale-m.sock"), 501).unwrap_err();
        assert!(
            err.to_string()
                .contains("MUXD_MIGRATE_SOCKET points at /tmp/stale-m.sock"),
            "{err}"
        );
    }
}
