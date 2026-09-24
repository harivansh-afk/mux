//! A durable offer of Mac devices, separate from each short-lived pane route.
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use anyhow::{ensure, Context, Result};
use mux_proto::{audio, frame, peer};
use parking_lot::Mutex;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};

use crate::manager::Manager;

pub const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(8);

pub(crate) struct Permit {
    pub request: audio::Request,
    pub valid: AtomicBool,
    pub claimed: AtomicBool,
    pub connected: Arc<AtomicBool>,
}

#[cfg(target_os = "linux")]
struct Pending(Arc<Permit>);
#[cfg(target_os = "linux")]
impl Drop for Pending {
    fn drop(&mut self) {
        self.0.valid.store(false, Ordering::Release);
    }
}

struct Acquisition {
    request: audio::Request,
    ready: oneshot::Sender<Result<(), String>>,
}

pub(crate) struct Provider {
    #[cfg_attr(
        target_os = "macos",
        allow(dead_code, reason = "requests originate at Linux ALSA devices")
    )]
    requests: mpsc::Sender<Acquisition>,
    #[cfg(target_os = "linux")]
    gate: tokio::sync::Mutex<()>,
    pending: Mutex<Weak<Permit>>,
    connected: Arc<AtomicBool>,
}

impl Provider {
    pub fn permit(&self, request: &audio::Request) -> Option<Arc<Permit>> {
        self.pending.lock().upgrade().filter(|permit| {
            permit.request == *request
                && permit.valid.load(Ordering::Acquire)
                && self.connected.load(Ordering::Acquire)
        })
    }
}

/// The caller owns one open ALSA device, even while that device is stopped.
#[cfg(target_os = "linux")]
pub(crate) struct DeviceLease(pub Arc<super::Route>);
#[cfg(target_os = "linux")]
impl Drop for DeviceLease {
    fn drop(&mut self) {
        self.0.users.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(target_os = "linux")]
impl super::Registry {
    fn join(&self, name: &str, attachment: u64, activate: bool) -> Option<DeviceLease> {
        // The expiry check holds this same lock before closing admission.
        let routes = self.routes.lock();
        let route = routes.get(name)?.upgrade()?;
        if route.attachment != attachment
            || !route.accepting.load(Ordering::Acquire)
            || route.events.is_closed()
        {
            return None;
        }
        if !activate && !route.ready.load(Ordering::Acquire) {
            return None;
        }
        if activate {
            route.ready.store(true, Ordering::Release);
        }
        route.users.fetch_add(1, Ordering::AcqRel);
        Some(DeviceLease(route))
    }

    pub(crate) async fn acquire(
        &self,
        session: &crate::manager::PtySession,
    ) -> Result<DeviceLease> {
        let (attachment, connection) = session
            .client
            .lock()
            .as_ref()
            .map(|client| (client.id.raw(), client.connection))
            .context("terminal is detached")?;
        if let Some(route) = self.join(&session.name, attachment, false) {
            return Ok(route);
        }
        let connection = connection.context("terminal has no remote audio provider")?;
        let provider = self
            .providers
            .lock()
            .get(&connection)
            .and_then(Weak::upgrade)
            .context("Mac audio is unavailable; enable Automatic Remote Audio in Mux")?;
        let _gate = provider.gate.lock().await;
        ensure!(
            session.client.lock().as_ref().is_some_and(
                |client| client.id.raw() == attachment && client.connection == Some(connection)
            ),
            "terminal attachment changed"
        );
        if let Some(route) = self.join(&session.name, attachment, false) {
            return Ok(route);
        }
        let permit = Arc::new(Permit {
            request: audio::Request {
                id: rand::random(),
                name: session.name.clone(),
                attachment,
            },
            valid: AtomicBool::new(true),
            claimed: AtomicBool::new(false),
            connected: provider.connected.clone(),
        });
        let _pending = Pending(permit.clone());
        *provider.pending.lock() = Arc::downgrade(&permit);
        let (ready, response) = oneshot::channel();
        provider
            .requests
            .send(Acquisition {
                request: permit.request.clone(),
                ready,
            })
            .await
            .context("Mac audio provider disconnected")?;
        response
            .await
            .context("Mac audio provider disconnected")?
            .map_err(anyhow::Error::msg)?;
        ensure!(
            session.client.lock().as_ref().is_some_and(
                |client| client.id.raw() == attachment && client.connection == Some(connection)
            ),
            "terminal attachment changed"
        );
        ensure!(
            provider.connected.load(Ordering::Acquire) && !session.exited.load(Ordering::Acquire),
            "audio provider or terminal closed"
        );
        let lease = self
            .join(&session.name, attachment, true)
            .context("Mac audio route closed before it became ready")?;
        permit.claimed.store(true, Ordering::Release);
        Ok(lease)
    }
}

pub async fn serve<R, W>(
    manager: Manager,
    connection: usize,
    mut reader: R,
    mut writer: W,
) -> Result<()>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let (requests, mut pending) = mpsc::channel::<Acquisition>(8);
    let connected = Arc::new(AtomicBool::new(true));
    let _registration = Registration(connected.clone());
    let provider = Arc::new(Provider {
        connected,
        requests,
        #[cfg(target_os = "linux")]
        gate: tokio::sync::Mutex::new(()),
        pending: Mutex::new(Weak::new()),
    });
    let registered = {
        let mut providers = manager.audio.providers.lock();
        providers.retain(|_, provider| provider.strong_count() > 0);
        if !manager.audio.enabled.load(Ordering::Acquire) {
            Err("Linux audio devices are not enabled on this host")
        } else if providers.get(&connection).and_then(Weak::upgrade).is_some() {
            Err("this connection already has an audio provider")
        } else {
            providers.insert(connection, Arc::downgrade(&provider));
            Ok(peer::Opened::AudioProvider)
        }
    };
    let reply = registered.map_err(|error| peer::OpenError::new(peer::ErrorKind::Other, error));
    crate::server::reply(&mut writer, &reply).await?;
    if reply.is_err() {
        return Ok(());
    }
    let mut eof = [0];
    loop {
        let acquisition = tokio::select! {
            _ = reader.read(&mut eof) => break,
            request = pending.recv() => request.context("audio provider closed")?,
        };
        if acquisition.ready.is_closed() {
            continue;
        }
        frame::aio::write_lane(
            &mut writer,
            frame::OUT_LANE_EVENTS,
            &peer::encode(&acquisition.request),
        )
        .await?;
        writer.flush().await?;
        // A cancelled partial read ends this registration; never decode its tail
        // as a different reply after an acquisition deadline.
        let response =
            tokio::time::timeout(ACQUIRE_TIMEOUT, frame::aio::read_message(&mut reader)).await??;
        let ready: audio::Ready = peer::decode(&response)?;
        ensure!(
            ready.id == acquisition.request.id,
            "unexpected audio readiness reply"
        );
        let result = ready.error.map_or(Ok(()), Err);
        let _ = acquisition.ready.send(result);
    }
    Ok(())
}

struct Registration(Arc<AtomicBool>);
impl Drop for Registration {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}
