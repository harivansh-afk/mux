//! Fixed-format audio v1: mono, 48 kHz, signed little-endian 16-bit PCM.
//! Reliable messages own lifetime. Datagram tokens belong to one connection
//! and are replaced on every open; sequence numbers count samples, not bytes.

use serde::{Deserialize, Serialize};

pub const RATE: usize = 48_000;
pub const SAMPLES: usize = 480;
pub const MAX_PCM: usize = SAMPLES * 2;
pub const HEADER: usize = 24;
pub const MAX_PACKET: usize = HEADER + MAX_PCM;

/// Identifies a single acquisition, including the terminal attachment it names.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    pub id: u64,
    pub name: String,
    pub attachment: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Ready {
    pub id: u64,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    pub capture: bool,
    pub playback: bool,
    pub capture_epoch: u64,
    pub playback_epoch: u64,
}

pub fn packet(token: u64, epoch: u64, position: u64, pcm: &[u8]) -> Option<Vec<u8>> {
    if pcm.is_empty() || pcm.len() > MAX_PCM || !pcm.len().is_multiple_of(2) {
        return None;
    }
    let mut out = Vec::with_capacity(HEADER + pcm.len());
    out.extend_from_slice(&token.to_le_bytes());
    out.extend_from_slice(&epoch.to_le_bytes());
    out.extend_from_slice(&position.to_le_bytes());
    out.extend_from_slice(pcm);
    Some(out)
}

#[derive(Debug, PartialEq, Eq)]
pub struct Packet<'a> {
    pub epoch: u64,
    pub position: u64,
    pub pcm: &'a [u8],
}

pub fn unpack(data: &[u8], token: u64) -> Option<Packet<'_>> {
    if !(HEADER + 2..=MAX_PACKET).contains(&data.len()) || !data.len().is_multiple_of(2) {
        return None;
    }
    let found = u64::from_le_bytes(data[..8].try_into().ok()?);
    let epoch = u64::from_le_bytes(data[8..16].try_into().ok()?);
    let position = u64::from_le_bytes(data[16..HEADER].try_into().ok()?);
    (found == token).then_some(Packet {
        epoch,
        position,
        pcm: &data[HEADER..],
    })
}

/// Drop duplicates/late media. A gap is loss, never a reason to replay audio.
#[derive(Default)]
pub struct Sequence {
    epoch: u64,
    end: Option<u64>,
}

impl Sequence {
    pub fn accept(&mut self, epoch: u64, position: u64, samples: usize) -> bool {
        let Some(end) = position.checked_add(samples as u64) else {
            return false;
        };
        if epoch < self.epoch {
            return false;
        }
        if epoch > self.epoch {
            self.epoch = epoch;
            self.end = None;
        }
        if self.end.is_some_and(|previous| position < previous) {
            return false;
        }
        self.end = Some(end);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_are_bounded_and_bound_to_their_open() {
        let data = packet(7, 1, 480, &[1, 2, 3, 4]).unwrap();
        assert_eq!(
            unpack(&data, 7),
            Some(Packet {
                epoch: 1,
                position: 480,
                pcm: [1, 2, 3, 4].as_slice()
            })
        );
        assert!(unpack(&data, 8).is_none());
        assert!(packet(7, 1, 0, &[0; MAX_PCM + 2]).is_none());
        assert!(packet(7, 1, 0, &[1]).is_none());
        for length in 0..HEADER + 2 {
            assert!(unpack(&data[..length.min(data.len())], 7).is_none());
        }
    }

    #[test]
    fn sequence_does_not_replay_or_wrap() {
        let mut sequence = Sequence::default();
        assert!(sequence.accept(1, 480, 480));
        assert!(!sequence.accept(1, 480, 480));
        assert!(!sequence.accept(1, 0, 480));
        assert!(sequence.accept(1, 1440, 480));
        assert!(!sequence.accept(1, u64::MAX, 480));
        assert!(sequence.accept(2, 0, 480));
        assert!(!sequence.accept(1, 1920, 480));
    }
}
