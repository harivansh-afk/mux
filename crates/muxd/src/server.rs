//! Per-connection protocol handling and the unix-socket listener. Fork
//! of ix-console's server.rs/session.rs dispatch skeleton: [u32 len]
//! [request] handshake, then lane frames.
//!
//! The handler is transport-generic: a unix stream and one QUIC
//! bidirectional stream run the identical protocol, and differ only in
//! the [`Policy`] that decides who is let in.

use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::peer::{self, ClientControl, OpenMode, OpenReply, OpenRequest, Opened, ServerEvent};
use mux_proto::shell::{
    IN_LANE_CONTROL, IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufWriter};
use tokio::net::{UnixListener, UnixStream};

use crate::manager::{self, ClientMsg, Manager};
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
    /// `Err(message)` goes back to the client verbatim as the failed
    /// `OpenReply`.
    fn admit(&self, request: &OpenRequest) -> Result<(), String> {
        match self {
            // The 0600 socket is the auth boundary, and requests naming a
            // remote target were handed to the broker before admission.
            Self::Local => Ok(()),
            Self::Remote { admitted } => {
                // Digests, not the secrets: fixed-size and preimage
                // resistant, so a short circuit leaks nothing useful.
                // `mux-attach probe` classifies this message, so its
                // wording is a contract.
                let presented = request.token.as_deref().map(tls::digest);
                if !presented.is_some_and(|d| admitted.contains(&d)) {
                    return Err("authentication failed".into());
                }
                if let Some(host) = &request.target {
                    return Err(format!(
                        "target {host:?} rejected: a remote daemon does not relay"
                    ));
                }
                Ok(())
            }
        }
    }
}

/// Take the control socket. Separate from [`serve`] so a daemon only
/// publishes itself (the pidfile a successor signals, see `migrate.rs`)
/// once it actually owns the socket.
///
/// # Errors
///
/// Another daemon already owns the socket, or the bind fails.
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
///
/// # Errors
///
/// An accept failure that is about the socket rather than the moment; see
/// [`transient`].
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
            if let Err(e) = handle_unix(manager, stream).await {
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

async fn handle_unix(manager: Manager, stream: UnixStream) -> Result<()> {
    let (reader, writer) = stream.into_split();
    handle_connection(manager, reader, writer, &Policy::Local).await
}

/// One run of the protocol over any byte stream: handshake, then either
/// a one-shot reply (list, kill, rejection) or an attached session.
///
/// # Errors
///
/// A malformed or slow handshake, or an IO failure on the stream.
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
    let request: OpenRequest = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_request(&mut reader))
        .await
        .context("handshake timeout")??;

    // Version first: a mismatched client gets a readable diagnosis, not
    // a dropped socket. A pre-v3 request has no version field, so the
    // first varint decodes as something else entirely - decode failure or
    // a wrong version both land here or in read_request's error path.
    // The leading phrase is what `mux-attach probe` classifies on.
    if request.version != peer::PROTOCOL_VERSION {
        let message = format!(
            "protocol version mismatch: daemon v{}, client v{} - upgrade or restart the daemon (muxd --upgrade)",
            peer::PROTOCOL_VERSION,
            request.version,
        );
        tracing::warn!(message, "handshake rejected");
        return reply(&mut writer, &Err(message)).await;
    }

    // Admission first, unconditionally: relayed requests must never skip
    // a future Policy::Local check by taking the broker branch early.
    if let Err(message) = policy.admit(&request) {
        tracing::debug!(message, "request rejected");
        return reply(&mut writer, &Err(message)).await;
    }
    // target = Some(host) on the unix socket: this daemon is the broker,
    // not the server - the whole connection goes out over the per-host
    // QUIC link. (Remote policy already refused targets in admit; the
    // guard is defense in depth.)
    if request.target.is_some() && matches!(policy, Policy::Local) {
        return broker::relay(request, reader, writer).await;
    }

    let OpenRequest {
        cols,
        rows,
        term,
        mode,
        ..
    } = request;

    match mode {
        OpenMode::List => {
            reply(
                &mut writer,
                &Ok(Opened::Listed {
                    ptys: manager.list(),
                }),
            )
            .await
        }

        OpenMode::Kill { name } => {
            let existed = manager.kill(&name);
            reply(&mut writer, &Ok(Opened::Killed { existed })).await
        }

        OpenMode::Open {
            name,
            cwd,
            command,
            cwd_from,
        } => {
            // Inherit the source pane's directory when no explicit cwd
            // came along: resolved here, where the source process lives.
            let cwd = cwd.or_else(|| {
                let source = manager.get(cwd_from.as_deref()?)?;
                source.current_cwd()
            });
            let open = Open {
                cols,
                rows,
                term,
                name,
                cwd,
                command,
            };
            handle_open(manager, open, reader, writer).await
        }
    }
}

/// The handshake's attach-or-create parameters.
struct Open {
    cols: u16,
    rows: u16,
    term: Option<String>,
    name: String,
    cwd: Option<String>,
    command: Vec<String>,
}

/// The attach-or-create arm: reply + replay, then pump both directions.
async fn handle_open<R, W>(
    manager: Manager,
    open: Open,
    mut reader: R,
    mut writer: BufWriter<W>,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let Open {
        cols,
        rows,
        term,
        name,
        cwd,
        command,
    } = open;

    let opened = manager.open(&name, &command, cwd.as_deref(), term.as_deref(), cols, rows);
    let (session, created) = match opened {
        Ok(v) => v,
        Err(e) => return reply(&mut writer, &Err(format!("{e:#}"))).await,
    };

    let attachment = manager::attach(&session, cols, rows);
    let client_id = attachment.id;

    let attached: OpenReply = Ok(Opened::Attached {
        name: name.clone(),
        created,
    });
    write_frame(&mut writer, OUT_LANE_OPENED, &peer::encode(&attached)).await?;
    write_frame(&mut writer, OUT_LANE_OUTPUT, &attachment.dump).await?;
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
                    write_frame(&mut writer, OUT_LANE_OUTPUT, &bytes).await?;
                }
                ClientMsg::Exit(code) => {
                    let event = ServerEvent::Exit { code };
                    write_frame(&mut writer, OUT_LANE_EVENTS, &peer::encode(&event)).await?;
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
            let Some(frame) = read_frame(&mut reader).await? else {
                return Ok::<_, anyhow::Error>(()); // clean detach
            };
            match frame.0 {
                IN_LANE_INPUT => {
                    pty::write_all(&session_in.master, &frame.1).await?;
                }
                IN_LANE_CONTROL => match peer::decode::<ClientControl>(&frame.1) {
                    Ok(ClientControl::Resize { cols, rows }) => {
                        let redump = {
                            let mut term = session_in.terminal.lock();
                            term.resize(rows, cols);
                            (!live_output.load(std::sync::atomic::Ordering::Relaxed))
                                .then(|| term.render_screen_bytes())
                        };
                        let _ = pty::resize(&session_in.master, cols, rows);
                        if let Some(dump) = redump {
                            let tx = session_in.client.lock().as_ref().map(|c| c.tx.clone());
                            if let Some(tx) = tx {
                                let _ = tx.send(ClientMsg::Output(dump)).await;
                            }
                        }
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

    // Detach, by identity: this handler may be here because another
    // client stole the pty, and that client's channel is in the slot now.
    session.detach(client_id);
    Ok(())
}

/// The one-shot handshake answer on the opened lane.
async fn reply<W: AsyncWrite + Unpin>(writer: &mut W, reply: &OpenReply) -> Result<()> {
    write_frame(writer, OUT_LANE_OPENED, &peer::encode(reply)).await?;
    writer.flush().await?;
    Ok(())
}

async fn read_request<R: AsyncRead + Unpin>(reader: &mut R) -> Result<OpenRequest> {
    let len = reader.read_u32_le().await.context("request length")?;
    if len == 0 || len > peer::MAX_REQUEST_BYTES {
        bail!("bad request length {len}");
    }
    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf).await.context("request body")?;
    match peer::decode(&buf) {
        Ok(request) => Ok(request),
        // A request shaped by another protocol version cannot decode at
        // all, but its version is the first varint by design: surface it
        // as a minimal request so the version check upstream answers
        // with the readable mismatch instead of a dropped socket.
        Err(e) => {
            if let Ok(version) = peer::decode_prefix::<u32>(&buf) {
                if version != peer::PROTOCOL_VERSION {
                    return Ok(OpenRequest {
                        version,
                        cols: 0,
                        rows: 0,
                        term: None,
                        token: None,
                        target: None,
                        mode: OpenMode::List,
                    });
                }
            }
            Err(e).context("request decode")
        }
    }
}

/// Lane frame: [u32 LE length][u8 lane][payload]; length covers lane+payload.
async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Option<(u8, Vec<u8>)>> {
    let len = match reader.read_u32_le().await {
        Ok(len) => len,
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    if len == 0 || len > mux_proto::frame::MAX_FRAME_SIZE {
        bail!("bad frame length {len}");
    }
    let lane = reader.read_u8().await?;
    let mut payload = vec![0u8; (len - 1) as usize];
    reader.read_exact(&mut payload).await?;
    Ok(Some((lane, payload)))
}

async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    lane: u8,
    payload: &[u8],
) -> Result<()> {
    let len = 1u32 + u32::try_from(payload.len()).context("frame too large")?;
    writer.write_u32_le(len).await?;
    writer.write_u8(lane).await?;
    writer.write_all(payload).await?;
    Ok(())
}
