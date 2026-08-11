//! mux-attach: the stdio relay every pane runs.
//!
//! libghostty's only IO backend is `exec`, so Mux.app sets each pane's
//! command to `mux-attach <target>`. libghostty forks us against a real
//! PTY; we bridge raw-mode stdio to the lane-framed protocol. That gets
//! correct key encoding, resize (winsize poll -> `ClientControl::Resize`),
//! and rendering for free, with no ghostty fork.
//!
//! Usage:
//!   mux-attach local:<name> [--cwd DIR] [-- cmd args...]   attach or create
//!   mux-attach --list                                       list ptys
//!   mux-attach --kill local:<name>                          kill a pty
//!   mux-attach probe <alias>                                check a host
//!
//! `probe` is the health check Mux.app runs per host. It relays a `List`
//! through the local daemon's broker, so one call exercises dial, pin,
//! token and protocol version end to end, and prints exactly one line of
//! JSON on stdout - exit 0 when the host answered, 1 otherwise:
//!
//! ```text
//! {"alias":"spark","ok":true,"rtt_ms":12,"ptys":2}
//! {"alias":"spark","ok":false,"class":"token-rejected","error":"..."}
//! ```
//!
//! `class` is one of `unreachable`, `pin-mismatch`, `token-rejected`,
//! `version-mismatch`, `no-host` (the alias is not in `hosts.json`) or
//! `error`. `rtt_ms` covers request to reply only, never the daemon
//! spawn that may precede it.
//!
//! Plain threads, no async: stdin pump, winsize poll (200ms - coalesces
//! during drags, same policy as ix's shell client), and the main thread
//! draining the socket to stdout. Exit code mirrors the remote process.
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
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use mux_proto::frame::{read_lane_frame, write_lane, FrameLimits};
use mux_proto::peer::{self, ClientControl, OpenMode, OpenReply, OpenRequest, Opened, ServerEvent};
use mux_proto::shell::{
    IN_LANE_CONTROL, IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT,
};

fn socket_path() -> std::path::PathBuf {
    if let Ok(path) = std::env::var("MUXD_SOCKET") {
        return path.into();
    }
    peer::socket_path(nix::unistd::getuid().as_raw())
}

/// Reconnect pacing after the daemon goes away. A successor daemon binds
/// the socket within milliseconds of the handoff, so start short.
const RECONNECT_BACKOFF: Duration = Duration::from_millis(100);
const RECONNECT_BACKOFF_MAX: Duration = Duration::from_secs(2);
const RECONNECT_GIVE_UP: Duration = Duration::from_secs(30);
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
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
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
        (
            mux_proto::shell::DEFAULT_COLS,
            mux_proto::shell::DEFAULT_ROWS,
        )
    }
}

/// Raw mode for the pane's PTY; restores termios on drop.
struct RawModeGuard {
    original: Option<libc::termios>,
}

impl RawModeGuard {
    fn enable() -> Self {
        unsafe {
            let mut original: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &raw mut original) != 0 {
                return Self { original: None };
            }
            let mut raw = original;
            libc::cfmakeraw(&raw mut raw);
            libc::tcsetattr(0, libc::TCSANOW, &raw const raw);
            Self {
                original: Some(original),
            }
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if let Some(original) = self.original {
            unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw const original) };
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
    // A subcommand, not a flag: `probe` reports through its JSON line and
    // its exit code, never through the flag parser's error path.
    if args.first().map(String::as_str) == Some("probe") {
        let alias = args.get(1).context("usage: mux-attach probe <alias>")?;
        exit(probe(alias));
    }

    let mut target: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut cwd_from: Option<String> = None;
    let mut command: Vec<String> = vec![];
    let mut list = false;
    let mut kill: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--list" => list = true,
            "--kill" => {
                i += 1;
                kill = Some(args.get(i).context("--kill needs a target")?.clone());
            }
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

    if list {
        return run_control(None, OpenMode::List);
    }
    if let Some(kill_target) = kill {
        let (kill_host, name) = parse_target(&kill_target)?;
        return run_control(kill_host, OpenMode::Kill { name });
    }

    let (host, name) = parse_target(&target.context("usage: mux-attach [host|local]:<name>")?)?;
    run_attach(&Attach {
        target: host,
        name,
        cwd,
        cwd_from,
        command,
    })
}

/// One-shot request/reply (list, kill).
fn run_control(target: Option<String>, mode: OpenMode) -> Result<()> {
    let mut stream = connect()?;
    let (cols, rows) = winsize();
    write_request(
        &mut stream,
        &OpenRequest {
            version: mux_proto::peer::PROTOCOL_VERSION,
            cols,
            rows,
            term: None,
            token: None,
            target,
            mode,
        },
    )?;
    let Some(frame) = read_lane_frame(&mut stream, FrameLimits::default())? else {
        bail!("daemon closed without a reply");
    };
    let reply: OpenReply = peer::decode(&frame.payload)?;
    match reply {
        Ok(Opened::Listed { ptys }) => {
            for p in ptys {
                println!(
                    "{}\t{}\t{}{}",
                    p.name,
                    if p.command.is_empty() {
                        "<shell>".to_string()
                    } else {
                        p.command.join(" ")
                    },
                    if p.attached { "attached" } else { "detached" },
                    if p.exited { " exited" } else { "" },
                );
            }
        }
        Ok(Opened::Killed { existed }) => {
            if !existed {
                eprintln!("no such pty");
            }
        }
        Ok(other) => bail!("unexpected reply: {other:?}"),
        Err(e) => bail!("daemon error: {e}"),
    }
    Ok(())
}

/// One line of `mux-attach probe` output. A struct, not a `json!`
/// literal: serde writes the fields in declaration order, which is the
/// order the module doc promises.
#[derive(serde::Serialize)]
struct Probe<'a> {
    alias: &'a str,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    rtt_ms: Option<u128>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ptys: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    class: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
}

/// Probe `alias` and print the result; returns the process exit code.
fn probe(alias: &str) -> i32 {
    let (listed, error) = match ask(alias) {
        Ok(listed) => (Some(listed), None),
        Err(e) => (None, Some(format!("{e:#}"))),
    };
    let result = Probe {
        alias,
        ok: error.is_none(),
        rtt_ms: listed.as_ref().map(|l| l.rtt.as_millis()),
        ptys: listed.as_ref().map(|l| l.ptys),
        class: error.as_deref().map(classify),
        error: error.as_deref(),
    };
    // The struct is plain data, so encoding cannot fail.
    println!("{}", serde_json::to_string(&result).unwrap_or_default());
    i32::from(error.is_some())
}

/// What a successful probe measured.
struct Listed {
    rtt: Duration,
    ptys: usize,
}

/// Relay a `List` to `alias` and time the round trip. Connecting is
/// outside the timing: it may spawn the local daemon, which says nothing
/// about the host being probed.
fn ask(alias: &str) -> Result<Listed> {
    let mut stream = connect()?;
    let (cols, rows) = winsize();
    let started = Instant::now();
    write_request(
        &mut stream,
        &OpenRequest {
            version: mux_proto::peer::PROTOCOL_VERSION,
            cols,
            rows,
            term: None,
            token: None,
            target: Some(alias.to_string()),
            mode: OpenMode::List,
        },
    )?;
    let Some(frame) = read_lane_frame(&mut stream, FrameLimits::default())? else {
        bail!("daemon closed without a reply");
    };
    let rtt = started.elapsed();
    match peer::decode::<OpenReply>(&frame.payload)? {
        Ok(Opened::Listed { ptys }) => Ok(Listed {
            rtt,
            ptys: ptys.len(),
        }),
        Ok(other) => bail!("unexpected reply: {other:?}"),
        // The daemon's own words, verbatim: `classify` reads them and the
        // user sees them.
        Err(message) => bail!(message),
    }
}

/// Sort a failure into the `class` Mux.app switches on.
///
/// The markers are substrings of messages produced elsewhere: "cannot
/// reach", "unknown host", "no host registry at" and "invalid host
/// alias" by muxd's broker, "host key changed for" by its TOFU verifier,
/// "authentication failed" and "protocol version mismatch" by the remote
/// daemon's admission. Order matters - the broker wraps a pin failure in
/// its own "cannot reach" context, so the specific marker has to win.
fn classify(error: &str) -> &'static str {
    const CLASSES: [(&str, &str); 7] = [
        ("host key changed for ", "pin-mismatch"),
        ("authentication failed", "token-rejected"),
        ("protocol version mismatch", "version-mismatch"),
        ("unknown host ", "no-host"),
        ("no host registry at ", "no-host"),
        ("invalid host alias ", "no-host"),
        ("cannot reach ", "unreachable"),
    ];
    CLASSES
        .iter()
        .find(|(marker, _)| error.contains(marker))
        .map_or("error", |(_, class)| class)
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
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = stream;
    }

    /// Best effort: a failed write means this socket is already gone, and
    /// the main loop's EOF is what drives the reconnect.
    fn send(&self, lane: u8, payload: &[u8]) {
        let mut guard = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(stream) = guard.as_mut() {
            if write_lane(stream, lane, payload).is_err() || stream.flush().is_err() {
                *guard = None;
            }
        }
    }

    fn shutdown_write(&self) {
        let guard = self.0.lock().unwrap_or_else(PoisonError::into_inner);
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
}

fn run_attach(attach: &Attach) -> Result<()> {
    // The first connection is the user's command: its errors print
    // normally, with no raw mode and no retry.
    let size = winsize();
    let mut stream = open_session(attach, connect()?, size)?;

    let _raw = RawModeGuard::enable();
    let uplink = Uplink::new();
    let stdin_closed = Arc::new(AtomicBool::new(false));
    // Seed the winsize poll with the size the handshake carried, not a
    // fresh read: a resize landing between the two reads would otherwise
    // never be sent, leaving the daemon pty stuck at the handshake size.
    spawn_input_threads(&uplink, &stdin_closed, size);

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
        stream = reconnect(attach, &stdin_closed)?;
    }
}

/// Handshake on an open socket and check the reply.
fn open_session(attach: &Attach, stream: UnixStream, size: (u16, u16)) -> Result<UnixStream> {
    let (cols, rows) = size;
    let mut writer = stream.try_clone()?;
    write_request(
        &mut writer,
        &OpenRequest {
            version: mux_proto::peer::PROTOCOL_VERSION,
            cols,
            rows,
            term: std::env::var("TERM").ok(),
            token: None,
            target: attach.target.clone(),
            // Same name every time: the daemon attaches us to the
            // existing pty and replays its screen.
            mode: OpenMode::Open {
                name: attach.name.clone(),
                cwd: attach.cwd.clone(),
                command: attach.command.clone(),
                cwd_from: attach.cwd_from.clone(),
            },
        },
    )?;

    let mut reader = stream;
    let Some(frame) = read_lane_frame(&mut reader, FrameLimits::default())? else {
        bail!("daemon closed during handshake");
    };
    if frame.lane != OUT_LANE_OPENED {
        bail!("unexpected first lane {}", frame.lane);
    }
    let reply: OpenReply = peer::decode(&frame.payload)?;
    if let Err(e) = reply {
        bail!("daemon error: {e}");
    }
    Ok(reader)
}

/// Wait out a daemon that went away and reattach by name.
fn reconnect(attach: &Attach, stdin_closed: &AtomicBool) -> Result<UnixStream> {
    let started = Instant::now();
    let mut backoff = RECONNECT_BACKOFF;
    loop {
        // The pane died while we were waiting: nothing left to attach to.
        if stdin_closed.load(Ordering::SeqCst) {
            exit(0);
        }
        if started.elapsed() > RECONNECT_GIVE_UP {
            bail!("muxd went away and did not come back");
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(RECONNECT_BACKOFF_MAX);

        let socket = if started.elapsed() < RESPAWN_AFTER {
            UnixStream::connect(socket_path()).ok()
        } else {
            connect().ok()
        };
        if let Some(socket) = socket {
            if let Ok(stream) = open_session(attach, socket, winsize()) {
                return Ok(stream);
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

/// Socket -> stdout for one connection.
fn pump(reader: &mut UnixStream) -> Relay {
    let mut stdout = std::io::stdout().lock();
    loop {
        // A read error mid-frame is a daemon that vanished, not a
        // protocol failure worth killing the pane over.
        let Ok(Some(frame)) = read_lane_frame(reader, FrameLimits::default()) else {
            return Relay::DaemonGone;
        };
        match frame.lane {
            OUT_LANE_OUTPUT => {
                if stdout.write_all(&frame.payload).is_err() || stdout.flush().is_err() {
                    return Relay::Exited(0);
                }
            }
            OUT_LANE_EVENTS => match peer::decode::<ServerEvent>(&frame.payload) {
                Ok(ServerEvent::Exit { code }) => return Relay::Exited(code),
                Ok(ServerEvent::Detached) => return Relay::Exited(0),
                Err(_) => {}
            },
            _ => {}
        }
    }
}

fn write_request(stream: &mut UnixStream, request: &OpenRequest) -> Result<()> {
    let bytes = peer::encode(request);
    let len = u32::try_from(bytes.len()).context("request too large")?;
    stream.write_all(&len.to_le_bytes())?;
    stream.write_all(&bytes)?;
    stream.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The inputs are the messages muxd actually produces, copied from
    /// the sites named in `classify`'s doc comment. If one of those is
    /// reworded, this test is where it shows up.
    #[test]
    fn failures_are_classified() {
        let cases = [
            (
                "spark: cannot reach spark at spark.lan:4433: resolve spark.lan:4433",
                "unreachable",
            ),
            (
                "spark: cannot reach spark at 10.0.0.1:4433: host key changed for spark: pinned sha256:A, presented sha256:B",
                "pin-mismatch",
            ),
            ("daemon error: authentication failed", "token-rejected"),
            (
                "protocol version mismatch: daemon v4, client v3 - upgrade or restart the daemon (muxd --upgrade)",
                "version-mismatch",
            ),
            (
                "spark: unknown host \"spark\" in /home/me/.config/mux/hosts.json; known hosts: box",
                "no-host",
            ),
            (
                "spark: no host registry at /home/me/.config/mux/hosts.json; add {\"spark\": {\"addr\": \"<host>:4433\"}}",
                "no-host",
            ),
            (
                "sp ark: invalid host alias \"sp ark\": letters, digits, '.', '_' and '-' only",
                "no-host",
            ),
            ("daemon closed without a reply", "error"),
        ];
        for (error, class) in cases {
            assert_eq!(classify(error), class, "{error}");
        }
    }

    /// The JSON shape is Mux.app's contract: both key sets exactly, in
    /// the order the module doc prints them.
    #[test]
    fn probe_json_is_the_documented_shape() {
        let ok = Probe {
            alias: "spark",
            ok: true,
            rtt_ms: Some(12),
            ptys: Some(2),
            class: None,
            error: None,
        };
        assert_eq!(
            serde_json::to_string(&ok).unwrap(),
            r#"{"alias":"spark","ok":true,"rtt_ms":12,"ptys":2}"#
        );

        let failed = Probe {
            alias: "spark",
            ok: false,
            rtt_ms: None,
            ptys: None,
            class: Some("token-rejected"),
            error: Some("authentication \"failed\""),
        };
        assert_eq!(
            serde_json::to_string(&failed).unwrap(),
            r#"{"alias":"spark","ok":false,"class":"token-rejected","error":"authentication \"failed\""}"#
        );
    }
}
