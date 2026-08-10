//! mux-attach: the stdio relay every pane runs.
//!
//! libghostty's only IO backend is `exec`, so Mux.app sets each pane's
//! command to `mux-attach <target>`. libghostty forks us against a real
//! PTY; we bridge raw-mode stdio to the lane-framed protocol. That gets
//! correct key encoding, resize (winsize poll -> ClientControl::Resize),
//! and rendering for free, with no ghostty fork.
//!
//! Usage:
//!   mux-attach local:<name> [--cwd DIR] [-- cmd args...]   attach or create
//!   mux-attach --list                                       list ptys
//!   mux-attach --kill local:<name>                          kill a pty
//!
//! Plain threads, no async: stdin pump, winsize poll (200ms - coalesces
//! during drags, same policy as ix's shell client), and the main thread
//! draining the socket to stdout. Exit code mirrors the remote process.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::exit;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::frame::{read_lane_frame, write_lane, FrameLimits};
use mux_proto::peer::{
    self, ClientControl, OpenMode, OpenReply, OpenRequest, Opened, ServerEvent,
};
use mux_proto::shell::{IN_LANE_CONTROL, IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT};

fn socket_path() -> std::path::PathBuf {
    if let Ok(path) = std::env::var("MUXD_SOCKET") {
        return path.into();
    }
    peer::socket_path(nix::unistd::getuid().as_raw())
}

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
    let mut ws = libc::winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    let ok = unsafe { libc::ioctl(0, libc::TIOCGWINSZ, &mut ws) } == 0;
    if ok && ws.ws_col > 0 && ws.ws_row > 0 {
        (ws.ws_col, ws.ws_row)
    } else {
        (mux_proto::shell::DEFAULT_COLS, mux_proto::shell::DEFAULT_ROWS)
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
            if libc::tcgetattr(0, &mut original) != 0 {
                return Self { original: None };
            }
            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(0, libc::TCSANOW, &raw);
            Self { original: Some(original) }
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if let Some(original) = self.original {
            unsafe { libc::tcsetattr(0, libc::TCSANOW, &original) };
        }
    }
}

fn parse_target(target: &str) -> Result<String> {
    match target.split_once(':') {
        Some(("local", name)) if !name.is_empty() => Ok(name.to_string()),
        _ => bail!("target must be local:<name>, got {target:?}"),
    }
}

fn main() -> Result<()> {
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut target: Option<String> = None;
    let mut cwd: Option<String> = None;
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
            "--" => {
                command = args[i + 1..].to_vec();
                break;
            }
            other => target = Some(other.to_string()),
        }
        i += 1;
    }

    if list {
        return run_control(OpenMode::List);
    }
    if let Some(kill_target) = kill {
        let name = parse_target(&kill_target)?;
        return run_control(OpenMode::Kill { name });
    }

    let name = parse_target(&target.context("usage: mux-attach local:<name>")?)?;
    run_attach(name, cwd, command)
}

/// One-shot request/reply (list, kill).
fn run_control(mode: OpenMode) -> Result<()> {
    let mut stream = connect()?;
    let (cols, rows) = winsize();
    write_request(&mut stream, &OpenRequest { cols, rows, term: None, mode })?;
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
                    if p.command.is_empty() { "<shell>".to_string() } else { p.command.join(" ") },
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

fn run_attach(name: String, cwd: Option<String>, command: Vec<String>) -> Result<()> {
    let stream = connect()?;
    let writer = stream.try_clone()?;
    let mut reader = stream;

    let (cols, rows) = winsize();
    let mut handshake_writer = writer.try_clone()?;
    write_request(&mut handshake_writer, &OpenRequest {
        cols,
        rows,
        term: std::env::var("TERM").ok(),
        mode: OpenMode::Open { name, cwd, command },
    })?;

    // Reply first; errors print like a normal command, no raw mode yet.
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

    let _raw = RawModeGuard::enable();

    // stdin -> socket (input lane). EOF means our PTY died with the pane.
    {
        let mut writer = writer.try_clone()?;
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin().lock();
            let mut buf = [0u8; 4096];
            loop {
                match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if write_lane(&mut writer, IN_LANE_INPUT, &buf[..n]).is_err() {
                            break;
                        }
                        if writer.flush().is_err() {
                            break;
                        }
                    }
                }
            }
            let _ = writer.shutdown(std::net::Shutdown::Write);
        });
    }

    // Winsize poll -> control lane (SIGWINCH coalesces during drags).
    {
        let mut writer = writer.try_clone()?;
        let mut last = (cols, rows);
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(200));
            let now = winsize();
            if now != last {
                last = now;
                let control = ClientControl::Resize { cols: now.0, rows: now.1 };
                if write_lane(&mut writer, IN_LANE_CONTROL, &peer::encode(&control)).is_err() {
                    break;
                }
                let _ = writer.flush();
            }
        });
    }

    // Socket -> stdout; events decide the exit code.
    let mut stdout = std::io::stdout().lock();
    let mut exit_code = 0;
    while let Some(frame) = read_lane_frame(&mut reader, FrameLimits::default())? {
        match frame.lane {
            OUT_LANE_OUTPUT => {
                stdout.write_all(&frame.payload)?;
                stdout.flush()?;
            }
            OUT_LANE_EVENTS => match peer::decode::<ServerEvent>(&frame.payload) {
                Ok(ServerEvent::Exit { code }) => exit_code = code,
                Ok(ServerEvent::Detached) => exit_code = 0,
                Err(_) => {}
            },
            _ => {}
        }
    }

    drop(stdout);
    exit(exit_code);
}

fn write_request(stream: &mut UnixStream, request: &OpenRequest) -> Result<()> {
    let bytes = peer::encode(request);
    stream.write_all(&(bytes.len() as u32).to_le_bytes())?;
    stream.write_all(&bytes)?;
    stream.flush()?;
    Ok(())
}
