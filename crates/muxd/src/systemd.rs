//! The one thing muxd says to systemd: `sd_notify(3)` over the datagram
//! socket in `NOTIFY_SOCKET`, with no library. Outside systemd the
//! variable is unset and nothing is sent.
//!
//! Two messages matter. `READY=1` once the control socket is bound, so
//! `Type=notify` waits for a daemon that answers. `MAINPID=<pid>` from a
//! successor (`--upgrade`) before it asks for the handoff, so the
//! predecessor's exit is a main process being replaced, not a service
//! stopping; under `NotifyAccess=all` any process in the unit may say it.
//! Between them, `nixos-rebuild switch` reloads the unit instead of
//! restarting it and no shell on the host notices (nix/module.nix).

use std::os::unix::net::UnixDatagram;
use std::path::Path;

/// Send one notification to `NOTIFY_SOCKET`, when there is one.
pub fn notify(message: &str) {
    let Some(socket) = std::env::var_os("NOTIFY_SOCKET") else {
        return;
    };
    if let Err(e) = send(Path::new(&socket), message) {
        tracing::warn!(%e, message, "sd_notify failed");
    }
}

fn send(socket: &Path, message: &str) -> std::io::Result<()> {
    let sender = UnixDatagram::unbound()?;
    // Linux abstract sockets spell their leading NUL as `@`.
    let address = socket.to_string_lossy();
    if let Some(abstract_name) = address.strip_prefix('@') {
        #[cfg(target_os = "linux")]
        {
            use std::os::linux::net::SocketAddrExt as _;
            let addr = std::os::unix::net::SocketAddr::from_abstract_name(abstract_name)?;
            sender.send_to_addr(message.as_bytes(), &addr)?;
            return Ok(());
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = abstract_name;
            return Err(std::io::Error::other("abstract socket on a non-linux host"));
        }
    }
    sender.send_to(message.as_bytes(), socket)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_reaches_the_socket_by_path() {
        let path = std::env::temp_dir().join(format!("muxd-notify-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let receiver = UnixDatagram::bind(&path).expect("bind");
        send(&path, "READY=1").expect("send");
        let mut buf = [0u8; 64];
        let n = receiver.recv(&mut buf).expect("recv");
        assert_eq!(&buf[..n], b"READY=1");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_missing_socket_is_an_error_not_a_panic() {
        assert!(send(Path::new("/nonexistent/notify.sock"), "READY=1").is_err());
    }
}
