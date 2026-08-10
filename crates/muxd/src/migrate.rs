//! Zero-downtime self-upgrade: a new muxd adopts the running one's live
//! ptys, so replacing the binary never kills a shell.
//!
//! The wire contract is `mux_proto::migrate`: one
//! `[u32 LE len][postcard MigratePayload]` message whose `SCM_RIGHTS`
//! control data carries the PTY master fds in `ptys` order. Unlike
//! upstream ix-console, the payload also carries each pty's
//! `render_screen_bytes()` snapshot, so the successor's VT starts with
//! the screen and scrollback the predecessor had instead of empty.
//!
//! Sequence:
//!
//! 1. successor (`muxd --upgrade`) binds the migration socket (0600),
//!    reads the pidfile, sends `SIGUSR1` to the predecessor;
//! 2. predecessor snapshots every pty under its VT lock, connects, sends
//!    payload + fds, and exits(0) - still holding those locks, so no read
//!    loop can consume a byte that is not in the snapshot;
//! 3. successor adopts each pty (fresh VT fed with the snapshot, the
//!    inherited master fd, same name), waits for the predecessor to go,
//!    then binds the control socket and serves.
//!
//! Clients see the predecessor's EOF and reconnect (mux-attach), which
//! reattaches by name and repaints from the migrated VT.
//!
//! `MUXD_MIGRATE_SOCKET` overrides the migration socket path; the pidfile
//! follows `HOME` (`mux_proto::paths::daemon_pid`). Both exist so a test
//! daemon can never signal, or steal the ptys of, the user's daemon.

use std::io::Write as _;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::migrate::{MigratePayload, MigratePty, MAX_MIGRATE_FDS, MIGRATE_VERSION};
use nix::sys::socket::{ControlMessage, ControlMessageOwned, MsgFlags};
use nix::unistd::Pid;
use tokio::io::{AsyncReadExt as _, Interest};
use tokio::net::{UnixListener, UnixStream};

use crate::manager::Manager;
use crate::pty;

/// Predecessor signal to payload. Generous: the predecessor only has to
/// render its screens and write one message.
const HANDOFF_TIMEOUT: Duration = Duration::from_secs(10);
/// After the payload lands, how long to wait for the predecessor to exit
/// and release the control socket.
const PREDECESSOR_EXIT_TIMEOUT: Duration = Duration::from_secs(5);
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(20);
/// A stalled successor must not freeze the predecessor's ptys (their VT
/// locks are held across the send).
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
/// Payload cap on receive; a screen snapshot per pty is well under this.
const MAX_PAYLOAD_BYTES: usize = 64 * 1024 * 1024;

/// Migration rendezvous socket. `MUXD_MIGRATE_SOCKET` overrides the
/// per-uid default so tests never touch the user's.
pub fn socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("MUXD_MIGRATE_SOCKET") {
        return PathBuf::from(path);
    }
    mux_proto::migrate::migrate_socket_path(nix::unistd::getuid().as_raw())
}

/// Publish our pid so a successor knows who to ask for a handoff.
pub fn write_pidfile() -> Result<()> {
    let path = mux_proto::paths::daemon_pid();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    std::fs::write(&path, format!("{}\n", std::process::id()))
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

fn read_pidfile() -> Option<Pid> {
    let text = std::fs::read_to_string(mux_proto::paths::daemon_pid()).ok()?;
    let pid = text.trim().parse::<i32>().ok()?;
    (pid > 1 && pid != std::process::id().cast_signed()).then(|| Pid::from_raw(pid))
}

/// `kill(pid, 0)`: EPERM still means alive, ESRCH means gone. darwin has
/// no pidfd, so liveness is polled rather than watched.
pub fn alive(pid: Pid) -> bool {
    !matches!(
        nix::sys::signal::kill(pid, None),
        Err(nix::errno::Errno::ESRCH)
    )
}

/// Is `pid` actually a daemon? A pidfile left by a crashed daemon can
/// name a pid the OS has since recycled, and `SIGUSR1`'s default action
/// is to kill: the handoff request must never reach a stranger.
fn is_muxd(pid: Pid) -> bool {
    let Some(path) = executable_of(pid) else {
        return false;
    };
    let name = std::path::Path::new(&path)
        .file_name()
        .map(std::ffi::OsStr::to_os_string);
    let ours = std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(std::ffi::OsStr::to_os_string));
    name.as_ref().is_some_and(|name| name == "muxd") || (name.is_some() && name == ours)
}

#[cfg(target_os = "macos")]
fn executable_of(pid: Pid) -> Option<String> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf is PROC_PIDPATHINFO_MAXSIZE bytes, as the call requires.
    let len = unsafe {
        libc::proc_pidpath(
            pid.as_raw(),
            buf.as_mut_ptr().cast(),
            u32::try_from(buf.len()).ok()?,
        )
    };
    if len <= 0 {
        return None;
    }
    buf.truncate(usize::try_from(len).ok()?);
    String::from_utf8(buf).ok()
}

#[cfg(not(target_os = "macos"))]
fn executable_of(pid: Pid) -> Option<String> {
    let comm = std::fs::read_to_string(format!("/proc/{}/comm", pid.as_raw())).ok()?;
    Some(comm.trim().to_string())
}

/// One pty as it arrives from the predecessor.
struct Adopted {
    pty: MigratePty,
    master: OwnedFd,
}

/// Successor side of the handoff (`muxd --upgrade`): adopt the
/// predecessor's ptys into `manager`, and do not return until the
/// predecessor has exited (it owns the control socket until then).
///
/// No predecessor, or a predecessor that never answers, is not fatal: the
/// new daemon simply starts with no ptys.
pub async fn adopt_from_predecessor(manager: &Manager) {
    let path = socket_path();
    let listener = match bind_listener(&path) {
        Ok(listener) => listener,
        Err(e) => {
            tracing::warn!(error = %format!("{e:#}"), "no migration socket; starting empty");
            return;
        }
    };

    let Some(pid) = read_pidfile().filter(|pid| alive(*pid) && is_muxd(*pid)) else {
        tracing::info!("no live predecessor; starting empty");
        let _ = std::fs::remove_file(&path);
        return;
    };

    if let Err(e) = nix::sys::signal::kill(pid, nix::sys::signal::Signal::SIGUSR1) {
        tracing::warn!(pid = pid.as_raw(), %e, "cannot signal predecessor; starting empty");
        let _ = std::fs::remove_file(&path);
        return;
    }
    tracing::info!(pid = pid.as_raw(), "asked predecessor for a handoff");

    match tokio::time::timeout(HANDOFF_TIMEOUT, receive(&listener)).await {
        Ok(Ok(adopted)) => {
            let count = adopted.len();
            for entry in adopted {
                let name = entry.pty.name.clone();
                if let Err(e) = manager.adopt(entry.pty, entry.master) {
                    tracing::warn!(name, error = %format!("{e:#}"), "failed to adopt pty");
                }
            }
            tracing::info!(count, "adopted ptys from predecessor");
        }
        Ok(Err(e)) => tracing::warn!(error = %format!("{e:#}"), "handoff failed; starting empty"),
        Err(_elapsed) => tracing::warn!("predecessor did not hand off in time; starting empty"),
    }
    let _ = std::fs::remove_file(&path);

    // The predecessor holds the control socket until it exits.
    let deadline = std::time::Instant::now() + PREDECESSOR_EXIT_TIMEOUT;
    while alive(pid) && std::time::Instant::now() < deadline {
        tokio::time::sleep(EXIT_POLL_INTERVAL).await;
    }
    if alive(pid) {
        tracing::warn!(
            pid = pid.as_raw(),
            "predecessor still running; the bind below will fail"
        );
    }
}

fn bind_listener(path: &std::path::Path) -> Result<UnixListener> {
    // Usual outcome is ENOENT; a bind that is actually blocked reports it.
    let _ = std::fs::remove_file(path);
    let listener = std::os::unix::net::UnixListener::bind(path)
        .with_context(|| format!("bind {}", path.display()))?;
    // Same auth boundary as the control socket: filesystem permissions.
    // Anyone who can connect here can hand us ptys.
    std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    UnixListener::from_std(listener).context("migration listener")
}

async fn receive(listener: &UnixListener) -> Result<Vec<Adopted>> {
    let (mut stream, _) = listener.accept().await.context("accept handoff")?;

    // The fds ride the first message; the payload may need more reads.
    let mut fds = Vec::new();
    let mut buf = loop {
        stream.readable().await?;
        match stream.try_io(Interest::READABLE, || recv_with_fds(&stream, &mut fds)) {
            Ok(data) => break data,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e).context("receive handoff"),
        }
    };
    if buf.len() < 4 {
        let mut head = [0u8; 4];
        head[..buf.len()].copy_from_slice(&buf);
        stream.read_exact(&mut head[buf.len()..]).await?;
        buf = head.to_vec();
    }
    let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    if len == 0 || len > MAX_PAYLOAD_BYTES {
        bail!("bad handoff payload length {len}");
    }
    let mut body = buf.split_off(4);
    if body.len() < len {
        let mut rest = vec![0u8; len - body.len()];
        stream.read_exact(&mut rest).await?;
        body.extend_from_slice(&rest);
    }

    let payload: MigratePayload =
        mux_proto::peer::decode(&body[..len]).context("decode payload")?;
    if payload.version != MIGRATE_VERSION {
        bail!("handoff version {} != {MIGRATE_VERSION}", payload.version);
    }
    if payload.ptys.len() != fds.len() {
        bail!(
            "handoff carried {} ptys but {} fds",
            payload.ptys.len(),
            fds.len()
        );
    }
    Ok(payload
        .ptys
        .into_iter()
        .zip(fds)
        .map(|(pty, master)| Adopted { pty, master })
        .collect())
}

/// One non-blocking `recvmsg`, appending any `SCM_RIGHTS` descriptors to
/// `fds` and returning the data bytes it carried.
fn recv_with_fds(stream: &UnixStream, fds: &mut Vec<OwnedFd>) -> std::io::Result<Vec<u8>> {
    let mut buf = vec![0u8; 64 * 1024];
    let mut cmsg = nix::cmsg_space!([RawFd; MAX_MIGRATE_FDS]);
    let mut iov = [std::io::IoSliceMut::new(&mut buf)];
    let msg = nix::sys::socket::recvmsg::<()>(
        stream.as_raw_fd(),
        &mut iov,
        Some(&mut cmsg),
        MsgFlags::empty(),
    )
    .map_err(errno_to_io)?;
    let received = msg.bytes;
    for cmsg in msg.cmsgs().map_err(errno_to_io)? {
        if let ControlMessageOwned::ScmRights(raw) = cmsg {
            for fd in raw {
                // SAFETY: an fd freshly materialized by SCM_RIGHTS; this
                // is its only owner.
                let owned = unsafe { OwnedFd::from_raw_fd(fd) };
                // SCM_RIGHTS does not carry CLOEXEC: without this the
                // adopted masters leak into every shell muxd forks later.
                let _ = nix::fcntl::fcntl(
                    owned.as_raw_fd(),
                    nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
                );
                fds.push(owned);
            }
        }
    }
    buf.truncate(received);
    Ok(buf)
}

fn errno_to_io(errno: nix::errno::Errno) -> std::io::Error {
    std::io::Error::from_raw_os_error(errno as i32)
}

/// Predecessor side: hand every live pty to the successor on `SIGUSR1`,
/// then exit so it can take the control socket.
pub fn spawn_handoff_task(manager: Manager) {
    tokio::spawn(async move {
        let mut signals =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::user_defined1()) {
                Ok(signals) => signals,
                Err(e) => {
                    tracing::error!(%e, "cannot listen for SIGUSR1; self-upgrade disabled");
                    return;
                }
            };
        while signals.recv().await.is_some() {
            match hand_off(&manager) {
                Ok(count) => {
                    tracing::info!(count, "handed off ptys; exiting for the successor");
                    std::process::exit(0);
                }
                // Keep serving: a failed upgrade must not take the ptys
                // down with it.
                Err(e) => {
                    tracing::warn!(error = %format!("{e:#}"), "handoff failed; still serving");
                }
            }
        }
    });
}

/// Snapshot + send, synchronously and without a single `.await`: every
/// pty's VT lock is held from its snapshot until the process exits, which
/// is what makes the handoff lossless (a read loop cannot drain the pty
/// into a VT nobody will ever see).
fn hand_off(manager: &Manager) -> Result<usize> {
    let sessions = manager.live_sessions();
    if sessions.len() > MAX_MIGRATE_FDS {
        bail!(
            "{} ptys exceeds the {MAX_MIGRATE_FDS} fd handoff cap",
            sessions.len()
        );
    }

    let path = socket_path();
    let stream = std::os::unix::net::UnixStream::connect(&path)
        .with_context(|| format!("connect {}", path.display()))?;
    stream.set_write_timeout(Some(SEND_TIMEOUT))?;

    let guards: Vec<_> = sessions.iter().map(|s| s.terminal.lock()).collect();
    let mut ptys = Vec::with_capacity(sessions.len());
    let mut fds: Vec<OwnedFd> = Vec::with_capacity(sessions.len());
    for (session, terminal) in sessions.iter().zip(&guards) {
        let size = pty::window_size(&session.master);
        // A duplicate, so the fd stays valid however the original is
        // dropped while the message is in flight.
        let master = session
            .master
            .get_ref()
            .try_clone()
            .context("dup pty master")?;
        ptys.push(MigratePty {
            name: session.name.clone(),
            command: session.command.clone(),
            child_pid: session.child.as_raw(),
            cols: size.cols,
            rows: size.rows,
            screen: terminal.render_screen_bytes(),
        });
        fds.push(master);
    }

    let payload = MigratePayload {
        version: MIGRATE_VERSION,
        ptys,
    };
    let body = mux_proto::peer::encode(&payload);
    let mut message = u32::try_from(body.len())
        .context("payload too large")?
        .to_le_bytes()
        .to_vec();
    message.extend_from_slice(&body);

    let raw: Vec<RawFd> = fds
        .iter()
        .map(std::os::fd::AsFd::as_fd)
        .map(|fd| fd.as_raw_fd())
        .collect();
    send_with_fds(&stream, &message, &raw)?;
    Ok(fds.len())
}

/// `sendmsg` the whole message, with the fds on the first chunk. A stream
/// socket may accept the message in pieces; the descriptors ride the
/// first one, which is what the receiver's single `recvmsg` reads.
fn send_with_fds(
    stream: &std::os::unix::net::UnixStream,
    message: &[u8],
    fds: &[RawFd],
) -> Result<()> {
    let iov = [std::io::IoSlice::new(message)];
    let cmsg = [ControlMessage::ScmRights(fds)];
    let sent =
        nix::sys::socket::sendmsg::<()>(stream.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
            .map_err(errno_to_io)
            .context("sendmsg handoff")?;
    let mut writer = stream;
    writer
        .write_all(&message[sent..])
        .context("write payload")?;
    writer.flush().context("flush payload")?;
    Ok(())
}
