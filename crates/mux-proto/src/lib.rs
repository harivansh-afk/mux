//! The wire between muxd and its clients: the lane framing (`frame`)
//! and the values that travel on it (`peer`).

pub mod frame;
pub mod peer;
