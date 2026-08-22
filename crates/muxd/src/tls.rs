//! Bearer tokens and the daemon's QUIC identity: load-or-generate, on
//! disk at the locations `crate::paths` documents.
//!
//! There is no CA. The certificate is self-signed and clients pin
//! [`fingerprint`] of it (ssh-style trust-on-first-use; `known_hosts` in
//! paths.rs). The token is the second factor: a certificate proves which
//! daemon answered, the token proves the caller is allowed to talk to
//! it.
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

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine as _;
use rand::RngCore as _;
use rustls::pki_types::pem::PemObject as _;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use sha2::{Digest as _, Sha256};

use crate::paths;

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
}

/// The `known_hosts` pin for a certificate: `sha256:<standard base64 of
/// the SHA-256 of the whole DER>`. The one fingerprint function in the
/// workspace, so a client comparing strings cannot be reading a
/// different field than a host printing one.
///
/// Hashing the certificate rather than its `SubjectPublicKeyInfo` needs
/// no X.509 parser and has the same trust lifetime here: [`generate`]
/// writes the pair together and `load_or_generate_identity` regenerates
/// both if either is missing, so nothing rotates one without the other.
#[must_use]
pub fn fingerprint(cert: &CertificateDer<'_>) -> String {
    format!(
        "sha256:{}",
        base64::engine::general_purpose::STANDARD.encode(Sha256::digest(cert.as_ref()))
    )
}

/// SHA-256 of a secret. Tokens are compared as digests: equal-length,
/// fixed-size values, so the comparison leaks nothing about the secret
/// even though `==` short circuits.
pub fn digest(secret: &str) -> [u8; 32] {
    Sha256::digest(secret.as_bytes()).into()
}

/// The printable form of [`digest`]: `sha256:<64 lowercase hex>`, one
/// line of an authorized-tokens file. This is what `muxd client-digest`
/// prints and the only thing about a token that ever leaves its machine.
pub fn digest_line(secret: &str) -> String {
    format!("sha256:{}", hex::encode(digest(secret)))
}

/// Read `cert.pem`/`key.pem`, generating a self-signed pair on first
/// use.
pub fn load_or_generate_identity() -> Result<Identity> {
    let cert_path = paths::daemon_cert();
    let key_path = paths::daemon_key();

    let (cert_pem, key_pem) = match (
        fs::read_to_string(&cert_path),
        fs::read_to_string(&key_path),
    ) {
        (Ok(cert), Ok(key)) => (cert, key),
        // A half-written pair (one file only) is regenerated whole:
        // a cert without its key is useless either way.
        _ => generate(&cert_path, &key_path)?,
    };

    Ok(Identity {
        cert: CertificateDer::from_pem_slice(cert_pem.as_bytes())
            .map_err(|e| anyhow!("parse {}: {e}", cert_path.display()))?,
        key: PrivateKeyDer::from_pem_slice(key_pem.as_bytes())
            .map_err(|e| anyhow!("parse {}: {e}", key_path.display()))?,
    })
}

/// Read the bearer token at `path`, generating 32 random bytes (hex) on
/// first use. Both the daemon's own token and a client's identity are
/// this, at the two paths `paths` names.
pub fn load_or_generate_token(path: &Path) -> Result<String> {
    if let Ok(existing) = fs::read_to_string(path) {
        let token = existing.trim();
        if !token.is_empty() {
            return Ok(token.to_string());
        }
    }
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = hex::encode(bytes);
    write_secret(path, token.as_bytes())?;
    tracing::info!(path = %path.display(), "generated bearer token");
    Ok(token)
}

/// The digests a `--authorized-tokens` file enrolls, on top of `own`
/// (the daemon's token always admits itself).
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
        let digits = line
            .strip_prefix("sha256:")
            .with_context(|| format!("line {}: expected sha256:<64 hex>, got {line:?}", n + 1))?;
        if !digits
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            bail!(
                "line {}: expected lowercase hex digits, got {digits:?}",
                n + 1
            );
        }
        let digest: [u8; 32] = hex::decode(digits)
            .with_context(|| format!("line {}: {digits:?} is not hex", n + 1))?
            .try_into()
            .map_err(|_| {
                anyhow!(
                    "line {}: expected 64 hex digits, got {}",
                    n + 1,
                    digits.len()
                )
            })?;
        digests.push(digest);
    }
    Ok(digests)
}

fn generate(cert_path: &Path, key_path: &Path) -> Result<(String, String)> {
    // The names are cosmetic: clients pin the certificate, they do not
    // resolve a hostname back to it.
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

    /// The pin is copied between machines as text, so its shape is a
    /// contract: `sha256:` plus padded standard base64 of a 32-byte
    /// digest of the certificate DER.
    #[test]
    fn fingerprint_is_the_known_hosts_form() {
        let key = rcgen::generate_simple_self_signed(vec!["muxd".to_string()]).unwrap();
        let printed = fingerprint(key.cert.der());
        let encoded = printed.strip_prefix("sha256:").expect("prefix");
        assert_eq!(encoded.len(), 44, "base64 of 32 bytes, padded: {encoded}");
        assert!(
            !encoded.contains(['-', '_']),
            "standard alphabet: {encoded}"
        );
        assert_eq!(
            encoded,
            base64::engine::general_purpose::STANDARD
                .encode(Sha256::digest(key.cert.der().as_ref()))
        );
    }

    #[test]
    fn admitted_always_holds_the_daemons_own_token() {
        let admitted = load_admitted(digest("mine"), None).unwrap();
        assert!(admitted.contains(&digest("mine")));
        assert!(!admitted.contains(&digest("theirs")));
    }
}
