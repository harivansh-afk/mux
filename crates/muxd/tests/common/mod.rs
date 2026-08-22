//! The wire, once, for every muxd integration test.
//!
//! `[u32 LE len][request]` to open, `[u32 LE len][u8 lane][payload]` after.
//! Everything here is generic over `AsyncRead`/`AsyncWrite` so the unix
//! tests and the QUIC test share it: quinn's `SendStream` and `RecvStream`
//! implement the tokio traits.
//!
//! Cargo compiles `tests/common/mod.rs` as a module of each test binary,
//! and no binary uses all of it.
#![allow(dead_code, reason = "each test binary uses a subset")]

use std::path::PathBuf;
use std::time::Duration;

use mux_proto::peer::{self, OpenMode, OpenReply, OpenRequest};
use mux_proto::shell::{OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT};
use tokio::io::{AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _};

/// Long enough to be immune to a loaded box, short enough that a hang
/// fails the run instead of stalling it.
pub const PATIENCE: Duration = Duration::from_secs(10);

/// Short /tmp path: `sun_path` is 104 bytes on darwin.
pub fn temp_socket(what: &str) -> PathBuf {
    let path = PathBuf::from(format!("/tmp/muxd-t-{}-{what}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

pub fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// An open request at the current protocol version, 80x24.
pub fn request(token: Option<&str>, target: Option<&str>, mode: OpenMode) -> OpenRequest {
    OpenRequest {
        version: peer::PROTOCOL_VERSION,
        cols: 80,
        rows: 24,
        term: Some("xterm-ghostty".into()),
        token: token.map(ToString::to_string),
        target: target.map(ToString::to_string),
        mode,
    }
}

pub async fn write_request<W: AsyncWrite + Unpin>(w: &mut W, request: &OpenRequest) {
    let bytes = peer::encode(request);
    let len = u32::try_from(bytes.len()).expect("request length");
    w.write_all(&len.to_le_bytes()).await.expect("write length");
    w.write_all(&bytes).await.expect("write request");
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, lane: u8, payload: &[u8]) {
    let len = u32::try_from(payload.len() + 1).expect("frame length");
    w.write_all(&len.to_le_bytes()).await.expect("write length");
    w.write_all(&[lane]).await.expect("write lane");
    w.write_all(payload).await.expect("write payload");
}

/// One frame, or `None` when the peer closed at a frame boundary.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Option<(u8, Vec<u8>)> {
    let read = async {
        let len = r.read_u32_le().await.ok()?;
        let lane = r.read_u8().await.ok()?;
        let mut payload = vec![0u8; (len - 1) as usize];
        r.read_exact(&mut payload).await.ok()?;
        Some((lane, payload))
    };
    tokio::time::timeout(PATIENCE, read)
        .await
        .expect("frame timed out")
}

pub async fn read_reply<R: AsyncRead + Unpin>(r: &mut R) -> OpenReply {
    let (lane, payload) = read_frame(r).await.expect("reply frame");
    assert_eq!(lane, OUT_LANE_OPENED);
    peer::decode(&payload).expect("decode reply")
}

/// The reattach replay always follows the reply, even when empty.
pub async fn read_dump<R: AsyncRead + Unpin>(r: &mut R) -> Vec<u8> {
    let (lane, payload) = read_frame(r).await.expect("dump frame");
    assert_eq!(lane, OUT_LANE_OUTPUT);
    payload
}

/// Drain output frames until `needle` shows up. The pty echoes the line and
/// `cat` writes it again, so the bytes can arrive in any grouping. A stream
/// that ends first is a failure, not a short answer.
pub async fn read_output_until<R: AsyncRead + Unpin>(r: &mut R, needle: &[u8]) -> Vec<u8> {
    let mut seen = Vec::new();
    while !contains(&seen, needle) {
        let Some((lane, payload)) = read_frame(r).await else {
            panic!("connection ended before {needle:?}");
        };
        match lane {
            OUT_LANE_OUTPUT => seen.extend_from_slice(&payload),
            OUT_LANE_EVENTS => panic!("unexpected event before {needle:?}"),
            other => panic!("unexpected lane {other}"),
        }
    }
    seen
}
