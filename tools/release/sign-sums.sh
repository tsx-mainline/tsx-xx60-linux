#!/bin/sh
# Sign the SHA256SUMS of a release (release.yml).
#
#   tools/release/sign-sums.sh SUMS PUBKEY...
#
# The private key comes from the environment variable TSX_SIGNING_KEY (the
# secret TSX_APORTS_PRIVKEY). The value can be the PEM text of the key or
# the base64 of that PEM text. A value that starts with "-----BEGIN" is used
# as it is. Any other value is decoded with base64.
#
# The script writes SUMS.sig (RSA, SHA-256, PKCS #1 v1.5) and checks it with
# each PUBKEY. One good check is necessary. The public half of the project key
# is rootfs/overlay/etc/apk/keys/tsx-mainline-*.rsa.pub.
#
# Exit status:
#   0  SUMS.sig is written and a PUBKEY verifies it. Or TSX_SIGNING_KEY is
#      empty: then the script writes a warning and no SUMS.sig.
#   1  the key does not decode, openssl cannot sign with it, or no PUBKEY
#      verifies the signature (a wrong key). No SUMS.sig is left.
#   2  usage error.
# The script never prints the key.
set -eu
[ $# -ge 2 ] || { echo "usage: $0 SUMS PUBKEY..." >&2; exit 2; }
SUMS=$1; shift
[ -f "$SUMS" ] || { echo "sign-sums: no file $SUMS" >&2; exit 2; }
SIG=$SUMS.sig
rm -f "$SIG"
if [ -z "${TSX_SIGNING_KEY:-}" ]; then
	echo "::warning::no secret TSX_APORTS_PRIVKEY: the release gets no SHA256SUMS.sig, and the download mode (--fetch) refuses it"
	exit 0
fi
umask 077
K=$(mktemp)
trap 'rm -f "$K"' EXIT
fail() { echo "::error::$*"; rm -f "$SIG"; exit 1; }
# Leading blank lines or spaces of a pasted value do not count.
case "$(printf '%s' "$TSX_SIGNING_KEY" | tr -d ' \t\r\n' | cut -c1-10)" in
-----BEGIN)
	# No blank lines, no spaces at the start of a line and no CR: openssl
	# reads only a clean PEM block.
	printf '%s\n' "$TSX_SIGNING_KEY" | sed 's/^[[:space:]]*//; s/\r$//' | grep -v '^$' > "$K"
	FORM=PEM;;
*)
	printf '%s' "$TSX_SIGNING_KEY" | base64 -d > "$K" 2>/dev/null || fail "the secret TSX_APORTS_PRIVKEY is not PEM text and not valid base64"
	FORM=base64;;
esac
grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$K" || fail "the secret TSX_APORTS_PRIVKEY ($FORM) does not hold a PEM private key"
openssl dgst -sha256 -sign "$K" -out "$SIG" "$SUMS" 2>/dev/null || fail "openssl cannot sign with the secret TSX_APORTS_PRIVKEY ($FORM): not a valid RSA private key"
for pub in "$@"; do
	[ -f "$pub" ] || continue
	if openssl dgst -sha256 -verify "$pub" -signature "$SIG" "$SUMS" >/dev/null 2>&1; then
		echo "sign-sums: $(basename "$SIG") written (key from the secret as $FORM), verified with $(basename "$pub")"
		exit 0
	fi
done
fail "the signature does not verify with a public key of the project ($*): the secret TSX_APORTS_PRIVKEY holds another key"
