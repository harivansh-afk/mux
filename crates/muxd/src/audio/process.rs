//! Kernel-backed ancestry for hardened helpers. `PIDFD_GET_INFO` exposes public
//! process identifiers/credentials without ptrace or weakening hidepid/dumpability.

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

// Linux's extensible pidfd_info v0 ABI (64 bytes), available since Linux 6.13.
#[repr(C)]
#[derive(Default)]
struct Info {
    mask: u64,
    cgroup: u64,
    pid: u32,
    tgid: u32,
    parent: u32,
    real_uid: u32,
    real_gid: u32,
    effective_uid: u32,
    effective_gid: u32,
    saved_uid: u32,
    saved_gid: u32,
    fs_uid: u32,
    fs_gid: u32,
    exit_code: i32,
}

nix::ioctl_readwrite!(get_info, 0xff, 11, Info);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    pid: i32,
    parent: i32,
}

impl Info {
    fn identity(&self, uid: u32) -> Option<Identity> {
        if self.mask & 3 != 3
            || self.pid != self.tgid
            || self.pid == 0
            || [
                self.real_uid,
                self.effective_uid,
                self.saved_uid,
                self.fs_uid,
            ] != [uid; 4]
        {
            return None;
        }
        Some(Identity {
            pid: self.pid.try_into().ok()?,
            parent: self.parent.try_into().ok()?,
        })
    }
}

pub(crate) struct Process(OwnedFd);

impl Process {
    pub fn supported() -> bool {
        Self::open(nix::unistd::getpid().as_raw())
            .and_then(|process| process.identity())
            .is_some()
    }

    /// `SO_PEERPIDFD` pins the exact connecting process, even if its numeric PID
    /// exits/recycles while the device handshake is being processed.
    pub fn peer(socket: &OwnedFd) -> std::io::Result<Self> {
        let mut raw = -1i32;
        let mut length = libc::socklen_t::try_from(std::mem::size_of::<i32>())
            .expect("descriptor size fits socklen_t");
        // SAFETY: SO_PEERPIDFD returns one new, close-on-exec descriptor in an
        // int-sized buffer. It is owned below exactly once on success.
        let result = unsafe {
            libc::getsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                77,
                (&raw mut raw).cast(),
                &raw mut length,
            )
        };
        if result < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if raw < 0 {
            return Err(std::io::Error::other("invalid peer pidfd"));
        }
        // SAFETY: a fresh descriptor returned by getsockopt.
        Ok(Self(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    fn open(pid: i32) -> Option<Self> {
        // SAFETY: pidfd_open accepts two scalar arguments and returns an owned
        // descriptor or -1. It does not attach to or change the target process.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        let raw = i32::try_from(raw).ok().filter(|fd| *fd >= 0)?;
        // SAFETY: a fresh close-on-exec descriptor from pidfd_open.
        Some(Self(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    fn identity(&self) -> Option<Identity> {
        let mut info = Info {
            mask: 3,
            ..Info::default()
        };
        // SAFETY: Info matches the published v0 ABI and get_info validates its
        // size. Only public IDs and credentials are requested, not namespaces.
        unsafe { get_info(self.0.as_raw_fd(), &raw mut info) }.ok()?;
        info.identity(nix::unistd::geteuid().as_raw())
    }
}

pub(crate) fn ancestor(peer: &Process, owns: impl Fn(i32) -> bool) -> Option<i32> {
    let mut handles: Vec<Process> = Vec::new();
    let mut identities: Vec<Identity> = Vec::new();
    for _ in 0..128 {
        let identity = handles.last().unwrap_or(peer).identity()?;
        if identity.pid <= 1 || identities.iter().any(|seen| seen.pid == identity.pid) {
            return None;
        }
        identities.push(identity);
        if owns(identity.pid) {
            if peer.identity() != identities.first().copied() {
                return None;
            }
            return handles
                .iter()
                .zip(&identities[1..])
                .all(|(handle, before)| handle.identity() == Some(*before))
                .then_some(identity.pid);
        }
        handles.push(Process::open(identity.parent)?);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_metadata_requires_complete_same_user_credentials() {
        assert_eq!(std::mem::size_of::<Info>(), 64);
        let mut info = Info {
            mask: 3,
            pid: 42,
            tgid: 42,
            parent: 41,
            real_uid: 1000,
            effective_uid: 1000,
            saved_uid: 1000,
            fs_uid: 1000,
            ..Info::default()
        };
        assert_eq!(
            info.identity(1000),
            Some(Identity {
                pid: 42,
                parent: 41
            })
        );
        info.effective_uid = 0;
        assert!(info.identity(1000).is_none());
        info.effective_uid = 1000;
        info.mask = 1;
        assert!(info.identity(1000).is_none());
    }
}
