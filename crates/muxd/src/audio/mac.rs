//! One `CoreAudio` helper process for the selected remote pane. Callbacks do no
//! networking and never wait for a mutex; queues and allocation are bounded.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{ensure, Context, Result};
use mux_proto::{audio, frame, peer};
use parking_lot::Mutex;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::sync::mpsc;

unsafe extern "C" {
    fn mux_audio_create(
        capture: extern "C" fn(*mut c_void, *mut i16, u32),
        playback: extern "C" fn(*mut c_void, *mut i16, u32),
        context: *mut c_void,
        status: *mut i32,
    ) -> *mut c_void;
    fn mux_audio_state(audio: *mut c_void, capture: i32, playback: i32) -> i32;
    fn mux_audio_destroy(audio: *mut c_void);
}

#[derive(Default)]
struct Playback {
    samples: VecDeque<i16>,
    phase: f64,
}

struct Callbacks {
    input: mpsc::Sender<Vec<u8>>,
    output: Mutex<Playback>,
    capture_epoch: AtomicU64,
    input_frames: AtomicU64,
    output_frames: AtomicU64,
}

extern "C" fn capture(context: *mut c_void, samples: *mut i16, count: u32) {
    // SAFETY: AudioQueue owns count initialized samples for this callback. The
    // boxed context lives until both queues have been synchronously disposed.
    let context = unsafe { &*context.cast::<Callbacks>() };
    let samples = unsafe { std::slice::from_raw_parts(samples, count as usize) };
    context
        .input_frames
        .fetch_add(u64::from(count), Ordering::Relaxed);
    for samples in samples.chunks(audio::SAMPLES) {
        let mut bytes = context
            .capture_epoch
            .load(Ordering::Acquire)
            .to_le_bytes()
            .to_vec();
        bytes.extend(samples.iter().flat_map(|value| value.to_le_bytes()));
        let _ = context.input.try_send(bytes);
    }
}

#[allow(
    clippy::cast_possible_truncation,
    reason = "linear interpolation of two i16 samples remains in the i16 range"
)]
extern "C" fn playback(context: *mut c_void, samples: *mut i16, count: u32) {
    // SAFETY: as above; the output buffer is writable for count samples.
    let context = unsafe { &*context.cast::<Callbacks>() };
    let output = unsafe { std::slice::from_raw_parts_mut(samples, count as usize) };
    context
        .output_frames
        .fetch_add(u64::from(count), Ordering::Relaxed);
    output.fill(0);
    let Some(mut ring) = context.output.try_lock() else {
        return;
    };
    let step = if ring.samples.len() > 1920 {
        1.001
    } else if ring.samples.len() < 960 {
        0.999
    } else {
        1.0
    };
    for value in output {
        if ring.samples.len() < 2 {
            ring.phase = 0.0;
            break;
        }
        let a = f64::from(ring.samples[0]);
        let b = f64::from(ring.samples[1]);
        *value = (a + (b - a) * ring.phase) as i16;
        ring.phase += step;
        while ring.phase >= 1.0 {
            ring.samples.pop_front();
            ring.phase -= 1.0;
        }
    }
}

struct Device {
    handle: *mut c_void,
    callbacks: Box<Callbacks>,
}

impl Device {
    fn open() -> Result<(Self, mpsc::Receiver<Vec<u8>>)> {
        let (input, captured) = mpsc::channel(8);
        let mut callbacks = Box::new(Callbacks {
            input,
            output: Mutex::default(),
            capture_epoch: AtomicU64::new(0),
            input_frames: AtomicU64::new(0),
            output_frames: AtomicU64::new(0),
        });
        let mut status = 0;
        // SAFETY: function signatures match coreaudio.c; Box keeps context stable.
        let handle = unsafe {
            mux_audio_create(
                capture,
                playback,
                (&raw mut *callbacks).cast(),
                &raw mut status,
            )
        };
        ensure!(!handle.is_null(), "Mac audio devices could not open (OSStatus {status}); check Mux microphone permission and selected devices");
        Ok((Self { handle, callbacks }, captured))
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        // SAFETY: the handle was returned by mux_audio_create and is disposed
        // before its boxed callbacks. No callback can outlive this call.
        unsafe {
            mux_audio_destroy(self.handle);
        }
    }
}

struct Abort(tokio::task::JoinHandle<()>);
impl Drop for Abort {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn connect_route(socket: &Path, request: peer::OpenRequest) -> Result<UnixStream> {
    let mut stream = UnixStream::connect(socket)
        .await
        .context("connect local muxd")?;
    frame::aio::write_message(&mut stream, &peer::encode(&request)).await?;
    let (_, payload) =
        tokio::time::timeout(Duration::from_secs(15), frame::aio::read_lane(&mut stream))
            .await??
            .context("audio open closed")?;
    match peer::decode_open_reply(&payload)? {
        Ok(peer::Opened::Audio { .. }) => {}
        Err(error) => anyhow::bail!("{error}"),
        other => anyhow::bail!("unexpected reply {other:?}"),
    }
    Ok(stream)
}

pub async fn run(socket: &Path, request: peer::OpenRequest) -> Result<()> {
    run_ready(socket, request, None).await
}

pub(super) async fn run_ready(
    socket: &Path,
    request: peer::OpenRequest,
    ready: Option<tokio::sync::oneshot::Sender<()>>,
) -> Result<()> {
    // Across host supervisors and explicit CLI clients there is only one
    // hardware owner. The OS releases this lock even after a helper crash.
    let _owner = super::automatic::hardware_owner()?;
    let stream = connect_route(socket, request).await?;
    let (device, mut captured) = Device::open()?;
    if let Some(ready) = ready {
        ready
            .send(())
            .map_err(|()| anyhow::anyhow!("audio acquisition cancelled"))?;
    }
    println!("Audio ready; microphone starts only when the remote app records.");
    let (mut reader, mut writer) = stream.into_split();
    let upload = async {
        while let Some(pcm) = captured.recv().await {
            frame::aio::write_message(&mut writer, &pcm).await?;
            writer.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    };
    let download = async {
        let mut state = audio::State::default();
        let mut previous = (0, 0);
        let mut stalled = 0;
        let mut last_control = Instant::now();
        let mut drain_until: Option<Instant> = None;
        let mut drain_clock = tokio::time::interval(Duration::from_millis(20));
        let mut clock = tokio::time::interval(Duration::from_secs(1));
        // A dedicated frame reader avoids cancelling a partially read frame
        // when the device-health timer fires.
        let (messages, mut received) = mpsc::channel(16);
        let read_task = tokio::spawn(async move {
            while let Ok(Some(message)) = frame::aio::read_lane(&mut reader).await {
                if messages.send(message).await.is_err() {
                    break;
                }
            }
        });
        let _abort = Abort(read_task);
        loop {
            tokio::select! {
                message = received.recv() => {
                    let (lane, payload) = message.context("remote audio disconnected")?;
                    match lane {
                        frame::OUT_LANE_EVENTS => {
                            let next: audio::State = peer::decode(&payload)?;
                            last_control = Instant::now();
                            let changed = next != state;
                            if next.playback_epoch != state.playback_epoch {
                                // SAFETY: stop the old queue before discarding its generation.
                                let error = unsafe { mux_audio_state(device.handle, i32::from(state.capture), 0) };
                                ensure!(error == 0, "Mac playback reset failed (OSStatus {error})");
                                let mut output = device.callbacks.output.lock();
                                output.samples.clear(); output.phase = 0.0;
                            }
                            if state.playback && !next.playback { drain_until = Some(Instant::now() + Duration::from_millis(200)); }
                            if next.playback { drain_until = None; }
                            state = next;
                            device.callbacks.capture_epoch.store(state.capture_epoch, Ordering::Release);
                            // SAFETY: handle remains alive until this future ends.
                            let error = unsafe { mux_audio_state(device.handle, i32::from(state.capture), i32::from(state.playback || drain_until.is_some())) };
                            ensure!(error == 0, "Mac audio state failed (OSStatus {error})");
                            if changed {
                                println!("Microphone {}; speaker {}.", if state.capture {"active"} else {"off"}, if state.playback {"active"} else {"off"});
                                stalled = 0;
                            }
                        }
                        frame::OUT_LANE_OUTPUT => {
                            ensure!(payload.len() >= 10 && payload.len() <= audio::MAX_PCM + 8 && payload.len().is_multiple_of(2), "invalid playback frame");
                            let epoch = u64::from_le_bytes(payload[..8].try_into()?);
                            if epoch != state.playback_epoch || (!state.playback && drain_until.is_none()) { continue; }
                            let mut output = device.callbacks.output.lock();
                            for sample in payload[8..].chunks_exact(2) { output.samples.push_back(i16::from_le_bytes([sample[0],sample[1]])); }
                            while output.samples.len() > 4800 { output.samples.pop_front(); }
                        }
                        _ => anyhow::bail!("unexpected audio frame"),
                    }
                }
                _ = drain_clock.tick(), if drain_until.is_some() => {
                    if drain_until.is_some_and(|deadline| Instant::now() >= deadline) {
                        drain_until = None;
                        // SAFETY: the handle is still owned by this future.
                        let error = unsafe { mux_audio_state(device.handle, i32::from(state.capture), 0) };
                        ensure!(error == 0, "Mac playback drain failed (OSStatus {error})");
                        let mut output = device.callbacks.output.lock(); output.samples.clear(); output.phase = 0.0;
                    }
                }
                _ = clock.tick() => {
                    ensure!(last_control.elapsed() < Duration::from_secs(2), "audio control connection stopped responding");
                    let now = (device.callbacks.input_frames.load(Ordering::Relaxed), device.callbacks.output_frames.load(Ordering::Relaxed));
                    if (state.capture && now.0 == previous.0) || (state.playback && now.1 == previous.1) { stalled += 1; } else { stalled = 0; }
                    ensure!(stalled < 3, "Mac audio device stopped; select your devices and enable sharing again");
                    previous = now;
                }
            }
        }
        #[allow(unreachable_code)]
        Ok::<_, anyhow::Error>(())
    };
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! { result = upload => result, result = download => result, result = tokio::signal::ctrl_c() => Ok(result?), _ = terminate.recv() => Ok(()) }
}
