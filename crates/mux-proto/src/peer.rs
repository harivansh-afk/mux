//! muxd's native peer protocol: the ix lane framing carrying
//! postcard-encoded control values.
//!
//! ix VMs speak the ix codec encoding (M4 golden-byte work); mux peers
//! (Mux.app panes via mux-attach <-> muxd) speak these types. Same
//! framing, same lane numbering, so mux-attach's relay loop is
//! transport-agnostic.
//!
//! Handshake: `[u32 LE len][postcard OpenRequest]`, then lane frames.
//! Ptys are keyed by client-chosen name (the pane id), so "attach or
//! create" is one round trip and restore needs no id handoff.

use serde::{Deserialize, Serialize};

/// Bumped on every incompatible change to the handshake or lane values.
/// The daemon replies with a readable error on mismatch instead of
/// dropping the connection, so skew between a running daemon and a newer
/// client is diagnosable (v1: M2; v2: token+target; v3: this field;
/// v4: `cwd_from`; v5: `PtyInfo::cwd`; v6: typed `OpenError`; v7:
/// `PtyInfo::agent`, `OpenMode::Watch`; v8: attach-only reopen).
pub const PROTOCOL_VERSION: u32 = 9;

/// ALPN for muxd's QUIC listener. Each bidirectional stream carries
/// exactly one protocol run: the same handshake + lane frames as a unix
/// socket connection.
pub const ALPN: &[u8] = b"muxd/1";
pub const DEFAULT_QUIC_PORT: u16 = 4433;

/// Grid a client asks for when it has no tty to measure.
pub const DEFAULT_COLS: u16 = 80;
pub const DEFAULT_ROWS: u16 = 24;

/// Environment override of [`socket_path`], read by the daemon and by
/// every client.
pub const SOCKET_ENV: &str = "MUXD_SOCKET";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenRequest {
    /// Must be `PROTOCOL_VERSION`; first field, so even a differently
    /// shaped future request still yields a meaningful version check.
    pub version: u32,
    pub cols: u16,
    pub rows: u16,
    pub term: Option<String>,
    /// Bearer token, required on QUIC-originated requests; unix-socket
    /// requests leave it None (filesystem perms are the auth boundary).
    pub token: Option<String>,
    /// None = this daemon serves the request itself. Some(host alias) =
    /// the LOCAL daemon relays the whole connection over its per-host
    /// QUIC link (panes never dial the network). Only meaningful on the
    /// unix socket; relayed requests arrive with target = None.
    pub target: Option<String>,
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
        /// Inherit the working directory of this existing pty (a split's
        /// source pane) when `cwd` is absent and the pty is being
        /// created. Resolved daemon-side from the live process - the
        /// daemon owns the shell, so only it can know where the user
        /// actually is; no shell integration required.
        cwd_from: Option<String>,
    },
    /// List ptys.
    List,
    /// Kill the pty named `name` (SIGKILL to its process group).
    Kill { name: String },
    /// Stream [`PtyEvent`]s: one per pty now, then one per change, on
    /// the events lane after the reply, until the client hangs up.
    Watch,
    /// Reattach a preserved terminal. Never create a process if missing.
    Attach { name: String },
    /// Read the current viewport without attaching or resizing.
    Inspect { name: String },
    /// Stream coalesced viewport snapshots without taking the client slot.
    Observe { name: String },
    /// Write only if the inspected terminal and input state still match.
    Input { name: String, input: PtyInput },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Opened {
    Attached { name: String, created: bool },
    Listed { ptys: Vec<PtyInfo> },
    Killed { existed: bool },
    Watching,
    Inspected { snapshot: PtySnapshot },
    Observing,
    InputWritten { bytes: usize, input_revision: u64 },
}

/// An incarnation is deliberately renewed at daemon handoff: stale writes fail
/// closed, while existing interactive clients continue using the v8 contract.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PtySnapshot {
    pub name: String,
    pub generation: String,
    pub revision: u64,
    pub input_revision: u64,
    pub pid: i32,
    pub foreground_pgid: Option<i32>,
    pub cols: u16,
    pub rows: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub text: Vec<String>,
    pub cwd: Option<String>,
    pub agent: Option<AgentInfo>,
    pub exited: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PtyInput {
    pub generation: String,
    pub revision: u64,
    pub input_revision: u64,
    pub foreground_pgid: i32,
    pub data: Vec<u8>,
}

/// Which coding agent a pty's foreground process is and what it is
/// doing, as the daemon read it. Strings on the wire so the JSON side is
/// the same shape: `agent` is the detector's label (`claude`, `codex`),
/// `state` is `working`, `idle` or `blocked`, `topic` is what the agent
/// says it is on (claude's title text, codex's project), possibly empty.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AgentInfo {
    pub agent: String,
    pub state: String,
    pub topic: String,
}

/// One line of a watch: the pty's current agent and directory. Sent for
/// every pty when the watch opens, then whenever any of it changes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PtyEvent {
    pub name: String,
    pub agent: Option<AgentInfo>,
    pub cwd: Option<String>,
    pub exited: bool,
}

/// Why an open failed, decided where the failure is raised. Clients
/// switch on this instead of reading the daemon's prose.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ErrorKind {
    /// No bytes reached the host: resolve, dial or stream-open failed.
    Unreachable,
    /// The host presented a key other than the pinned one.
    PinMismatch,
    /// The host refused our bearer token.
    TokenRejected,
    /// The two daemons disagree about `PROTOCOL_VERSION`.
    VersionMismatch,
    /// The alias is not one this client knows how to reach.
    NoHost,
    /// Anything else. Named `error` on the wire's JSON side, which is
    /// the fallback class Mux.app has always shown.
    #[serde(rename = "error")]
    Other,
}

impl ErrorKind {
    /// The kebab-case name, the same string the JSON encoding uses.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unreachable => "unreachable",
            Self::PinMismatch => "pin-mismatch",
            Self::TokenRejected => "token-rejected",
            Self::VersionMismatch => "version-mismatch",
            Self::NoHost => "no-host",
            Self::Other => "error",
        }
    }
}

impl std::fmt::Display for ErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Field order is wire order, and `detail` goes first on purpose: a v5
/// client decodes `Err(String)`, so it reads the prose verbatim and
/// postcard leaves the trailing kind unread. Put `kind` first and a
/// skewed client reads its index as a string length.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenError {
    /// What to show the user. Prose, and only prose: nothing parses it.
    pub detail: String,
    pub kind: ErrorKind,
}

impl OpenError {
    #[must_use]
    pub fn new(kind: ErrorKind, detail: impl Into<String>) -> Self {
        Self {
            detail: detail.into(),
            kind,
        }
    }
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.kind, self.detail)
    }
}

pub type OpenReply = Result<Opened, OpenError>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PtyInfo {
    pub name: String,
    pub command: Vec<String>,
    pub attached: bool,
    pub exited: bool,
    /// Working directory of the pty's foreground process, when readable.
    /// What a client needs to adopt a pty it has no record of.
    pub cwd: Option<String>,
    /// The coding agent in the foreground, when there is one.
    pub agent: Option<AgentInfo>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ClientControl {
    Resize { cols: u16, rows: u16 },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ServerEvent {
    Exit { code: i32 },
}

pub fn encode<T: Serialize>(value: &T) -> Vec<u8> {
    postcard::to_stdvec(value).expect("postcard encode cannot fail for these types")
}

pub fn decode<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, postcard::Error> {
    postcard::from_bytes(bytes)
}

/// Decode a handshake reply from a daemon of this version or of v5.
///
/// One-release shim for the v5 -> v6 boundary; delete it once no v5
/// daemon can still be running. v5 replied `Result<Opened, String>` and
/// v6 replies `Result<Opened, OpenError>`. The Ok arm is byte-identical,
/// but a v5 rejection is one string where v6 expects `detail` then
/// `kind`, so the v6 decode runs out of bytes at the kind and fails on
/// exactly the reply that exists to diagnose skew. Retry as v5 and
/// classify the prose: a v5 daemon's version rejection starts with
/// [`V5_VERSION_MISMATCH`], and nothing else it could say has a kind.
pub fn decode_open_reply(bytes: &[u8]) -> Result<OpenReply, postcard::Error> {
    decode::<OpenReply>(bytes).or_else(|e| {
        let Ok(Err(detail)) = decode::<Result<Opened, String>>(bytes) else {
            return Err(e);
        };
        let kind = if detail.starts_with(V5_VERSION_MISMATCH) {
            ErrorKind::VersionMismatch
        } else {
            ErrorKind::Other
        };
        Ok(Err(OpenError::new(kind, detail)))
    })
}

/// How a v5 daemon's rejection of a newer client begins.
pub const V5_VERSION_MISMATCH: &str = "protocol version mismatch";

/// Decode a value from the front of `bytes`, ignoring what follows. This
/// is how a daemon reads the version out of a request whose shape it
/// cannot decode: the version is the first field by design.
pub fn decode_prefix<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, postcard::Error> {
    postcard::take_from_bytes(bytes).map(|(value, _rest)| value)
}

/// Default daemon socket: a short /tmp path (`sun_path` is 104 bytes on
/// darwin), per-uid so multi-user machines don't collide.
pub fn socket_path(uid: u32) -> std::path::PathBuf {
    std::path::PathBuf::from(format!("/tmp/muxd-{uid}.sock"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_request_roundtrip() {
        let req = OpenRequest {
            version: PROTOCOL_VERSION,
            cols: 120,
            rows: 40,
            term: Some("xterm-ghostty".into()),
            token: None,
            target: Some("spark".into()),
            mode: OpenMode::Open {
                name: "pane-1".into(),
                cwd: Some("/tmp".into()),
                command: vec![],
                cwd_from: Some("pane-0".into()),
            },
        };
        let bytes = encode(&req);
        assert_eq!(decode::<OpenRequest>(&bytes).unwrap(), req);
    }

    #[test]
    fn attach_only_request_roundtrips_without_spawn_parameters() {
        let mode = OpenMode::Attach {
            name: "saved".into(),
        };
        assert_eq!(decode::<OpenMode>(&encode(&mode)).unwrap(), mode);
        assert_eq!(encode(&mode), [4, 5, b's', b'a', b'v', b'e', b'd']);
    }

    /// The documented wire example (docs/architecture.html section 2):
    /// this test IS the spec. If it breaks, either update the doc and
    /// accept a protocol break, or revert the change.
    #[test]
    fn golden_wire_bytes() {
        // Handshake payload: attach-or-create "p1" at 120x40, local.
        let req = OpenRequest {
            version: PROTOCOL_VERSION,
            cols: 120,
            rows: 40,
            term: Some("xterm-ghostty".into()),
            token: None,
            target: None,
            mode: OpenMode::Open {
                name: "p1".into(),
                cwd: None,
                command: vec![],
                cwd_from: None,
            },
        };
        assert_eq!(
            encode(&req),
            [
                0x09, // version = PROTOCOL_VERSION (varint)
                0x78, // cols = 120 (varint)
                0x28, // rows = 40
                0x01, 0x0d, // term: Some, len 13
                0x78, 0x74, 0x65, 0x72, 0x6d, 0x2d, 0x67, 0x68, 0x6f, 0x73, 0x74, 0x74,
                0x79, // "xterm-ghostty"
                0x00, // token: None
                0x00, // target: None
                0x00, // mode: Open (discriminant 0)
                0x02, 0x70, 0x31, // name: len 2, "p1"
                0x00, // cwd: None
                0x00, // command: 0 args
                0x00, // cwd_from: None
            ]
        );

        // Control frame payload: resize to 120x40.
        let resize = ClientControl::Resize {
            cols: 120,
            rows: 40,
        };
        assert_eq!(encode(&resize), [0x00, 0x78, 0x28]);

        // Event frame payload: clean exit (i32 zigzag varint).
        let exit = ServerEvent::Exit { code: 0 };
        assert_eq!(encode(&exit), [0x00, 0x00]);

        // Failed reply: Err, then the detail string, then the kind. A v5
        // client stops after the string, which is exactly its error type.
        let rejected: OpenReply = Err(OpenError::new(ErrorKind::VersionMismatch, "v6"));
        assert_eq!(
            encode(&rejected),
            [
                0x01, // Err
                0x02, 0x76, 0x36, // detail: len 2, "v6"
                0x03, // kind: VersionMismatch (variant 3)
            ]
        );
    }

    #[test]
    fn reply_roundtrip() {
        let ok: OpenReply = Ok(Opened::Attached {
            name: "p".into(),
            created: true,
        });
        assert_eq!(decode::<OpenReply>(&encode(&ok)).unwrap(), ok);
        let err: OpenReply = Err(OpenError::new(ErrorKind::PinMismatch, "nope"));
        assert_eq!(decode::<OpenReply>(&encode(&err)).unwrap(), err);
    }

    /// The two sides of the v5 -> v6 boundary. A v5 daemon's rejection
    /// reaches a v6 client with its kind recovered from the prose, and a
    /// v6 daemon's rejection reaches a v5 client as the string it expects.
    #[test]
    fn skewed_replies_decode_on_both_sides() {
        let v5_detail = "protocol version mismatch: daemon v5, client v6 - upgrade";
        let from_v5 = encode::<Result<Opened, String>>(&Err(v5_detail.into()));
        assert!(decode::<OpenReply>(&from_v5).is_err(), "the shim is needed");
        assert_eq!(
            decode_open_reply(&from_v5).unwrap(),
            Err(OpenError::new(ErrorKind::VersionMismatch, v5_detail))
        );
        let other = encode::<Result<Opened, String>>(&Err("no such pty".into()));
        assert_eq!(
            decode_open_reply(&other).unwrap(),
            Err(OpenError::new(ErrorKind::Other, "no such pty"))
        );

        let from_v6: OpenReply = Err(OpenError::new(ErrorKind::VersionMismatch, "v6 says"));
        assert_eq!(
            decode::<Result<Opened, String>>(&encode(&from_v6)).unwrap(),
            Err("v6 says".to_string())
        );
        // Not a rejection: the shim stays out of the way.
        let ok: OpenReply = Ok(Opened::Killed { existed: false });
        assert_eq!(decode_open_reply(&encode(&ok)).unwrap(), ok);
    }

    /// Swift switches on these strings; they are the JSON encoding.
    #[test]
    fn error_kinds_serialise_by_name() {
        assert_eq!(
            serde_json::to_string(&ErrorKind::PinMismatch).unwrap(),
            "\"pin-mismatch\""
        );
        assert_eq!(ErrorKind::VersionMismatch.to_string(), "version-mismatch");
        assert_eq!(ErrorKind::Other.to_string(), "error");
    }
}
