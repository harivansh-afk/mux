//! The QUIC listener: the same protocol the unix socket serves, reached
//! over the network.
//!
//! One bidirectional stream is one logical connection - handshake plus
//! lane frames - so a client keeps a single QUIC connection per host and
//! opens a stream per pane. Panes then attach and detach independently
//! without re-handshaking TLS, and QUIC's per-stream flow control keeps
//! one busy pane from starving the others.
//!
//! Admission differs from the unix socket in exactly two ways, both in
//! [`server::Policy::Remote`]: the bearer token is required, and a
//! `target` is refused. Reaching another host is the *local* daemon's
//! job (it is the broker), so a request that arrives here has already
//! been routed and must be served by this daemon or not at all.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use mux_proto::peer;
use quinn::{Endpoint, Incoming, RecvStream, SendStream, ServerConfig};

/// Explicit rather than inherited from quinn (whose default happens to
/// match): 30 seconds of silence from a client that keep-alives every
/// few seconds means it is genuinely gone, and its ptys just detach.
const MAX_IDLE: Duration = Duration::from_secs(30);

use crate::manager::Manager;
use crate::server::{self, Policy};
use crate::tls::{self, Identity};

/// Load the daemon's identity and token, bind, and serve until the
/// endpoint dies.
///
/// # Errors
///
/// Missing or unreadable TLS material, or a failed bind.
pub async fn serve(manager: Manager, addr: SocketAddr) -> Result<()> {
    let identity = tls::load_or_generate_identity()?;
    let token = tls::load_or_generate_token()?;
    let endpoint = endpoint(addr, &identity)?;
    tracing::info!(addr = %endpoint.local_addr()?, "muxd listening (quic)");
    accept(manager, endpoint, tls::digest(&token)).await;
    Ok(())
}

/// Bind a QUIC endpoint presenting `identity`. Separate from [`accept`]
/// so a caller can read `local_addr()` (an ephemeral port in tests)
/// before serving.
///
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
    config.transport_config(Arc::new(transport));
    Endpoint::server(config, addr).with_context(|| format!("bind {addr}"))
}

/// Accept connections until the endpoint is closed.
pub async fn accept(manager: Manager, endpoint: Endpoint, token_digest: [u8; 32]) {
    while let Some(incoming) = endpoint.accept().await {
        let manager = manager.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(manager, incoming, token_digest).await {
                tracing::debug!(error = %e, "quic connection ended with error");
            }
        });
    }
}

async fn handle_connection(
    manager: Manager,
    incoming: Incoming,
    token_digest: [u8; 32],
) -> Result<()> {
    let connection = incoming.await.context("quic handshake")?;
    let peer_addr = connection.remote_address();
    tracing::info!(peer = %peer_addr, "quic client connected");

    loop {
        // Every close - graceful, idle timeout, peer gone - ends the
        // accept loop the same way: no more streams are coming.
        let (send, recv) = match connection.accept_bi().await {
            Ok(stream) => stream,
            Err(e) => {
                tracing::info!(peer = %peer_addr, reason = %e, "quic client disconnected");
                return Ok(());
            }
        };
        let manager = manager.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_stream(manager, send, recv, token_digest).await {
                tracing::debug!(error = %e, "quic stream ended with error");
            }
        });
    }
}

async fn handle_stream(
    manager: Manager,
    mut send: SendStream,
    mut recv: RecvStream,
    token_digest: [u8; 32],
) -> Result<()> {
    // By reference: the handler owns the streams for its lifetime, and
    // we still need `send` afterwards to close our half.
    let result = server::handle_connection(
        manager,
        &mut recv,
        &mut send,
        &Policy::Remote { token_digest },
    )
    .await;
    // A one-shot caller (list, kill, a rejection) reads until EOF, so
    // finish even when the handler failed.
    let _ = send.finish();
    result
}
