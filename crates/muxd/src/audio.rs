//! One explicit audio lease per pane and per QUIC connection. Hardware access
//! lives in the Mac driver; Linux clients are bound by their peer PID/session.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock, Weak};
use std::time::Duration;

use anyhow::{bail, ensure, Context, Result};
use mux_proto::{audio, frame, peer};
use parking_lot::Mutex;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{broadcast, mpsc};

use crate::manager::Manager;

#[cfg(target_os = "linux")]
#[path = "audio/linux.rs"]
pub mod linux;
#[cfg(target_os = "macos")]
#[path = "audio/mac.rs"]
pub mod mac;

#[derive(Default)]
pub struct Registry {
    routes: Mutex<HashMap<String, Weak<Route>>>,
    pub(crate) enabled: std::sync::atomic::AtomicBool,
}

#[cfg_attr(
    target_os = "macos",
    allow(
        dead_code,
        reason = "ALSA device events originate on Linux; the Mac only brokers them"
    )
)]
pub(crate) enum Event {
    Running {
        id: u64,
        capture: bool,
        running: bool,
    },
    Playback {
        pcm: Vec<u8>,
    },
}

pub(crate) struct Route {
    pub events: mpsc::Sender<Event>,
    pub capture: broadcast::Sender<Vec<u8>>,
    #[cfg(target_os = "linux")]
    pub playback_owner: Mutex<Option<u64>>,
}

impl Registry {
    #[cfg(target_os = "linux")]
    pub(crate) fn get(&self, name: &str) -> Option<Arc<Route>> {
        self.routes
            .lock()
            .get(name)
            .and_then(Weak::upgrade)
            .filter(|route| !route.events.is_closed())
    }

    fn open(&self, name: &str) -> Result<(Arc<Route>, mpsc::Receiver<Event>)> {
        ensure!(
            self.enabled.load(std::sync::atomic::Ordering::Acquire),
            "Linux audio devices are not enabled on this host"
        );
        let mut routes = self.routes.lock();
        ensure!(
            routes
                .get(name)
                .and_then(Weak::upgrade)
                .is_none_or(|route| route.events.is_closed()),
            "pane audio is already shared"
        );
        let (events, rx) = mpsc::channel(32);
        let route = Arc::new(Route {
            events,
            capture: broadcast::channel(16).0,
            #[cfg(target_os = "linux")]
            playback_owner: Mutex::default(),
        });
        routes.insert(name.to_owned(), Arc::downgrade(&route));
        routes.retain(|_, value| value.strong_count() > 0);
        Ok((route, rx))
    }
}

/// `read_datagram` is connection-scoped. Never install competing readers.
pub(crate) struct ConnectionLease(usize);

fn connections() -> &'static Mutex<HashSet<usize>> {
    static ACTIVE: OnceLock<Mutex<HashSet<usize>>> = OnceLock::new();
    ACTIVE.get_or_init(Mutex::default)
}

impl ConnectionLease {
    pub fn take(connection: &quinn::Connection) -> Result<Self> {
        let id = connection.stable_id();
        ensure!(
            connections().lock().insert(id),
            "this host connection already has an audio owner"
        );
        Ok(Self(id))
    }
}

impl Drop for ConnectionLease {
    fn drop(&mut self) {
        connections().lock().remove(&self.0);
    }
}

pub async fn serve<R, W>(
    manager: Manager,
    connection: quinn::Connection,
    name: &str,
    mut reader: R,
    mut writer: W,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let opened = (|| {
        let session = manager.get(name).context("terminal does not exist")?;
        let owner = session
            .client
            .lock()
            .as_ref()
            .map(|client| client.id)
            .context("terminal is not attached")?;
        let lease = ConnectionLease::take(&connection)?;
        ensure!(
            connection
                .max_datagram_size()
                .is_some_and(|size| size >= audio::MAX_PACKET),
            "peer does not support audio datagrams"
        );
        let (route, events) = manager.audio.open(name)?;
        Ok::<_, anyhow::Error>((session, owner, lease, route, events))
    })();
    let (session, owner, _lease, route, mut events) = match opened {
        Ok(opened) => opened,
        Err(error) => {
            return crate::server::reply(
                &mut writer,
                &Err(peer::OpenError::new(
                    peer::ErrorKind::Other,
                    error.to_string(),
                )),
            )
            .await
        }
    };
    let token = rand::random();
    crate::server::reply(&mut writer, &Ok(peer::Opened::Audio { token })).await?;
    let mut state = audio::State::default();
    let mut playback_position = 0u64;
    let mut clients = HashSet::new();
    let mut sequence = audio::Sequence::default();
    let mut check = tokio::time::interval(Duration::from_millis(100));
    let mut heartbeat = tokio::time::interval(Duration::from_millis(500));
    let mut closed = [0];
    loop {
        tokio::select! {
            _ = reader.read(&mut closed) => break,
            _ = heartbeat.tick() => {
                frame::aio::write_message(&mut writer, &peer::encode(&state)).await?;
                writer.flush().await?;
            }
            _ = check.tick() => {
                if session.exited.load(std::sync::atomic::Ordering::Acquire)
                    || session.client.lock().as_ref().is_none_or(|client| client.id != owner) { break; }
            }
            event = events.recv() => match event {
                Some(Event::Running { id, capture, running }) => {
                    if running { clients.insert((id, capture)); } else { clients.remove(&(id, capture)); }
                    let mut next = audio::State { capture: clients.iter().any(|(_, capture)| *capture), playback: clients.iter().any(|(_, capture)| !capture), ..state };
                    if next.capture && !state.capture { next.capture_epoch = state.capture_epoch.checked_add(1).context("capture epoch overflow")?; }
                    if next.playback && !state.playback { next.playback_epoch = state.playback_epoch.checked_add(1).context("playback epoch overflow")?; playback_position = 0; }
                    if next != state {
                        state = next;
                        frame::aio::write_message(&mut writer, &peer::encode(&state)).await?;
                        writer.flush().await?;
                    }
                }
                Some(Event::Playback { pcm }) => {
                    if let Some(packet) = audio::packet(token, state.playback_epoch, playback_position, &pcm) {
                        playback_position = playback_position.checked_add((pcm.len()/2) as u64).context("audio clock overflow")?;
                        connection.send_datagram(packet.into())?;
                    }
                }
                None => break,
            },
            packet = connection.read_datagram() => {
                let packet = packet?;
                if let Some(packet) = audio::unpack(&packet, token) {
                    if state.capture && packet.epoch == state.capture_epoch && sequence.accept(packet.epoch, packet.position, packet.pcm.len() / 2) {
                        let _ = route.capture.send(packet.pcm.to_vec());
                    }
                }
            }
        }
    }
    // Removing the lease makes new device opens fail. Existing device tasks
    // observe their event receiver closing and report device loss.
    drop(events);
    Ok(())
}

/// Local driver framing -> QUIC datagrams. The reliable stream carries only
/// State messages; audio never waits in a terminal's output queue.
pub(crate) async fn bridge<R, W>(
    connection: quinn::Connection,
    mut reader: R,
    mut writer: W,
    _send: quinn::SendStream,
    mut recv: quinn::RecvStream,
) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let _lease = ConnectionLease::take(&connection)?;
    let (_, payload) = frame::aio::read_lane(&mut recv)
        .await?
        .context("audio open closed")?;
    let token = match peer::decode_open_reply(&payload)? {
        Ok(peer::Opened::Audio { token }) => token,
        Err(error) => {
            crate::server::reply(&mut writer, &Err(error)).await?;
            return Ok(());
        }
        other => bail!("unexpected audio reply: {other:?}"),
    };
    crate::server::reply(&mut writer, &Ok(peer::Opened::Audio { token })).await?;
    let writer = tokio::sync::Mutex::new(writer);
    let latest = Mutex::new(audio::State::default());
    let capture = async {
        let mut position = 0u64;
        loop {
            let data = frame::aio::read_message(&mut reader).await?;
            ensure!(data.len() >= 10, "invalid capture frame");
            let epoch = u64::from_le_bytes(data[..8].try_into()?);
            let pcm = &data[8..];
            let state = *latest.lock();
            if !state.capture || epoch != state.capture_epoch {
                continue;
            }
            let packet =
                audio::packet(token, epoch, position, pcm).context("invalid capture frame")?;
            position = position
                .checked_add((pcm.len() / 2) as u64)
                .context("audio clock overflow")?;
            connection.send_datagram(packet.into())?;
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let controls = async {
        loop {
            let state: audio::State = peer::decode(&frame::aio::read_message(&mut recv).await?)?;
            let mut writer = writer.lock().await;
            *latest.lock() = state;
            frame::aio::write_lane(&mut *writer, frame::OUT_LANE_EVENTS, &peer::encode(&state))
                .await?;
            writer.flush().await?;
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let playback = async {
        let mut sequence = audio::Sequence::default();
        loop {
            let packet = connection.read_datagram().await?;
            if let Some(packet) = audio::unpack(&packet, token) {
                let state = *latest.lock();
                if packet.epoch == state.playback_epoch
                    && sequence.accept(packet.epoch, packet.position, packet.pcm.len() / 2)
                {
                    let mut data = packet.epoch.to_le_bytes().to_vec();
                    data.extend_from_slice(packet.pcm);
                    let mut writer = writer.lock().await;
                    frame::aio::write_lane(&mut *writer, frame::OUT_LANE_OUTPUT, &data).await?;
                    writer.flush().await?;
                }
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    tokio::select! { result = capture => result, result = controls => result, result = playback => result }
}
