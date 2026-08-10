#!/usr/bin/env bash
# Create a stable self-signed code-signing identity for local dev builds.
#
# Why: an ad-hoc signature (codesign -s -) gets a fresh identity every build,
# so macOS TCC (Full Disk / Documents access, etc.) never remembers a grant -
# every rebuild is a stranger. A self-signed cert in a dedicated keychain gives
# Mux.app one stable designated requirement, so you approve a TCC prompt once
# and it sticks across rebuilds.
#
# The identity lives in its own keychain (mux-dev.keychain-db) with a known
# password, so everything here is non-interactive: no login-keychain password,
# no GUI "allow access" dialog. Idempotent - re-running is a no-op once set up.
#
# This trusts a LOCAL dev cert for CODE SIGNING only; it is not a CA and grants
# no network/TLS trust. Delete with: security delete-keychain "$KEYCHAIN".
set -euo pipefail

IDENTITY="mux-dev"
KEYCHAIN="$HOME/Library/Keychains/mux-dev.keychain-db"
KC_PASS="mux-dev"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "signing identity '$IDENTITY' already present in $KEYCHAIN"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Self-signed cert with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# -legacy: OpenSSL 3 defaults to a PKCS12 MAC/cipher Apple's Security
# framework cannot verify ("MAC verification failed"); the legacy algs import.
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/id.p12" -passout pass:"$KC_PASS"

# Dedicated keychain with a known password: fully scriptable.
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$work/id.p12" -k "$KEYCHAIN" -P "$KC_PASS" -T /usr/bin/codesign
# Let codesign use the key without a GUI prompt (uses the keychain's own pass).
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
# Add to the user search list so `codesign -s mux-dev` resolves it.
existing="$(security list-keychains -d user | sed 's/[[:space:]]*"//;s/"//')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $existing

echo "created signing identity '$IDENTITY' in $KEYCHAIN"
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$IDENTITY"
