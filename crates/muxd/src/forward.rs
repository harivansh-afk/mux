//! Unix services use the existing broker and authentication, on the same host
//! connection as terminals. Only the opening handshake speaks the Mux protocol;
//! the service owns every byte after `Connected` (including WebSocket upgrades).

use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, ensure, Context, Result};
use mux_proto::{frame, peer};
use peer::{ErrorKind, OpenError, OpenMode, OpenRequest, Opened};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

/// Called only after the daemon's normal admission check. Socket ownership
/// limits the destination to this user's services; no TCP/public forwarding.
pub async fn connect<R, W>(path: &str, reader: R, mut writer: W) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let destination = async {
        ensure!(
            Path::new(path).is_absolute(),
            "socket path must be absolute"
        );
        let metadata = std::fs::metadata(path).context("inspect destination socket")?;
        ensure!(
            metadata.file_type().is_socket(),
            "destination is not a socket"
        );
        ensure!(
            metadata.uid() == nix::unistd::geteuid().as_raw(),
            "socket belongs to another user"
        );
        tokio::time::timeout(CONNECT_TIMEOUT, UnixStream::connect(path))
            .await
            .context("destination connection timed out")?
            .context("connect destination socket")
    }
    .await;
    let mut destination = match destination {
        Ok(stream) => stream,
        Err(error) => {
            return crate::server::reply(
                &mut writer,
                &Err(OpenError::new(ErrorKind::Other, format!("{error:#}"))),
            )
            .await;
        }
    };
    crate::server::reply(&mut writer, &Ok(Opened::Connected)).await?;
    tokio::io::copy_bidirectional(&mut tokio::io::join(reader, writer), &mut destination).await?;
    Ok(())
}

/// A foreground forwarder. Binding never removes an existing filesystem entry.
/// Each accepted client opens a fresh stream through the local daemon's broker.
pub async fn serve(
    daemon: &Path,
    target: Option<String>,
    remote: &str,
    local: &Path,
) -> Result<()> {
    ensure!(
        Path::new(remote).is_absolute(),
        "remote socket path must be absolute"
    );
    ensure!(local.is_absolute(), "local socket path must be absolute");
    let parent = std::fs::metadata(local.parent().context("socket needs a parent directory")?)?;
    ensure!(
        parent.is_dir()
            && parent.uid() == nix::unistd::geteuid().as_raw()
            && parent.mode() & 0o777 == 0o700,
        "local socket needs a private, user-owned directory (mode 0700)"
    );
    let listener = UnixListener::bind(local).context("bind local forward socket")?;
    let metadata = std::fs::symlink_metadata(local)?;
    let _cleanup = SocketPath {
        path: local.to_owned(),
        device: metadata.dev(),
        inode: metadata.ino(),
    };
    std::fs::set_permissions(local, std::fs::Permissions::from_mode(0o600))?;
    println!("unix://{}", local.display());
    let mut clients = tokio::task::JoinSet::new();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            result = listener.accept() => {
                let (client, _) = result?;
                let daemon = daemon.to_owned();
                let request = OpenRequest {
                    version: peer::PROTOCOL_VERSION, cols: 0, rows: 0, term: None,
                    token: None, target: target.clone(), mode: OpenMode::Connect { path: remote.into() },
                };
                clients.spawn(async move {
                    if let Err(error) = relay(&daemon, &request, client).await {
                        tracing::warn!(%error, "socket forward ended");
                    }
                });
            }
            _ = clients.join_next(), if !clients.is_empty() => {}
            result = tokio::signal::ctrl_c() => { result?; return Ok(()); }
            _ = terminate.recv() => return Ok(()),
        }
    }
}

async fn relay(daemon: &Path, request: &OpenRequest, mut client: UnixStream) -> Result<()> {
    let mut upstream = tokio::time::timeout(CONNECT_TIMEOUT, async {
        let mut stream = UnixStream::connect(daemon)
            .await
            .context("connect local muxd")?;
        frame::aio::write_message(&mut stream, &peer::encode(request)).await?;
        stream.flush().await?;
        let (lane, payload) = frame::aio::read_lane(&mut stream)
            .await?
            .context("muxd closed before reply")?;
        ensure!(lane == frame::OUT_LANE_OPENED, "unexpected handshake lane");
        match peer::decode_open_reply(&payload)? {
            Ok(Opened::Connected) => Ok(stream),
            Err(error) => bail!("{error}"),
            Ok(other) => bail!("unexpected reply: {other:?}"),
        }
    })
    .await
    .context("forward connection timed out")??;
    tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
    Ok(())
}

struct SocketPath {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl Drop for SocketPath {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.path).is_ok_and(|metadata| {
            metadata.dev() == self.device
                && metadata.ino() == self.inode
                && metadata.file_type().is_socket()
        }) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}
