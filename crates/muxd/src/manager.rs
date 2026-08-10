//! Pty session manager. Fork of ix-console's manager.rs / pty/io.rs /
//! session/attach.rs, with two upstream bugs fixed:
//!
//! 1. The attach race: upstream renders the reattach dump, releases the
//!    terminal lock, and only later installs the client channel - bytes
//!    fed in between are silently dropped for the client and the two VTs
//!    diverge (ix test `missed_output_causes_divergence` proves it). Here
//!    the channel is installed and the dump rendered under ONE terminal
//!    lock, and the read loop resolves the client sender while holding
//!    that same lock: every chunk is either in the dump or delivered.
//! 2. Slow clients are disconnected (bounded channel + send timeout),
//!    never silently skipped.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use parking_lot::Mutex;
use tokio::sync::mpsc;

use crate::pty;

/// Matches ix: a client that can't accept output within this window is
/// disconnected rather than fed a gappy stream.
const CLIENT_SEND_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_PTYS: usize = 256;
const READ_CHUNK: usize = 4096;
/// Client channel depth (chunks), matching ix.
const CLIENT_CHANNEL_DEPTH: usize = 64;
/// How long an adopted child is given to disappear after its pty EOFs
/// before the exit is reported anyway (see [`wait_adopted`]).
const ADOPTED_EXIT_GRACE: Duration = Duration::from_secs(2);
const ADOPTED_EXIT_POLL: Duration = Duration::from_millis(20);

pub enum ClientMsg {
    Output(Vec<u8>),
    Exit(i32),
}

pub struct AttachedClient {
    pub tx: mpsc::Sender<ClientMsg>,
}

pub struct PtySession {
    pub name: String,
    pub command: Vec<String>,
    pub terminal: Mutex<ghostty_vt::Terminal>,
    pub client: Mutex<Option<AttachedClient>>,
    pub master: tokio::io::unix::AsyncFd<std::os::fd::OwnedFd>,
    pub child: nix::unistd::Pid,
    /// Inherited from a predecessor daemon (migrate.rs), so the child is
    /// not ours: `waitpid` answers ECHILD and the exit is observed
    /// instead of reaped. See [`wait_adopted`].
    pub adopted: bool,
    pub exited: AtomicBool,
    pub exit_code: AtomicI32,
}

impl PtySession {
    pub fn info(&self) -> mux_proto::peer::PtyInfo {
        mux_proto::peer::PtyInfo {
            name: self.name.clone(),
            command: self.command.clone(),
            attached: self.client.lock().is_some(),
            exited: self.exited.load(Ordering::SeqCst),
        }
    }
}

#[derive(Default, Clone)]
pub struct Manager {
    ptys: Arc<Mutex<HashMap<String, Arc<PtySession>>>>,
}

impl Manager {
    #[must_use]
    pub fn get(&self, name: &str) -> Option<Arc<PtySession>> {
        self.ptys.lock().get(name).cloned()
    }

    /// Every pty that has not exited: what a self-upgrade hands over.
    #[must_use]
    pub fn live_sessions(&self) -> Vec<Arc<PtySession>> {
        let mut sessions: Vec<_> = self
            .ptys
            .lock()
            .values()
            .filter(|s| !s.exited.load(Ordering::SeqCst))
            .cloned()
            .collect();
        sessions.sort_by(|a, b| a.name.cmp(&b.name));
        sessions
    }

    #[must_use]
    pub fn list(&self) -> Vec<mux_proto::peer::PtyInfo> {
        let mut infos: Vec<_> = self.ptys.lock().values().map(|s| s.info()).collect();
        infos.sort_by(|a, b| a.name.cmp(&b.name));
        infos
    }

    /// Attach-or-create: the pane id is the pty name, so restore is one
    /// round trip and needs no id handoff.
    ///
    /// # Errors
    ///
    /// The pty limit is reached, or the pty/terminal could not be
    /// allocated.
    pub fn open(
        &self,
        name: &str,
        command: &[String],
        cwd: Option<&str>,
        term: Option<&str>,
        cols: u16,
        rows: u16,
    ) -> Result<(Arc<PtySession>, bool)> {
        if let Some(existing) = self.get(name) {
            return Ok((existing, false));
        }
        if self.ptys.lock().len() >= MAX_PTYS {
            bail!("pty limit reached ({MAX_PTYS})");
        }

        let pty = pty::spawn(&pty::Spawn {
            command,
            cwd,
            term,
            cols,
            rows,
        })
        .context("spawn pty")?;
        let terminal = ghostty_vt::Terminal::new(rows, cols).context("terminal alloc")?;
        let session = Arc::new(PtySession {
            name: name.to_string(),
            command: command.to_vec(),
            terminal: Mutex::new(terminal),
            client: Mutex::new(None),
            master: pty.master,
            child: pty.child,
            adopted: false,
            exited: AtomicBool::new(false),
            exit_code: AtomicI32::new(0),
        });
        self.ptys.lock().insert(name.to_string(), session.clone());

        tokio::spawn(read_loop(self.clone(), session.clone()));

        tracing::info!(name, ?command, "pty created");
        Ok((session, true))
    }

    /// Take over a pty from a predecessor daemon: the inherited master fd
    /// plus a fresh VT primed with the predecessor's screen snapshot, so
    /// a reattaching client repaints exactly what it had.
    ///
    /// # Errors
    ///
    /// A pty of that name already exists, or the fd/terminal could not be
    /// prepared.
    pub fn adopt(
        &self,
        pty: mux_proto::migrate::MigratePty,
        master: std::os::fd::OwnedFd,
    ) -> Result<()> {
        if self.get(&pty.name).is_some() {
            bail!("pty {} already exists", pty.name);
        }
        crate::pty::set_nonblocking(&master).context("nonblocking master")?;
        let mut terminal =
            ghostty_vt::Terminal::new(pty.rows, pty.cols).context("terminal alloc")?;
        terminal.feed(&pty.screen);
        let session = Arc::new(PtySession {
            name: pty.name.clone(),
            command: pty.command,
            terminal: Mutex::new(terminal),
            client: Mutex::new(None),
            master: tokio::io::unix::AsyncFd::new(master).context("AsyncFd")?,
            child: nix::unistd::Pid::from_raw(pty.child_pid),
            adopted: true,
            exited: AtomicBool::new(false),
            exit_code: AtomicI32::new(0),
        });
        self.ptys.lock().insert(pty.name.clone(), session.clone());

        tokio::spawn(read_loop(self.clone(), session));

        tracing::info!(name = pty.name, pid = pty.child_pid, "pty adopted");
        Ok(())
    }

    pub fn kill(&self, name: &str) -> bool {
        let Some(session) = self.ptys.lock().remove(name) else {
            return false;
        };
        // The child is a session leader; nuke its whole process group.
        let _ = nix::sys::signal::killpg(session.child, nix::sys::signal::Signal::SIGKILL);
        *session.client.lock() = None;
        tracing::info!(name, "pty killed");
        true
    }

    fn remove_if_same(&self, session: &Arc<PtySession>) {
        let mut ptys = self.ptys.lock();
        if let Some(current) = ptys.get(&session.name) {
            if Arc::ptr_eq(current, session) {
                ptys.remove(&session.name);
            }
        }
    }
}

/// Outcome of one readiness turn of the read loop.
enum Step {
    /// `n` bytes were fed to the VT; `tx` is the client to forward to.
    Fed(usize, Option<mpsc::Sender<ClientMsg>>),
    Retry,
    Eof,
    Failed(std::io::Error),
}

/// PTY -> terminal + attached client. One task per pty for its lifetime;
/// when the PTY EOFs it reaps the child and propagates the exit, so the
/// client always sees all output BEFORE the exit event.
async fn read_loop(manager: Manager, session: Arc<PtySession>) {
    let mut buf = [0u8; READ_CHUNK];
    loop {
        let Ok(mut guard) = session.master.readable().await else {
            break;
        };
        // Read, feed the VT and resolve the client under ONE terminal
        // lock. Feed+resolve is the attach race fix (see module docs);
        // including the read is what makes a self-upgrade lossless: the
        // handoff snapshots every VT while holding these locks, so no
        // byte can leave the pty for a VT that is about to be discarded.
        let step = {
            let mut term = session.terminal.lock();
            let read = guard.try_io(|fd| {
                nix::unistd::read(std::os::fd::AsRawFd::as_raw_fd(fd.get_ref()), &mut buf)
                    .map_err(|e| std::io::Error::from_raw_os_error(e as i32))
            });
            match read {
                Ok(Ok(0)) => Step::Eof, // child side gone
                Ok(Ok(n)) => {
                    term.feed(&buf[..n]);
                    Step::Fed(n, session.client.lock().as_ref().map(|c| c.tx.clone()))
                }
                // EIO on darwin/linux when the child exits: treat as EOF.
                Ok(Err(e)) if e.raw_os_error() == Some(libc::EIO) => Step::Eof,
                Ok(Err(e)) if e.kind() == std::io::ErrorKind::WouldBlock => Step::Retry,
                Ok(Err(e)) => Step::Failed(e),
                Err(_would_block) => Step::Retry,
            }
        };
        match step {
            Step::Fed(n, Some(tx)) => {
                let send =
                    tx.send_timeout(ClientMsg::Output(buf[..n].to_vec()), CLIENT_SEND_TIMEOUT);
                if send.await.is_err() {
                    // Slow or gone: disconnect, never drop bytes silently.
                    tracing::warn!(name = %session.name, "client too slow; detaching");
                    *session.client.lock() = None;
                }
            }
            Step::Fed(_, None) | Step::Retry => {}
            Step::Eof => break,
            Step::Failed(e) => {
                tracing::warn!(name = %session.name, error = %e, "pty read failed");
                break;
            }
        }
    }
    reap(manager, session).await;
}

/// waitpid the child, record the exit, tell the client, drop the pty.
/// Content does not outlive the process: a dead shell has nothing to
/// reattach to, and the app closes the pane on Exit.
async fn reap(manager: Manager, session: Arc<PtySession>) {
    let pid = session.child;
    let code = if session.adopted {
        wait_adopted(pid).await
    } else {
        let status = tokio::task::spawn_blocking(move || nix::sys::wait::waitpid(pid, None)).await;
        match status {
            Ok(Ok(nix::sys::wait::WaitStatus::Exited(_, code))) => code,
            Ok(Ok(nix::sys::wait::WaitStatus::Signaled(_, signal, _))) => 128 + signal as i32,
            _ => 1,
        }
    };
    session.exit_code.store(code, Ordering::SeqCst);
    session.exited.store(true, Ordering::SeqCst);

    // Take (not clone) the client so the last sender drops after Exit:
    // the forwarder drains remaining output, sees the channel close, and
    // ends the client connection cleanly.
    let client = session.client.lock().take();
    if let Some(client) = client {
        let _ = client.tx.send(ClientMsg::Exit(code)).await;
    }
    manager.remove_if_same(&session);
    tracing::info!(name = %session.name, code, "pty exited");
}

/// An adopted child (migrate.rs) belongs to a daemon that is gone, so
/// `waitpid` answers ECHILD and darwin offers no pidfd: its exit is
/// observed, not reaped. The PTY already reported EOF, which means the
/// slave side closed; wait briefly for the pid itself to disappear (init
/// reaps the reparented child) and report 0, because a foreign child's
/// status is genuinely unknowable.
async fn wait_adopted(pid: nix::unistd::Pid) -> i32 {
    let deadline = std::time::Instant::now() + ADOPTED_EXIT_GRACE;
    while std::time::Instant::now() < deadline {
        if !crate::migrate::alive(pid) {
            break;
        }
        tokio::time::sleep(ADOPTED_EXIT_POLL).await;
    }
    0
}

/// Everything attach needs to hand back to the connection handler.
pub struct Attachment {
    pub rx: mpsc::Receiver<ClientMsg>,
    pub dump: Vec<u8>,
}

/// Resize + install the client channel + render the reattach dump under
/// one terminal lock. See module docs for why the order is load-bearing.
pub fn attach(session: &Arc<PtySession>, cols: u16, rows: u16) -> Attachment {
    let (tx, rx) = mpsc::channel(CLIENT_CHANNEL_DEPTH);
    let dump = {
        let mut term = session.terminal.lock();
        term.resize(rows, cols);
        let _ = pty::resize(&session.master, cols, rows);
        // Evict any previous client (its forwarder ends when tx drops)
        // and publish the new channel BEFORE rendering.
        *session.client.lock() = Some(AttachedClient { tx });
        term.render_screen_bytes()
    };
    Attachment { rx, dump }
}
