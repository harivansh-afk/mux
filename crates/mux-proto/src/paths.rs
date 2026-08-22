use std::path::PathBuf;

fn home() -> PathBuf {
    // Panicking here is worse than degrading: this is called lazily from
    // request handlers (broker init), where a panic poisons a OnceLock
    // and turns every later request into a repeat panic. home_dir reads
    // HOME and falls back to the passwd entry.
    #[allow(deprecated)] // un-deprecated in newer std; harmless here
    std::env::home_dir().unwrap_or_else(|| PathBuf::from("/"))
}

#[must_use]
pub fn hosts_config() -> PathBuf {
    home().join(".config/mux/hosts.json")
}

#[must_use]
pub fn client_state_dir() -> PathBuf {
    home().join(".local/state/mux")
}

#[must_use]
pub fn known_hosts() -> PathBuf {
    client_state_dir().join("known_hosts")
}

/// One identity for every host, so enrolling a new host is a digest
/// paste rather than a secret copy.
#[must_use]
pub fn client_token() -> PathBuf {
    client_state_dir().join("token")
}

#[must_use]
pub fn host_token(alias: &str) -> PathBuf {
    client_state_dir().join("tokens").join(alias)
}

#[must_use]
pub fn daemon_state_dir() -> PathBuf {
    home().join(".local/state/muxd")
}

#[must_use]
pub fn daemon_cert() -> PathBuf {
    daemon_state_dir().join("cert.pem")
}

#[must_use]
pub fn daemon_key() -> PathBuf {
    daemon_state_dir().join("key.pem")
}

#[must_use]
pub fn daemon_token() -> PathBuf {
    daemon_state_dir().join("token")
}

/// Running daemon's pidfile: `~/.local/state/muxd/muxd.pid`, one decimal
/// pid and a newline. Written at startup; the successor reads it to know
/// which process to ask for a live-fd handoff (see `migrate.rs`). Derived
/// from `HOME` on purpose, so a test daemon with its own `HOME` never
/// signals the user's.
#[must_use]
pub fn daemon_pid() -> PathBuf {
    daemon_state_dir().join("muxd.pid")
}

/// The daemon is spawned detached with stderr on /dev/null, so without
/// a file the whole pty lifecycle (created/attached/killed/exited) is
/// unobservable - and a session that vanished cannot be diagnosed after
/// the fact.
#[must_use]
pub fn daemon_log() -> PathBuf {
    daemon_state_dir().join("muxd.log")
}
