//! The control socket's accept loop under descriptor exhaustion.
//!
//! One test, one file: proving this means lowering `RLIMIT_NOFILE` and
//! holding every free descriptor in the process, which no sibling test in
//! the same binary could survive. Cargo gives each `tests/*.rs` its own
//! process, so the squeeze stays in here. Multi-threaded, because the
//! daemon under test has to keep running while this thread squeezes it.

use std::path::PathBuf;
use std::time::Duration;

use mux_proto::peer::{self, OpenMode, OpenReply, OpenRequest, Opened};
use mux_proto::shell::OUT_LANE_OPENED;
use muxd::manager::Manager;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;

const PATIENCE: Duration = Duration::from_secs(10);
/// Low enough that hoarding every free descriptor is instant, high enough
/// that the runtime and the listener already have theirs.
const SQUEEZED_NOFILE: u64 = 256;

/// Regression: a single `accept` error propagated out of `serve` and out
/// of `main`, so one EMFILE - a burst of panes, another process eating the
/// descriptor table - killed the daemon and every session on it. Transient
/// accept failures are now logged and retried.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn accept_survives_running_out_of_descriptors() {
    let socket = temp_socket();
    let listener = muxd::server::bind(&socket).await.expect("bind");
    let serving = tokio::spawn(muxd::server::serve(Manager::default(), listener));

    // Baseline: the daemon answers before the squeeze.
    let mut probe = UnixStream::connect(&socket).await.expect("connect");
    write_request(&mut probe).await;
    assert!(matches!(
        read_reply(&mut probe).await,
        Ok(Opened::Listed { .. })
    ));
    drop(probe);

    let saved = soft_nofile();
    set_soft_nofile(SQUEEZED_NOFILE.min(saved));
    let mut hoard = hoard_descriptors();
    assert!(hoard.len() > 4, "the squeeze took no descriptors");
    // Hand one back: enough for the client's connect, nothing left for
    // the daemon's accept.
    close(hoard.pop().expect("a descriptor to release"));

    // A connect lands in the listener's backlog without the daemon
    // spending a descriptor; the accept it provokes is what fails. The
    // connection itself is collateral - darwin dequeues it before it
    // discovers it has no descriptor for it, and aborts it - so what is
    // being proven here is that the daemon outlives the failure, not that
    // this client is served.
    let doomed = UnixStream::connect(&socket)
        .await
        .expect("connect under pressure");

    // Several backoff turns: the connection stays queued, so every accept
    // in this window fails the same way.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let survived = !serving.is_finished();

    // Pressure off before asserting: a panic holding the whole descriptor
    // table cannot even print itself.
    for fd in hoard.drain(..) {
        close(fd);
    }
    set_soft_nofile(saved);
    assert!(
        survived,
        "the daemon died of a transient accept failure: {:?}",
        serving.await
    );

    drop(doomed);

    // Still the same daemon, on the same socket, serving normally.
    let mut client = UnixStream::connect(&socket).await.expect("reconnect");
    write_request(&mut client).await;
    let reply = read_reply(&mut client).await;
    assert!(
        matches!(reply, Ok(Opened::Listed { .. })),
        "the daemon serves again once descriptors free up: {reply:?}"
    );

    let _ = std::fs::remove_file(&socket);
}

/// Short /tmp path: `sun_path` is 104 bytes on darwin.
fn temp_socket() -> PathBuf {
    let path = PathBuf::from(format!("/tmp/muxd-t-{}-accept.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

async fn write_request(stream: &mut UnixStream) {
    let request = OpenRequest {
        version: peer::PROTOCOL_VERSION,
        cols: 80,
        rows: 24,
        term: None,
        token: None,
        target: None,
        mode: OpenMode::List,
    };
    let bytes = peer::encode(&request);
    let len = u32::try_from(bytes.len()).expect("request length");
    stream
        .write_all(&len.to_le_bytes())
        .await
        .expect("write length");
    stream.write_all(&bytes).await.expect("write request");
}

async fn read_reply(stream: &mut UnixStream) -> OpenReply {
    let read = async {
        let len = stream.read_u32_le().await.expect("reply length");
        let lane = stream.read_u8().await.expect("reply lane");
        assert_eq!(lane, OUT_LANE_OPENED);
        let mut payload = vec![0u8; (len - 1) as usize];
        stream.read_exact(&mut payload).await.expect("reply body");
        peer::decode::<OpenReply>(&payload).expect("decode reply")
    };
    tokio::time::timeout(PATIENCE, read)
        .await
        .expect("the daemon never answered")
}

fn soft_nofile() -> u64 {
    limits().rlim_cur
}

fn limits() -> libc::rlimit {
    // SAFETY: getrlimit fills the struct it is handed; zeroed is a valid
    // starting value for it.
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) } == 0;
    assert!(ok, "getrlimit: {}", std::io::Error::last_os_error());
    limit
}

fn set_soft_nofile(soft: u64) {
    let mut limit = limits();
    limit.rlim_cur = soft.min(limit.rlim_max);
    // SAFETY: a well-formed rlimit whose soft value the hard limit allows.
    let ok = unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limit) } == 0;
    assert!(ok, "setrlimit: {}", std::io::Error::last_os_error());
}

/// Take every descriptor the process can still open, so the next `accept`
/// answers EMFILE.
fn hoard_descriptors() -> Vec<i32> {
    let mut held = Vec::new();
    loop {
        // SAFETY: dup of the process's own stdin, which is open for the
        // life of the test.
        let fd = unsafe { libc::dup(0) };
        if fd < 0 {
            return held;
        }
        held.push(fd);
    }
}

fn close(fd: i32) {
    // SAFETY: fd came from hoard_descriptors and is closed exactly once.
    unsafe { libc::close(fd) };
}
