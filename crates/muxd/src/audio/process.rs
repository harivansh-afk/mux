//! A pipe-launched helper may call setsid without leaving its owning terminal's
//! process tree. Bind by ancestry, and recheck every observed process identity.

use std::os::unix::fs::MetadataExt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    parent: i32,
    started: u64,
}

impl Identity {
    fn parse(stat: &str) -> Option<Self> {
        let (_, fields) = stat.rsplit_once(')')?;
        let fields: Vec<_> = fields.split_whitespace().collect();
        if *fields.first()? == "Z" {
            return None;
        }
        Some(Self {
            parent: fields.get(1)?.parse().ok()?,
            started: fields.get(19)?.parse().ok()?,
        })
    }

    fn read(pid: i32) -> Option<Self> {
        let path = format!("/proc/{pid}");
        if std::fs::metadata(&path).ok()?.uid() != nix::unistd::geteuid().as_raw() {
            return None;
        }
        Self::parse(&std::fs::read_to_string(format!("{path}/stat")).ok()?)
    }
}

pub(crate) fn ancestor(pid: i32, owns: impl Fn(i32) -> bool) -> Option<i32> {
    walk(pid, owns, Identity::read)
}

fn walk(
    mut pid: i32,
    owns: impl Fn(i32) -> bool,
    mut read: impl FnMut(i32) -> Option<Identity>,
) -> Option<i32> {
    let mut chain = Vec::new();
    for _ in 0..128 {
        if pid <= 1 || chain.iter().any(|(seen, _)| *seen == pid) {
            return None;
        }
        let identity = read(pid)?;
        chain.push((pid, identity));
        if owns(pid) {
            return chain
                .iter()
                .all(|(pid, identity)| read(*pid) == Some(*identity))
                .then_some(pid);
        }
        pid = identity.parent;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_names_with_parentheses_without_confusing_stat_fields() {
        let mut fields = vec!["0"; 20];
        fields[0] = "S";
        fields[1] = "42";
        fields[3] = "999";
        fields[19] = "12345";
        let stat = format!("123 (voice ) helper) {}", fields.join(" "));
        assert_eq!(
            Identity::parse(&stat),
            Some(Identity {
                parent: 42,
                started: 12345
            })
        );
    }

    #[test]
    fn finds_the_terminal_ancestor_and_rejects_unrelated_roots() {
        let read = |pid| {
            Some(Identity {
                parent: pid / 10,
                started: u64::try_from(pid).ok()?,
            })
        };
        assert_eq!(walk(1000, |pid| pid == 10, read), Some(10));
        assert_eq!(walk(1000, |pid| pid == 11, read), None);
    }

    #[test]
    fn refuses_reparenting_pid_reuse_and_cycles() {
        for replacement in [
            Identity {
                parent: 11,
                started: 100,
            },
            Identity {
                parent: 10,
                started: 101,
            },
        ] {
            let mut reads = 0;
            assert_eq!(
                walk(
                    100,
                    |pid| pid == 10,
                    |pid| {
                        reads += 1;
                        Some(if reads == 3 {
                            replacement
                        } else {
                            Identity {
                                parent: pid / 10,
                                started: u64::try_from(pid).ok()?,
                            }
                        })
                    }
                ),
                None
            );
        }
        assert_eq!(
            walk(
                100,
                |_| false,
                |_| Some(Identity {
                    parent: 100,
                    started: 1
                })
            ),
            None
        );
    }
}
