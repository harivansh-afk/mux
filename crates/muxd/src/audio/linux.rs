//! ALSA's local device endpoint. `SOCK_SEQPACKET` preserves PCM packet boundaries;
//! `SO_PEERCRED` + process ancestry binds the caller to its owning terminal.

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::Duration;

use anyhow::{ensure, Result};
use nix::sys::socket::{self, AddressFamily, Backlog, MsgFlags, SockFlag, SockType, UnixAddr};
use tokio::io::unix::AsyncFd;
use tokio::sync::broadcast::error::RecvError;

use super::{Event, Route};
use crate::manager::Manager;

fn io(error: nix::errno::Errno) -> std::io::Error {
    error.into()
}

pub async fn serve(manager: Manager, path: &Path) -> Result<()> {
    ensure!(
        super::process::Process::supported(),
        "native audio requires Linux 6.13+ pidfd metadata"
    );
    let fd = socket::socket(
        AddressFamily::Unix,
        SockType::SeqPacket,
        SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
        None,
    )?;
    // A live predecessor must go away before its pathname can be replaced.
    let address = UnixAddr::new(path)?;
    match socket::connect(fd.as_raw_fd(), &address) {
        Ok(()) => anyhow::bail!("audio endpoint is already running"),
        Err(nix::errno::Errno::ENOENT | nix::errno::Errno::ECONNREFUSED) => {}
        Err(error) => return Err(error.into()),
    }
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        ensure!(
            metadata.file_type().is_socket() && metadata.uid() == nix::unistd::geteuid().as_raw(),
            "refusing to replace a foreign audio path"
        );
        std::fs::remove_file(path)?;
    }
    socket::bind(fd.as_raw_fd(), &address)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    socket::listen(&fd, Backlog::new(32)?)?;
    let listener = AsyncFd::new(fd)?;
    manager
        .audio
        .enabled
        .store(true, std::sync::atomic::Ordering::Release);
    let _enabled = Enabled(manager.audio.clone());
    loop {
        let mut ready = listener.readable().await?;
        let accepted = ready.try_io(|fd| {
            socket::accept4(
                fd.as_raw_fd(),
                SockFlag::SOCK_CLOEXEC | SockFlag::SOCK_NONBLOCK,
            )
            .map_err(io)
        });
        let Ok(accepted) = accepted else { continue };
        // SAFETY: accept4 returned a new descriptor owned by this task.
        let fd = unsafe { OwnedFd::from_raw_fd(accepted?) };
        let manager = manager.clone();
        tokio::spawn(async move {
            if let Err(error) = device(manager, fd).await {
                tracing::debug!(%error, "audio device closed");
            }
        });
    }
}

struct Enabled(std::sync::Arc<super::Registry>);
impl Drop for Enabled {
    fn drop(&mut self) {
        self.0
            .enabled
            .store(false, std::sync::atomic::Ordering::Release);
    }
}

async fn receive(fd: &AsyncFd<OwnedFd>, data: &mut [u8]) -> std::io::Result<usize> {
    loop {
        let mut ready = fd.readable().await?;
        if let Ok(result) = ready.try_io(|fd| {
            socket::recv(
                fd.as_raw_fd(),
                data,
                MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_TRUNC,
            )
            .map_err(io)
        }) {
            return result;
        }
    }
}

fn send(fd: &AsyncFd<OwnedFd>, data: &[u8]) -> std::io::Result<()> {
    match socket::send(
        fd.as_raw_fd(),
        data,
        MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_NOSIGNAL,
    ) {
        Ok(size) if size == data.len() => Ok(()),
        Err(nix::errno::Errno::EAGAIN) => Ok(()), // bounded capture: discard stale media
        Ok(_) => Err(std::io::Error::other("short audio packet")),
        Err(error) => Err(io(error)),
    }
}

struct Running {
    route: std::sync::Arc<Route>,
    id: u64,
    capture: bool,
}

impl Drop for Running {
    fn drop(&mut self) {
        if !self.capture {
            let mut owner = self.route.playback_owner.lock();
            if *owner == Some(self.id) {
                *owner = None;
            }
        }
        let event = Event::Running {
            id: self.id,
            capture: self.capture,
            running: false,
        };
        // Reserve channel capacity for this reliable state transition instead
        // of silently dropping a microphone-off message behind media.
        let sender = self.route.events.clone();
        tokio::spawn(async move {
            let _ = sender.send(event).await;
        });
    }
}

async fn device(manager: Manager, fd: OwnedFd) -> Result<()> {
    let credentials = socket::getsockopt(&fd, socket::sockopt::PeerCredentials)?;
    ensure!(
        credentials.uid() == nix::unistd::geteuid().as_raw(),
        "audio peer uid mismatch"
    );
    let peer = super::process::Process::peer(&fd)?;
    let fd = AsyncFd::new(fd)?;
    let mut data = [0u8; mux_proto::audio::MAX_PCM + 1];
    let size = tokio::time::timeout(Duration::from_secs(3), receive(&fd, &mut data)).await??;
    ensure!(
        size == 2 && data[0] == 1 && data[1] <= 1,
        "invalid audio device handshake"
    );
    let capture = data[1] == 1;
    let Some(route) = manager.audio_for_process(&peer) else {
        send(&fd, &[1])?;
        anyhow::bail!("no Mac audio owner for this terminal");
    };
    send(&fd, &[0])?;
    let mut pcm = route.capture.subscribe();
    let running = Running {
        route,
        id: rand::random(),
        capture,
    };
    let mut active = false;
    loop {
        tokio::select! {
            () = running.route.events.closed() => break,
            packet = receive(&fd, &mut data) => {
                let size = packet?;
                if size == 0 { break; }
                ensure!(size <= data.len(), "oversized audio IPC packet");
                match data[0] {
                    0 | 1 if size == 1 => {
                        active = data[0] == 1;
                        if !capture {
                            let mut owner = running.route.playback_owner.lock();
                            if active {
                                ensure!(owner.is_none() || *owner == Some(running.id), "another application is playing in this pane");
                                *owner = Some(running.id);
                            } else if *owner == Some(running.id) { *owner = None; }
                        }
                        running.route.events.send(Event::Running { id: running.id, capture, running: active }).await?;
                    }
                    2 if !capture && active && size > 1 && size % 2 == 1 => {
                        let _ = running.route.events.try_send(Event::Playback { pcm: data[1..size].to_vec() });
                    }
                    _ => anyhow::bail!("invalid audio IPC operation"),
                }
            }
            packet = pcm.recv(), if capture => match packet {
                Ok(packet) if active => send(&fd, &packet)?,
                Ok(_) | Err(RecvError::Lagged(_)) => {},
                Err(RecvError::Closed) => break,
            },
        }
    }
    Ok(())
}
