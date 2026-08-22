//! One bidirectional stream is one logical connection - handshake plus
//! lane frames - so a client keeps a single QUIC connection per host and
//! opens a stream per pane.
//!
//! A remote request must carry a bearer token this daemon admits and may
//! not carry a `target`: reaching another host is the local daemon's job.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::paths;
use mux_proto::peer;
use quinn::{Endpoint, Incoming, RecvStream, SendStream, ServerConfig};

/// Explicit rather than inherited from quinn (whose default happens to match): 30 seconds of silence from a client that keep-alives every few seconds means it is genuinely gone, and its ptys just detach.
const MAX_IDLE: Duration = Duration::from_secs(30);
/// Concurrent bidi streams per connection: one per pane connection, so far more than any real client opens, and small enough to cap what a pre-auth peer can make the daemon buffer.
const MAX_STREAMS: u32 = 64;

use crate::manager::Manager;
use crate::server::{self, Policy};
use crate::tls::{self, Admitted, Identity};

/// Load the daemon's identity and the tokens it admits, bind, and serve.
/// Never returns `Ok`: while the listener was asked for, serving it is
/// the daemon's job for as long as the daemon lives.
///
/// # Errors
///
/// Missing or unreadable TLS material, an unparseable authorized-tokens
/// file, a failed bind, or a closed endpoint.
pub async fn serve(manager: Manager, addr: SocketAddr, authorized: Option<&Path>) -> Result<()> {
    let identity = tls::load_or_generate_identity()?;
    let token = tls::load_or_generate_token(&paths::daemon_token())?;
    let admitted = tls::load_admitted(tls::digest(&token), authorized)?;
    let endpoint = endpoint(addr, &identity)?;
    tracing::info!(addr = %endpoint.local_addr()?, "muxd listening (quic)");
    accept(manager, endpoint, admitted).await;
    bail!("quic endpoint closed")
}

/// # Errors
///
/// A rustls config the ring provider rejects, or a failed UDP bind.
pub fn endpoint(addr: SocketAddr, identity: &Identity) -> Result<Endpoint> {
    // rustls 0.23 has no implicit provider: name ring (the feature the
    // workspace pins) rather than depending on process-wide install
    // order.
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .context("rustls protocol versions")?
        .with_no_client_auth()
        .with_single_cert(vec![identity.cert.clone()], identity.key.clone_key())
        .context("server certificate")?;
    tls.alpn_protocols = vec![peer::ALPN.to_vec()];

    let crypto = quinn::crypto::rustls::QuicServerConfig::try_from(tls).context("quic tls")?;
    let mut config = ServerConfig::with_crypto(Arc::new(crypto));
    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(MAX_IDLE.try_into().context("idle timeout")?));
    transport.max_concurrent_bidi_streams(quinn::VarInt::from_u32(MAX_STREAMS));
    transport.max_concurrent_uni_streams(quinn::VarInt::from_u32(0));
    config.transport_config(Arc::new(transport));
    Endpoint::server(config, addr).with_context(|| format!("bind {addr}"))
}

/// Accept connections until the endpoint is closed.
pub async fn accept(manager: Manager, endpoint: Endpoint, admitted: Admitted) {
    while let Some(incoming) = endpoint.accept().await {
        let manager = manager.clone();
        let admitted = admitted.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(manager, incoming, admitted).await {
                tracing::debug!(error = %e, "quic connection ended with error");
            }
        });
    }
}

async fn handle_connection(manager: Manager, incoming: Incoming, admitted: Admitted) -> Result<()> {
    let connection = incoming.await.context("quic handshake")?;
    let peer_addr = connection.remote_address();
    tracing::info!(peer = %peer_addr, "quic client connected");

    loop {
        let (send, recv) = match connection.accept_bi().await {
            Ok(stream) => stream,
            Err(e) => {
                tracing::info!(peer = %peer_addr, reason = %e, "quic client disconnected");
                return Ok(());
            }
        };
        let manager = manager.clone();
        let admitted = admitted.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_stream(manager, send, recv, admitted).await {
                tracing::debug!(error = %e, "quic stream ended with error");
            }
        });
    }
}

async fn handle_stream(
    manager: Manager,
    mut send: SendStream,
    mut recv: RecvStream,
    admitted: Admitted,
) -> Result<()> {
    let result =
        server::handle_connection(manager, &mut recv, &mut send, &Policy::Remote { admitted })
            .await;
    let _ = send.finish();
    result
}
