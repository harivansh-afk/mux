//! The local daemon's outbound half: one QUIC connection per remote host,
//! one bidirectional stream per relayed pane.
//!
//! Panes never dial the network. A pane opens the local unix socket with
//! `target = Some(alias)`; this module rewrites the handshake (target
//! cleared, bearer token injected) onto a stream of the per-host QUIC
//! connection and then splices raw bytes both ways. Nothing after the
//! handshake is parsed here: the pane and the remote daemon speak the same
//! lane protocol end to end, so the broker is a pipe.
//!
//! Trust is trust-on-first-use keyed by the host ALIAS, like ssh:
//! [`tls::fingerprint`] of the presented certificate is written to
//! `known_hosts` on first contact and must match on every later one. The
//! certificate is self-signed by design, so nothing else about it is
//! checked - the pin, not a CA and not the name, is the whole decision.

use std::collections::{BTreeMap, HashMap};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use mux_proto::frame;
use mux_proto::peer::{self, ErrorKind, OpenError, OpenRequest};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, PeerIncompatible, SignatureScheme};
use serde::Deserialize;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

use crate::{paths, server, tls};

const DIAL_TIMEOUT: Duration = Duration::from_secs(10);
const RESOLVE_TIMEOUT: Duration = Duration::from_secs(5);

/// Opening a stream on a cached connection must not hang: a connection
/// whose network path silently died looks live until the idle timeout,
/// and `open_bi` on it would stall a new pane for that whole window.
const OPEN_TIMEOUT: Duration = Duration::from_secs(10);

/// A terminal connection is idle almost all the time, and quinn's
/// defaults (no keep-alive, 30s idle timeout) tear it down under every
/// quiet pane - each one paying a redial plus reattach on the next
/// keystroke. PINGs keep the connection and the path (NAT bindings,
/// overlay tunnels) warm.
const KEEP_ALIVE: Duration = Duration::from_secs(5);

/// Also the ceiling on how long a pane freezes when the path dies
/// without a `CONNECTION_CLOSE` (sleep/wake, network switch): silence
/// this long despite keep-alives every [`KEEP_ALIVE`] means the peer
/// or the path is genuinely gone, and reconnect + replay is automatic
/// and cheap, so err toward declaring death early.
const MAX_IDLE: Duration = Duration::from_secs(15);

/// The SNI every dial sends. A host presents one certificate and the pin
/// decides trust, so the name carries no meaning; a constant also spares
/// aliases that are not legal DNS names a special case.
const SNI: &str = "muxd";

/// Why a dial failed. A changed host key is the one reason that is not
/// "the host is not reachable", and rustls buries it under a generic TLS
/// alert, so it travels back separately.
enum DialError {
    Pin(String),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for DialError {
    fn from(e: anyhow::Error) -> Self {
        Self::Other(e)
    }
}

/// A broker-side failure, as the pane sees it.
fn failed(kind: ErrorKind, e: &anyhow::Error) -> OpenError {
    OpenError::new(kind, format!("{e:#}"))
}

/// Nothing got through to the host. The address is in the message
/// because "spark is off" and "spark moved" read identically without it.
fn unreachable(alias: &str, addr: &str, e: &anyhow::Error) -> OpenError {
    OpenError::new(
        ErrorKind::Unreachable,
        format!("cannot reach {alias} at {addr}: {e:#}"),
    )
}

/// Relay a targeted request over the per-host QUIC link.
///
/// Failures before the request reaches the remote daemon are reported to
/// the pane as an `Err` `OpenReply` on lane 0, the same shape the local
/// arms of the protocol use, so the pane shows a message instead of a
/// silently dead socket.
pub async fn relay<R, W>(request: OpenRequest, reader: R, writer: W) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    global().relay(request, reader, writer).await
}

fn global() -> &'static Broker {
    static BROKER: OnceLock<Broker> = OnceLock::new();
    BROKER.get_or_init(Broker::from_env)
}

/// The host registry plus the live connections opened from it.
struct Broker {
    /// `hosts.json`: `{"alias": {"addr": "host:4433"}}`.
    hosts: PathBuf,
    /// `known_hosts`: one `<alias> sha256:<b64>` line per pinned host.
    known_hosts: PathBuf,
    /// This client's own bearer token, presented to every host that has
    /// no per-alias override.
    client_token: PathBuf,
    /// The directory of per-alias overrides of that token.
    tokens: PathBuf,
    links: tokio::sync::Mutex<HashMap<String, quinn::Connection>>,
}

impl Broker {
    fn from_env() -> Self {
        Self {
            hosts: paths::hosts_config(),
            known_hosts: paths::known_hosts(),
            client_token: paths::client_token(),
            tokens: paths::token_dir(),
            links: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    async fn relay<R, W>(&self, request: OpenRequest, reader: R, mut writer: W) -> Result<()>
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let Some(alias) = request.target.clone() else {
            bail!("relay called on a request with no target");
        };
        let stream = match self.open_stream(&alias, request).await {
            Ok(stream) => stream,
            Err(error) => {
                tracing::warn!(host = %alias, kind = %error.kind, detail = error.detail, "relay failed");
                return server::reply(&mut writer, &Err(error)).await;
            }
        };
        splice(reader, &mut writer, stream).await
    }

    /// Dial (or reuse) the host's connection, open a stream on it and send
    /// the rewritten handshake. Everything that can fail with a message the
    /// user can act on happens here, before any byte reaches the pane.
    async fn open_stream(&self, alias: &str, request: OpenRequest) -> Result<(quinn::SendStream, quinn::RecvStream), OpenError> {
        check_alias(alias).map_err(|e| failed(ErrorKind::NoHost, &e))?;
        let addr = host_addr(&self.hosts, alias).map_err(|e| failed(ErrorKind::NoHost, &e))?;
        let token = host_token(&self.tokens, &self.client_token, alias)
            .map_err(|e| failed(ErrorKind::Other, &e))?;
        let connection = self.connection(alias, &addr).await?;

        let request = OpenRequest {
            version: mux_proto::peer::PROTOCOL_VERSION,
            // The remote daemon serves this itself, and it authenticates by
            // token: the pane never holds either.
            target: None,
            token: Some(token),
            ..request
        };
        let payload = peer::encode(&request);
        if payload.len() > frame::MAX_REQUEST_BYTES as usize {
            let len = payload.len();
            return Err(OpenError::new(
                ErrorKind::Other,
                format!("request too large ({len} bytes)"),
            ));
        }

        let opened = tokio::time::timeout(OPEN_TIMEOUT, async {
            let (mut send, recv) = connection.open_bi().await.context("open QUIC stream")?;
            frame::aio::write_message(&mut send, &payload)
                .await
                .context("send handshake")?;
            Ok::<_, anyhow::Error>((send, recv))
        })
        .await
        .unwrap_or_else(|_| bail!("open stream timed out after {OPEN_TIMEOUT:?}"));
        match opened {
            Ok(stream) => Ok(stream),
            // A cached connection that cannot open a stream is dead
            // weight: evict it so the pane's automatic retry redials
            // instead of hitting the same corpse.
            Err(e) => {
                self.evict(alias).await;
                Err(unreachable(alias, &addr, &e))
            }
        }
    }

    async fn evict(&self, alias: &str) {
        if let Some(connection) = self.links.lock().await.remove(alias) {
            connection.close(0u32.into(), b"evicted");
        }
    }

    /// The cached connection for `alias`, redialing when there is none or
    /// the cached one is closed. The cache lock is not held across the dial,
    /// so an unreachable host cannot stall relays to other hosts; a lost
    /// race just closes the loser's connection.
    async fn connection(&self, alias: &str, addr: &str) -> Result<quinn::Connection, OpenError> {
        if let Some(connection) = self.live(alias).await {
            return Ok(connection);
        }
        let connection = self.dial(alias, addr).await?;
        let mut links = self.links.lock().await;
        if let Some(existing) = links.get(alias) {
            if existing.close_reason().is_none() {
                connection.close(0u32.into(), b"duplicate");
                return Ok(existing.clone());
            }
        }
        links.insert(alias.to_string(), connection.clone());
        Ok(connection)
    }

    async fn live(&self, alias: &str) -> Option<quinn::Connection> {
        let mut links = self.links.lock().await;
        let connection = links.get(alias)?;
        if let Some(reason) = connection.close_reason() {
            tracing::debug!(host = %alias, %reason, "cached connection is dead, redialing");
            links.remove(alias);
            return None;
        }
        Some(connection.clone())
    }

    async fn dial(&self, alias: &str, addr: &str) -> Result<quinn::Connection, OpenError> {
        match self.try_dial(alias, addr).await {
            Ok(link) => Ok(link),
            // rustls only hands the caller a generic TLS alert, so a pin
            // failure recorded by the verifier is the real reason.
            Err(DialError::Pin(failure)) => Err(OpenError::new(ErrorKind::PinMismatch, failure)),
            Err(DialError::Other(e)) => Err(unreachable(alias, addr, &e)),
        }
    }

    async fn try_dial(&self, alias: &str, addr: &str) -> Result<quinn::Connection, DialError> {
        let remote = resolve(addr).await?;
        let provider = rustls::crypto::ring::default_provider();
        let verifier = Arc::new(Tofu::new(
            alias,
            self.known_hosts.clone(),
            provider.signature_verification_algorithms,
        ));

        let mut crypto = rustls::ClientConfig::builder_with_provider(Arc::new(provider))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .context("TLS 1.3 unavailable")?
            .dangerous()
            .with_custom_certificate_verifier(verifier.clone())
            .with_no_client_auth();
        crypto.alpn_protocols = vec![peer::ALPN.to_vec()];
        let crypto = quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
            .context("QUIC-incompatible TLS config")?;

        let bind = if remote.is_ipv6() {
            SocketAddr::from((Ipv6Addr::UNSPECIFIED, 0))
        } else {
            SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0))
        };
        let mut endpoint = quinn::Endpoint::client(bind).context("bind QUIC socket")?;
        let mut client = quinn::ClientConfig::new(Arc::new(crypto));
        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(KEEP_ALIVE));
        transport.max_idle_timeout(Some(MAX_IDLE.try_into().context("idle timeout")?));
        client.transport_config(Arc::new(transport));
        endpoint.set_default_client_config(client);

        let connecting = endpoint.connect(remote, SNI).context("start QUIC dial")?;
        let connection = match tokio::time::timeout(DIAL_TIMEOUT, connecting).await {
            Err(_) => {
                return Err(
                    anyhow::anyhow!("dial {remote} timed out after {DIAL_TIMEOUT:?}").into(),
                )
            }
            Ok(Err(e)) => match verifier.failure() {
                Some(failure) => return Err(DialError::Pin(failure)),
                None => {
                    return Err(anyhow::Error::from(e)
                        .context(format!("dial {remote}"))
                        .into())
                }
            },
            Ok(Ok(connection)) => connection,
        };
        tracing::info!(host = %alias, %remote, "QUIC connection established");
        // The endpoint keeps its UDP socket alive for as long as a
        // connection made on it exists, so dropping this handle costs the
        // connection nothing and redialing gets a fresh socket.
        Ok(connection)
    }
}

/// Pump bytes both ways until either side is done, then close the other
/// half so the peer sees an EOF rather than a stall.
async fn splice<R, W>(
    mut reader: R,
    writer: &mut W,
    stream: (quinn::SendStream, quinn::RecvStream),
) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let (mut send, mut recv) = stream;
    let up = async {
        tokio::io::copy(&mut reader, &mut send).await?;
        let _ = send.finish(); // pane detached: half-close the stream
        Ok::<_, anyhow::Error>(())
    };
    let down = async {
        tokio::io::copy(&mut recv, writer).await?;
        writer.shutdown().await?; // remote hung up: let the pane see it
        Ok::<_, anyhow::Error>(())
    };
    tokio::select! {
        r = up => r,
        r = down => r,
    }
}

// ---------------------------------------------------------------- registry

/// An alias keys a `known_hosts` line and names a token file, so it may
/// not carry whitespace (which would split the line) or path separators
/// (which would leave the token directory).
fn check_alias(alias: &str) -> Result<()> {
    let ok = alias.starts_with(|c: char| c.is_ascii_alphanumeric())
        && alias
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
    if !ok {
        bail!("invalid host alias {alias:?}: letters, digits, '.', '_' and '-' only");
    }
    Ok(())
}

/// One host in `hosts.json`. Unknown fields are ignored: Mux.app reads
/// the same file and may carry keys the daemon has no use for.
#[derive(Deserialize)]
struct HostEntry {
    /// `host[:port]`; a bare host takes [`peer::DEFAULT_QUIC_PORT`].
    addr: String,
}

/// The `addr` of `alias` in `hosts.json`. A missing file is an empty
/// registry: "not in there" is the same answer either way, and the
/// listing of what *is* there says which case it was. Sorted map, so
/// that listing is in a stable order.
fn host_addr(hosts: &Path, alias: &str) -> Result<String> {
    let table: BTreeMap<String, HostEntry> = match std::fs::read(hosts) {
        Ok(bytes) => {
            serde_json::from_slice(&bytes).with_context(|| format!("parse {}", hosts.display()))?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
        Err(e) => return Err(e).with_context(|| format!("read {}", hosts.display())),
    };
    if let Some(host) = table.get(alias) {
        return Ok(host.addr.clone());
    }
    let known: Vec<&str> = table.keys().map(String::as_str).collect();
    let known = if known.is_empty() {
        "none".to_string()
    } else {
        known.join(", ")
    };
    bail!(
        "unknown host {alias:?} in {}; known: {known}",
        hosts.display()
    )
}

/// The bearer token to present to `alias`, injected into the relayed
/// handshake so the pane never holds it.
///
/// Normally this client's single identity, generated on first use: the
/// host enrolls its digest (`muxd client-digest`), so nothing secret
/// crosses machines. `tokens/<alias>` overrides it for a host that hands
/// out a token of its own instead.
fn host_token(tokens: &Path, client_token: &Path, alias: &str) -> Result<String> {
    let path = tokens.join(alias);
    match std::fs::read_to_string(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tls::load_or_generate_token(client_token)
        }
        Err(e) => Err(e).with_context(|| format!("read {}", path.display())),
        Ok(token) => {
            let token = token.trim().to_string();
            if token.is_empty() {
                bail!("{} is empty", path.display());
            }
            Ok(token)
        }
    }
}

async fn resolve(addr: &str) -> Result<SocketAddr> {
    let addr = with_default_port(addr);
    let resolved = tokio::time::timeout(RESOLVE_TIMEOUT, tokio::net::lookup_host(&addr))
        .await
        .map_err(|_| anyhow::anyhow!("resolve {addr}: timed out after {RESOLVE_TIMEOUT:?}"))?
        .with_context(|| format!("resolve {addr}"))?
        .next();
    resolved.with_context(|| format!("{addr} resolved to no address"))
}

/// `hosts.json` documents `host:4433`, but a bare host is the obvious
/// shorthand for the default port.
fn with_default_port(addr: &str) -> String {
    let has_port = match addr.rfind(']') {
        Some(bracket) => addr[bracket..].contains(':'),
        None => addr.matches(':').count() == 1,
    };
    if has_port {
        addr.to_string()
    } else {
        format!("{addr}:{}", peer::DEFAULT_QUIC_PORT)
    }
}

// -------------------------------------------------------------------- tofu

/// Trust-on-first-use pinning for one host alias.
#[derive(Debug)]
struct Tofu {
    alias: String,
    known_hosts: PathBuf,
    algorithms: WebPkiSupportedAlgorithms,
    /// The pin failure, kept because rustls turns it into an opaque alert.
    /// Written at most once, by the one handshake this verifier serves.
    failure: OnceLock<String>,
}

impl Tofu {
    fn new(alias: &str, known_hosts: PathBuf, algorithms: WebPkiSupportedAlgorithms) -> Self {
        Self {
            alias: alias.to_string(),
            known_hosts,
            algorithms,
            failure: OnceLock::new(),
        }
    }

    fn failure(&self) -> Option<String> {
        self.failure.get().cloned()
    }
}

impl ServerCertVerifier for Tofu {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        match check_pin(&self.alias, &self.known_hosts, end_entity) {
            Ok(stored) => {
                if let Some(fingerprint) = stored {
                    tracing::warn!(
                        host = %self.alias,
                        %fingerprint,
                        "pinned new host key on first contact",
                    );
                }
                Ok(ServerCertVerified::assertion())
            }
            Err(e) => {
                let message = format!("{e:#}");
                let _ = self.failure.set(message.clone());
                Err(rustls::Error::General(message))
            }
        }
    }

    /// Unreachable: `dial` offers TLS 1.3 only, and QUIC forbids anything
    /// older. Refusing beats verifying a version this client never agreed
    /// to speak.
    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            PeerIncompatible::Tls12NotOfferedOrEnabled,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// The whole trust decision: match the stored pin, or store it. `Some`
/// is the fingerprint written on first contact.
fn check_pin(alias: &str, known_hosts: &Path, cert: &CertificateDer<'_>) -> Result<Option<String>> {
    let fingerprint = tls::fingerprint(cert);
    if let Some(pinned) = read_pin(known_hosts, alias)? {
        if pinned == fingerprint {
            return Ok(None);
        }
        bail!(
            "host key changed for {alias}: pinned {pinned}, presented {fingerprint}. \
             Either someone is impersonating {alias} or its key was regenerated; \
             remove the {alias} line from {} to trust the new key",
            known_hosts.display()
        );
    }
    append_pin(known_hosts, alias, &fingerprint)?;
    Ok(Some(fingerprint))
}

fn read_pin(known_hosts: &Path, alias: &str) -> Result<Option<String>> {
    let text = match std::fs::read_to_string(known_hosts) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("read {}", known_hosts.display())),
    };
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        if fields.next() == Some(alias) {
            return Ok(fields.next().map(ToString::to_string));
        }
    }
    Ok(None)
}

fn append_pin(known_hosts: &Path, alias: &str, fingerprint: &str) -> Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;

    if let Some(parent) = known_hosts.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(known_hosts)
        .with_context(|| format!("open {}", known_hosts.display()))?;
    writeln!(file, "{alias} {fingerprint}")
        .with_context(|| format!("append to {}", known_hosts.display()))
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    fn cert() -> rcgen::CertifiedKey {
        rcgen::generate_simple_self_signed(vec!["muxd".to_string()]).unwrap()
    }

    fn broker(dir: &TempDir) -> Broker {
        let dir = dir.path();
        Broker {
            hosts: dir.join("hosts.json"),
            known_hosts: dir.join("known_hosts"),
            client_token: dir.join("token"),
            tokens: dir.join("tokens"),
            links: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    fn request(alias: &str) -> OpenRequest {
        OpenRequest {
            version: mux_proto::peer::PROTOCOL_VERSION,
            cols: 120,
            rows: 40,
            term: Some("xterm-ghostty".to_string()),
            token: None,
            target: Some(alias.to_string()),
            mode: peer::OpenMode::List,
        }
    }

    /// With no `tokens/<alias>` override the broker presents this
    /// client's own identity, generating it on first use - that token's
    /// digest is what the host enrolled.
    #[test]
    fn client_token_is_the_default_and_an_override_wins() {
        let dir = TempDir::new().unwrap();
        let client_token = dir.path().join("token");
        let tokens = dir.path().join("tokens");

        let generated = host_token(&tokens, &client_token, "spark").unwrap();
        assert_eq!(generated.len(), 64, "32 random bytes, hex encoded");
        // Stable across calls and across hosts: one identity, so a host
        // that enrolled the digest keeps working.
        assert_eq!(
            host_token(&tokens, &client_token, "spark").unwrap(),
            generated
        );
        assert_eq!(
            host_token(&tokens, &client_token, "box").unwrap(),
            generated
        );

        std::fs::create_dir_all(&tokens).unwrap();
        std::fs::write(tokens.join("spark"), "handed-out\n").unwrap();
        assert_eq!(
            host_token(&tokens, &client_token, "spark").unwrap(),
            "handed-out"
        );
        assert_eq!(
            host_token(&tokens, &client_token, "box").unwrap(),
            generated
        );

        std::fs::write(tokens.join("box"), "  \n").unwrap();
        let empty = format!(
            "{:#}",
            host_token(&tokens, &client_token, "box").unwrap_err()
        );
        assert!(empty.contains("is empty"), "{empty}");
    }

    #[test]
    fn first_use_pins_then_matches() {
        let dir = TempDir::new().unwrap();
        let known_hosts = dir.path().join("state/known_hosts");
        let key = cert();

        // A pin for another host must not answer for this one.
        append_pin(&known_hosts, "other", "sha256:AAAA").unwrap();

        let fingerprint = check_pin("spark", &known_hosts, key.cert.der())
            .unwrap()
            .expect("first contact must store a pin");
        assert_eq!(fingerprint, tls::fingerprint(key.cert.der()));
        assert_eq!(
            std::fs::read_to_string(&known_hosts).unwrap(),
            format!("other sha256:AAAA\nspark {fingerprint}\n")
        );
        assert_eq!(
            check_pin("spark", &known_hosts, key.cert.der()).unwrap(),
            None
        );
    }

    #[test]
    fn changed_host_key_is_rejected() {
        let dir = TempDir::new().unwrap();
        let known_hosts = dir.path().join("known_hosts");
        check_pin("spark", &known_hosts, cert().cert.der()).unwrap();

        let e = check_pin("spark", &known_hosts, cert().cert.der()).unwrap_err();
        let message = format!("{e:#}");
        assert!(message.contains("host key changed for spark"), "{message}");
        // The stored pin stands until the user removes it.
        assert_eq!(
            std::fs::read_to_string(&known_hosts)
                .unwrap()
                .lines()
                .count(),
            1
        );
    }

    #[test]
    fn hosts_json_lookup() {
        let dir = TempDir::new().unwrap();
        let hosts = dir.path().join("hosts.json");
        std::fs::write(
            &hosts,
            r#"{"spark": {"addr": "100.64.0.7:4433"}, "box": {"addr": "box.local"}}"#,
        )
        .unwrap();

        assert_eq!(host_addr(&hosts, "spark").unwrap(), "100.64.0.7:4433");
        assert_eq!(host_addr(&hosts, "box").unwrap(), "box.local");

        let unknown = format!("{:#}", host_addr(&hosts, "nope").unwrap_err());
        // serde_json keeps the object in a sorted map, so the hint is stable.
        assert!(unknown.contains("known: box, spark"), "{unknown}");
        assert!(unknown.contains("unknown host \"nope\""), "{unknown}");

        let missing = format!(
            "{:#}",
            host_addr(&dir.path().join("absent.json"), "spark").unwrap_err()
        );
        assert!(missing.contains("known: none"), "{missing}");

        std::fs::write(&hosts, "not json").unwrap();
        assert!(host_addr(&hosts, "spark").is_err());

        std::fs::write(&hosts, r#"{"spark": {}}"#).unwrap();
        let no_addr = format!("{:#}", host_addr(&hosts, "spark").unwrap_err());
        assert!(no_addr.contains("addr"), "{no_addr}");

        // Mux.app writes this file too, so a key the daemon does not
        // know must not break the entry it does.
        std::fs::write(
            &hosts,
            r#"{"spark": {"addr": "spark.lan", "label": "the nixos box"}}"#,
        )
        .unwrap();
        assert_eq!(host_addr(&hosts, "spark").unwrap(), "spark.lan");
    }

    #[test]
    fn aliases_cannot_break_out_of_their_files() {
        assert!(check_alias("spark").is_ok());
        assert!(check_alias("box-1.lan").is_ok());
        assert!(check_alias("").is_err());
        assert!(check_alias("..").is_err());
        assert!(check_alias("../../etc/passwd").is_err());
        assert!(check_alias("two words").is_err());
    }

    #[test]
    fn default_port_fills_in() {
        assert_eq!(with_default_port("spark"), "spark:4433");
        assert_eq!(with_default_port("spark:9000"), "spark:9000");
        assert_eq!(with_default_port("10.0.0.1"), "10.0.0.1:4433");
        assert_eq!(with_default_port("[::1]:9000"), "[::1]:9000");
        assert_eq!(with_default_port("[::1]"), "[::1]:4433");
    }

    fn error_reply(bytes: &[u8]) -> OpenError {
        let (lane, len) = frame::parse_header(bytes[..5].try_into().unwrap()).unwrap();
        assert_eq!(lane, frame::OUT_LANE_OPENED);
        assert_eq!(bytes.len(), 5 + len);
        match peer::decode::<peer::OpenReply>(&bytes[5..]).unwrap() {
            Err(error) => error,
            Ok(opened) => panic!("expected an error reply, got {opened:?}"),
        }
    }

    /// An unknown alias must reach the pane as a readable reply, not a
    /// dropped socket.
    #[tokio::test]
    async fn relay_reports_an_unknown_host() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join("hosts.json"),
            r#"{"spark": {"addr": "127.0.0.1:4433"}}"#,
        )
        .unwrap();

        let mut written = Vec::new();
        broker(&dir)
            .relay(request("ghost"), tokio::io::empty(), &mut written)
            .await
            .unwrap();

        let error = error_reply(&written);
        assert_eq!(error.kind, ErrorKind::NoHost);
        assert!(error.detail.contains("ghost"), "{error}");
        assert!(error.detail.contains("known: spark"), "{error}");

    }

    /// A host that cannot be reached comes back as `Unreachable`.
    /// `.invalid` never resolves (RFC 2606), so this fails at the first
    /// network step.
    #[tokio::test]
    async fn relay_reports_an_unreachable_host() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join("hosts.json"),
            r#"{"spark": {"addr": "spark.invalid"}}"#,
        )
        .unwrap();

        let mut written = Vec::new();
        broker(&dir)
            .relay(request("spark"), tokio::io::empty(), &mut written)
            .await
            .unwrap();

        let error = error_reply(&written);
        assert_eq!(error.kind, ErrorKind::Unreachable);
        assert!(error.detail.contains("cannot reach spark"), "{error}");

    }

    /// A minimal QUIC listener presenting `key`: enough of a peer to prove
    /// the dial, the pin, the rewritten handshake and the byte pump. Built
    /// through `quic::endpoint` so the two halves cannot drift apart.
    fn listener(key: &rcgen::CertifiedKey) -> quinn::Endpoint {
        let identity = tls::Identity {
            cert: key.cert.der().clone(),
            key: rustls::pki_types::PrivatePkcs8KeyDer::from(key.key_pair.serialize_der()).into(),
        };
        crate::quic::endpoint(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), &identity).unwrap()
    }

    /// A listener on loopback, plus the `hosts.json` and token file a
    /// broker over `dir` needs to reach it.
    fn quic_fixture(dir: &TempDir, key: &rcgen::CertifiedKey) -> quinn::Endpoint {
        let endpoint = listener(key);
        let addr = endpoint.local_addr().unwrap();
        std::fs::write(
            dir.path().join("hosts.json"),
            format!(r#"{{"spark": {{"addr": "{addr}"}}}}"#),
        )
        .unwrap();
        std::fs::create_dir_all(dir.path().join("tokens")).unwrap();
        std::fs::write(dir.path().join("tokens/spark"), "s3cret\n").unwrap();
        endpoint
    }

    /// The pin failure has to survive the TLS stack, which turns it into an
    /// opaque alert, and come out as the message the user needs.
    #[tokio::test]
    async fn relay_reports_a_changed_host_key() {
        let dir = TempDir::new().unwrap();
        let endpoint = quic_fixture(&dir, &cert());
        append_pin(&dir.path().join("known_hosts"), "spark", "sha256:stale").unwrap();

        let remote = tokio::spawn(async move {
            if let Some(incoming) = endpoint.accept().await {
                let _ = incoming.await;
            }
        });

        let mut written = Vec::new();
        tokio::time::timeout(
            Duration::from_secs(10),
            broker(&dir).relay(request("spark"), tokio::io::empty(), &mut written),
        )
        .await
        .expect("dial timed out")
        .unwrap();
        remote.abort();

        let error = error_reply(&written);
        assert_eq!(error.kind, ErrorKind::PinMismatch);
        assert!(
            error.detail.contains("host key changed for spark"),
            "{error}"
        );
        assert!(error.detail.contains("sha256:stale"), "{error}");

    }

    /// One relayed connection: send `up`, collect what comes back. The
    /// duplex keeps the pane's side open, so the relay ends when the remote
    /// finishes its stream rather than when a canned reader hits EOF.
    async fn exchange(broker: &Broker) -> Vec<u8> {
        let (pane, mut app) = tokio::io::duplex(64);
        app.write_all(b"up").await.unwrap();
        let mut down = Vec::new();
        tokio::time::timeout(
            Duration::from_secs(10),
            broker.relay(request("spark"), pane, &mut down),
        )
        .await
        .expect("relay timed out")
        .unwrap();
        down
    }

    #[tokio::test]
    async fn relays_the_rewritten_handshake_and_bytes() {

        let dir = TempDir::new().unwrap();
        let key = cert();
        let endpoint = quic_fixture(&dir, &key);

        // One connection, one stream per relayed pane: the listener accepts
        // a single connection and serves both panes on it.
        let remote = tokio::spawn(async move {
            let connection = endpoint.accept().await.unwrap().await.unwrap();
            let mut relayed = Vec::new();
            for _ in 0..2 {
                let (mut send, mut recv) = connection.accept_bi().await.unwrap();
                let buf = frame::aio::read_message(&mut recv).await.unwrap();
                let mut up = [0u8; 2];
                recv.read_exact(&mut up).await.unwrap();
                assert_eq!(&up, b"up");
                send.write_all(b"down").await.unwrap();
                send.finish().unwrap();
                relayed.push(peer::decode::<OpenRequest>(&buf).unwrap());
            }
            // Hold the connection open until the broker drops it.
            connection.closed().await;
            relayed
        });

        let broker = broker(&dir);
        assert_eq!(exchange(&broker).await, b"down");
        assert_eq!(exchange(&broker).await, b"down");
        assert_eq!(broker.links.lock().await.len(), 1);
        drop(broker);

        let relayed = remote.await.unwrap();
        assert_eq!(relayed.len(), 2);
        for request in relayed {
            // Rewritten: the target is resolved here and the token is added
            // here; everything else passes through untouched.
            assert_eq!(request.target, None);
            assert_eq!(request.token.as_deref(), Some("s3cret"));
            assert_eq!(request.cols, 120);
            assert_eq!(request.term.as_deref(), Some("xterm-ghostty"));
        }

        // First contact pinned the host key.
        let pinned = read_pin(&dir.path().join("known_hosts"), "spark").unwrap();
        assert_eq!(pinned, Some(tls::fingerprint(key.cert.der())));
    }
}
