//! Per-connection protocol handling and the unix-socket listener. Fork
//! of ix-console's server.rs/session.rs dispatch skeleton: [u32 len]
//! [request] handshake, then lane frames.
//!
//! The handler is transport-generic: a unix stream and one QUIC
//! bidirectional stream run the identical protocol, and differ only in
//! the [`Policy`] that decides who is let in.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::frame::{
    self, IN_LANE_CONTROL, IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT,
};
use mux_proto::peer::{
    self, ClientControl, ErrorKind, OpenError, OpenMode, OpenReply, OpenRequest, Opened,
    ServerEvent,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufWriter};
use tokio::net::{UnixListener, UnixStream};

use crate::manager::{self, ClientMsg, Manager, PtySession};
use crate::{broker, pty, tls};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Pause after a transient accept failure. The connection that provoked
/// it stays in the backlog, so the listener is still readable and the
/// next call fails identically: without a pause the loop would spin a
/// core until the pressure lifts.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

/// Admission rules, one per transport.
pub enum Policy {
    /// Unix socket: the 0600 socket file is the auth boundary, so no
    /// token. Requests may name a remote `target` for the broker to
    /// relay (M3).
    Local,
    /// QUIC: every request carries a bearer token this daemon admits,
    /// and none relays onward - dialing peers is the *local* daemon's
    /// job, so panes never touch the network themselves.
    Remote { admitted: tls::Admitted },
}

impl Policy {
    /// The error goes back to the client as the failed `OpenReply`.
    fn admit(&self, request: &OpenRequest) -> Result<(), OpenError> {
        match self {
            // The 0600 socket is the auth boundary, and requests naming a
            // remote target were handed to the broker before admission.
            Self::Local => Ok(()),
            Self::Remote { admitted } => {
                // Digests, not the secrets: fixed-size and preimage
                // resistant, so a short circuit leaks nothing useful.
                let presented = request.token.as_deref().map(tls::digest);
                if !presented.is_some_and(|d| admitted.contains(&d)) {
                    return Err(OpenError::new(
                        ErrorKind::TokenRejected,
                        "authentication failed",
                    ));
                }
                if let Some(host) = &request.target {
                    return Err(OpenError::new(
                        ErrorKind::Other,
                        format!("target {host:?} rejected: a remote daemon does not relay"),
                    ));
                }
                Ok(())
            }
        }
    }
}

/// Take the control socket. Owning it is what makes this daemon the one
/// a successor asks for a handoff (see `migrate.rs`). Fails when another
/// daemon already owns it.
pub async fn bind(socket: &std::path::Path) -> Result<UnixListener> {
    // A live daemon on the socket wins; a stale file is replaced.
    if UnixStream::connect(socket).await.is_ok() {
        bail!("muxd already running on {}", socket.display());
    }
    let _ = std::fs::remove_file(socket);
    let listener =
        UnixListener::bind(socket).with_context(|| format!("bind {}", socket.display()))?;
    std::fs::set_permissions(socket, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    tracing::info!(socket = %socket.display(), "muxd listening");
    Ok(listener)
}

/// Serve the control socket forever. Only a listener that has stopped
/// being a listener ends this.
pub async fn serve(manager: Manager, listener: UnixListener) -> Result<()> {
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            // Running out of descriptors, or a client that hung up
            // between connect and accept, is a bad moment - never a
            // reason to take every live session down with the daemon.
            Err(e) if transient(&e) => {
                tracing::warn!(error = %e, "accept failed; retrying");
                tokio::time::sleep(ACCEPT_BACKOFF).await;
                continue;
            }
            Err(e) => return Err(e).context("accept on the control socket"),
        };
        let manager = manager.clone();
        tokio::spawn(async move {
            let (reader, writer) = stream.into_split();
            let served = handle_connection(manager, reader, writer, &Policy::Local).await;
            if let Err(e) = served {
                tracing::debug!(error = %e, "connection ended with error");
            }
        });
    }
}

/// An accept failure that describes the moment, not the listener:
/// resource pressure (descriptors, memory, socket buffers), an
/// interrupted call, or a peer that vanished before it could be accepted.
/// Anything else says the socket itself is broken, and retrying it would
/// spin forever instead of letting the supervisor restart the daemon.
fn transient(e: &std::io::Error) -> bool {
    matches!(
        e.raw_os_error(),
        Some(
            libc::EMFILE
                | libc::ENFILE
                | libc::ENOBUFS
                | libc::ENOMEM
                | libc::ECONNABORTED
                | libc::ECONNRESET
                | libc::EINTR
                | libc::ETIMEDOUT
        )
    )
}

/// One run of the protocol over any byte stream: handshake, then either
/// a one-shot reply (list, kill, rejection) or an attached session.
pub async fn handle_connection<R, W>(
    manager: Manager,
    mut reader: R,
    writer: W,
    policy: &Policy,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let mut writer = BufWriter::new(writer);
    let handshake = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_request(&mut reader))
        .await
        .context("handshake timeout")??;

    // A mismatched client gets a readable diagnosis, not a dropped socket.
    let request = match handshake {
        Ok(request) => request,
        Err(version) => {
            let detail = format!(
                "protocol version mismatch: daemon v{}, client v{version} - upgrade or restart the daemon (muxd --upgrade)",
                peer::PROTOCOL_VERSION,
            );
            tracing::warn!(detail, "handshake rejected");
            let error = OpenError::new(ErrorKind::VersionMismatch, detail);
            return reply(&mut writer, &Err(error)).await;
        }
    };

    // Admission first, unconditionally: relayed requests must never skip
    // a future Policy::Local check by taking the broker branch early.
    if let Err(error) = policy.admit(&request) {
        tracing::debug!(detail = error.detail, "request rejected");
        return reply(&mut writer, &Err(error)).await;
    }
    // target = Some(host) on the unix socket: this daemon is the broker,
    // not the server - the whole connection goes out over the per-host
    // QUIC link. (Remote policy already refused targets in admit; the
    // guard is defense in depth.)
    if request.target.is_some() && matches!(policy, Policy::Local) {
        return broker::relay(request, reader, writer).await;
    }

    match request.mode {
        OpenMode::List => {
            return reply(
                &mut writer,
                &Ok(Opened::Listed {
                    ptys: manager.list(),
                }),
            )
            .await;
        }
        OpenMode::Kill { ref name } => {
            // The request itself is logged, not just the effect: when a
            // session vanishes, the question is always who asked.
            tracing::info!(name, "kill requested");
            let existed = manager.kill(name);
            return reply(&mut writer, &Ok(Opened::Killed { existed })).await;
        }
        OpenMode::Close { ref name } => {
            let result = manager
                .close(name)
                .map(|expires_at_ms| Opened::Closed { expires_at_ms })
                .map_err(|error| OpenError::new(ErrorKind::Other, error.to_string()));
            return reply(&mut writer, &result).await;
        }
        OpenMode::Watch => {
            reply(&mut writer, &Ok(Opened::Watching)).await?;
            return watch(manager, reader, writer).await;
        }
        OpenMode::Inspect { ref name }
        | OpenMode::Observe { ref name }
        | OpenMode::Input { ref name, .. } => {
            let Some(session) = manager.get(name) else {
                return reply(
                    &mut writer,
                    &Err(OpenError::new(ErrorKind::Other, "terminal does not exist")),
                )
                .await;
            };
            return crate::control::handle(session, request.mode, reader, writer).await;
        }
        OpenMode::Open { .. } | OpenMode::Attach { .. } | OpenMode::Reopen { .. } => {}
    }
    handle_open(manager, request, reader, writer).await
}

/// Stream pty events on the events lane until the client hangs up. A subscriber
/// that fell behind the backlog gets every pty again rather than a gap.
async fn watch<R, W>(manager: Manager, mut reader: R, mut writer: BufWriter<W>) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    use tokio::sync::broadcast::error::RecvError;

    let (mut snapshot, mut rx) = manager.watch();
    let mut sink = [0u8; 64];
    loop {
        for event in snapshot.drain(..) {
            frame::aio::write_lane(&mut writer, OUT_LANE_EVENTS, &peer::encode(&event)).await?;
        }
        writer.flush().await?;
        tokio::select! {
            received = rx.recv() => match received {
                Ok(event) => snapshot.push(event),
                Err(RecvError::Lagged(_)) => snapshot = manager.watch().0,
                Err(RecvError::Closed) => return Ok(()),
            },
            // The client writes nothing on a watch; any read result is
            // its departure.
            _ = reader.read(&mut sink) => return Ok(()),
        }
    }
}

/// The directory a new pty starts in: the explicit `cwd`, else the live
/// working directory of `cwd_from` (a split's source pane), resolved here
/// where that process lives.
fn inherited_cwd(manager: &Manager, cwd: Option<String>, cwd_from: Option<&str>) -> Option<String> {
    cwd.or_else(|| manager.get(cwd_from?)?.current_cwd())
}

/// The attach-or-create arm: reply + replay, then pump both directions.
struct ClientGuard {
    session: Arc<PtySession>,
    id: manager::ClientId,
}

impl Drop for ClientGuard {
    fn drop(&mut self) {
        self.session.detach(self.id);
    }
}

fn open_terminal(manager: &Manager, request: OpenRequest) -> Result<(Arc<PtySession>, bool)> {
    match request.mode {
        OpenMode::Open {
            name,
            cwd,
            command,
            cwd_from,
        } => {
            let cwd = inherited_cwd(manager, cwd, cwd_from.as_deref());
            manager.open(
                &name,
                &command,
                cwd.as_deref(),
                request.term.as_deref(),
                request.cols,
                request.rows,
            )
        }
        OpenMode::Reopen { name } => manager.reopen(&name),
        OpenMode::Attach { name } => manager.open_existing(&name),
        _ => bail!("request is not an open"),
    }
}

async fn handle_open<R, W>(
    manager: Manager,
    request: OpenRequest,
    mut reader: R,
    mut writer: BufWriter<W>,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let (cols, rows) = (request.cols, request.rows);
    let opened = open_terminal(&manager, request);
    let (session, created) = match opened {
        Ok(v) => v,
        Err(e) => {
            let error = OpenError::new(ErrorKind::Other, format!("{e:#}"));
            return reply(&mut writer, &Err(error)).await;
        }
    };

    let name = session.name.clone();
    let attachment = manager::attach(&session, cols, rows);
    let client_id = attachment.id;
    let _client = ClientGuard {
        session: session.clone(),
        id: client_id,
    };
    tracing::info!(
        name,
        created,
        cols,
        rows,
        client = client_id.raw(),
        "attached"
    );

    let attached: OpenReply = Ok(Opened::Attached {
        name: name.clone(),
        created,
    });
    frame::aio::write_lane(&mut writer, OUT_LANE_OPENED, &peer::encode(&attached)).await?;
    frame::aio::write_lane(&mut writer, OUT_LANE_OUTPUT, &attachment.dump).await?;
    writer.flush().await?;

    // The client's handshake size can be provisional (a restoring app
    // attaches before its window layout settles), which renders the
    // replay for the wrong grid. Until the first byte of live output
    // proves the two sides are in lockstep, a Resize re-renders and
    // re-sends the replay at the corrected size; after live output a
    // re-dump would clear real screen state, so the window closes for
    // good.
    let live_output = std::sync::atomic::AtomicBool::new(false);

    // Forward daemon -> client; ends when the channel closes (exit or
    // eviction).
    let forward = async {
        let mut rx = attachment.rx;
        while let Some(msg) = rx.recv().await {
            match msg {
                ClientMsg::Output(bytes) => {
                    live_output.store(true, std::sync::atomic::Ordering::Relaxed);
                    frame::aio::write_lane(&mut writer, OUT_LANE_OUTPUT, &bytes).await?;
                }
                ClientMsg::Exit(code) => {
                    let event = ServerEvent::Exit { code };
                    frame::aio::write_lane(&mut writer, OUT_LANE_EVENTS, &peer::encode(&event))
                        .await?;
                }
            }
            writer.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    };

    // Client -> pty; ends on stream EOF (detach).
    let session_in = session.clone();
    let live_output = &live_output;
    let receive = async move {
        loop {
            let Some((lane, payload)) = frame::aio::read_lane(&mut reader).await? else {
                return Ok::<_, anyhow::Error>(()); // clean detach
            };
            match lane {
                IN_LANE_INPUT => {
                    session_in.write_input(&payload).await?;
                }
                IN_LANE_CONTROL => match peer::decode::<ClientControl>(&payload) {
                    Ok(ClientControl::Resize { cols, rows }) => {
                        resize(&session_in, cols, rows, live_output).await;
                    }
                    Err(e) => tracing::warn!(error = %e, "bad control frame"),
                },
                other => tracing::warn!(lane = other, "unknown ingress lane"),
            }
        }
    };

    tokio::select! {
        r = forward => r?,
        r = receive => r?,
    }

    tracing::info!(name = %session.name, client = client_id.raw(), "detached");
    Ok(())
}

/// A client resize: the VT and the pty follow. Until the first byte of
/// live output, the replay is re-rendered and re-sent at the new size
/// (the handshake size can be provisional); after it, a re-dump would
/// clear real screen state, so only the sizes change.
async fn resize(
    session: &Arc<PtySession>,
    cols: u16,
    rows: u16,
    live_output: &std::sync::atomic::AtomicBool,
) {
    let redump = {
        let mut term = session.terminal.lock();
        term.resize(rows, cols);
        session.changed();
        (!live_output.load(std::sync::atomic::Ordering::Relaxed))
            .then(|| term.render_screen_bytes())
    };
    let _ = pty::resize(&session.master, cols, rows);
    if let Some(dump) = redump {
        let tx = session.client.lock().as_ref().map(|c| c.tx.clone());
        if let Some(tx) = tx {
            let _ = tx.send(ClientMsg::Output(dump)).await;
        }
    }
}

/// The one-shot handshake answer on the opened lane.
pub(crate) async fn reply<W: AsyncWrite + Unpin>(writer: &mut W, reply: &OpenReply) -> Result<()> {
    frame::aio::write_lane(writer, OUT_LANE_OPENED, &peer::encode(reply)).await?;
    writer.flush().await?;
    Ok(())
}

/// A decoded handshake, or the protocol version of a client this daemon
/// cannot speak to: version is the request's first field by design, so
/// it reads even when nothing else does.
type Handshake = std::result::Result<OpenRequest, u32>;

async fn read_request<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Handshake> {
    let buf = frame::aio::read_message(reader).await.context("request")?;
    let version = peer::decode_prefix::<u32>(&buf).context("request version")?;
    // v8-v10 append variants; existing v7-v9 requests and replies retain
    // their byte layout, including the interactive input/output lanes.
    if version != peer::PROTOCOL_VERSION && version != 7 && version != 8 && version != 9 {
        return Ok(Err(version));
    }
    let request: OpenRequest = peer::decode(&buf).context("request decode")?;
    let minimum = match request.mode {
        OpenMode::Open { .. } | OpenMode::List | OpenMode::Kill { .. } | OpenMode::Watch => 7,
        OpenMode::Attach { .. } => 8,
        OpenMode::Close { .. } | OpenMode::Reopen { .. } => 10,
        OpenMode::Inspect { .. } | OpenMode::Observe { .. } | OpenMode::Input { .. } => 9,
    };
    if version < minimum {
        return Ok(Err(version));
    }
    Ok(Ok(request))
}
