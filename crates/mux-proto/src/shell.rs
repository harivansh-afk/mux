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

pub const METHOD: &str = "shell";
pub const DEFAULT_PORT: u16 = 5001;
pub const DEFAULT_COLS: u16 = 80;
pub const DEFAULT_ROWS: u16 = 24;

pub const IN_LANE_INPUT: u8 = 0;
pub const IN_LANE_CONTROL: u8 = 1;
pub const OUT_LANE_OPENED: u8 = 0;
pub const OUT_LANE_OUTPUT: u8 = 1;
pub const OUT_LANE_EVENTS: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Create {
        command: Vec<String>,
        default_shell: bool,
    },
    Attach {
        session: u32,
    },
    Peek {
        session: u32,
    },
    List,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    /// Upstream: the target VM uuid. For muxd peers this is a session-host id.
    pub target: String,
    pub cols: u16,
    pub rows: u16,
    pub term: Option<String>,
    pub mode: Mode,
    pub env: Vec<EnvVar>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientControl {
    Resize { cols: u16, rows: u16 },
    Close,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInfo {
    pub id: u32,
    pub command: Vec<String>,
    pub attached: bool,
    pub exited: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenSuccess {
    Attached { session: u32 },
    Listed { sessions: Vec<SessionInfo> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerEvent {
    Exit { code: i32 },
    Detached,
}
