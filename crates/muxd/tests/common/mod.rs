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

use mux_proto::frame;
use mux_proto::frame::{OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT};
use mux_proto::peer::{self, OpenMode, OpenReply, OpenRequest};
use tokio::io::{AsyncRead, AsyncWrite};

/// Long enough to be immune to a loaded box, short enough that a hang
/// fails the run instead of stalling it.
pub const PATIENCE: Duration = Duration::from_secs(10);

/// NixOS keeps coreutils in PATH rather than /bin.
pub fn cat() -> String {
    let path = std::env::var_os("PATH").expect("test PATH");
    std::env::split_paths(&path)
        .map(|dir| dir.join("cat"))
        .find(|candidate| candidate.is_file())
        .expect("cat on test PATH")
        .to_string_lossy()
        .into_owned()
}

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
    frame::aio::write_message(w, &peer::encode(request))
        .await
        .expect("write request");
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, lane: u8, payload: &[u8]) {
    frame::aio::write_lane(w, lane, payload)
        .await
        .expect("write frame");
}

/// One frame, or `None` when the peer closed at a frame boundary.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Option<(u8, Vec<u8>)> {
    tokio::time::timeout(PATIENCE, frame::aio::read_lane(r))
        .await
        .expect("frame timed out")
        .expect("read frame")
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
