//! Lane framing: `[u32 LE length][u8 lane][payload]`.
//!
//! `length` counts the lane byte plus the payload, matching ix's
//! rpc-transport `frame.rs`. Keep this file byte-compatible with upstream.

use std::io::{self, Read, Write};

/// Public-peer frame cap (ix uses 64 MiB public, 512 MiB for mTLS peers).
pub const MAX_FRAME_SIZE: u32 = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameLimits {
    pub max_frame_size: u32,
}

impl Default for FrameLimits {
    fn default() -> Self {
        Self {
            max_frame_size: MAX_FRAME_SIZE,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneFrame {
    pub lane: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("frame length {0} exceeds limit {1}")]
    TooLarge(u32, u32),
    #[error("zero-length frame (missing lane byte)")]
    Empty,
    #[error(transparent)]
    Io(#[from] io::Error),
}

/// Write one lane frame.
///
/// # Errors
///
/// Returns [`FrameError::TooLarge`] when the payload cannot be described by
/// the u32 length prefix, or [`FrameError::Io`] when the writer fails.
pub fn write_lane<W: Write>(w: &mut W, lane: u8, payload: &[u8]) -> Result<(), FrameError> {
    let len = u32::try_from(payload.len())
        .ok()
        .and_then(|n| n.checked_add(1))
        .ok_or(FrameError::TooLarge(u32::MAX, MAX_FRAME_SIZE))?;
    w.write_all(&len.to_le_bytes())?;
    w.write_all(&[lane])?;
    w.write_all(payload)?;
    Ok(())
}

/// Read one lane frame. Returns `Ok(None)` on clean EOF at a frame boundary.
///
/// # Errors
///
/// Returns [`FrameError::Empty`] on a zero-length frame,
/// [`FrameError::TooLarge`] when the length prefix exceeds
/// [`FrameLimits::max_frame_size`], or [`FrameError::Io`] on read failure
/// (including EOF inside a frame).
pub fn read_lane_frame<R: Read>(
    r: &mut R,
    limits: FrameLimits,
) -> Result<Option<LaneFrame>, FrameError> {
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let len = u32::from_le_bytes(len_buf);
    if len == 0 {
        return Err(FrameError::Empty);
    }
    if len > limits.max_frame_size {
        return Err(FrameError::TooLarge(len, limits.max_frame_size));
    }
    let mut lane = [0u8; 1];
    r.read_exact(&mut lane)?;
    let mut payload = vec![0u8; (len - 1) as usize];
    r.read_exact(&mut payload)?;
    Ok(Some(LaneFrame {
        lane: lane[0],
        payload,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut buf = Vec::new();
        write_lane(&mut buf, 1, b"hello").unwrap();
        write_lane(&mut buf, 0, b"").unwrap();
        let mut r = buf.as_slice();
        let f1 = read_lane_frame(&mut r, FrameLimits::default())
            .unwrap()
            .unwrap();
        assert_eq!(
            f1,
            LaneFrame {
                lane: 1,
                payload: b"hello".to_vec()
            }
        );
        let f2 = read_lane_frame(&mut r, FrameLimits::default())
            .unwrap()
            .unwrap();
        assert_eq!(
            f2,
            LaneFrame {
                lane: 0,
                payload: vec![]
            }
        );
        assert!(read_lane_frame(&mut r, FrameLimits::default())
            .unwrap()
            .is_none());
    }

    #[test]
    fn wire_layout_is_exact() {
        // [u32 LE len=6][lane=2][payload="hello"]
        let mut buf = Vec::new();
        write_lane(&mut buf, 2, b"hello").unwrap();
        assert_eq!(buf, [6, 0, 0, 0, 2, b'h', b'e', b'l', b'l', b'o']);
    }

    #[test]
    fn rejects_oversized() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&(MAX_FRAME_SIZE + 1).to_le_bytes());
        buf.push(0);
        let err = read_lane_frame(&mut buf.as_slice(), FrameLimits::default()).unwrap_err();
        assert!(matches!(err, FrameError::TooLarge(_, _)));
    }
}
