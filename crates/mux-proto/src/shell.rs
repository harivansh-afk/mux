//! Shell service types, mirroring ix/crates/ix/rpc/src/session/shell.rs.
//!
//! Lane ids (declaration order upstream, restated as consts there):
//! ingress `input=0`, `control=1`; egress `opened=0`, `output=1`, `events=2`.
//!
//! Encoding note: upstream serializes these with ix's `codec` crate, a slot-table
//! format (`[u32 slot_count][(offset,len) x N][payload]`, version 2, append-only
//! `#[wire(N)]` slots). We do NOT vendor that 6k-LOC nightly-only crate; these
//! seven types get a minimal hand-written encoder in M4, validated by
//! golden-byte fixtures captured from a real ix VM. Until M4, mux-attach reaches
//! ix VMs by exec-ing `ix shell <vm>` and muxd peers use these Rust types over
//! a serde encoding of our own (same lane framing).

pub const DEFAULT_COLS: u16 = 80;
pub const DEFAULT_ROWS: u16 = 24;

pub const IN_LANE_INPUT: u8 = 0;
pub const IN_LANE_CONTROL: u8 = 1;
pub const OUT_LANE_OPENED: u8 = 0;
pub const OUT_LANE_OUTPUT: u8 = 1;
pub const OUT_LANE_EVENTS: u8 = 2;
