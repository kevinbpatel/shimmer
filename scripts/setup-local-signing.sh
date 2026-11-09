#!/bin/bash
# One-time setup of a stable, self-signed code-signing identity for local builds.
#
# WHY: without a Developer ID, builds were signed ad hoc, and an ad hoc
# signature's identity is its cdhash - different on every build. macOS ties
# privacy grants (Input Monitoring, Local Network) and background-item records
# to that identity, so every reinstall silently dropped them and the app had to
# be re-approved. A self-signed certificate is the same on every build, so the
# designated requirement becomes `identifier "com.kevinbpatel.shimmer" and
# certificate leaf = H"..."` and grants survive reinstalls.
#
# What it creates (nothing else is touched):
#   ~/Library/Keychains/shimmer-local-signing.keychain-db   key + certificate
#   ~/.config/shimmer/local-signing.pass                     that keychain's password (0600)
# The keychain is added to the user search list so codesign can find it; it is
# separate from the login keychain, and its key's ACL allows /usr/bin/codesign,
# so signing never prompts (including over SSH).
#
# The certificate is not trusted by anyone and doesn't need to be: it's only an
# identity for this Mac's own builds. It is not a substitute for a Developer ID
# (Gatekeeper still rejects a downloaded copy).
#
# Usage: scripts/setup-local-signing.sh      (or `make local-signing-setup`)
set -euo pipefail

NAME="Shimmer Local Signing"
KEYCHAIN="$HOME/Library/Keychains/shimmer-local-signing.keychain-db"
PASS_FILE="$HOME/.config/shimmer/local-signing.pass"

if [ -f "$KEYCHAIN" ] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
	echo "✓ $NAME already set up in $KEYCHAIN"
	exit 0
fi

OPENSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL=/usr/bin/openssl

mkdir -p "$(dirname "$PASS_FILE")"
umask 077
[ -s "$PASS_FILE" ] || "$OPENSSL" rand -hex 24 > "$PASS_FILE"
chmod 600 "$PASS_FILE"
PASS="$(cat "$PASS_FILE")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# macOS's importer reads the legacy PKCS#12 algorithms, not OpenSSL 3's defaults.
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
	-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
	-passout "pass:$PASS" -out "$WORK/identity.p12"

[ -f "$KEYCHAIN" ] || security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

# Add to the user search list (keeping everything already on it) so codesign
# resolves the identity by name.
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g')
if ! printf '%s\n' "$EXISTING" | grep -qxF "$KEYCHAIN"; then
	# shellcheck disable=SC2086
	security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

echo "✓ created $NAME in $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN" | sed -n '1,3p'
