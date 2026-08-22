//! muxd: the session daemon.
//!
//! The daemon is a binary; this library exists so integration tests can
//! drive the listeners in-process on ephemeral ports.

pub mod broker;
pub mod manager;
pub mod migrate;
pub mod pty;
pub mod quic;
pub mod server;
pub mod tls;
