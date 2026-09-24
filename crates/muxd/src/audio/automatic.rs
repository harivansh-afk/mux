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
    connected_with(socket, request, |media, ready| {
        super::mac::run_ready(socket, media, Some(ready))
    })
    .await
}

async fn connected_with<D, F>(socket: &Path, request: peer::OpenRequest, mut drive: D) -> Result<()>
where
    D: FnMut(peer::OpenRequest, oneshot::Sender<()>) -> F,
    F: std::future::Future<Output = Result<()>>,
{
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
    let read = tokio::spawn(async move {
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
    let _reader = Reader(read);
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
        let operation = drive(media, ready);
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

struct Reader(tokio::task::JoinHandle<()>);
impl Drop for Reader {
    fn drop(&mut self) {
        self.0.abort();
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;

    struct Active(Arc<AtomicBool>);
    impl Drop for Active {
        fn drop(&mut self) {
            self.0.store(false, Ordering::Release);
        }
    }

    fn registration() -> peer::OpenRequest {
        peer::OpenRequest {
            version: peer::PROTOCOL_VERSION,
            cols: 0,
            rows: 0,
            term: None,
            token: None,
            target: Some("test".to_owned()),
            mode: peer::OpenMode::AudioProvider,
        }
    }

    #[tokio::test]
    async fn supervisor_registers_again_after_connection_loss_without_opening_hardware() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("provider.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = async {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let request: peer::OpenRequest =
                    peer::decode(&frame::aio::read_message(&mut stream).await.unwrap()).unwrap();
                assert_eq!(request.mode, peer::OpenMode::AudioProvider);
                crate::server::reply(&mut stream, &Ok(peer::Opened::AudioProvider))
                    .await
                    .unwrap();
            }
        };
        tokio::select! {
            result = run(&socket, registration()) => panic!("supervisor exited: {result:?}"),
            result = tokio::time::timeout(Duration::from_secs(6), server) => result.unwrap(),
        }
    }

    async fn requested(stream: &mut UnixStream, id: u64) -> audio::Ready {
        let request = audio::Request {
            id,
            name: format!("pane-{id}"),
            attachment: id,
        };
        frame::aio::write_lane(stream, frame::OUT_LANE_EVENTS, &peer::encode(&request))
            .await
            .unwrap();
        peer::decode(&frame::aio::read_message(stream).await.unwrap()).unwrap()
    }

    #[tokio::test]
    async fn provider_is_lazy_rejects_competitors_and_drops_hardware_on_disconnect() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("provider.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let active = Arc::new(AtomicBool::new(false));
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request: peer::OpenRequest =
                peer::decode(&frame::aio::read_message(&mut stream).await.unwrap()).unwrap();
            assert_eq!(request.mode, peer::OpenMode::AudioProvider);
            crate::server::reply(&mut stream, &Ok(peer::Opened::AudioProvider))
                .await
                .unwrap();
            assert_eq!(observed.load(Ordering::Acquire), 0);
            let first = requested(&mut stream, 1).await;
            assert_eq!(first.id, 1);
            assert!(first.error.is_none());
            let second = requested(&mut stream, 2).await;
            assert_eq!(second.id, 2);
            assert!(second.error.unwrap().contains("pane-1"));
        });
        let result = connected_with(&socket, registration(), |_, ready| {
            let active = active.clone();
            calls.fetch_add(1, Ordering::AcqRel);
            async move {
                active.store(true, Ordering::Release);
                let _active = Active(active);
                let _ = ready.send(());
                std::future::pending::<Result<()>>().await
            }
        })
        .await;
        server.await.unwrap();
        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::Acquire), 1);
        assert!(!active.load(Ordering::Acquire));
    }

    #[tokio::test]
    async fn next_pane_waits_for_a_closing_route_before_acquiring_hardware() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("provider.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let closing = Arc::new(tokio::sync::Notify::new());
        let release = closing.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            frame::aio::read_message(&mut stream).await.unwrap();
            crate::server::reply(&mut stream, &Ok(peer::Opened::AudioProvider))
                .await
                .unwrap();
            assert!(requested(&mut stream, 1).await.error.is_none());
            release.notify_one();
            assert!(requested(&mut stream, 2).await.error.is_none());
        });
        let mut calls = 0;
        let result = connected_with(&socket, registration(), |_, ready| {
            calls += 1;
            let first = calls == 1;
            let closing = closing.clone();
            async move {
                let _ = ready.send(());
                if first {
                    closing.notified().await;
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    Ok(())
                } else {
                    std::future::pending::<Result<()>>().await
                }
            }
        })
        .await;
        server.await.unwrap();
        assert!(result.is_err());
        assert_eq!(calls, 2);
    }

    #[tokio::test]
    async fn failed_hardware_open_returns_error_and_keeps_provider_available() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("provider.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            frame::aio::read_message(&mut stream).await.unwrap();
            crate::server::reply(&mut stream, &Ok(peer::Opened::AudioProvider))
                .await
                .unwrap();
            for id in [1, 2] {
                let reply = requested(&mut stream, id).await;
                assert_eq!(reply.id, id);
                assert_eq!(reply.error.as_deref(), Some("microphone unavailable"));
            }
        });
        let result = connected_with(&socket, registration(), |_, _| async {
            anyhow::bail!("microphone unavailable")
        })
        .await;
        server.await.unwrap();
        assert!(result.is_err());
    }
}
