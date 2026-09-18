//! The QUIC listener end to end: a real quinn client against the real
//! accept loop, over loopback on an ephemeral port.
//!
//! One test function, not three: the daemon's TLS material and token
//! live under `$HOME`, and pointing `HOME` at a tempdir is a
//! process-wide change that would race sibling tests in this binary.

use std::net::SocketAddr;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use mux_proto::frame::IN_LANE_INPUT;
use mux_proto::peer::{self, ErrorKind, OpenError, OpenMode, Opened};
use quinn::Endpoint;

mod common;
use common::{read_dump, read_output_until, read_reply, request, write_frame, write_request};

#[tokio::test]
async fn quic_listener_serves_authenticated_clients() {
    let home = tempdir();
    std::env::set_var("HOME", &home);

    let identity = muxd::tls::load_or_generate_identity().expect("identity");
    let token = muxd::tls::load_or_generate_token(&muxd::paths::daemon_token()).expect("token");
    assert_eq!(token.len(), 64, "32 random bytes, hex encoded");
    let state = home.join(".local/state/muxd");
    assert_eq!(mode(&state.join("key.pem")), 0o600, "private key is 0600");
    assert_eq!(mode(&state.join("token")), 0o600, "token is 0600");
    // Second load reuses the files rather than rotating them out from
    // under clients that already pinned.
    assert_eq!(
        token,
        muxd::tls::load_or_generate_token(&muxd::paths::daemon_token()).expect("token")
    );

    // A client enrolled by digest only: the daemon never sees "enrolled"
    // itself, just the line `muxd client-digest` would have printed for
    // it. This is the whole point of --authorized-tokens.
    let authorized = home.join("authorized-tokens");
    std::fs::write(
        &authorized,
        format!("# the macbook\n{}\n", muxd::tls::digest_line("enrolled")),
    )
    .expect("write authorized tokens");
    let admitted =
        muxd::tls::load_admitted(muxd::tls::digest(&token), Some(&authorized)).expect("admitted");

    let manager = muxd::manager::Manager::default();
    let endpoint = muxd::quic::endpoint(loopback(), &identity).expect("bind");
    let addr = endpoint.local_addr().expect("local addr");
    tokio::spawn(muxd::quic::accept(manager.clone(), endpoint, admitted));

    let client = client_endpoint();
    let connection = client
        .connect(addr, "muxd")
        .expect("connect")
        .await
        .expect("handshake");

    // (a) A wrong bearer token is refused, with no pty created.
    let (mut send, mut recv) = connection.open_bi().await.expect("open_bi");
    write_request(
        &mut send,
        &request(Some("wrong-token"), None, OpenMode::List),
    )
    .await;
    let refused = OpenError::new(ErrorKind::TokenRejected, "authentication failed");
    assert_eq!(read_reply(&mut recv).await, Err(refused));

    // (b) An enrolled client's token is admitted the same as the
    // daemon's own, with no file ever copied between the two machines.
    let (mut send, mut recv) = connection.open_bi().await.expect("open_bi");
    write_request(&mut send, &request(Some("enrolled"), None, OpenMode::List)).await;
    match read_reply(&mut recv).await {
        Ok(Opened::Listed { .. }) => {}
        other => panic!("an enrolled token must be admitted, got {other:?}"),
    }

    // (c) The daemon's own token attaches, and the pty is wired both ways.
    let (mut send, mut recv) = connection.open_bi().await.expect("open_bi");
    write_request(
        &mut send,
        &request(
            Some(&token),
            None,
            OpenMode::Open {
                name: "cat".into(),
                cwd: None,
                command: vec![common::cat()],
                cwd_from: None,
            },
        ),
    )
    .await;
    assert_eq!(
        read_reply(&mut recv).await,
        Ok(Opened::Attached {
            name: "cat".into(),
            created: true,
        })
    );
    read_dump(&mut recv).await;

    // cat echoes back, or this never returns.
    write_frame(&mut send, IN_LANE_INPUT, b"ping\n").await;
    read_output_until(&mut recv, b"ping").await;

    // (d) A relay request is refused: routing is the local daemon's job.
    let (mut send, mut recv) = connection.open_bi().await.expect("open_bi");
    write_request(
        &mut send,
        &request(Some(&token), Some("elsewhere"), OpenMode::List),
    )
    .await;
    match read_reply(&mut recv).await {
        Err(error) => assert!(error.detail.contains("does not relay"), "{error}"),
        other => panic!("expected a rejection, got {other:?}"),
    }

    assert!(manager.kill("cat"), "the pty outlived the test");
    let _ = std::fs::remove_dir_all(&home);
}

fn loopback() -> SocketAddr {
    "127.0.0.1:0".parse().expect("loopback addr")
}

fn tempdir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("muxd-quic-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("tempdir");
    dir
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path)
        .unwrap_or_else(|e| panic!("stat {}: {e}", path.display()))
        .permissions()
        .mode()
        & 0o777
}

fn client_endpoint() -> Endpoint {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert(provider)))
        .with_no_client_auth();
    tls.alpn_protocols = vec![peer::ALPN.to_vec()];

    let crypto = quinn::crypto::rustls::QuicClientConfig::try_from(tls).expect("quic tls");
    let mut endpoint = Endpoint::client(loopback()).expect("client endpoint");
    endpoint.set_default_client_config(quinn::ClientConfig::new(Arc::new(crypto)));
    endpoint
}

/// Test-only: real clients pin the server's certificate (`known_hosts`),
/// which is the client branch's job. Here the certificate is generated
/// fresh per run, so there is nothing to pin against.
#[derive(Debug)]
struct AcceptAnyCert(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}
