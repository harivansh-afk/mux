//! Admission and protocol failures must happen before opening a service socket.

use mux_proto::peer::{ErrorKind, OpenMode, OpenRequest};
use muxd::{manager::Manager, server::Policy};
use tokio::io::{duplex, split};
use tokio::net::UnixListener;

mod common;

async fn rejection(request: OpenRequest, policy: Policy) -> mux_proto::peer::OpenError {
    let (mut client, server) = duplex(4096);
    let (reader, writer) = split(server);
    let handling = tokio::spawn(async move {
        muxd::server::handle_connection(Manager::default(), reader, writer, &policy).await
    });
    common::write_request(&mut client, &request).await;
    let error = common::read_reply(&mut client).await.expect_err("rejected");
    handling
        .await
        .expect("handler task")
        .expect("rejection reply");
    error
}

#[tokio::test]
async fn forward_requires_authentication_and_v11_before_connecting() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("service.sock");
    let listener = UnixListener::bind(&path).expect("service");
    let mode = OpenMode::Connect {
        path: path.to_string_lossy().into_owned(),
    };
    let request = common::request(None, None, mode);
    let policy = Policy::Remote {
        admitted: muxd::tls::load_admitted(muxd::tls::digest("secret"), None).expect("admitted"),
    };
    assert_eq!(
        rejection(request.clone(), policy).await.kind,
        ErrorKind::TokenRejected
    );
    let mut old = request;
    old.version = 10;
    assert_eq!(
        rejection(old, Policy::Local).await.kind,
        ErrorKind::VersionMismatch
    );
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn forward_rejects_relative_paths_regular_files_and_missing_sockets() {
    let dir = tempfile::tempdir().expect("tempdir");
    let file = dir.path().join("file");
    std::fs::write(&file, b"preserve me").expect("file");
    for path in [
        "relative.sock".to_owned(),
        file.to_string_lossy().into_owned(),
        dir.path().join("missing").to_string_lossy().into_owned(),
    ] {
        let error = rejection(
            common::request(None, None, OpenMode::Connect { path }),
            Policy::Local,
        )
        .await;
        assert_eq!(error.kind, ErrorKind::Other);
    }
    assert_eq!(std::fs::read(file).expect("original file"), b"preserve me");
}
