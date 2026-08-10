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
//! Trust is trust-on-first-use keyed by the host ALIAS, like ssh: the
//! SHA-256 of the presented certificate's `SubjectPublicKeyInfo` is written
//! to `known_hosts` on first contact and must match on every later one. The
//! certificate is self-signed by design, so nothing else about it is
//! checked - the pin, not a CA and not the name, is the whole decision.

use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use base64::Engine as _;
use mux_proto::paths;
use mux_proto::peer::{self, OpenReply, OpenRequest};
use mux_proto::shell::OUT_LANE_OPENED;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

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
/// without a CONNECTION_CLOSE (sleep/wake, network switch): silence
/// this long despite keep-alives every [`KEEP_ALIVE`] means the peer
/// or the path is genuinely gone, and reconnect + replay is automatic
/// and cheap, so err toward declaring death early.
const MAX_IDLE: Duration = Duration::from_secs(15);

/// SNI for aliases that are not legal DNS names. The pin decides trust, so
/// the name we send is cosmetic.
const SNI_FALLBACK: &str = "muxd";

/// Relay a targeted request over the per-host QUIC link.
///
/// Failures before the request reaches the remote daemon are reported to
/// the pane as an `Err` `OpenReply` on lane 0, the same shape the local
/// arms of the protocol use, so the pane shows a message instead of a
/// silently dead socket.
///
/// # Errors
///
/// Returns an error only when writing to the pane's own socket fails;
/// broker-side failures are turned into error replies instead.
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
    /// The directory holding one bearer token per alias.
    tokens: PathBuf,
    links: tokio::sync::Mutex<HashMap<String, Link>>,
}

/// A live connection and the endpoint that owns its UDP socket. The
/// endpoint is held so redialing a host drops the old socket with the old
/// connection.
struct Link {
    _endpoint: quinn::Endpoint,
    connection: quinn::Connection,
}

impl Broker {
    fn from_env() -> Self {
        Self {
            hosts: paths::hosts_config(),
            known_hosts: paths::known_hosts(),
            // `paths::host_token` is the contract; `token_dir_matches_paths`
            // holds this equal to it.
            tokens: paths::client_state_dir().join("tokens"),
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
            Err(e) => {
                tracing::warn!(host = %alias, error = %format!("{e:#}"), "relay failed");
                let reply: OpenReply = Err(format!("{alias}: {e:#}"));
                return write_reply(&mut writer, &reply).await;
            }
        };
        splice(reader, &mut writer, stream).await
    }

    /// Dial (or reuse) the host's connection, open a stream on it and send
    /// the rewritten handshake. Everything that can fail with a message the
    /// user can act on happens here, before any byte reaches the pane.
    async fn open_stream(&self, alias: &str, request: OpenRequest) -> Result<Stream> {
        check_alias(alias)?;
        let addr = host_addr(&self.hosts, alias)?;
        let token = host_token(&self.tokens, alias)?;
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
        let len = u32::try_from(payload.len()).unwrap_or(u32::MAX);
        if len > peer::MAX_REQUEST_BYTES {
            bail!("request too large ({len} bytes)");
        }

        let opened = tokio::time::timeout(OPEN_TIMEOUT, async {
            let (mut send, recv) = connection.open_bi().await.context("open QUIC stream")?;
            send.write_u32_le(len).await.context("send handshake")?;
            send.write_all(&payload).await.context("send handshake")?;
            Ok::<_, anyhow::Error>(Stream { send, recv })
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
                Err(e)
            }
        }
    }

    async fn evict(&self, alias: &str) {
        if let Some(link) = self.links.lock().await.remove(alias) {
            link.connection.close(0u32.into(), b"evicted");
        }
    }

    /// The cached connection for `alias`, redialing when there is none or
    /// the cached one is closed. The cache lock is not held across the dial,
    /// so an unreachable host cannot stall relays to other hosts; a lost
    /// race just closes the loser's connection.
    async fn connection(&self, alias: &str, addr: &str) -> Result<quinn::Connection> {
        if let Some(connection) = self.live(alias).await {
            return Ok(connection);
        }
        let link = self.dial(alias, addr).await?;
        let mut links = self.links.lock().await;
        if let Some(existing) = links.get(alias) {
            if existing.connection.close_reason().is_none() {
                link.connection.close(0u32.into(), b"duplicate");
                return Ok(existing.connection.clone());
            }
        }
        let connection = link.connection.clone();
        links.insert(alias.to_string(), link);
        Ok(connection)
    }

    async fn live(&self, alias: &str) -> Option<quinn::Connection> {
        let mut links = self.links.lock().await;
        let link = links.get(alias)?;
        if let Some(reason) = link.connection.close_reason() {
            tracing::debug!(host = %alias, %reason, "cached connection is dead, redialing");
            links.remove(alias);
            return None;
        }
        Some(link.connection.clone())
    }

    async fn dial(&self, alias: &str, addr: &str) -> Result<Link> {
        let remote = resolve(addr).await?;
        let verifier = Arc::new(Tofu::new(alias, self.known_hosts.clone()));

        let mut crypto = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
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

        let sni = if ServerName::try_from(alias).is_ok() {
            alias
        } else {
            SNI_FALLBACK
        };
        let connecting = endpoint.connect(remote, sni).context("start QUIC dial")?;
        let connection = match tokio::time::timeout(DIAL_TIMEOUT, connecting).await {
            Err(_) => bail!("dial {remote} timed out after {DIAL_TIMEOUT:?}"),
            // rustls only hands the caller a generic TLS alert, so a pin
            // failure recorded by the verifier wins over quinn's error.
            Ok(Err(e)) => match verifier.failure() {
                Some(failure) => bail!(failure),
                None => return Err(e).with_context(|| format!("dial {remote}")),
            },
            Ok(Ok(connection)) => connection,
        };
        tracing::info!(host = %alias, %remote, "QUIC connection established");
        Ok(Link {
            _endpoint: endpoint,
            connection,
        })
    }
}

struct Stream {
    send: quinn::SendStream,
    recv: quinn::RecvStream,
}

/// Pump bytes both ways until either side is done, then close the other
/// half so the peer sees an EOF rather than a stall.
async fn splice<R, W>(mut reader: R, writer: &mut W, stream: Stream) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let Stream { mut send, mut recv } = stream;
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

async fn write_reply<W: AsyncWrite + Unpin>(writer: &mut W, reply: &OpenReply) -> Result<()> {
    let payload = peer::encode(reply);
    let len = 1 + u32::try_from(payload.len()).context("reply too large")?;
    writer.write_u32_le(len).await?;
    writer.write_u8(OUT_LANE_OPENED).await?;
    writer.write_all(&payload).await?;
    writer.flush().await?;
    Ok(())
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

/// The `addr` of `alias` in `hosts.json`.
fn host_addr(hosts: &Path, alias: &str) -> Result<String> {
    let bytes = std::fs::read(hosts).with_context(|| {
        format!(
            "no host registry at {}; add {{\"{alias}\": {{\"addr\": \"<host>:{}\"}}}}",
            hosts.display(),
            peer::DEFAULT_QUIC_PORT,
        )
    })?;
    let parsed: serde_json::Value =
        serde_json::from_slice(&bytes).with_context(|| format!("parse {}", hosts.display()))?;
    let table = parsed
        .as_object()
        .with_context(|| format!("{}: expected a JSON object", hosts.display()))?;
    let host = table.get(alias).with_context(|| {
        let known: Vec<&str> = table.keys().map(String::as_str).collect();
        format!(
            "unknown host {alias:?} in {}; known hosts: {}",
            hosts.display(),
            if known.is_empty() {
                "none".to_string()
            } else {
                known.join(", ")
            }
        )
    })?;
    host.get("addr")
        .and_then(serde_json::Value::as_str)
        .map(ToString::to_string)
        .with_context(|| format!("{}: host {alias:?} has no \"addr\"", hosts.display()))
}

/// The bearer token the remote daemon expects, injected into the relayed
/// handshake so the pane never holds it.
fn host_token(tokens: &Path, alias: &str) -> Result<String> {
    let path = tokens.join(alias);
    let token = std::fs::read_to_string(&path).with_context(|| {
        format!(
            "no bearer token for {alias:?}: copy the remote daemon's ~/.local/state/muxd/token to {} (mode 0600)",
            path.display()
        )
    })?;
    let token = token.trim().to_string();
    if token.is_empty() {
        bail!("{} is empty", path.display());
    }
    Ok(token)
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
    provider: Arc<rustls::crypto::CryptoProvider>,
    /// The pin failure, kept because rustls turns it into an opaque alert.
    failure: Mutex<Option<String>>,
}

impl Tofu {
    fn new(alias: &str, known_hosts: PathBuf) -> Self {
        Self {
            alias: alias.to_string(),
            known_hosts,
            provider: Arc::new(rustls::crypto::ring::default_provider()),
            failure: Mutex::new(None),
        }
    }

    fn failure(&self) -> Option<String> {
        self.failure.lock().unwrap().clone()
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
            Ok(Pin::Stored(fingerprint)) => {
                tracing::warn!(
                    host = %self.alias,
                    %fingerprint,
                    "pinned new host key on first contact",
                );
                Ok(ServerCertVerified::assertion())
            }
            Ok(Pin::Matched) => Ok(ServerCertVerified::assertion()),
            Err(e) => {
                let message = format!("{e:#}");
                *self.failure.lock().unwrap() = Some(message.clone());
                Err(rustls::Error::General(message))
            }
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Pin {
    /// First contact: the fingerprint was appended to `known_hosts`.
    Stored(String),
    /// The stored pin matched.
    Matched,
}

/// The whole trust decision: match the stored pin, or store it.
fn check_pin(alias: &str, known_hosts: &Path, cert: &CertificateDer<'_>) -> Result<Pin> {
    let fingerprint = fingerprint(cert)?;
    if let Some(pinned) = read_pin(known_hosts, alias)? {
        if pinned == fingerprint {
            return Ok(Pin::Matched);
        }
        bail!(
            "host key changed for {alias}: pinned {pinned}, presented {fingerprint}. \
             Either someone is impersonating {alias} or its key was regenerated; \
             remove the {alias} line from {} to trust the new key",
            known_hosts.display()
        );
    }
    append_pin(known_hosts, alias, &fingerprint)?;
    Ok(Pin::Stored(fingerprint))
}

/// `sha256:<base64 of the SHA-256 of the certificate's SPKI>`, the form
/// stored in `known_hosts`.
fn fingerprint(cert: &CertificateDer<'_>) -> Result<String> {
    let spki = spki(cert).context("read the server certificate's public key")?;
    let digest = Sha256::digest(spki);
    Ok(format!(
        "sha256:{}",
        base64::engine::general_purpose::STANDARD.encode(digest)
    ))
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

// --------------------------------------------------------------------- der

/// The DER of the certificate's `SubjectPublicKeyInfo`.
///
/// X.509 is nested DER SEQUENCEs (RFC 5280 4.1): a Certificate opens with
/// its `TBSCertificate`, whose fields are an optional `[0]` version tag, then
/// serialNumber, signature, issuer, validity, subject and the
/// `SubjectPublicKeyInfo` we hash. Walking that far needs no X.509 parser,
/// only lengths, and the pin covers exactly the key doing the channel
/// crypto.
fn spki<'a>(cert: &'a CertificateDer<'_>) -> Result<&'a [u8]> {
    const SEQUENCE: u8 = 0x30;
    const CONTEXT_0: u8 = 0xa0;

    let certificate = tlv(cert.as_ref())?;
    if certificate.tag != SEQUENCE {
        bail!("certificate is not a DER SEQUENCE");
    }
    let tbs = tlv(certificate.value)?;
    if tbs.tag != SEQUENCE {
        bail!("tbsCertificate is not a DER SEQUENCE");
    }
    let mut field = tlv(tbs.value)?;
    if field.tag == CONTEXT_0 {
        field = tlv(field.rest)?;
    }
    // serialNumber -> signature -> issuer -> validity -> subject -> spki
    for _ in 0..5 {
        field = tlv(field.rest)?;
    }
    if field.tag != SEQUENCE {
        bail!("subjectPublicKeyInfo is not a DER SEQUENCE");
    }
    Ok(field.whole)
}

/// One DER tag-length-value, plus what follows it.
struct Tlv<'a> {
    tag: u8,
    /// The value bytes.
    value: &'a [u8],
    /// Tag, length and value together: what a hash of this element covers.
    whole: &'a [u8],
    /// The bytes after this element.
    rest: &'a [u8],
}

fn tlv(der: &[u8]) -> Result<Tlv<'_>> {
    let (&tag, after_tag) = der.split_first().context("truncated DER element")?;
    let (&first, after_first) = after_tag.split_first().context("truncated DER length")?;
    let (len, body) = if first < 0x80 {
        (usize::from(first), after_first)
    } else {
        let count = usize::from(first & 0x7f);
        if count == 0 || count > 4 {
            bail!("unsupported DER length form");
        }
        let (bytes, body) = after_first
            .split_at_checked(count)
            .context("truncated DER length")?;
        let len = bytes
            .iter()
            .fold(0usize, |acc, b| (acc << 8) | usize::from(*b));
        (len, body)
    };
    let (value, rest) = body.split_at_checked(len).context("truncated DER value")?;
    Ok(Tlv {
        tag,
        value,
        whole: &der[..der.len() - rest.len()],
        rest,
    })
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU32, Ordering};

    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "muxd-broker-{tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn cert() -> rcgen::CertifiedKey {
        rcgen::generate_simple_self_signed(vec!["muxd".to_string()]).unwrap()
    }

    fn broker(dir: &Path) -> Broker {
        Broker {
            hosts: dir.join("hosts.json"),
            known_hosts: dir.join("known_hosts"),
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

    /// The token directory is spelled out here; `paths` owns the contract.
    #[test]
    fn token_dir_matches_paths() {
        assert_eq!(
            Broker::from_env().tokens.join("spark"),
            paths::host_token("spark")
        );
    }

    /// rcgen writes the same structure it hands back as `public_key_der`,
    /// so it is the oracle for the DER walk.
    #[test]
    fn spki_is_the_certificate_public_key() {
        let key = cert();
        assert_eq!(spki(key.cert.der()).unwrap(), key.key_pair.public_key_der());
    }

    #[test]
    fn truncated_certificate_is_an_error() {
        let key = cert();
        let der = CertificateDer::from(key.cert.der().as_ref()[..40].to_vec());
        assert!(spki(&der).is_err());
    }

    #[test]
    fn first_use_pins_then_matches() {
        let dir = scratch("tofu");
        let known_hosts = dir.join("state/known_hosts");
        let key = cert();

        // A pin for another host must not answer for this one.
        append_pin(&known_hosts, "other", "sha256:AAAA").unwrap();

        let first = check_pin("spark", &known_hosts, key.cert.der()).unwrap();
        let Pin::Stored(fingerprint) = first else {
            panic!("first contact must store a pin, got {first:?}");
        };
        assert_eq!(
            std::fs::read_to_string(&known_hosts).unwrap(),
            format!("other sha256:AAAA\nspark {fingerprint}\n")
        );
        assert_eq!(
            check_pin("spark", &known_hosts, key.cert.der()).unwrap(),
            Pin::Matched
        );

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn changed_host_key_is_rejected() {
        let dir = scratch("changed");
        let known_hosts = dir.join("known_hosts");
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

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn fingerprint_is_the_known_hosts_form() {
        let key = cert();
        let printed = fingerprint(key.cert.der()).unwrap();
        let expected = base64::engine::general_purpose::STANDARD
            .encode(Sha256::digest(key.key_pair.public_key_der()));
        assert_eq!(printed, format!("sha256:{expected}"));
    }

    #[test]
    fn hosts_json_lookup() {
        let dir = scratch("hosts");
        let hosts = dir.join("hosts.json");
        std::fs::write(
            &hosts,
            r#"{"spark": {"addr": "100.64.0.7:4433"}, "box": {"addr": "box.local"}}"#,
        )
        .unwrap();

        assert_eq!(host_addr(&hosts, "spark").unwrap(), "100.64.0.7:4433");
        assert_eq!(host_addr(&hosts, "box").unwrap(), "box.local");

        let unknown = format!("{:#}", host_addr(&hosts, "nope").unwrap_err());
        // serde_json keeps the object in a sorted map, so the hint is stable.
        assert!(unknown.contains("known hosts: box, spark"), "{unknown}");
        assert!(unknown.contains("unknown host \"nope\""), "{unknown}");

        let missing = format!(
            "{:#}",
            host_addr(&dir.join("absent.json"), "spark").unwrap_err()
        );
        assert!(missing.contains("no host registry at"), "{missing}");

        std::fs::write(&hosts, "not json").unwrap();
        assert!(host_addr(&hosts, "spark").is_err());

        std::fs::write(&hosts, r#"{"spark": {}}"#).unwrap();
        let no_addr = format!("{:#}", host_addr(&hosts, "spark").unwrap_err());
        assert!(no_addr.contains("has no \"addr\""), "{no_addr}");

        std::fs::remove_dir_all(&dir).unwrap();
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

    fn error_reply(frame: &[u8]) -> String {
        let len = usize::try_from(u32::from_le_bytes(frame[..4].try_into().unwrap())).unwrap();
        assert_eq!(frame.len(), 4 + len);
        assert_eq!(frame[4], OUT_LANE_OPENED);
        match peer::decode::<OpenReply>(&frame[5..]).unwrap() {
            Err(message) => message,
            Ok(opened) => panic!("expected an error reply, got {opened:?}"),
        }
    }

    /// An unknown alias must reach the pane as a readable reply, not a
    /// dropped socket.
    #[tokio::test]
    async fn relay_reports_an_unknown_host() {
        let dir = scratch("relay-unknown");
        std::fs::write(
            dir.join("hosts.json"),
            r#"{"spark": {"addr": "127.0.0.1:4433"}}"#,
        )
        .unwrap();

        let mut written = Vec::new();
        broker(&dir)
            .relay(request("ghost"), tokio::io::empty(), &mut written)
            .await
            .unwrap();

        let message = error_reply(&written);
        assert!(message.contains("ghost"), "{message}");
        assert!(message.contains("known hosts: spark"), "{message}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A known host with no token file must say where to put one.
    #[tokio::test]
    async fn relay_reports_a_missing_token() {
        let dir = scratch("relay-token");
        std::fs::write(
            dir.join("hosts.json"),
            r#"{"spark": {"addr": "127.0.0.1:4433"}}"#,
        )
        .unwrap();

        let mut written = Vec::new();
        broker(&dir)
            .relay(request("spark"), tokio::io::empty(), &mut written)
            .await
            .unwrap();

        let message = error_reply(&written);
        assert!(message.contains("no bearer token"), "{message}");
        assert!(message.contains("tokens/spark"), "{message}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A minimal QUIC listener: enough of a peer to prove the dial, the
    /// pin, the rewritten handshake and the byte pump. The real daemon
    /// listener is the other half of M3.
    fn listener(key: &rcgen::CertifiedKey) -> quinn::Endpoint {
        let mut crypto = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![key.cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(key.key_pair.serialize_der()).into(),
        )
        .unwrap();
        crypto.alpn_protocols = vec![peer::ALPN.to_vec()];
        let config = quinn::ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(crypto).unwrap(),
        ));
        quinn::Endpoint::server(config, SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap()
    }

    /// The pin failure has to survive the TLS stack, which turns it into an
    /// opaque alert, and come out as the message the user needs.
    #[tokio::test]
    async fn relay_reports_a_changed_host_key() {
        let dir = scratch("relay-pin");
        let endpoint = listener(&cert());
        let addr = endpoint.local_addr().unwrap();
        std::fs::write(
            dir.join("hosts.json"),
            format!(r#"{{"spark": {{"addr": "{addr}"}}}}"#),
        )
        .unwrap();
        std::fs::create_dir_all(dir.join("tokens")).unwrap();
        std::fs::write(dir.join("tokens/spark"), "s3cret").unwrap();
        append_pin(&dir.join("known_hosts"), "spark", "sha256:stale").unwrap();

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

        let message = error_reply(&written);
        assert!(message.contains("host key changed for spark"), "{message}");
        assert!(message.contains("sha256:stale"), "{message}");

        std::fs::remove_dir_all(&dir).unwrap();
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
        use tokio::io::AsyncReadExt as _;

        let dir = scratch("relay-quic");
        let key = cert();
        let endpoint = listener(&key);
        let addr = endpoint.local_addr().unwrap();
        std::fs::write(
            dir.join("hosts.json"),
            format!(r#"{{"spark": {{"addr": "{addr}"}}}}"#),
        )
        .unwrap();
        std::fs::create_dir_all(dir.join("tokens")).unwrap();
        std::fs::write(dir.join("tokens/spark"), "s3cret\n").unwrap();

        // One connection, one stream per relayed pane: the listener accepts
        // a single connection and serves both panes on it.
        let remote = tokio::spawn(async move {
            let connection = endpoint.accept().await.unwrap().await.unwrap();
            let mut relayed = Vec::new();
            for _ in 0..2 {
                let (mut send, mut recv) = connection.accept_bi().await.unwrap();
                let len = recv.read_u32_le().await.unwrap();
                let mut buf = vec![0u8; usize::try_from(len).unwrap()];
                recv.read_exact(&mut buf).await.unwrap();
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
        let pinned = read_pin(&dir.join("known_hosts"), "spark").unwrap();
        assert_eq!(pinned, Some(fingerprint(key.cert.der()).unwrap()));

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
