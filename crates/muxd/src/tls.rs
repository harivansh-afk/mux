//! Bearer tokens and the daemon's QUIC identity: load-or-generate, on
//! disk at the locations `mux_proto::paths` documents.
//!
//! There is no CA. The certificate is self-signed and clients pin the
//! SHA-256 of its `SubjectPublicKeyInfo` (ssh-style trust-on-first-use;
//! `known_hosts` in paths.rs), so the pin is logged once at startup for
//! out-of-band copying. The token is the second factor: a certificate
//! proves which daemon answered, the token proves the caller is allowed
//! to talk to it.
//!
//! Tokens are the same recipe on both sides - 32 random bytes as hex,
//! 0600 - because both sides hold one: the daemon its own, a client its
//! single identity. Only digests travel, so enrolling a client is
//! pasting the output of `muxd client-digest` into the daemon's
//! `--authorized-tokens` file.

use std::collections::HashSet;
use std::fs;
use std::io::Write as _;
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::path::Path;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use base64::Engine as _;
use rand::RngCore as _;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest as _, Sha256};

use mux_proto::paths;

/// Every token digest a listener admits: its own, plus whatever
/// `--authorized-tokens` enrolled. Shared by every connection handler,
/// hence the `Arc`.
pub type Admitted = Arc<HashSet<[u8; 32]>>;

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

/// The printable form of [`digest`]: `sha256:<64 lowercase hex>`, one
/// line of an authorized-tokens file. This is what `muxd client-digest`
/// prints and the only thing about a token that ever leaves its machine.
#[must_use]
pub fn digest_line(secret: &str) -> String {
    format!("sha256:{}", hex(&digest(secret)))
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

/// Read the bearer token at `path`, generating 32 random bytes (hex) on
/// first use. Both the daemon's own token and a client's identity are
/// this, at the two paths `paths` names.
///
/// # Errors
///
/// Writing the token file or its parent directory.
pub fn load_or_generate_token(path: &Path) -> Result<String> {
    if let Ok(existing) = fs::read_to_string(path) {
        let token = existing.trim();
        if !token.is_empty() {
            return Ok(token.to_string());
        }
    }
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = hex(&bytes);
    write_secret(path, token.as_bytes())?;
    tracing::info!(path = %path.display(), "generated bearer token");
    Ok(token)
}

/// The digests a `--authorized-tokens` file enrolls, on top of `own`
/// (the daemon's token always admits itself).
///
/// # Errors
///
/// The file is unreadable, or a line is not `sha256:<64 hex>`.
pub fn load_admitted(own: [u8; 32], authorized: Option<&Path>) -> Result<Admitted> {
    let mut digests = HashSet::from([own]);
    if let Some(path) = authorized {
        let text = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        let enrolled = parse_digests(&text).with_context(|| format!("parse {}", path.display()))?;
        tracing::info!(path = %path.display(), count = enrolled.len(), "authorized tokens");
        digests.extend(enrolled);
    }
    Ok(Arc::new(digests))
}

/// One `sha256:<64 lowercase hex>` per line; blank lines and `#`
/// comments are ignored. A malformed line is an error rather than a skip:
/// a typo that silently locked a client out would look exactly like a
/// rejected token.
fn parse_digests(text: &str) -> Result<Vec<[u8; 32]>> {
    let mut digests = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let hex = line
            .strip_prefix("sha256:")
            .with_context(|| format!("line {}: expected sha256:<64 hex>, got {line:?}", n + 1))?;
        if hex.len() != 64
            || !hex
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            bail!(
                "line {}: expected 64 lowercase hex digits, got {hex:?}",
                n + 1
            );
        }
        let mut digest = [0u8; 32];
        for (byte, pair) in digest.iter_mut().zip(hex.as_bytes().chunks_exact(2)) {
            let pair = std::str::from_utf8(pair).expect("hex is ascii");
            *byte = u8::from_str_radix(pair, 16).expect("checked hex digits");
        }
        digests.push(digest);
    }
    Ok(digests)
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The file format is what a user pastes into their host config, so
    /// every shape it tolerates is spelled out here.
    #[test]
    fn authorized_tokens_file_parses() {
        let a = digest_line("client-a");
        let b = digest_line("client-b");
        let text = format!("# the macbook\n{a}\n\n  {b}  \n");

        let parsed = parse_digests(&text).unwrap();
        assert_eq!(parsed, vec![digest("client-a"), digest("client-b")]);
    }

    #[test]
    fn a_malformed_digest_is_an_error() {
        for bad in [
            "deadbeef",                              // no prefix
            "sha256:",                               // no digest
            "sha256:xyz",                            // too short
            &format!("sha256:{}", "A".repeat(64)),   // uppercase hex
            &format!("sha256:{}", "ab".repeat(33)),  // too long
            &format!("{}\nnope", digest_line("ok")), // a good line does not excuse a bad one
        ] {
            assert!(parse_digests(bad).is_err(), "{bad:?} should not parse");
        }
    }

    /// `sha256:<64 hex>` of the token, and it round-trips back to the
    /// digest the admission check compares.
    #[test]
    fn digest_line_round_trips() {
        let line = digest_line("s3cret");
        let hex = line.strip_prefix("sha256:").expect("prefix");
        assert_eq!(hex.len(), 64);
        assert_eq!(parse_digests(&line).unwrap(), vec![digest("s3cret")]);
    }

    #[test]
    fn admitted_always_holds_the_daemons_own_token() {
        let admitted = load_admitted(digest("mine"), None).unwrap();
        assert!(admitted.contains(&digest("mine")));
        assert!(!admitted.contains(&digest("theirs")));
    }
}
