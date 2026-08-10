//! Unix-socket listener and per-connection protocol handling. Fork of
//! ix-console's server.rs/session.rs dispatch skeleton: [u32 len][request]
//! handshake, then lane frames. Local-only M2: a 0600 unix socket is the
//! auth boundary (no token; ix's token flow returns with TCP in M3).

use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::peer::{self, ClientControl, OpenMode, OpenReply, OpenRequest, Opened, ServerEvent};
use mux_proto::shell::{
    IN_LANE_CONTROL, IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufWriter};
use tokio::net::{UnixListener, UnixStream};

use crate::manager::{self, ClientMsg, Manager};
use crate::pty;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

pub async fn serve(manager: Manager, socket: &std::path::Path) -> Result<()> {
    // A live daemon on the socket wins; a stale file is replaced.
    if UnixStream::connect(socket).await.is_ok() {
        bail!("muxd already running on {}", socket.display());
    }
    let _ = std::fs::remove_file(socket);
    let listener =
        UnixListener::bind(socket).with_context(|| format!("bind {}", socket.display()))?;
    std::fs::set_permissions(socket, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    tracing::info!(socket = %socket.display(), "muxd listening");

    loop {
        let (stream, _) = listener.accept().await?;
        let manager = manager.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(manager, stream).await {
                tracing::debug!(error = %e, "connection ended with error");
            }
        });
    }
}

async fn handle_connection(manager: Manager, stream: UnixStream) -> Result<()> {
    let (mut reader, writer) = stream.into_split();
    let mut writer = BufWriter::new(writer);

    let request: OpenRequest = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_request(&mut reader))
        .await
        .context("handshake timeout")??;

    // Broker relay (target = Some(host)) lands in M3; until then be
    // explicit rather than silently serving the wrong machine.
    if let Some(host) = &request.target {
        let reply: OpenReply = Err(format!(
            "remote target {host:?} not supported yet (M3 broker)"
        ));
        write_frame(&mut writer, OUT_LANE_OPENED, &peer::encode(&reply)).await?;
        writer.flush().await?;
        return Ok(());
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
            let reply: OpenReply = Ok(Opened::Listed {
                ptys: manager.list(),
            });
            write_frame(&mut writer, OUT_LANE_OPENED, &peer::encode(&reply)).await?;
            writer.flush().await?;
            Ok(())
        }

        OpenMode::Kill { name } => {
            let existed = manager.kill(&name);
            let reply: OpenReply = Ok(Opened::Killed { existed });
            write_frame(&mut writer, OUT_LANE_OPENED, &peer::encode(&reply)).await?;
            writer.flush().await?;
            Ok(())
        }

        OpenMode::Open { name, cwd, command } => {
            handle_open(
                manager, cols, rows, term, name, cwd, command, reader, writer,
            )
            .await
        }
    }
}

/// The attach-or-create arm: reply + replay, then pump both directions.
#[allow(clippy::too_many_arguments)]
async fn handle_open(
    manager: Manager,
    cols: u16,
    rows: u16,
    term: Option<String>,
    name: String,
    cwd: Option<String>,
    command: Vec<String>,
    mut reader: tokio::net::unix::OwnedReadHalf,
    mut writer: BufWriter<tokio::net::unix::OwnedWriteHalf>,
) -> Result<()> {
    {
        {
            let opened = manager.open(&name, &command, cwd.as_deref(), term.as_deref(), cols, rows);
            let (session, created) = match opened {
                Ok(v) => v,
                Err(e) => {
                    let reply: OpenReply = Err(format!("{e:#}"));
                    write_frame(&mut writer, OUT_LANE_OPENED, &peer::encode(&reply)).await?;
                    writer.flush().await?;
                    return Ok(());
                }
            };

            let attachment = manager::attach(&session, cols, rows);

            let reply: OpenReply = Ok(Opened::Attached {
                name: name.clone(),
                created,
            });
            write_frame(&mut writer, OUT_LANE_OPENED, &peer::encode(&reply)).await?;
            write_frame(&mut writer, OUT_LANE_OUTPUT, &attachment.dump).await?;
            writer.flush().await?;

            // Forward daemon -> client; ends when the channel closes
            // (exit or eviction).
            let forward = async {
                let mut rx = attachment.rx;
                while let Some(msg) = rx.recv().await {
                    match msg {
                        ClientMsg::Output(bytes) => {
                            write_frame(&mut writer, OUT_LANE_OUTPUT, &bytes).await?;
                        }
                        ClientMsg::Exit(code) => {
                            let event = ServerEvent::Exit { code };
                            write_frame(&mut writer, OUT_LANE_EVENTS, &peer::encode(&event))
                                .await?;
                        }
                    }
                    writer.flush().await?;
                }
                Ok::<_, anyhow::Error>(())
            };

            // Client -> pty; ends on socket EOF (detach).
            let session_in = session.clone();
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
                                session_in.terminal.lock().resize(rows, cols);
                                let _ = pty::resize(&session_in.master, cols, rows);
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

            // Detach: clear the client slot if it is still ours.
            let mut client = session.client.lock();
            if client.is_some() {
                *client = None;
            }
            Ok(())
        }
    }
}

async fn read_request<R: AsyncRead + Unpin>(reader: &mut R) -> Result<OpenRequest> {
    let len = reader.read_u32_le().await.context("request length")?;
    if len == 0 || len > peer::MAX_REQUEST_BYTES {
        bail!("bad request length {len}");
    }
    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf).await.context("request body")?;
    peer::decode(&buf).context("request decode")
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
