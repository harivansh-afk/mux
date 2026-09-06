//! The daemon reads the agent in a pty end to end: identity from the
//! foreground process's name, state from the title that reaches the
//! terminal, and a watch that reports each change once.
//!
//! The child is `/bin/cat` behind a symlink named `claude`: the daemon
//! names a process by its argv[0], and cat echoes what it is fed, so the
//! test writes claude's titles into the pty and the vt sees them come
//! back as output.

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use mux_proto::peer::PtyEvent;
use muxd::manager::{Manager, PtySession};
use tokio::sync::broadcast::Receiver;

mod common;
use common::PATIENCE;

#[tokio::test]
async fn an_adopted_idle_agent_is_detected_without_fresh_output() {
    let dir = tempfile::tempdir().expect("tempdir");
    let executable = dir.path().join("codex");
    std::os::unix::fs::symlink("/bin/cat", &executable).expect("link cat");
    let command = vec![executable.to_string_lossy().into_owned()];
    let pty = muxd::pty::spawn(&muxd::pty::Spawn {
        command: &command,
        cwd: None,
        term: None,
        cols: 80,
        rows: 24,
    })
    .expect("spawn silent agent");
    let manager = Manager::default();
    let (_, mut events) = manager.watch();
    manager
        .adopt(
            muxd::migrate::MigratePty {
                name: "idle".into(),
                command,
                child_pid: pty.child.as_raw(),
                cols: 80,
                rows: 24,
                screen: b"\x1b]0;A restored conversation\x07".to_vec(),
            },
            pty.master.into_inner(),
        )
        .expect("adopt");
    let agent = next_agent(&mut events).await.agent.expect("restored agent");
    assert_eq!(agent.agent, "codex");
    assert_eq!(agent.state, "idle");
    assert_eq!(agent.topic, "A restored conversation");
    assert!(manager.kill("idle"));
    let _ = nix::sys::wait::waitpid(pty.child, None);
}

#[tokio::test]
async fn npm_codex_launcher_reports_its_title_through_list_and_watch() {
    let dir = tempfile::tempdir().expect("tempdir");
    let script = dir.path().join("codex");
    nix::unistd::mkfifo(
        &script,
        nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
    )
    .expect("create script fifo");
    let mut input = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&script)
        .expect("open fifo");
    let manager = Manager::default();
    let (_, mut events) = manager.watch();
    // cat supplies terminal output with the same argv shape as the npm launcher,
    // without requiring Node or a Codex account on the test host.
    let (session, _) = manager
        .open(
            "npm",
            &[
                "/bin/bash".into(),
                "-c".into(),
                "exec -a node /bin/cat \"$1\"".into(),
                "launcher".into(),
                script.to_string_lossy().into_owned(),
            ],
            None,
            None,
            80,
            24,
        )
        .expect("open pty");
    for (title, state) in [
        ("⠋ Review title recognition", "working"),
        (
            "[ ! ] Action Required | Review title recognition",
            "blocked",
        ),
        ("Review title recognition", "idle"),
    ] {
        write!(input, "\x1b]0;{title}\x07").expect("emit title");
        let event = next_event(&mut events, |event| {
            event.agent.as_ref().is_some_and(|a| a.state == state)
        })
        .await;
        let agent = event.agent.expect("npm launcher is an agent");
        assert_eq!(agent.agent, "codex");
        assert_eq!(agent.topic, "Review title recognition");
        assert_eq!(manager.list()[0].agent.as_ref(), Some(&agent));
    }
    assert!(manager.kill(&session.name));
}

#[tokio::test]
async fn a_pty_running_claude_reports_its_state_as_the_title_moves() {
    let claude = fake_agent("claude");
    let mut command = vec![claude.to_string_lossy().into_owned()];
    // NixOS's multicall coreutils dispatches by argv[0]. Preserve the
    // fake agent name while explicitly selecting its cat implementation.
    if std::fs::canonicalize(common::cat()).is_ok_and(|path| path.ends_with("coreutils")) {
        command.push("--coreutils-prog=cat".into());
    }
    let manager = Manager::default();
    let (snapshot, mut events) = manager.watch();
    assert!(snapshot.is_empty(), "a fresh daemon has no ptys to report");

    let (session, created) = manager
        .open("a1", &command, None, None, 80, 24)
        .expect("open pty");
    assert!(created);

    // claude at rest: U+2733, a space, the topic.
    write_pty(
        &session,
        "\x1b]0;\u{2733} fix the flaky test\x07\n".as_bytes(),
    )
    .await;
    let idle = next_agent(&mut events).await;
    let agent = idle.agent.expect("an agent is in the foreground");
    assert_eq!(agent.agent, "claude");
    assert_eq!(agent.state, "idle");
    assert_eq!(agent.topic, "fix the flaky test");
    assert!(!idle.exited);

    // claude working: a half-circle spinner frame.
    write_pty(
        &session,
        "\x1b]0;\u{25D0} fix the flaky test\x07\n".as_bytes(),
    )
    .await;
    let working = next_agent(&mut events).await;
    let agent = working.agent.expect("still an agent");
    assert_eq!(agent.state, "working");
    assert_eq!(agent.topic, "fix the flaky test");

    // `ls` carries the same reading.
    let listed = manager.list();
    let info = listed.iter().find(|p| p.name == "a1").expect("listed");
    assert_eq!(
        info.agent.as_ref().map(|a| a.state.as_str()),
        Some("working")
    );

    // EOT: cat exits, and the watch hears the exit.
    write_pty(&session, b"\x04").await;
    let exited = next_event(&mut events, |e| e.exited).await;
    assert_eq!(exited.name, "a1");
    assert!(
        exited.agent.is_none(),
        "nothing is in the foreground of a dead pty"
    );

    let _ = std::fs::remove_dir_all(claude.parent().expect("tempdir"));
}

#[tokio::test]
async fn a_shell_is_not_an_agent_and_a_watch_opens_with_every_pty() {
    let manager = Manager::default();
    let (session, _) = manager
        .open("s1", &[common::cat()], None, None, 80, 24)
        .expect("open pty");
    write_pty(
        &session,
        "\x1b]0;\u{2733} looks like claude\x07\n".as_bytes(),
    )
    .await;
    // Give the settle timer every chance to fire.
    tokio::time::sleep(Duration::from_millis(400)).await;

    let (snapshot, _) = manager.watch();
    assert_eq!(snapshot.len(), 1);
    assert_eq!(snapshot[0].name, "s1");
    assert!(
        snapshot[0].agent.is_none(),
        "cat is not an agent, whatever its title says"
    );
    assert!(manager.kill("s1"));
}

#[tokio::test]
async fn a_watch_reports_directory_changes_without_an_agent() {
    let manager = Manager::default();
    let (_, mut events) = manager.watch();
    let (session, _) = manager
        .open("cwd", &["/bin/sh".into()], Some("/"), None, 80, 24)
        .expect("open shell");
    write_pty(&session, b"printf 'ready\\n'\n").await;
    let initial = next_event(&mut events, |e| e.cwd.as_deref() == Some("/")).await;
    assert!(initial.agent.is_none());

    write_pty(&session, b"cd /usr && printf 'changed\\n'\n").await;
    let changed = next_event(&mut events, |e| e.cwd.as_deref() == Some("/usr")).await;
    assert!(changed.agent.is_none());

    write_pty(&session, b"printf 'unchanged\\n'\n").await;
    assert!(
        tokio::time::timeout(Duration::from_millis(500), events.recv())
            .await
            .is_err(),
        "unchanged metadata must not repeat"
    );
    assert!(manager.kill("cwd"));
}

/// `/bin/cat` under an agent's name, in a private directory. A link,
/// not a copy: macOS kills platform binaries that run from elsewhere.
fn fake_agent(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("muxd-agents-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("tempdir");
    let path = dir.join(name);
    std::os::unix::fs::symlink(common::cat(), &path).expect("link cat");
    path
}

async fn write_pty(session: &Arc<PtySession>, bytes: &[u8]) {
    muxd::pty::write_all(&session.master, bytes)
        .await
        .expect("write to pty");
}

/// The next event that carries an agent reading.
async fn next_agent(events: &mut Receiver<PtyEvent>) -> PtyEvent {
    next_event(events, |e| e.agent.is_some()).await
}

async fn next_event(events: &mut Receiver<PtyEvent>, want: impl Fn(&PtyEvent) -> bool) -> PtyEvent {
    let drain = async {
        loop {
            let event = events.recv().await.expect("the event channel stays open");
            if want(&event) {
                return event;
            }
        }
    };
    tokio::time::timeout(PATIENCE, drain)
        .await
        .expect("timed out waiting for an event")
}
