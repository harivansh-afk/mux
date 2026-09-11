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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::peer::{AgentInfo, PtyEvent, PtyInfo};
use parking_lot::Mutex;
use tokio::sync::{broadcast, mpsc};

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
/// Output settles for this long before the agent detector looks at the
/// pty: once per burst, never per byte, never on a clock.
const AGENT_SETTLE: Duration = Duration::from_millis(200);
/// The screen tail the manifests read; upstream's rules look at most
/// this far up.
const AGENT_TAIL_ROWS: usize = 24;
/// Watch subscribers that fall this many events behind get a fresh
/// snapshot instead of the gap.
const EVENT_BACKLOG: usize = 256;

pub enum ClientMsg {
    Output(Vec<u8>),
    Exit(i32),
}

/// Which client is in a pty's slot. Attach evicts the previous client, so
/// two handlers exist at once for a moment: the newcomer's, and the
/// evicted one on its way out. Every release of the slot names the client
/// it means, or the loser's teardown takes the winner's channel with it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct ClientId(u64);

impl ClientId {
    /// The numeric identity, for correlating attach/detach log lines.
    pub fn raw(self) -> u64 {
        self.0
    }
}

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

pub struct AttachedClient {
    pub id: ClientId,
    pub tx: mpsc::Sender<ClientMsg>,
}

pub struct PtySession {
    pub generation: String,
    pub revision: AtomicU64,
    pub input_revision: AtomicU64,
    pub input_lock: tokio::sync::Mutex<()>,
    pub changes: tokio::sync::watch::Sender<u64>,
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
    pub close_deadline: Mutex<Option<u64>>,
    /// The detector's last reading, and the input it read, so a settled
    /// pty that wrote nothing new costs nothing.
    pub agent: Mutex<Option<AgentInfo>>,
    /// An evaluation is scheduled; output that lands meanwhile rides it.
    agent_pending: AtomicBool,
    last_event: Mutex<Option<PtyEvent>>,
}

impl PtySession {
    /// Where the user is in this pty: the working directory of its
    /// foreground process (tmux's trick - `tcgetpgrp` on the master
    /// names the foreground process group, whose leader is the shell
    /// or whatever it ran), read from the live process. The daemon owns
    /// the process, so this needs no shell integration on either end.
    #[must_use]
    pub fn current_cwd(&self) -> Option<String> {
        let pid = nix::unistd::tcgetpgrp(self.master.get_ref())
            .map_or_else(|_| self.child.as_raw(), nix::unistd::Pid::as_raw);
        process_cwd(pid).or_else(|| process_cwd(self.child.as_raw()))
    }

    /// Release the client slot, but only if `id` is still the client in
    /// it. A steal-attach installs its channel while the evicted handler
    /// is still winding down: clearing unconditionally would drop the
    /// *new* client's sender, which closes its channel and tears down the
    /// connection that just took the pty over.
    pub fn detach(&self, id: ClientId) {
        let mut client = self.client.lock();
        if client.as_ref().is_some_and(|c| c.id == id) {
            *client = None;
        }
    }

    pub fn info(&self) -> PtyInfo {
        PtyInfo {
            name: self.name.clone(),
            command: self.command.clone(),
            attached: self.client.lock().is_some(),
            exited: self.exited.load(Ordering::SeqCst),
            cwd: self.current_cwd(),
            agent: self.agent.lock().clone(),
        }
    }

    /// The watch line for this pty as it is now.
    pub fn event(&self) -> PtyEvent {
        PtyEvent {
            name: self.name.clone(),
            agent: self.agent.lock().clone(),
            cwd: self.current_cwd(),
            exited: self.exited.load(Ordering::SeqCst),
        }
    }

    /// The coding agent in the foreground, by what it was run as: the
    /// foreground process group's leader (`tcgetpgrp`), else the child.
    fn foreground_agent(&self) -> Option<agents::Agent> {
        let pid = nix::unistd::tcgetpgrp(self.master.get_ref())
            .map_or_else(|_| self.child.as_raw(), nix::unistd::Pid::as_raw);
        process_args(pid).and_then(|argv| agents::Agent::from_command(&argv))
    }

    /// Read the pty once: who is in the foreground, and what the title
    /// and the screen tail say it is doing.
    fn refresh_agent(&self) {
        let next = self.foreground_agent().map(|agent| {
            let (title, screen) = {
                let term = self.terminal.lock();
                let rows = term.row_texts();
                let tail = rows.len().saturating_sub(AGENT_TAIL_ROWS);
                (term.title().unwrap_or_default(), rows[tail..].join("\n"))
            };
            let input = agents::DetectionInput {
                screen: &screen,
                osc_title: &title,
                osc_progress: "",
            };
            let detection = agents::detect(agent, input);
            let previous = self.agent.lock();
            // A viewer over the live screen keeps the state it covers.
            let state = match detection.state {
                Some(state) => state.label(),
                None => previous
                    .as_ref()
                    .map_or(agents::AgentState::Idle.label(), |info| info.state.as_str()),
            };
            AgentInfo {
                agent: agent.label().to_string(),
                state: state.to_string(),
                topic: agents::topic(&title),
            }
        });
        *self.agent.lock() = next;
    }
}

#[derive(Clone)]
pub struct Manager {
    ptys: Arc<Mutex<HashMap<String, Arc<PtySession>>>>,
    events: broadcast::Sender<PtyEvent>,
}

impl Default for Manager {
    fn default() -> Self {
        Self {
            ptys: Arc::default(),
            events: broadcast::channel(EVENT_BACKLOG).0,
        }
    }
}

impl Manager {
    /// Every pty as one event, for a watch that just opened or fell
    /// behind, then the live feed.
    pub fn watch(&self) -> (Vec<PtyEvent>, broadcast::Receiver<PtyEvent>) {
        let rx = self.events.subscribe();
        let snapshot = self.ptys.lock().values().map(|s| s.event()).collect();
        (snapshot, rx)
    }

    fn emit(&self, session: &PtySession) {
        let mut previous = session.last_event.lock();
        let event = session.event();
        if previous.as_ref() == Some(&event) {
            return;
        }
        *previous = Some(event.clone());
        // No receivers is the common case and not an error.
        let _ = self.events.send(event);
    }

    /// Output landed: look at the pty once it settles. One evaluation
    /// per burst; bytes that arrive during the wait are read by it.
    fn schedule_agent(&self, session: &Arc<PtySession>) {
        if session.agent_pending.swap(true, Ordering::AcqRel) {
            return;
        }
        let manager = self.clone();
        let session = Arc::clone(session);
        tokio::spawn(async move {
            tokio::time::sleep(AGENT_SETTLE).await;
            session.agent_pending.store(false, Ordering::Release);
            // A pty that exited meanwhile was reported by its reaper.
            if !session.exited.load(Ordering::SeqCst) {
                session.refresh_agent();
                manager.emit(&session);
            }
        });
    }

    pub fn get(&self, name: &str) -> Option<Arc<PtySession>> {
        self.ptys.lock().get(name).cloned()
    }

    /// Reopen a closed terminal without an attach-or-create fallback.
    pub fn open_existing(&self, name: &str) -> Result<(Arc<PtySession>, bool)> {
        let session = self.get(name).filter(|s| !s.exited.load(Ordering::SeqCst));
        match session {
            Some(session) => {
                if session.close_deadline.lock().is_some() {
                    bail!("terminal is closed; use reopen within 60 seconds");
                }
                Ok((session, false))
            }
            None => {
                bail!("saved terminal {name} no longer exists; no replacement shell was started")
            }
        }
    }

    /// Every pty that has not exited: what a self-upgrade hands over.
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

    pub fn list(&self) -> Vec<mux_proto::peer::PtyInfo> {
        let mut infos: Vec<_> = self.ptys.lock().values().map(|s| s.info()).collect();
        infos.sort_by(|a, b| a.name.cmp(&b.name));
        infos
    }

    /// Build the session and put it in the table. Takes the guard the
    /// caller is already holding, never one of its own: one guard must
    /// span lookup, capacity check, spawn and insert, or two racing
    /// opens for the same name each spawn a shell and the loser is
    /// evicted from the map, leaking a process that `kill` can no longer
    /// reach. The same guard is what keeps the map inside `MAX_PTYS`.
    ///
    /// # Errors
    ///
    /// The name is taken or the pty limit is reached.
    fn insert_locked(
        ptys: &mut HashMap<String, Arc<PtySession>>,
        name: &str,
        command: Vec<String>,
        terminal: ghostty_vt::Terminal,
        master: tokio::io::unix::AsyncFd<std::os::fd::OwnedFd>,
        child: nix::unistd::Pid,
        adopted: bool,
    ) -> Result<Arc<PtySession>> {
        if ptys.contains_key(name) {
            bail!("pty {name} already exists");
        }
        if ptys.len() >= MAX_PTYS {
            bail!("pty limit reached ({MAX_PTYS})");
        }
        let session = Arc::new(PtySession {
            generation: format!("{:032x}", rand::random::<u128>()),
            revision: AtomicU64::new(0),
            input_revision: AtomicU64::new(0),
            input_lock: tokio::sync::Mutex::new(()),
            changes: tokio::sync::watch::channel(0).0,
            name: name.to_string(),
            command,
            terminal: Mutex::new(terminal),
            client: Mutex::new(None),
            master,
            child,
            adopted,
            exited: AtomicBool::new(false),
            close_deadline: Mutex::new(None),
            agent: Mutex::new(None),
            agent_pending: AtomicBool::new(false),
            last_event: Mutex::new(None),
        });
        ptys.insert(name.to_string(), session.clone());
        Ok(session)
    }

    /// Attach-or-create: the pane id is the pty name, so restore is one
    /// round trip and needs no id handoff. Fails once `MAX_PTYS` ptys
    /// are already open.
    pub fn open(
        &self,
        name: &str,
        command: &[String],
        cwd: Option<&str>,
        term: Option<&str>,
        cols: u16,
        rows: u16,
    ) -> Result<(Arc<PtySession>, bool)> {
        let mut ptys = self.ptys.lock();
        if let Some(existing) = ptys.get(name) {
            if existing.close_deadline.lock().is_some() {
                bail!("terminal is closed; use reopen within 60 seconds");
            }
            return Ok((existing.clone(), false));
        }
        // Before the fork, not only in insert_locked: a full table must
        // not cost a shell that is spawned and immediately hung up.
        if ptys.len() >= MAX_PTYS {
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
        let session = Self::insert_locked(
            &mut ptys,
            name,
            command.to_vec(),
            terminal,
            pty.master,
            pty.child,
            false,
        )?;
        drop(ptys);

        tokio::spawn(read_loop(self.clone(), session.clone()));

        tracing::info!(name, ?command, "pty created");
        Ok((session, true))
    }

    /// Take over a pty from a predecessor daemon: the inherited master fd
    /// plus a fresh VT primed with the predecessor's screen snapshot, so
    /// a reattaching client repaints exactly what it had.
    pub fn adopt(
        &self,
        pty: crate::migrate::MigratePty,
        master: std::os::fd::OwnedFd,
    ) -> Result<()> {
        self.adopt_many([(pty, master)])
    }

    /// Prepare the entire handoff before installing any read loop. A failed
    /// adoption leaves both managers and the predecessor's output untouched.
    pub fn adopt_many(
        &self,
        incoming: impl IntoIterator<Item = (crate::migrate::MigratePty, std::os::fd::OwnedFd)>,
    ) -> Result<()> {
        let mut staged = HashMap::new();
        for (pty, master) in incoming {
            crate::pty::set_nonblocking(&master).context("nonblocking master")?;
            let mut terminal =
                ghostty_vt::Terminal::new(pty.rows, pty.cols).context("terminal alloc")?;
            terminal.feed(&pty.screen);
            let master = tokio::io::unix::AsyncFd::new(master).context("AsyncFd")?;

            let deadline = pty.close_deadline;
            let session = Self::insert_locked(
                &mut staged,
                &pty.name,
                pty.command,
                terminal,
                master,
                nix::unistd::Pid::from_raw(pty.child_pid),
                true,
            )?;
            *session.close_deadline.lock() = deadline;
        }
        {
            let mut ptys = self.ptys.lock();
            if ptys.len() + staged.len() > MAX_PTYS {
                bail!("pty limit reached ({MAX_PTYS})");
            }
            for name in staged.keys() {
                if ptys.contains_key(name) {
                    bail!("pty {name} already exists");
                }
            }
            ptys.extend(
                staged
                    .iter()
                    .map(|(name, session)| (name.clone(), session.clone())),
            );
        }
        for (name, session) in staged {
            tracing::info!(name, pid = session.child.as_raw(), "pty adopted");
            tokio::spawn(read_loop(self.clone(), session.clone()));
            self.schedule_agent(&session);
            if let Some(deadline) = *session.close_deadline.lock() {
                self.schedule_close(&session, deadline);
            }
        }
        Ok(())
    }

    pub fn kill(&self, name: &str) -> bool {
        let Some(session) = self.ptys.lock().remove(name) else {
            return false;
        };
        self.kill_session(&session);
        true
    }

    fn kill_session(&self, session: &PtySession) {
        // Job control puts the foreground job in a different process group.
        if let Ok(foreground) = nix::unistd::tcgetpgrp(session.master.get_ref()) {
            if foreground.as_raw() > 0 {
                let _ = nix::sys::signal::killpg(foreground, nix::sys::signal::Signal::SIGKILL);
            }
        }
        // The child is a session leader; nuke its whole process group.
        // And the pid itself: for the moment between fork and setsid it
        // leads no group, and killpg alone answers ESRCH and leaves a
        // shell running that nothing in the table can reach any more.
        let _ = nix::sys::signal::killpg(session.child, nix::sys::signal::Signal::SIGKILL);
        let _ = nix::sys::signal::kill(session.child, nix::sys::signal::Signal::SIGKILL);
        *session.client.lock() = None;
        session.exited.store(true, Ordering::SeqCst);
        *session.agent.lock() = None;
        self.emit(session);
        tracing::info!(name = %session.name, "pty killed");
    }

    /// Only an explicit close arms this lease. Detach and app termination do not.
    pub fn close(&self, name: &str) -> Result<u64> {
        self.close_for(name, Duration::from_mins(1))
    }

    fn close_for(&self, name: &str, retention: Duration) -> Result<u64> {
        let ptys = self.ptys.lock();
        let session = ptys.get(name).context("terminal no longer exists")?;
        let mut deadline = session.close_deadline.lock();
        // Retrying an uncertain request never extends the lease.
        let expires = *deadline.get_or_insert_with(|| {
            unix_millis().saturating_add(u64::try_from(retention.as_millis()).unwrap_or(u64::MAX))
        });
        self.schedule_close(session, expires);
        Ok(expires)
    }

    fn schedule_close(&self, session: &Arc<PtySession>, deadline: u64) {
        let manager = self.clone();
        let name = session.name.clone();
        let generation = session.generation.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(
                deadline.saturating_sub(unix_millis()),
            ))
            .await;
            let session = {
                let mut ptys = manager.ptys.lock();
                let Some(session) = ptys.get(&name) else {
                    return;
                };
                if session.generation != generation
                    || *session.close_deadline.lock() != Some(deadline)
                {
                    return;
                }
                ptys.remove(&name).expect("checked session")
            };
            manager.kill_session(&session);
        });
    }

    /// Reopening is distinct from a relay reconnect, which must not cancel a close.
    pub fn reopen(&self, name: &str) -> Result<(Arc<PtySession>, bool)> {
        let ptys = self.ptys.lock();
        let session = ptys
            .get(name)
            .context("saved terminal no longer exists; no replacement shell was started")?;
        let mut deadline = session.close_deadline.lock();
        if deadline.is_some_and(|expires| expires <= unix_millis()) {
            bail!("saved terminal expired; no replacement shell was started");
        }
        *deadline = None;
        Ok((session.clone(), false))
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
        // The client's id travels with its sender, so a disconnect
        // decided on this chunk cannot land on a client that attached
        // meanwhile.
        let fed = {
            let mut term = session.terminal.lock();
            let read = guard.try_io(|fd| {
                nix::unistd::read(std::os::fd::AsRawFd::as_raw_fd(fd.get_ref()), &mut buf)
                    .map_err(|e| std::io::Error::from_raw_os_error(e as i32))
            });
            match read {
                Ok(Ok(0)) => break, // child side gone
                Ok(Ok(n)) => {
                    term.feed(&buf[..n]);
                    session.changed();
                    let client = session.client.lock();
                    Some((n, client.as_ref().map(|c| (c.id, c.tx.clone()))))
                }
                // EIO on darwin/linux when the child exits: treat as EOF.
                Ok(Err(e)) if e.raw_os_error() == Some(libc::EIO) => break,
                Ok(Err(e)) if e.kind() == std::io::ErrorKind::WouldBlock => None,
                Ok(Err(e)) => {
                    tracing::warn!(name = %session.name, error = %e, "pty read failed");
                    break;
                }
                Err(_would_block) => None,
            }
        };
        let Some((n, client)) = fed else { continue };
        // Fed or not, the screen moved: the detector looks once it settles.
        manager.schedule_agent(&session);
        let Some((id, tx)) = client else { continue };

        let send = tx.send_timeout(ClientMsg::Output(buf[..n].to_vec()), CLIENT_SEND_TIMEOUT);
        if send.await.is_err() {
            // Slow or gone: disconnect, never drop bytes silently.
            // By id: the timeout took 100ms, which is long enough for
            // another client to have stolen the slot.
            tracing::warn!(name = %session.name, "client too slow; detaching");
            session.detach(id);
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
        wait_child(pid).await
    };
    session.exited.store(true, Ordering::SeqCst);
    session.changed();
    // Nothing is in the foreground of a dead pty.
    *session.agent.lock() = None;

    // Take (not clone) the client so the last sender drops after Exit:
    // the forwarder drains remaining output, sees the channel close, and
    // ends the client connection cleanly.
    let client = session.client.lock().take();
    if let Some(client) = client {
        // Bounded, like the read path: an unbounded send on the depth-64
        // channel parks here forever behind a client that stopped
        // reading, and the removal below - the only thing that frees the
        // pty name for a reopen - would never run.
        let send = client
            .tx
            .send_timeout(ClientMsg::Exit(code), CLIENT_SEND_TIMEOUT);
        if send.await.is_err() {
            tracing::warn!(name = %session.name, "client never took the exit event");
        }
    }
    manager.remove_if_same(&session);
    manager.emit(&session);
    tracing::info!(name = %session.name, code, "pty exited");
}

/// Reap our own child without ever parking a thread indefinitely.
/// Master EOF proves the slave side closed, not that the child exited:
/// a bare blocking waitpid here could pin a blocking-pool thread
/// forever per stuck child. Poll with WNOHANG for the same grace as
/// adopted ptys; a child still alive after that has abandoned its
/// terminal and gets its group `SIGKILL`ed, after which one blocking
/// reap is guaranteed to return promptly.
async fn wait_child(pid: nix::unistd::Pid) -> i32 {
    use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
    let deadline = std::time::Instant::now() + ADOPTED_EXIT_GRACE;
    loop {
        match waitpid(pid, Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::Exited(_, code)) => return code,
            Ok(WaitStatus::Signaled(_, signal, _)) => return 128 + signal as i32,
            Err(_) => return 1,
            Ok(_) => {}
        }
        if std::time::Instant::now() >= deadline {
            // setsid at spawn makes the child its own group leader.
            let _ = nix::sys::signal::killpg(pid, nix::sys::signal::Signal::SIGKILL);
            let status = tokio::task::spawn_blocking(move || waitpid(pid, None)).await;
            return match status {
                Ok(Ok(WaitStatus::Exited(_, code))) => code,
                Ok(Ok(WaitStatus::Signaled(_, signal, _))) => 128 + signal as i32,
                _ => 1,
            };
        }
        tokio::time::sleep(ADOPTED_EXIT_POLL).await;
    }
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
    /// This attachment's identity, for [`PtySession::detach`] on the way
    /// out.
    pub id: ClientId,
    pub rx: mpsc::Receiver<ClientMsg>,
    pub dump: Vec<u8>,
}

/// Resize + install the client channel + render the reattach dump under
/// one terminal lock. See module docs for why the order is load-bearing.
pub fn attach(session: &Arc<PtySession>, cols: u16, rows: u16) -> Attachment {
    let (tx, rx) = mpsc::channel(CLIENT_CHANNEL_DEPTH);
    let id = ClientId(NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed));
    let dump = {
        let mut term = session.terminal.lock();
        term.resize(rows, cols);
        session.changed();
        let _ = pty::resize(&session.master, cols, rows);
        // Evict any previous client (its forwarder ends when tx drops)
        // and publish the new channel BEFORE rendering.
        *session.client.lock() = Some(AttachedClient { id, tx });
        term.render_screen_bytes()
    };
    Attachment { id, rx, dump }
}

/// The working directory of a live process, from the kernel.
#[cfg(target_os = "macos")]
fn process_cwd(pid: i32) -> Option<String> {
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info` and
    // returns how many it wrote; vip_path is NUL-terminated on success.
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = i32::try_from(std::mem::size_of::<libc::proc_vnodepathinfo>()).ok()?;
    let written = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    if written < size {
        return None;
    }
    // SAFETY: vip_path is NUL-terminated by the kernel.
    let path = unsafe { std::ffi::CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) };
    let path = path.to_str().ok()?;
    (!path.is_empty()).then(|| path.to_string())
}

/// The live process's arguments, including an interpreter's script name.
#[cfg(target_os = "macos")]
fn process_args(pid: i32) -> Option<Vec<String>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size: libc::size_t = 0;
    // SAFETY: a size query writes nothing but `size`.
    let probed = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if probed != 0 || size == 0 {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: the kernel writes at most `size` bytes into `buf` and
    // updates `size` to what it wrote.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    buf.truncate(size);
    // Layout: argc (int), executable path, NUL padding, argv, environment.
    // Stop at argc so environment values cannot become agent identities.
    let count = usize::try_from(i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?)).ok()?;
    let rest = buf.get(4..)?;
    let after_exec = &rest[rest.iter().position(|b| *b == 0)?..];
    let argv = &after_exec[after_exec.iter().position(|b| *b != 0)?..];
    Some(
        argv.split(|b| *b == 0)
            .take(count)
            .map(|arg| String::from_utf8_lossy(arg).into_owned())
            .collect(),
    )
}

/// The live process's arguments, from procfs.
#[cfg(target_os = "linux")]
fn process_args(pid: i32) -> Option<Vec<String>> {
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(
        cmdline
            .strip_suffix(&[0])
            .unwrap_or(&cmdline)
            .split(|b| *b == 0)
            .map(|arg| String::from_utf8_lossy(arg).into_owned())
            .collect(),
    )
}

/// The working directory of a live process, from procfs.
#[cfg(target_os = "linux")]
fn process_cwd(pid: i32) -> Option<String> {
    let path = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
    path.to_str().map(ToString::to_string)
}

/// Absolute time is used only to carry the remaining lease across a daemon handoff.
pub fn unix_millis() -> u64 {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(u64::MAX)
}

#[cfg(test)]
mod expiry_tests {
    use super::*;

    fn cat(manager: &Manager, name: &str) -> Arc<PtySession> {
        let path = std::env::var_os("PATH").expect("PATH");
        let cat = std::env::split_paths(&path)
            .map(|dir| dir.join("cat"))
            .find(|path| path.is_file())
            .expect("cat");
        manager
            .open(
                name,
                &[cat.to_string_lossy().into_owned()],
                None,
                None,
                80,
                24,
            )
            .expect("open")
            .0
    }

    async fn gone(session: &PtySession) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while crate::migrate::alive(session.child) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("child reaped");
    }

    #[tokio::test]
    async fn expiry_reaps_and_does_not_restart_on_retry() {
        let manager = Manager::default();
        let session = cat(&manager, "closed");
        let deadline = manager
            .close_for("closed", Duration::from_millis(100))
            .unwrap();
        assert_eq!(manager.close("closed").unwrap(), deadline);
        assert!(manager.open_existing("closed").is_err());
        assert!(manager.open("closed", &[], None, None, 80, 24).is_err());
        gone(&session).await;
        assert!(manager.get("closed").is_none());
        assert!(manager.reopen("closed").is_err());
    }

    #[tokio::test]
    async fn reopen_cancels_expiry_but_detach_does_not_arm_it() {
        let manager = Manager::default();
        let session = cat(&manager, "reopened");
        let attachment = attach(&session, 80, 24);
        session.detach(attachment.id);
        assert!(session.close_deadline.lock().is_none());
        manager
            .close_for("reopened", Duration::from_millis(100))
            .unwrap();
        let (reopened, created) = manager.reopen("reopened").unwrap();
        assert!(!created);
        assert!(Arc::ptr_eq(&session, &reopened));
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(manager.get("reopened").is_some());
        assert!(crate::migrate::alive(session.child));
        manager.kill("reopened");
        gone(&session).await;
    }

    #[tokio::test]
    async fn stale_expiry_cannot_kill_a_reclosed_or_replaced_terminal() {
        let manager = Manager::default();
        let original = cat(&manager, "same");
        manager
            .close_for("same", Duration::from_millis(50))
            .unwrap();
        manager.reopen("same").unwrap();
        manager
            .close_for("same", Duration::from_millis(250))
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(crate::migrate::alive(original.child));
        manager.kill("same");
        gone(&original).await;
        let replacement = cat(&manager, "same");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(crate::migrate::alive(replacement.child));
        manager.kill("same");
        gone(&replacement).await;
    }

    #[tokio::test]
    async fn adopted_expiry_keeps_the_original_deadline() {
        let old = Manager::default();
        let session = cat(&old, "adopted");
        let deadline = old
            .close_for("adopted", Duration::from_millis(100))
            .unwrap();
        let new = Manager::default();
        new.adopt(
            crate::migrate::MigratePty {
                name: session.name.clone(),
                command: session.command.clone(),
                child_pid: session.child.as_raw(),
                cols: 80,
                rows: 24,
                screen: Vec::new(),
                close_deadline: Some(deadline),
            },
            session.master.get_ref().try_clone().unwrap(),
        )
        .unwrap();
        assert_eq!(
            *new.get("adopted").unwrap().close_deadline.lock(),
            Some(deadline)
        );
        gone(&session).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(new.get("adopted").is_none());
    }
}
