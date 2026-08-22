# task 09: one fingerprint, no ASN.1 parser

PR title: `muxd: pin the certificate, compute it one way, drop the DER walker and the wrappers`

Depends on: 07. Needs README decisions 4 and 6.

## Why

The client pins SHA-256 of the certificate's SubjectPublicKeyInfo. To
reach that field `broker.rs:585-657` walks nested DER SEQUENCEs with a
hand-written `Tlv`/`tlv` parser (73 lines, two tests). The daemon side
produces the same value a different way: `tls.rs:88-98` re-parses the
private key through `rcgen::KeyPair::from_pem` on every boot to call
`public_key_der()`, hashes it, and logs it for a `muxd pin` subcommand
nothing calls (the app only ever runs `client-digest`; enrollment is
digest-paste by doctrine).

`tls::generate` writes `cert.pem` and `key.pem` together and
`load_or_generate_identity` regenerates both if either is missing
(tls.rs:77-85). Nothing in the repo rotates a certificate without its key,
so a pin over the whole certificate DER has the same trust lifetime as a
pin over its SPKI, and `Sha256::digest(cert.as_ref())` needs no parser.
Cost: the one `known_hosts` line for spark re-pins on first contact with
the documented "host key changed" message; the verifier knows the old
format by its length and can say so.

Around the pin: `verify_tls12_signature` cannot be called (the client
pins TLS 1.3 at :237 and QUIC is 1.3-only); `Tofu.provider` allocates a
second `CryptoProvider` per dial to reach a `Copy` field; `failure:
Mutex<Option<String>>` is written once and read once with poison
ceremony both times; `Link` holds a `quinn::Endpoint` that quinn already
keeps alive while a connection exists; `Stream` is built once and
destructured once; `Pin` is a two-variant enum whose only consumer is a
log line; the SNI branch at :259-263 cannot change any outcome (the
verifier ignores `server_name`, the server presents one cert). The test
module (:659-1084) rebuilds `quic::endpoint` by hand in `listener()`,
hand-rolls a tempdir, and ends seven tests with `remove_dir_all` that is
skipped exactly when a test fails. `tls.rs` hand-rolls `hex()` and a
29-line hex decoder with two `expect`s, and a PEM splitter, when
`rustls::pki_types::pem::PemObject` is already in the tree.

## Changes

### tls.rs

- `pub fn fingerprint(cert: &CertificateDer) -> String` =
  `format!("sha256:{}", STANDARD.encode(Sha256::digest(cert.as_ref())))`.
  Infallible. This is the only fingerprint function in the workspace.
- `Identity` loses `spki_pin`. `load_or_generate_identity` parses with
  `CertificateDer::from_pem_slice` and `PrivateKeyDer::from_pem_slice`;
  `pem_body`, the `rcgen::KeyPair::from_pem` round trip, and the startup
  pin log go. If decision 6 keeps an out-of-band check, `muxd
  fingerprint` prints `fingerprint(&identity.cert)` lazily inside the
  subcommand; otherwise delete `muxd pin` and `print_enrollment`'s arm.
- `parse_digests`: `strip_prefix("sha256:")`, `hex::decode`, `try_into`
  with the existing per-line context and the strictness tests unchanged
  (add `hex = "0.4"` to the workspace table). `hex()` is replaced by
  `hex::encode`.

### broker.rs

- `fingerprint`, `spki`, `Tlv`, `tlv` deleted with their two tests;
  `check_pin` calls `tls::fingerprint` and returns
  `Result<Option<String>>` (Some = newly stored); `Pin` deleted. The
  verifier's log line reads the Option.
- `Tofu` holds `algorithms: WebPkiSupportedAlgorithms` by value (copied
  from the provider `dial` already built) and `failure: OnceLock<String>`.
  `verify_tls12_signature` returns
  `Err(rustls::Error::PeerIncompatible(PeerIncompatible::Tls12NotOfferedOrEnabled))`.
- `links: Mutex<HashMap<String, quinn::Connection>>`; `Link` deleted.
  `open_stream` returns `(SendStream, RecvStream)`; `Stream` deleted.
  Always connect with `SNI_FALLBACK`; delete the branch and the
  `ServerName` import.
- `write_reply` is already gone (task 06). `from_env` uses a new
  `paths::token_dir()` that `paths::host_token` is defined through, and
  the `token_dir_matches_paths` test goes.
- Tests: `listener()` calls `crate::quic::endpoint(addr, &Identity {
  cert, key })`; add `tempfile` as a dev-dependency and replace
  `scratch()` plus every trailing `remove_dir_all` with a `TempDir`; one
  fixture function builds hosts.json, the tokens file and the listener
  for the two QUIC tests. The first-use-pins and changed-key tests stay
  and now assert the cert-DER fingerprint.

### paths / docs

`docs/architecture.html` section 2.4 and the known_hosts format line
(formerly paths.rs:9-11, now in muxd/paths.rs) say "SHA-256 of the
certificate DER". `nix/module.nix` option docs that mention the SPKI say
the same.

## Keep

- TOFU keyed by alias, 0600 `known_hosts`, append-on-first-use, refuse on
  mismatch with the same message shape (`ErrorKind::PinMismatch` from
  task 07).
- `load_or_generate_token`, `write_secret`, `load_admitted`, `digest`,
  `digest_line` and their tests, untouched.
- The pin-failure-beats-quinn-error handling in `dial` (:266-271).

## Done when

- `rg -n 'spki|Tlv|tlv\(|SEQUENCE|CONTEXT_0|PoisonError|verify_tls12' crates/muxd/src`
  returns only the TLS1.2 refusal line.
- `rg -n 'remove_dir_all' crates/muxd/src/broker.rs` returns nothing.
- `cargo test -p muxd` passes; connecting to spark re-pins once and
  works thereafter; editing one byte of the pin line yields the
  pin-mismatch status in the hosts window.
- `broker.rs` ≤ 700 lines including tests; `tls.rs` ≤ 230.
