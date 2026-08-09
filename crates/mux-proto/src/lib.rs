//! mux-proto: the wire protocol, forked from ix.
//!
//! Source of truth upstream:
//! - framing: ix/crates/rpc/transport/src/frame.rs
//! - shell service: ix/crates/ix/rpc/src/session/shell.rs
//!
//! Frame layout: `[u32 LE length][u8 lane][payload]`. PTY bytes travel only on
//! raw byte lanes; the encoded values are handshake, control and status
//! metadata. Wire compatibility with ix is a hard requirement, enforced by
//! golden-byte tests against captures from a real ix VM (M4).

pub mod frame;
pub mod shell;

pub use frame::{read_lane_frame, write_lane, FrameLimits, LaneFrame};
