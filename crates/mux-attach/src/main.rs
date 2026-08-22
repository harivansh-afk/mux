//! mux-attach: the stdio relay every pane runs.
//!
//! libghostty's only IO backend is `exec`, so Mux.app sets each pane's
//! command to `mux-attach <target>`; it bridges raw-mode stdio to the
//! lane-framed protocol.
//!
//! Usage:
//!   mux-attach [host|local]:<name> [--cwd DIR] [-- cmd args...]
//!
//! Only that: asking the daemon about itself (list, kill, probe a host)
//! is `muxd`'s own job, and this binary never relays those bytes.
//!
//! `--expect-existing` marks an attach that restores a known pane: if the
//! daemon had to create the pty, a notice is written into the terminal so
//! a lost shell never masquerades as a healthy restore. Reconnects after
//! a daemon EOF always print the notice when the pty came back `created`.
//!
//! Plain threads, no async: stdin pump, winsize poll (200ms - coalesces
//! during drags), and the main thread draining the socket to stdout.
//! Exit code mirrors the remote process.
//!
//! Socket EOF is not the end: only `ServerEvent::Exit` is. A daemon that
//! goes away mid-session (a `muxd --upgrade` handoff, or a crash) is
//! waited out and reattached to by name, which replays the screen. The
//! two input threads outlive a reconnect - stdin cannot be read by two
//! threads and a thread blocked in `read` cannot be cancelled - so they
//! write through an [`Uplink`] whose socket the main loop swaps.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::exit;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, ensure, Context, Result};
use mux_proto::frame::{
    self, write_lane, IN_LANE_CONTROL, IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED,
    OUT_LANE_OUTPUT,
};
use mux_proto::peer::{self, ClientControl, OpenMode, OpenReply, OpenRequest, Opened, ServerEvent};
use nix::sys::termios;
use parking_lot::Mutex;

fn socket_path() -> std::path::PathBuf {
    std::env::var_os(peer::SOCKET_ENV).map_or_else(
        || peer::socket_path(nix::unistd::getuid().as_raw()),
        std::path::PathBuf::from,
    )
}

/// Reconnect pacing after the daemon goes away. A successor daemon binds
/// the socket within milliseconds of the handoff, so start short.
const RECONNECT_BACKOFF: Duration = Duration::from_millis(100);
const RECONNECT_BACKOFF_MAX: Duration = Duration::from_secs(2);
/// When to tell the user the wait is unusual. Never a give-up: a relay
/// that exits makes the app treat the pane as closed and erase it from
/// the layout, which turns a long daemon outage into permanent loss.
const RECONNECT_NOTIFY: Duration = Duration::from_secs(30);
/// Reconnect attempts do not spawn a daemon at first. During a handoff
/// the socket is briefly unanswered while the successor waits for the
/// predecessor to exit; a client that raced in a fresh `muxd` there would
/// bind the socket with no ptys and make the successor fail to start.
/// Past this window no handoff is in flight, so a truly dead daemon does
/// get replaced.
const RESPAWN_AFTER: Duration = Duration::from_secs(5);

/// Connect to muxd, spawning it first if the socket is dead.
fn connect() -> Result<UnixStream> {
    let path = socket_path();
    if let Ok(stream) = UnixStream::connect(&path) {
        return Ok(stream);
    }

    // Spawn the daemon beside our own binary (the app bundles both),
    // falling back to PATH.
    let muxd = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("muxd")))
        .filter(|p| p.exists())
        .unwrap_or_else(|| "muxd".into());
    let mut cmd = std::process::Command::new(muxd);
    cmd.arg("--socket")
        .arg(&path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // The daemon must outlive the pane that births it: detach it from our
    // session and controlling TTY, or the pty teardown SIGHUPs it away.
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            nix::unistd::setsid()
                .map(|_| ())
                .map_err(std::io::Error::from)
        });
    }
    cmd.spawn().context("spawn muxd")?;

    // The daemon binds quickly; a double-spawn race resolves because the
    // loser exits on "already running" and we only need the socket to
    // answer.
    for _ in 0..100 {
        std::thread::sleep(Duration::from_millis(20));
        if let Ok(stream) = UnixStream::connect(&path) {
            return Ok(stream);
        }
    }
    bail!("muxd did not come up on {}", path.display());
}

fn winsize() -> (u16, u16) {
    let mut ws = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let ok = unsafe { libc::ioctl(0, libc::TIOCGWINSZ, &raw mut ws) } == 0;
    if ok && ws.ws_col > 0 && ws.ws_row > 0 {
        (ws.ws_col, ws.ws_row)
    } else {
        (peer::DEFAULT_COLS, peer::DEFAULT_ROWS)
    }
}

/// Raw mode for the pane's PTY; restores termios on drop. `None` when
/// stdin is not a terminal, which leaves nothing to restore.
struct RawModeGuard {
    original: Option<termios::Termios>,
}

impl RawModeGuard {
    fn enable() -> Self {
        let stdin = std::io::stdin();
        let Ok(original) = termios::tcgetattr(&stdin) else {
            return Self { original: None };
        };
        let mut raw = original.clone();
        termios::cfmakeraw(&mut raw);
        let _ = termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, &raw);
        Self {
            original: Some(original),
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if let Some(original) = &self.original {
            let _ = termios::tcsetattr(std::io::stdin(), termios::SetArg::TCSANOW, original);
        }
    }
}

/// `local:<name>` or `<host-alias>:<name>`. Returns (target, name)
/// where target None = this machine. The local daemon does the remote
/// dialing (broker); mux-attach always talks to the local unix socket.
fn parse_target(target: &str) -> Result<(Option<String>, String)> {
    match target.split_once(':') {
        Some(("local", name)) if !name.is_empty() => Ok((None, name.to_string())),
        Some((host, name)) if !host.is_empty() && !name.is_empty() => {
            Ok((Some(host.to_string()), name.to_string()))
        }
        _ => bail!("target must be [host|local]:<name>, got {target:?}"),
    }
}

fn main() -> Result<()> {
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut target: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut cwd_from: Option<String> = None;
    let mut command: Vec<String> = vec![];
    let mut expect_existing = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--expect-existing" => expect_existing = true,
            "--cwd" => {
                i += 1;
                cwd = Some(args.get(i).context("--cwd needs a dir")?.clone());
            }
            "--cwd-from" => {
                i += 1;
                cwd_from = Some(args.get(i).context("--cwd-from needs a pty name")?.clone());
            }
            "--" => {
                command = args[i + 1..].to_vec();
                break;
            }
            other => target = Some(other.to_string()),
        }
        i += 1;
    }

    let (host, name) = parse_target(&target.context("usage: mux-attach [host|local]:<name>")?)?;
    run_attach(&Attach {
        target: host,
        name,
        cwd,
        cwd_from,
        command,
        expect_existing,
    })
}

/// The socket the input threads currently write to. `None` between a
/// daemon going away and the reattach completing: input during that gap
/// is dropped, the same as input typed at a pane whose daemon is wedged.
#[derive(Clone)]
struct Uplink(Arc<Mutex<Option<UnixStream>>>);

impl Uplink {
    fn new() -> Self {
        Self(Arc::new(Mutex::new(None)))
    }

    fn set(&self, stream: Option<UnixStream>) {
        *self.0.lock() = stream;
    }

    /// Best effort: a failed write means this socket is already gone, and
    /// the main loop's EOF is what drives the reconnect.
    fn send(&self, lane: u8, payload: &[u8]) {
        let mut guard = self.0.lock();
        if let Some(stream) = guard.as_mut() {
            if write_lane(stream, lane, payload).is_err() || stream.flush().is_err() {
                *guard = None;
            }
        }
    }

    fn shutdown_write(&self) {
        let guard = self.0.lock();
        if let Some(stream) = guard.as_ref() {
            let _ = stream.shutdown(std::net::Shutdown::Write);
        }
    }
}

/// Why the relay for one connection ended.
enum Relay {
    /// The remote process exited: this is our exit code too.
    Exited(i32),
    /// Socket EOF with no `Exit` event: the daemon went away (upgrade or
    /// crash) and the pty may well still be running under its successor.
    DaemonGone,
}

/// What every (re)attach handshake repeats. Unchanged across a
/// reconnect: same name means the successor daemon attaches us to the
/// same pty rather than creating one.
struct Attach {
    target: Option<String>,
    name: String,
    cwd: Option<String>,
    /// Inherit the working directory of this pty on the same daemon
    /// (the split's source pane), resolved daemon-side at create time.
    cwd_from: Option<String>,
    command: Vec<String>,
    /// This attach restores a pane the client believes exists: a
    /// `created` reply means the daemon lost it, which the user must see.
    expect_existing: bool,
}

fn run_attach(attach: &Attach) -> Result<()> {
    let size = winsize();
    let uplink = Uplink::new();
    let stdin_closed = Arc::new(AtomicBool::new(false));

    // The first connection is the user's command: for a fresh pane its
    // errors print normally, with no raw mode and no retry. A restored
    // pane is different - its relay dying makes the app treat the pane
    // as closed and erase it from the layout, so a pane that is believed
    // to exist reports the failure into its terminal and keeps trying.
    let first = connect().and_then(|stream| open_session(attach, stream, size));
    let (stream, created) = match first {
        Ok(opened) => opened,
        Err(e) if attach.expect_existing => {
            print_notice(&format!("cannot attach ({e:#}); retrying"));
            let _raw = RawModeGuard::enable();
            spawn_input_threads(&uplink, &stdin_closed, size);
            let stream = reconnect(attach, &stdin_closed);
            return relay_loop(attach, stream, &uplink, &stdin_closed);
        }
        Err(e) => return Err(e),
    };

    let _raw = RawModeGuard::enable();
    if created && attach.expect_existing {
        print_recreated_notice();
    }
    // Seed the winsize poll with the size the handshake carried, not a
    // fresh read: a resize landing between the two reads would otherwise
    // never be sent, leaving the daemon pty stuck at the handshake size.
    spawn_input_threads(&uplink, &stdin_closed, size);
    relay_loop(attach, stream, &uplink, &stdin_closed)
}

/// Pump connections until the pane's process exits (or the pane itself
/// dies). Daemon outages are waited out, never fatal.
fn relay_loop(
    attach: &Attach,
    mut stream: UnixStream,
    uplink: &Uplink,
    stdin_closed: &Arc<AtomicBool>,
) -> Result<()> {
    loop {
        uplink.set(Some(stream.try_clone()?));
        let relay = pump(&mut stream);
        uplink.set(None);
        match relay {
            Relay::Exited(code) => exit(code),
            // Our own pty died with the pane, so there is nothing left to
            // reattach: the daemon keeps the pty for the next client.
            Relay::DaemonGone if stdin_closed.load(Ordering::SeqCst) => exit(0),
            Relay::DaemonGone => {}
        }
        stream = reconnect(attach, stdin_closed);
    }
}

fn print_recreated_notice() {
    print_notice("the daemon lost this pane's shell; this is a fresh one");
}

/// One `[mux]` line into the pane's terminal, raw-mode friendly.
fn print_notice(message: &str) {
    let mut stdout = std::io::stdout().lock();
    let _ = write!(stdout, "\r\n[mux] {message}\r\n");
    let _ = stdout.flush();
}

/// Handshake on an open socket and check the reply. The flag is the
/// reply's `created`: true when the daemon had no pty by this name and
/// made one, rather than attaching to a survivor.
fn open_session(
    attach: &Attach,
    mut stream: UnixStream,
    size: (u16, u16),
) -> Result<(UnixStream, bool)> {
    let (cols, rows) = size;
    let request = OpenRequest {
        version: peer::PROTOCOL_VERSION,
        cols,
        rows,
        term: std::env::var("TERM").ok(),
        token: None,
        target: attach.target.clone(),
        // Same name every time: the daemon attaches us to the existing
        // pty and replays its screen.
        mode: OpenMode::Open {
            name: attach.name.clone(),
            cwd: attach.cwd.clone(),
            command: attach.command.clone(),
            cwd_from: attach.cwd_from.clone(),
        },
    };
    match handshake(&mut stream, &request)? {
        Opened::Attached { created, .. } => Ok((stream, created)),
        other => bail!("unexpected reply: {other:?}"),
    }
}

/// Write the request, read the reply off lane 0. The daemon's failure
/// arrives typed; the kind is what the user needs to see first.
fn handshake(stream: &mut UnixStream, request: &OpenRequest) -> Result<Opened> {
    frame::write_message(stream, &peer::encode(request))?;
    stream.flush()?;
    let Some((lane, payload)) = frame::read_lane(stream)? else {
        bail!("daemon closed during handshake");
    };
    ensure!(lane == OUT_LANE_OPENED, "unexpected first lane {lane}");
    peer::decode::<OpenReply>(&payload)?.map_err(|e| anyhow!("{e}"))
}

/// Wait out a daemon that went away and reattach by name. Waits forever:
/// exiting instead would make the app erase the pane, so a long outage
/// is announced in the terminal rather than fatal.
fn reconnect(attach: &Attach, stdin_closed: &AtomicBool) -> UnixStream {
    let started = Instant::now();
    let mut backoff = RECONNECT_BACKOFF;
    let mut notified = false;
    loop {
        // The pane died while we were waiting: nothing left to attach to.
        if stdin_closed.load(Ordering::SeqCst) {
            exit(0);
        }
        if !notified && started.elapsed() > RECONNECT_NOTIFY {
            notified = true;
            print_notice("muxd is not answering; still retrying");
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(RECONNECT_BACKOFF_MAX);

        let socket = if started.elapsed() < RESPAWN_AFTER {
            UnixStream::connect(socket_path()).ok()
        } else {
            connect().ok()
        };
        if let Some(socket) = socket {
            if let Ok((stream, created)) = open_session(attach, socket, winsize()) {
                // A reconnect always expected the pty to survive: the
                // daemon creating one means the shell was lost.
                if created {
                    print_recreated_notice();
                }
                return stream;
            }
        }
    }
}

/// stdin -> input lane, and a winsize poll -> control lane (SIGWINCH
/// coalesces during drags). Both live for the whole process and follow
/// the uplink across reconnects.
fn spawn_input_threads(uplink: &Uplink, stdin_closed: &Arc<AtomicBool>, initial: (u16, u16)) {
    {
        let uplink = uplink.clone();
        let stdin_closed = Arc::clone(stdin_closed);
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin().lock();
            let mut buf = [0u8; 4096];
            loop {
                match stdin.read(&mut buf) {
                    // EOF means our PTY died with the pane.
                    Ok(0) | Err(_) => break,
                    Ok(n) => uplink.send(IN_LANE_INPUT, &buf[..n]),
                }
            }
            stdin_closed.store(true, Ordering::SeqCst);
            uplink.shutdown_write();
        });
    }

    let uplink = uplink.clone();
    let mut last = initial;
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(200));
        let now = winsize();
        if now != last {
            last = now;
            let control = ClientControl::Resize {
                cols: now.0,
                rows: now.1,
            };
            uplink.send(IN_LANE_CONTROL, &peer::encode(&control));
        }
    });
}

fn pump(reader: &mut UnixStream) -> Relay {
    let mut stdout = std::io::stdout().lock();
    loop {
        // A read error mid-frame is a daemon that vanished, not a
        // protocol failure worth killing the pane over.
        let Ok(Some((lane, payload))) = frame::read_lane(reader) else {
            return Relay::DaemonGone;
        };
        match lane {
            OUT_LANE_OUTPUT => {
                if stdout.write_all(&payload).is_err() || stdout.flush().is_err() {
                    return Relay::Exited(0);
                }
            }
            OUT_LANE_EVENTS => match peer::decode::<ServerEvent>(&payload) {
                Ok(ServerEvent::Exit { code }) => return Relay::Exited(code),
                Err(_) => {}
            },
            _ => {}
        }
    }
}
