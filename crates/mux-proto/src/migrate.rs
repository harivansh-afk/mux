//! Daemon self-upgrade contract (M2.5): a new muxd adopts the old one's
//! live ptys over a unix socket with `SCM_RIGHTS` fd passing.
//!
//! Wire: one `[u32 LE len][postcard MigratePayload]` message with the PTY
//! master fds attached as `SCM_RIGHTS` control data, one fd per pty, in
//! `ptys` order. Unlike upstream ix-console, the payload carries a screen
//! snapshot per pty (`render_screen_bytes`), so scrollback and screen
//! state survive the handoff instead of being rebuilt empty.

use serde::{Deserialize, Serialize};

pub const MIGRATE_VERSION: u32 = 1;
pub const MAX_MIGRATE_FDS: usize = 256;
/// The successor's "they are mine now" byte, written once every pty in
/// the payload has been adopted. The predecessor does not exit until it
/// lands: an fd that has left the old process but reached no new one is a
/// session nobody can serve.
pub const MIGRATE_ACK: u8 = 0xAC;

/// Short /tmp path (`sun_path` is 104 bytes on darwin), per-uid.
#[must_use]
pub fn migrate_socket_path(uid: u32) -> std::path::PathBuf {
    std::path::PathBuf::from(format!("/tmp/muxd-{uid}-migrate.sock"))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MigratePty {
    pub name: String,
    pub command: Vec<String>,
    pub child_pid: i32,
    pub cols: u16,
    pub rows: u16,
    /// `render_screen_bytes()` of the old daemon's terminal at handoff;
    /// the new daemon feeds it into a fresh VT before reading the fd.
    pub screen: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MigratePayload {
    pub version: u32,
    pub ptys: Vec<MigratePty>,
}
