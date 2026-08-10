//! The daemon's QUIC identity and bearer token: load-or-generate, on
//! disk at the locations `mux_proto::paths` documents.
//!
//! There is no CA. The certificate is self-signed and clients pin the
//! SHA-256 of its `SubjectPublicKeyInfo` (ssh-style trust-on-first-use;
//! `known_hosts` in paths.rs), so the pin is logged once at startup for
//! out-of-band copying. The token is the second factor: a certificate
//! proves which daemon answered, the token proves the caller is allowed
//! to talk to it.

use std::fs;
use std::io::Write as _;
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::path::Path;

use anyhow::{Context, Result};
use base64::Engine as _;
use mux_proto::paths;
use rand::RngCore as _;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest as _, Sha256};

/// A key is a secret; a certificate is not, but nothing else needs to
/// read either, so both are owner-only.
const SECRET_MODE: u32 = 0o600;

/// What the QUIC listener needs to present itself.
pub struct Identity {
    pub cert: CertificateDer<'static>,
    pub key: PrivateKeyDer<'static>,
    /// `sha256:<base64>` over the certificate SPKI: byte for byte the
    /// token a client stores in `known_hosts` (see paths.rs), so the
    /// logged line can be copied verbatim.
    pub spki_pin: String,
}

/// SHA-256 of a secret. Tokens are compared as digests: equal-length,
/// fixed-size values, so the comparison leaks nothing about the secret
/// even though `==` short circuits.
#[must_use]
pub fn digest(secret: &str) -> [u8; 32] {
    Sha256::digest(secret.as_bytes()).into()
}

/// Read `cert.pem`/`key.pem`, generating a self-signed pair on first
/// use, and log the pin clients need.
///
/// # Errors
///
/// Certificate generation, PEM parsing, or writing the state directory.
pub fn load_or_generate_identity() -> Result<Identity> {
    let cert_path = paths::daemon_cert();
    let key_path = paths::daemon_key();

    let pair = match (
        fs::read_to_string(&cert_path),
        fs::read_to_string(&key_path),
    ) {
        (Ok(cert), Ok(key)) => (cert, key),
        // A half-written pair (one file only) is regenerated whole:
        // a cert without its key is useless either way.
        _ => generate(&cert_path, &key_path)?,
    };
    let (cert_pem, key_pem) = pair;

    // rcgen re-derives the SPKI from the private key, which saves
    // pulling in an X.509 parser just to reach one field.
    let key_pair = rcgen::KeyPair::from_pem(&key_pem)
        .with_context(|| format!("parse {}", key_path.display()))?;
    // Exactly the `known_hosts` token: SHA-256 over the SPKI DER
    // (tag+len+value, what public_key_der returns), standard base64
    // alphabet, padded. A client comparing strings must get a match.
    let spki_pin = format!(
        "sha256:{}",
        base64::engine::general_purpose::STANDARD.encode(Sha256::digest(key_pair.public_key_der()))
    );
    tracing::info!(pin = %spki_pin, "certificate SPKI (pin this on clients)");

    Ok(Identity {
        cert: CertificateDer::from(pem_body(&cert_pem, "CERTIFICATE")?),
        key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(pem_body(&key_pem, "PRIVATE KEY")?)),
        spki_pin,
    })
}

/// Read the bearer token, generating 32 random bytes (hex) on first use.
///
/// # Errors
///
/// Writing the token file or its parent directory.
pub fn load_or_generate_token() -> Result<String> {
    let path = paths::daemon_token();
    if let Ok(existing) = fs::read_to_string(&path) {
        let token = existing.trim();
        if !token.is_empty() {
            return Ok(token.to_string());
        }
    }
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = hex(&bytes);
    write_secret(&path, token.as_bytes())?;
    tracing::info!(path = %path.display(), "generated bearer token");
    Ok(token)
}

fn generate(cert_path: &Path, key_path: &Path) -> Result<(String, String)> {
    // The names are cosmetic: clients pin the SPKI, they do not resolve
    // a hostname back to this certificate.
    let certified = rcgen::generate_simple_self_signed(vec!["muxd".into(), "localhost".into()])
        .context("generate self-signed certificate")?;
    let cert_pem = certified.cert.pem();
    let key_pem = certified.key_pair.serialize_pem();
    write_secret(cert_path, cert_pem.as_bytes())?;
    write_secret(key_path, key_pem.as_bytes())?;
    tracing::info!(cert = %cert_path.display(), "generated self-signed certificate");
    Ok((cert_pem, key_pem))
}

fn write_secret(path: &Path, contents: &[u8]) -> Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(SECRET_MODE)
        .open(path)
        .with_context(|| format!("create {}", path.display()))?;
    file.write_all(contents)
        .with_context(|| format!("write {}", path.display()))?;
    // `.mode()` only applies when the file is created; a pre-existing
    // file keeps its old, possibly wider, permissions.
    fs::set_permissions(path, fs::Permissions::from_mode(SECRET_MODE))
        .with_context(|| format!("chmod {}", path.display()))
}

/// The DER between a PEM block's BEGIN/END lines. Enough for the two
/// shapes rcgen writes, and cheaper than a PEM dependency.
fn pem_body(pem: &str, tag: &str) -> Result<Vec<u8>> {
    let base64: String = pem
        .split_once(&format!("-----BEGIN {tag}-----"))
        .and_then(|(_, rest)| rest.split_once(&format!("-----END {tag}-----")))
        .map(|(body, _)| body.split_whitespace().collect())
        .with_context(|| format!("no {tag} block in PEM"))?;
    base64::engine::general_purpose::STANDARD
        .decode(base64)
        .with_context(|| format!("decode {tag} body"))
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}
