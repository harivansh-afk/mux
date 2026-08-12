//! The pty manager and its connection handler end to end: open, attach,
//! steal-attach, kill, reap, and the `SCM_RIGHTS` self-upgrade handoff.
//!
//! Every test drives a real child through a real pty, because the bugs
//! these cover live in the seams between the read loop, the client slot
//! and the connection handler - not inside any one of them. `/bin/cat` is
//! the workhorse: it echoes (so bytes can be proven to flow both ways),
//! it writes nothing on its own (so a test can wedge a client without the
//! read loop noticing first), and it exits on EOT.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use mux_proto::peer::{self, OpenMode, OpenReply, OpenRequest, Opened};
use mux_proto::shell::{IN_LANE_INPUT, OUT_LANE_EVENTS, OUT_LANE_OPENED, OUT_LANE_OUTPUT};
use muxd::manager::{ClientMsg, Manager, PtySession};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;
use tokio::sync::mpsc::Receiver;

/// Long enough to be immune to a loaded box, short enough that a hang
/// fails the run instead of stalling it.
const PATIENCE: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------- manager

#[tokio::test]
async fn open_attach_and_exit_are_wired_end_to_end() {
    let manager = Manager::default();
    let session = open_cat(&manager, "t1");

    // Attach-or-create: a second open under the same name is the same pty,
    // which is what makes restore one round trip.
    let (again, created) = manager.open("t1", &[], None, None, 80, 24).expect("reopen");
    assert!(!created, "an existing name is never re-created");
    assert!(Arc::ptr_eq(&session, &again));

    let mut attached = muxd::manager::attach(&session, 80, 24);
    let listed = manager.list();
    let info = listed.iter().find(|p| p.name == "t1").expect("listed");
    assert!(info.attached, "the pty knows it has a client");
    assert!(!info.exited);

    write_pty(&session, b"ping\n").await;
    let seen = recv_output_until(&mut attached.rx, b"ping").await;
    assert!(
        seen.windows(4).any(|w| w == b"ping"),
        "cat echoes what it is fed: {seen:?}"
    );

    // EOT: cat exits, the client is told, and the name comes free.
    write_pty(&session, b"\x04").await;
    assert_eq!(recv_exit(&mut attached.rx).await, 0, "clean exit");
    wait_until(|| manager.get("t1").is_none(), "the pty to leave the table").await;
}

#[tokio::test]
async fn kill_takes_the_name_and_the_process_group() {
    let manager = Manager::default();
    let session = open_cat(&manager, "doomed");
    let child = session.child;
    let attached = muxd::manager::attach(&session, 80, 24);

    assert!(manager.kill("doomed"), "the pty was there to kill");
    assert!(manager.get("doomed").is_none(), "the name is free at once");
    assert!(!manager.kill("doomed"), "a second kill finds nothing");
    assert!(
        session.client.lock().is_none(),
        "the client slot is released"
    );
    wait_until(|| !muxd::migrate::alive(child), "the child to be reaped").await;
    drop(attached);
}

/// Regression: `reap` used to `.await` an unbounded send of the exit event
/// on the depth-64 client channel, so a client that had stopped reading
/// parked the reap forever - and the `remove_if_same` that frees the pty
/// name never ran. Every later open of that name then returned a dead pty.
#[tokio::test]
async fn a_wedged_client_cannot_hold_the_pty_name_hostage() {
    let manager = Manager::default();
    let session = open_cat(&manager, "wedged");

    // Attach and never read, then fill the channel to its depth: the exit
    // event now has nowhere to go. cat prints nothing unprompted, so the
    // read loop gets no chance to detach the slow client first.
    let attached = muxd::manager::attach(&session, 80, 24);
    let tx = session
        .client
        .lock()
        .as_ref()
        .expect("just attached")
        .tx
        .clone();
    while tx.try_send(ClientMsg::Output(b"x".to_vec())).is_ok() {}

    // By pid, not process group: the child may not have reached its
    // setsid yet, and this has to be the thing that ends the pty.
    let _ = nix::sys::signal::kill(session.child, nix::sys::signal::Signal::SIGKILL);

    wait_until(
        || manager.get("wedged").is_none(),
        "the name to be freed despite the wedged client",
    )
    .await;
    drop(attached);
}

// ----------------------------------------------------------------- server

/// Regression: attaching a second client evicts the first, whose handler
/// then cleared `session.client` unconditionally - nulling the *new*
/// client's slot. The stolen-from pane went quiet and the pty looked
/// detached to `list`.
#[tokio::test]
async fn a_stolen_attach_leaves_the_new_client_wired() {
    let manager = Manager::default();
    let socket = temp_socket("steal");
    let listener = muxd::server::bind(&socket).await.expect("bind");
    tokio::spawn(muxd::server::serve(manager.clone(), listener));

    let mut first = connect(&socket).await;
    let reply = open_pane(&mut first, "p1").await.expect("attach");
    assert_eq!(reply, attached("p1", true));
    read_dump(&mut first).await;

    let mut second = connect(&socket).await;
    let reply = open_pane(&mut second, "p1").await.expect("steal attach");
    assert_eq!(reply, attached("p1", false));
    read_dump(&mut second).await;

    // The evicted client's handler tears its connection down; until that
    // EOF lands, the clobber has not had its chance to happen.
    read_until_eof(&mut first).await;

    write_frame(&mut second, IN_LANE_INPUT, b"ping\n").await;
    let seen = read_output_until(&mut second, b"ping").await;
    assert!(
        seen.windows(4).any(|w| w == b"ping"),
        "the surviving client still gets output: {seen:?}"
    );

    let session = manager.get("p1").expect("pty still open");
    assert!(
        session.client.lock().is_some(),
        "the pty must not look detached to `list`"
    );

    assert!(manager.kill("p1"));
    let _ = std::fs::remove_file(&socket);
}

// ---------------------------------------------------------------- upgrade

/// The self-upgrade handoff, both halves in one process: the predecessor
/// snapshots and sends its live ptys over `SCM_RIGHTS`, the successor
/// adopts them, and the child on the far end of the inherited fd is the
/// same process it always was.
///
/// Multi-threaded, as the daemon is: the handoff holds every VT lock
/// while it waits, so the pty's read loop parks on one the moment its
/// child prints anything. On one worker that park would starve the
/// successor half of this test, which in the real thing is another
/// process entirely.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_self_upgrade_carries_the_pty_its_screen_and_its_child() {
    let predecessor = Manager::default();
    let session = open_cat(&predecessor, "carried");
    let child = session.child;

    // Drive output through the VT first: the snapshot is what the
    // reattaching client repaints, so an empty one would prove nothing.
    let mut before = muxd::manager::attach(&session, 80, 24);
    write_pty(&session, b"before-upgrade\n").await;
    recv_output_until(&mut before.rx, b"before-upgrade").await;

    let socket = temp_socket("handoff");
    let listener = muxd::migrate::bind_listener(&socket).expect("migration listener");
    let successor = Manager::default();

    let adopting = tokio::spawn({
        let successor = successor.clone();
        async move { muxd::migrate::accept_handoff(&listener, &successor).await }
    });
    let handed = tokio::task::spawn_blocking({
        let predecessor = predecessor.clone();
        let socket = socket.clone();
        move || muxd::migrate::hand_off(&predecessor, &socket)
    })
    .await
    .expect("join hand_off");

    assert_eq!(handed.expect("hand off"), 1, "one live pty went across");
    assert_eq!(
        adopting.await.expect("join adopt").expect("adopt"),
        1,
        "the successor adopted it"
    );

    let adopted = successor.get("carried").expect("adopted pty");
    assert_eq!(adopted.child, child, "the shell was never restarted");
    assert!(adopted.adopted, "an inherited child is not ours to waitpid");
    let screen = adopted.terminal.lock().render_screen_bytes();
    assert!(
        contains(&screen, b"before-upgrade"),
        "the successor repaints the predecessor's screen: {:?}",
        String::from_utf8_lossy(&screen)
    );

    // The inherited fd is a live pty, not a record of one: it still names
    // the foreground process group on the far end. Driving IO *through*
    // it is what scripts/test-muxd-upgrade.py proves, and only it can -
    // here the predecessor's read loop is still on the other end of the
    // same pty, racing for every byte, where in a real upgrade that
    // process has already exited.
    assert!(
        adopted.current_cwd().is_some(),
        "the adopted master is a live tty with a foreground process"
    );

    assert!(successor.kill("carried"));
    let _ = std::fs::remove_file(&socket);
}

/// Regression: the predecessor used to `exit(0)` the instant `sendmsg`
/// returned, so a successor that died before adopting took every pty with
/// it. The handoff now waits for the successor's one-byte ack, and a
/// successor that never sends it leaves the predecessor serving.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_handoff_the_successor_never_acknowledges_leaves_the_ptys_alone() {
    let predecessor = Manager::default();
    let session = open_cat(&predecessor, "stranded");

    // A "successor" that takes the payload and the fds, then says nothing.
    let socket = temp_socket("no-ack");
    let listener = tokio::net::UnixListener::bind(&socket).expect("bind");
    let mute = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        tokio::time::sleep(PATIENCE).await;
        drop(stream);
    });

    let handed = tokio::task::spawn_blocking({
        let predecessor = predecessor.clone();
        let socket = socket.clone();
        move || muxd::migrate::hand_off(&predecessor, &socket)
    })
    .await
    .expect("join hand_off");

    assert!(
        handed.is_err(),
        "an unacknowledged handoff is a failed handoff, not an exit(0)"
    );
    let still_here = predecessor.get("stranded").expect("pty survived");
    assert!(Arc::ptr_eq(&still_here, &session));

    // Still serving: the VT locks the handoff held are released, and the
    // pty answers.
    let mut attached = muxd::manager::attach(&session, 80, 24);
    write_pty(&session, b"still-here\n").await;
    recv_output_until(&mut attached.rx, b"still-here").await;

    assert!(predecessor.kill("stranded"));
    mute.abort();
    let _ = std::fs::remove_file(&socket);
}

// ----------------------------------------------------------------- helpers

/// A pty running `/bin/cat` under `name`.
fn open_cat(manager: &Manager, name: &str) -> Arc<PtySession> {
    let (session, created) = manager
        .open(name, &["/bin/cat".to_string()], None, None, 80, 24)
        .expect("open pty");
    assert!(created, "{name} is a fresh pty");
    session
}

async fn write_pty(session: &Arc<PtySession>, bytes: &[u8]) {
    muxd::pty::write_all(&session.master, bytes)
        .await
        .expect("write to pty");
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// Poll `ready` until it holds, or fail the test.
async fn wait_until(mut ready: impl FnMut() -> bool, what: &str) {
    let deadline = std::time::Instant::now() + PATIENCE;
    while std::time::Instant::now() < deadline {
        if ready() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for {what}");
}

/// Drain client messages until `needle` shows up in the output stream.
async fn recv_output_until(rx: &mut Receiver<ClientMsg>, needle: &[u8]) -> Vec<u8> {
    let drain = async {
        let mut seen = Vec::new();
        while !contains(&seen, needle) {
            match rx.recv().await {
                Some(ClientMsg::Output(bytes)) => seen.extend_from_slice(&bytes),
                Some(ClientMsg::Exit(code)) => panic!("pty exited {code} before {needle:?}"),
                None => panic!("client channel closed before {needle:?}"),
            }
        }
        seen
    };
    tokio::time::timeout(PATIENCE, drain)
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for {needle:?}"))
}

/// Drain output until the exit event, and answer with its code.
async fn recv_exit(rx: &mut Receiver<ClientMsg>) -> i32 {
    let drain = async {
        loop {
            match rx.recv().await {
                Some(ClientMsg::Output(_)) => {}
                Some(ClientMsg::Exit(code)) => return code,
                None => panic!("client channel closed before the exit event"),
            }
        }
    };
    tokio::time::timeout(PATIENCE, drain)
        .await
        .expect("timed out waiting for the exit event")
}

/// Short /tmp path: `sun_path` is 104 bytes on darwin.
fn temp_socket(what: &str) -> PathBuf {
    let path = PathBuf::from(format!("/tmp/muxd-t-{}-{what}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

async fn connect(socket: &Path) -> UnixStream {
    UnixStream::connect(socket).await.expect("connect")
}

fn attached(name: &str, created: bool) -> Opened {
    Opened::Attached {
        name: name.to_string(),
        created,
    }
}

/// Handshake an attach-or-create of `name` running `/bin/cat`.
async fn open_pane(stream: &mut UnixStream, name: &str) -> OpenReply {
    let request = OpenRequest {
        version: peer::PROTOCOL_VERSION,
        cols: 80,
        rows: 24,
        term: Some("xterm-ghostty".into()),
        token: None,
        target: None,
        mode: OpenMode::Open {
            name: name.to_string(),
            cwd: None,
            command: vec!["/bin/cat".to_string()],
            cwd_from: None,
        },
    };
    let bytes = peer::encode(&request);
    let len = u32::try_from(bytes.len()).expect("request length");
    stream
        .write_all(&len.to_le_bytes())
        .await
        .expect("write length");
    stream.write_all(&bytes).await.expect("write request");

    let (lane, payload) = read_frame(stream).await.expect("reply frame");
    assert_eq!(lane, OUT_LANE_OPENED);
    peer::decode(&payload).expect("decode reply")
}

/// The reattach replay always follows the reply, even when empty.
async fn read_dump(stream: &mut UnixStream) -> Vec<u8> {
    let (lane, payload) = read_frame(stream).await.expect("dump frame");
    assert_eq!(lane, OUT_LANE_OUTPUT);
    payload
}

async fn write_frame(stream: &mut UnixStream, lane: u8, payload: &[u8]) {
    let len = u32::try_from(payload.len() + 1).expect("frame length");
    stream
        .write_all(&len.to_le_bytes())
        .await
        .expect("write length");
    stream.write_all(&[lane]).await.expect("write lane");
    stream.write_all(payload).await.expect("write payload");
}

async fn read_frame(stream: &mut UnixStream) -> Option<(u8, Vec<u8>)> {
    let read = async {
        let len = stream.read_u32_le().await.ok()?;
        let lane = stream.read_u8().await.ok()?;
        let mut payload = vec![0u8; (len - 1) as usize];
        stream.read_exact(&mut payload).await.ok()?;
        Some((lane, payload))
    };
    tokio::time::timeout(PATIENCE, read)
        .await
        .expect("frame timed out")
}

async fn read_output_until(stream: &mut UnixStream, needle: &[u8]) -> Vec<u8> {
    let mut seen = Vec::new();
    while !contains(&seen, needle) {
        let Some((lane, payload)) = read_frame(stream).await else {
            panic!("connection ended before {needle:?}");
        };
        match lane {
            OUT_LANE_OUTPUT => seen.extend_from_slice(&payload),
            OUT_LANE_EVENTS => panic!("unexpected event before {needle:?}"),
            other => panic!("unexpected lane {other}"),
        }
    }
    seen
}

/// Read whatever is left until the daemon closes its half.
async fn read_until_eof(stream: &mut UnixStream) {
    let drain = async {
        let mut scratch = [0u8; 1024];
        loop {
            match stream.read(&mut scratch).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
        }
    };
    tokio::time::timeout(PATIENCE, drain)
        .await
        .expect("the evicted client's connection never ended");
}
