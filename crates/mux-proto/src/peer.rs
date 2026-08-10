//! muxd's native peer protocol: the ix lane framing carrying
//! postcard-encoded control values.
//!
//! ix VMs speak the ix codec encoding (`shell.rs` types, M4 golden-byte
//! work); mux peers (Mux.app panes via mux-attach <-> muxd) speak these
//! types. Same framing, same lane numbering, so mux-attach's relay loop
//! is transport-agnostic.
//!
//! Handshake: `[u32 LE len][postcard OpenRequest]`, then lane frames.
//! Ptys are keyed by client-chosen name (the pane id), so "attach or
//! create" is one round trip and restore needs no id handoff.

use serde::{Deserialize, Serialize};

/// Handshake cap, matching ix's `MAX_LOCAL_REQUEST_BYTES`.
pub const MAX_REQUEST_BYTES: u32 = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenRequest {
    pub cols: u16,
    pub rows: u16,
    pub term: Option<String>,
    pub mode: OpenMode,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum OpenMode {
    /// Attach to the pty named `name`, creating it first if missing
    /// (running `command`, or the user's shell when empty, at `cwd`).
    Open {
        name: String,
        cwd: Option<String>,
        command: Vec<String>,
    },
    /// List ptys.
    List,
    /// Kill the pty named `name` (SIGKILL to its process group).
    Kill { name: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Opened {
    Attached { name: String, created: bool },
    Listed { ptys: Vec<PtyInfo> },
    Killed { existed: bool },
}

pub type OpenReply = Result<Opened, String>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PtyInfo {
    pub name: String,
    pub command: Vec<String>,
    pub attached: bool,
    pub exited: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ClientControl {
    Resize { cols: u16, rows: u16 },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ServerEvent {
    Exit { code: i32 },
    Detached,
}

/// # Panics
///
/// Never for the types in this module: postcard encoding of plain data
/// enums cannot fail.
#[must_use]
pub fn encode<T: Serialize>(value: &T) -> Vec<u8> {
    postcard::to_stdvec(value).expect("postcard encode cannot fail for these types")
}

/// # Errors
///
/// Returns the postcard error when `bytes` is not a valid encoding of `T`.
pub fn decode<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, postcard::Error> {
    postcard::from_bytes(bytes)
}

/// Default daemon socket: a short /tmp path (`sun_path` is 104 bytes on
/// darwin), per-uid so multi-user machines don't collide.
#[must_use]
pub fn socket_path(uid: u32) -> std::path::PathBuf {
    std::path::PathBuf::from(format!("/tmp/muxd-{uid}.sock"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_request_roundtrip() {
        let req = OpenRequest {
            cols: 120,
            rows: 40,
            term: Some("xterm-ghostty".into()),
            mode: OpenMode::Open {
                name: "pane-1".into(),
                cwd: Some("/tmp".into()),
                command: vec![],
            },
        };
        let bytes = encode(&req);
        assert_eq!(decode::<OpenRequest>(&bytes).unwrap(), req);
    }

    #[test]
    fn reply_roundtrip() {
        let ok: OpenReply = Ok(Opened::Attached {
            name: "p".into(),
            created: true,
        });
        assert_eq!(decode::<OpenReply>(&encode(&ok)).unwrap(), ok);
        let err: OpenReply = Err("nope".into());
        assert_eq!(decode::<OpenReply>(&encode(&err)).unwrap(), err);
    }
}
