//! The two envelopes on the wire, defined once.
//!
//! Lane frame: `[u32 LE length][u8 lane][payload]`, where `length` counts
//! the lane byte plus the payload. Message: `[u32 LE length][bytes]`, the
//! handshake envelope. Both layouts are byte-compatible with ix's
//! rpc-transport `frame.rs`; `encode`/`parse_header` are the only code
//! that may lay out those bytes.

use std::io::{self, Read, Write};

/// Public-peer frame cap (ix uses 64 MiB public, 512 MiB for mTLS peers).
pub const MAX_FRAME_SIZE: u32 = 64 * 1024 * 1024;
/// Handshake cap, matching ix's `MAX_LOCAL_REQUEST_BYTES`.
pub const MAX_REQUEST_BYTES: u32 = 1024 * 1024;

/// Lane ids, ingress then egress. The two directions number
/// independently: lane 0 is `input` from a client and `opened` from the
/// daemon.
pub const IN_LANE_INPUT: u8 = 0;
pub const IN_LANE_CONTROL: u8 = 1;
pub const OUT_LANE_OPENED: u8 = 0;
pub const OUT_LANE_OUTPUT: u8 = 1;
pub const OUT_LANE_EVENTS: u8 = 2;

/// Length prefix plus lane byte.
const HEADER_LEN: usize = 5;

fn invalid(message: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn payload_len(len: u32) -> io::Result<usize> {
    usize::try_from(len).map_err(|_| invalid(format!("length {len} exceeds this machine's usize")))
}

/// `[u32 LE len][u8 lane][payload]`, `len` = 1 + `payload.len()`.
///
/// # Errors
///
/// The payload does not fit under [`MAX_FRAME_SIZE`].
pub fn encode(lane: u8, payload: &[u8]) -> io::Result<Vec<u8>> {
    let len = u32::try_from(payload.len())
        .ok()
        .and_then(|n| n.checked_add(1))
        .filter(|n| *n <= MAX_FRAME_SIZE)
        .ok_or_else(|| {
            invalid(format!(
                "frame payload {} exceeds {MAX_FRAME_SIZE}",
                payload.len()
            ))
        })?;
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&len.to_le_bytes());
    out.push(lane);
    out.extend_from_slice(payload);
    Ok(out)
}

/// The 5-byte header: `(lane, payload length)`.
///
/// # Errors
///
/// The length is zero (no room for the lane byte) or above
/// [`MAX_FRAME_SIZE`].
pub fn parse_header(bytes: [u8; HEADER_LEN]) -> io::Result<(u8, usize)> {
    let len = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    if len == 0 {
        return Err(invalid("zero-length frame (missing lane byte)".into()));
    }
    if len > MAX_FRAME_SIZE {
        return Err(invalid(format!(
            "frame length {len} exceeds {MAX_FRAME_SIZE}"
        )));
    }
    Ok((bytes[4], payload_len(len - 1)?))
}

/// `[u32 LE len][bytes]`, the handshake envelope.
///
/// # Errors
///
/// `bytes` is empty or does not fit under [`MAX_REQUEST_BYTES`].
pub fn encode_message(bytes: &[u8]) -> io::Result<Vec<u8>> {
    let len = u32::try_from(bytes.len())
        .ok()
        .filter(|n| *n > 0 && *n <= MAX_REQUEST_BYTES)
        .ok_or_else(|| invalid(format!("bad message length {}", bytes.len())))?;
    let mut out = Vec::with_capacity(4 + bytes.len());
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(bytes);
    Ok(out)
}

/// The message length prefix.
///
/// # Errors
///
/// The length is zero or above [`MAX_REQUEST_BYTES`].
pub fn parse_message_len(bytes: [u8; 4]) -> io::Result<usize> {
    let len = u32::from_le_bytes(bytes);
    if len == 0 || len > MAX_REQUEST_BYTES {
        return Err(invalid(format!("bad message length {len}")));
    }
    payload_len(len)
}

/// # Errors
///
/// [`encode`] rejects the payload, or the writer fails.
pub fn write_lane<W: Write>(w: &mut W, lane: u8, payload: &[u8]) -> io::Result<()> {
    w.write_all(&encode(lane, payload)?)
}

/// Read one lane frame, `Ok(None)` on EOF at a frame boundary.
///
/// # Errors
///
/// [`parse_header`] rejects the header, or the reader fails (EOF partway
/// through a frame included).
pub fn read_lane<R: Read>(r: &mut R) -> io::Result<Option<(u8, Vec<u8>)>> {
    let mut header = [0u8; HEADER_LEN];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let (lane, len) = parse_header(header)?;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload)?;
    Ok(Some((lane, payload)))
}

/// # Errors
///
/// [`encode_message`] rejects the bytes, or the writer fails.
pub fn write_message<W: Write>(w: &mut W, bytes: &[u8]) -> io::Result<()> {
    w.write_all(&encode_message(bytes)?)
}

/// # Errors
///
/// [`parse_message_len`] rejects the prefix, or the reader fails.
pub fn read_message<R: Read>(r: &mut R) -> io::Result<Vec<u8>> {
    let mut prefix = [0u8; 4];
    r.read_exact(&mut prefix)?;
    let mut body = vec![0u8; parse_message_len(prefix)?];
    r.read_exact(&mut body)?;
    Ok(body)
}

/// The same four over tokio's traits. muxd enables this; mux-attach is
/// sync and must not link tokio.
#[cfg(feature = "tokio")]
pub mod aio {
    use std::io;

    use tokio::io::{AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _};

    use super::{encode, encode_message, parse_header, parse_message_len, HEADER_LEN};

    /// # Errors
    ///
    /// [`encode`] rejects the payload, or the writer fails.
    pub async fn write_lane<W: AsyncWrite + Unpin>(
        w: &mut W,
        lane: u8,
        payload: &[u8],
    ) -> io::Result<()> {
        w.write_all(&encode(lane, payload)?).await
    }

    /// Read one lane frame, `Ok(None)` on EOF at a frame boundary.
    ///
    /// # Errors
    ///
    /// [`parse_header`] rejects the header, or the reader fails.
    pub async fn read_lane<R: AsyncRead + Unpin>(r: &mut R) -> io::Result<Option<(u8, Vec<u8>)>> {
        let mut header = [0u8; HEADER_LEN];
        match r.read_exact(&mut header).await {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e),
        }
        let (lane, len) = parse_header(header)?;
        let mut payload = vec![0u8; len];
        r.read_exact(&mut payload).await?;
        Ok(Some((lane, payload)))
    }

    /// # Errors
    ///
    /// [`encode_message`] rejects the bytes, or the writer fails.
    pub async fn write_message<W: AsyncWrite + Unpin>(w: &mut W, bytes: &[u8]) -> io::Result<()> {
        w.write_all(&encode_message(bytes)?).await
    }

    /// # Errors
    ///
    /// [`parse_message_len`] rejects the prefix, or the reader fails.
    pub async fn read_message<R: AsyncRead + Unpin>(r: &mut R) -> io::Result<Vec<u8>> {
        let mut prefix = [0u8; 4];
        r.read_exact(&mut prefix).await?;
        let mut body = vec![0u8; parse_message_len(prefix)?];
        r.read_exact(&mut body).await?;
        Ok(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut buf = Vec::new();
        write_lane(&mut buf, 1, b"hello").unwrap();
        write_lane(&mut buf, 0, b"").unwrap();
        write_message(&mut buf, b"tail").unwrap();
        let mut r = buf.as_slice();
        assert_eq!(read_lane(&mut r).unwrap().unwrap(), (1, b"hello".to_vec()));
        assert_eq!(read_lane(&mut r).unwrap().unwrap(), (0, vec![]));
        assert_eq!(read_message(&mut r).unwrap(), b"tail".to_vec());
        assert!(read_lane(&mut r).unwrap().is_none());
    }

    #[test]
    fn wire_layout_is_exact() {
        // [u32 LE len=6][lane=2][payload="hello"]
        let mut buf = Vec::new();
        write_lane(&mut buf, 2, b"hello").unwrap();
        assert_eq!(buf, [6, 0, 0, 0, 2, b'h', b'e', b'l', b'l', b'o']);
    }

    #[test]
    fn message_layout_is_exact() {
        // [u32 LE len=5][payload="hello"]
        assert_eq!(
            encode_message(b"hello").unwrap(),
            [5, 0, 0, 0, b'h', b'e', b'l', b'l', b'o']
        );
    }

    #[test]
    fn rejects_bad_lengths() {
        let mut oversized = (MAX_FRAME_SIZE + 1).to_le_bytes().to_vec();
        oversized.push(0);
        assert_eq!(
            read_lane(&mut oversized.as_slice()).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            parse_header([0, 0, 0, 0, 0]).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            parse_message_len((MAX_REQUEST_BYTES + 1).to_le_bytes())
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
    }
}
