//! One reconnectable provider per host; hardware lives only for a pane lease.
use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use mux_proto::{audio, frame, peer};
use nix::fcntl::{Flock, FlockArg};
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

pub(super) fn hardware_owner() -> Result<Flock<File>> {
    let dir = crate::paths::client_state_dir();
    std::fs::create_dir_all(&dir)?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(dir.join("audio.lock"))?;
    Flock::lock(file, FlockArg::LockExclusiveNonblock)
        .map_err(|(_, error)| anyhow::anyhow!("Mac audio is in use by another pane ({error})"))
}

async fn reply(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: u64,
    error: Option<String>,
) -> Result<()> {
    frame::aio::write_message(writer, &peer::encode(&audio::Ready { id, error })).await?;
    writer.flush().await?;
    Ok(())
}

async fn connected(socket: &Path, request: peer::OpenRequest) -> Result<()> {
    let mut stream = UnixStream::connect(socket).await?;
    frame::aio::write_message(&mut stream, &peer::encode(&request)).await?;
    let (_, payload) =
        tokio::time::timeout(Duration::from_secs(15), frame::aio::read_lane(&mut stream))
            .await??
            .context("audio provider disconnected")?;
    match peer::decode_open_reply(&payload)? {
        Ok(peer::Opened::AudioProvider) => {}
        Err(error) => anyhow::bail!("{error}"),
        other => anyhow::bail!("unexpected audio provider reply: {other:?}"),
    }
    println!("Automatic audio ready.");
    let (mut reader, mut writer) = stream.into_split();
    let (requests, mut received) = mpsc::channel(8);
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(async move {
        while let Ok(Some((lane, payload))) = frame::aio::read_lane(&mut reader).await {
            if lane != frame::OUT_LANE_EVENTS {
                break;
            }
            let Ok(request) = peer::decode::<audio::Request>(&payload) else {
                break;
            };
            if requests.send(request).await.is_err() {
                break;
            }
        }
    });
    let mut queued = None;
    loop {
        let wanted = match queued.take() {
            Some(request) => request,
            None => received
                .recv()
                .await
                .context("audio provider disconnected")?,
        };
        println!("Connecting audio for {}.", wanted.name);
        let mut media = request.clone();
        media.mode = peer::OpenMode::AudioAcquire {
            request: wanted.clone(),
        };
        let (ready, response) = oneshot::channel();
        let operation = super::mac::run_ready(socket, media, Some(ready));
        tokio::pin!(operation);
        let error = tokio::select! {
            result = &mut operation => Some(setup_error(result)),
            result = response => {
                if result.is_ok() { None } else { Some(setup_error((&mut operation).await)) }
            }
        };
        reply(&mut writer, wanted.id, error.clone()).await?;
        if let Some(error) = error {
            println!("Audio unavailable: {error}");
            continue;
        }
        loop {
            tokio::select! {
                result = &mut operation => {
                    if let Err(error) = result { println!("Audio ended: {error}"); }
                    println!("Automatic audio ready.");
                    break;
                }
                next = received.recv() => {
                    let next = next.context("audio provider disconnected")?;
                    // A just-closed pane's media stream and this request travel
                    // independently. Let idle expiry/drain finish before busy.
                    if tokio::time::timeout(Duration::from_millis(750), &mut operation).await.is_ok() {
                        queued = Some(next);
                        break;
                    }
                    let error = format!("Mac audio is in use by pane {}; end its voice session first", wanted.name);
                    println!("Audio unavailable: {error}");
                    reply(&mut writer, next.id, Some(error)).await?;
                }
            }
        }
    }
}

fn setup_error(result: Result<()>) -> String {
    result.err().map_or_else(
        || "Audio closed during setup".to_owned(),
        |error| error.to_string(),
    )
}

pub async fn run(socket: &Path, request: peer::OpenRequest) -> Result<()> {
    let parent = nix::unistd::getppid();
    let disconnected = async {
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            if nix::unistd::getppid() != parent {
                return;
            }
        }
    };
    let reconnect = async {
        loop {
            if let Err(error) = connected(socket, request.clone()).await {
                println!("Automatic audio unavailable: {error}; reconnecting.");
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    };
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! {
        () = disconnected => {},
        () = reconnect => {},
        _ = terminate.recv() => {},
        result = tokio::signal::ctrl_c() => { result?; },
    }
    Ok(())
}
