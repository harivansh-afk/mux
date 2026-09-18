//! Non-attaching terminal control. Output has one reader, in manager.rs;
//! observers receive coalesced snapshots and never backpressure that reader.
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::{
    frame,
    peer::{self, ErrorKind, OpenError, OpenMode, Opened, PtyInput, PtySnapshot},
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::{manager::PtySession, pty, server};

pub const MAX_INPUT_BYTES: usize = 8192;

impl PtySession {
    /// Call with the terminal lock held when changing the viewport.
    pub fn changed(&self) {
        self.revision.fetch_add(1, Ordering::SeqCst);
        self.notify_observers();
    }

    /// Snapshot metadata can change without new terminal output.
    pub fn notify_observers(&self) {
        self.changes.send_replace(());
    }

    fn advance_input(&self) -> u64 {
        let revision = self.input_revision.fetch_add(1, Ordering::SeqCst) + 1;
        self.notify_observers();
        revision
    }

    pub fn snapshot(&self) -> PtySnapshot {
        let term = self.terminal.lock();
        let (cols, rows) = term.size();
        let cursor = term.cursor_position();
        PtySnapshot {
            name: self.name.clone(),
            generation: self.generation.clone(),
            revision: self.revision.load(Ordering::SeqCst),
            input_revision: self.input_revision.load(Ordering::SeqCst),
            pid: self.child.as_raw(),
            foreground_pgid: nix::unistd::tcgetpgrp(self.master.get_ref())
                .ok()
                .map(nix::unistd::Pid::as_raw)
                .filter(|pid| *pid > 0),
            cols,
            rows,
            cursor_row: cursor.row,
            cursor_col: cursor.col,
            text: term.row_texts(),
            cwd: self.current_cwd(),
            agent: self.agent.lock().clone(),
            exited: self.exited.load(Ordering::SeqCst),
        }
    }

    /// Interactive and automation writes share this lock, including partial writes.
    pub async fn write_input(&self, data: &[u8]) -> Result<()> {
        let _guard = self.input_lock.lock().await;
        self.advance_input();
        pty::write_all(&self.master, data).await
    }

    pub async fn checked_input(&self, input: &PtyInput) -> Result<u64> {
        if input.data.is_empty() || input.data.len() > MAX_INPUT_BYTES {
            bail!("input must contain 1..={MAX_INPUT_BYTES} bytes");
        }
        let _guard = self.input_lock.lock().await;
        let foreground = nix::unistd::tcgetpgrp(self.master.get_ref())?.as_raw();
        if foreground <= 0
            || self.generation != input.generation
            || self.exited.load(Ordering::SeqCst)
            || self.revision.load(Ordering::SeqCst) != input.revision
            || self.input_revision.load(Ordering::SeqCst) != input.input_revision
            || foreground != input.foreground_pgid
        {
            bail!("terminal changed since inspection; inspect again before submitting input");
        }
        // Advance before writing: even a partially failed write must never be replayed.
        let revision = self.advance_input();
        pty::write_all(&self.master, &input.data)
            .await
            .context("input write failed; delivery may be partial; do not retry")?;
        Ok(revision)
    }
}

pub async fn handle<R, W>(
    session: Arc<PtySession>,
    mode: OpenMode,
    mut reader: R,
    mut writer: W,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    match mode {
        OpenMode::Inspect { .. } => {
            server::reply(
                &mut writer,
                &Ok(Opened::Inspected {
                    snapshot: session.snapshot(),
                }),
            )
            .await
        }
        OpenMode::Input { input, .. } => {
            // A stalled terminal cannot keep a control request open indefinitely.
            let result =
                tokio::time::timeout(Duration::from_secs(2), session.checked_input(&input)).await;
            let reply = match result {
                Ok(Ok(input_revision)) => Ok(Opened::InputWritten {
                    bytes: input.data.len(),
                    input_revision,
                }),
                Ok(Err(e)) => Err(OpenError::new(ErrorKind::Other, format!("{e:#}"))),
                Err(_) => Err(OpenError::new(
                    ErrorKind::Other,
                    "input timed out; delivery may be partial; do not retry",
                )),
            };
            server::reply(&mut writer, &reply).await
        }
        OpenMode::Observe { .. } => {
            let mut changes = session.changes.subscribe();
            server::reply(&mut writer, &Ok(Opened::Observing)).await?;
            let mut sink = [0u8; 1];
            loop {
                changes.borrow_and_update();
                let snapshot = session.snapshot();
                let send = async {
                    frame::aio::write_lane(
                        &mut writer,
                        frame::OUT_LANE_EVENTS,
                        &peer::encode(&snapshot),
                    )
                    .await?;
                    writer.flush().await
                };
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(2), send) => { result??; },
                    _ = reader.read(&mut sink) => return Ok(()),
                }
                if snapshot.exited {
                    return Ok(());
                }
                tokio::select! {
                    notification = changes.changed() => { if notification.is_err() { return Ok(()); } },
                    _ = reader.read(&mut sink) => return Ok(()),
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
        _ => bail!("not a terminal control request"),
    }
}
