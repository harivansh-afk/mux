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
use std::time::Duration;

use mux_proto::peer::{self, OpenMode, OpenReply, OpenRequest, Opened};
use mux_proto::shell::{IN_LANE_INPUT, OUT_LANE_OPENED, OUT_LANE_OUTPUT};
use quinn::{Endpoint, RecvStream, SendStream};
use tokio::io::AsyncReadExt as _;

/// Long enough to be immune to a loaded CI box, short enough that a hang
/// fails the run instead of stalling it.
const PATIENCE: Duration = Duration::from_secs(10);

#[tokio::test]
async fn quic_listener_serves_authenticated_clients() {
    let home = tempdir();
    std::env::set_var("HOME", &home);

    let identity = muxd::tls::load_or_generate_identity().expect("identity");
    let token = muxd::tls::load_or_generate_token().expect("token");
    assert_eq!(token.len(), 64, "32 random bytes, hex encoded");
    // The pin is copied verbatim into a client's known_hosts, so its
    // shape is a contract: sha256: plus padded standard base64 of a
    // 32-byte digest.
    let encoded = identity
        .spki_pin
        .strip_prefix("sha256:")
        .expect("known_hosts pin prefix");
    assert_eq!(encoded.len(), 44, "base64 of 32 bytes, padded: {encoded}");
    assert!(
        !encoded.contains(['-', '_']),
        "standard alphabet: {encoded}"
    );

    let state = home.join(".local/state/muxd");
    assert_eq!(mode(&state.join("key.pem")), 0o600, "private key is 0600");
    assert_eq!(mode(&state.join("token")), 0o600, "token is 0600");
    // Second load reuses the files rather than rotating them out from
    // under clients that already pinned.
    assert_eq!(token, muxd::tls::load_or_generate_token().expect("token"));

    let manager = muxd::manager::Manager::default();
    let endpoint = muxd::quic::endpoint(loopback(), &identity).expect("bind");
    let addr = endpoint.local_addr().expect("local addr");
    tokio::spawn(muxd::quic::accept(
        manager.clone(),
        endpoint,
        muxd::tls::digest(&token),
    ));

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
    let reply = read_reply(&mut recv).await;
    assert_eq!(reply, Err("authentication failed".to_string()));

    // (b) The real token attaches, and the pty is wired both ways.
    let (mut send, mut recv) = connection.open_bi().await.expect("open_bi");
    write_request(
        &mut send,
        &request(
            Some(&token),
            None,
            OpenMode::Open {
                name: "cat".into(),
                cwd: None,
                command: vec!["/bin/cat".into()],
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
    // The reattach dump always follows the reply, even when empty.
    let (lane, _dump) = read_frame(&mut recv).await.expect("dump frame");
    assert_eq!(lane, OUT_LANE_OUTPUT);

    write_frame(&mut send, IN_LANE_INPUT, b"ping\n").await;
    let echoed = read_output_until(&mut recv, b"ping").await;
    assert!(
        echoed.windows(4).any(|w| w == b"ping"),
        "cat should echo back: {echoed:?}"
    );

    // (c) A relay request is refused: routing is the local daemon's job.
    let (mut send, mut recv) = connection.open_bi().await.expect("open_bi");
    write_request(
        &mut send,
        &request(Some(&token), Some("elsewhere"), OpenMode::List),
    )
    .await;
    match read_reply(&mut recv).await {
        Err(message) => assert!(message.contains("does not relay"), "{message}"),
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

fn request(token: Option<&str>, target: Option<&str>, mode: OpenMode) -> OpenRequest {
    OpenRequest {
        version: mux_proto::peer::PROTOCOL_VERSION,
        cols: 80,
        rows: 24,
        term: Some("xterm-ghostty".into()),
        token: token.map(ToString::to_string),
        target: target.map(ToString::to_string),
        mode,
    }
}

async fn write_request(send: &mut SendStream, request: &OpenRequest) {
    let bytes = peer::encode(request);
    let len = u32::try_from(bytes.len()).expect("request length");
    send.write_all(&len.to_le_bytes()).await.expect("write len");
    send.write_all(&bytes).await.expect("write request");
}

async fn write_frame(send: &mut SendStream, lane: u8, payload: &[u8]) {
    let len = u32::try_from(payload.len() + 1).expect("frame length");
    send.write_all(&len.to_le_bytes()).await.expect("write len");
    send.write_all(&[lane]).await.expect("write lane");
    send.write_all(payload).await.expect("write payload");
}

async fn read_frame(recv: &mut RecvStream) -> Option<(u8, Vec<u8>)> {
    let read = async {
        let len = recv.read_u32_le().await.ok()?;
        let lane = recv.read_u8().await.ok()?;
        let mut payload = vec![0u8; (len - 1) as usize];
        recv.read_exact(&mut payload).await.ok()?;
        Some((lane, payload))
    };
    tokio::time::timeout(PATIENCE, read)
        .await
        .expect("frame timed out")
}

async fn read_reply(recv: &mut RecvStream) -> OpenReply {
    let (lane, payload) = read_frame(recv).await.expect("reply frame");
    assert_eq!(lane, OUT_LANE_OPENED);
    peer::decode(&payload).expect("decode reply")
}

/// Drain output frames until `needle` shows up. The pty echoes the line
/// and `cat` writes it again, so the bytes can arrive in any grouping.
async fn read_output_until(recv: &mut RecvStream, needle: &[u8]) -> Vec<u8> {
    let mut seen = Vec::new();
    while !seen.windows(needle.len()).any(|w| w == needle) {
        let Some((lane, payload)) = read_frame(recv).await else {
            break;
        };
        if lane == OUT_LANE_OUTPUT {
            seen.extend_from_slice(&payload);
        }
    }
    seen
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

/// Test-only: real clients pin the server's SPKI hash (`known_hosts`),
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
