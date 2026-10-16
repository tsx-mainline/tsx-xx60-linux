#!/bin/bash
# Host test: tools/release/sign-sums.sh with THROWAWAY keys that this test
# makes (never the project key). It checks the two forms of the secret (PEM
# text and base64), the warning for no secret, and a failure for a value
# that does not decode, for text that is not a key, and for a key that the
# public key does not match. It also checks that the script never prints
# the key.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
S="$HERE/sign-sums.sh"
command -v openssl >/dev/null 2>&1 || { echo "SKIPPED test-sign-sums: no openssl"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

openssl genrsa -out "$W/a.key" 2048 2>/dev/null && openssl rsa -in "$W/a.key" -pubout -out "$W/a.pub" 2>/dev/null || { echo "FAIL: openssl genrsa"; exit 1; }
openssl genrsa -out "$W/b.key" 2048 2>/dev/null && openssl rsa -in "$W/b.key" -pubout -out "$W/b.pub" 2>/dev/null || { echo "FAIL: openssl genrsa"; exit 1; }
printf 'abc  ./x\n' > "$W/SHA256SUMS"
MARK=$(sed -n 2p "$W/a.key" | cut -c1-24)   # a piece of the key that must never show
run() { OUT=$(TSX_SIGNING_KEY=$1 sh "$S" "$W/SHA256SUMS" "${@:2}" 2>&1); RC=$?; }
noleak() { case "$OUT" in *"$MARK"*) bad "$1: the output shows the key";; *) ok "$1: the output does not show the key";; esac; }
verifies() { openssl dgst -sha256 -verify "$W/a.pub" -signature "$W/SHA256SUMS.sig" "$W/SHA256SUMS" >/dev/null 2>&1; }

echo "== 1. the secret as PEM text"
run "$(cat "$W/a.key")" "$W/a.pub"
[ $RC = 0 ] && verifies && case "$OUT" in *"as PEM"*) true;; *) false;; esac && ok "PEM: rc 0, SHA256SUMS.sig verifies" || bad "PEM: rc $RC: $OUT"
noleak PEM

echo "== 2. the secret as base64 of the PEM text (with and without line breaks)"
run "$(base64 -w0 < "$W/a.key")" "$W/a.pub"
[ $RC = 0 ] && verifies && case "$OUT" in *"as base64"*) true;; *) false;; esac && ok "base64: rc 0, SHA256SUMS.sig verifies" || bad "base64: rc $RC: $OUT"
noleak base64
run "$(base64 < "$W/a.key")" "$W/a.pub"
[ $RC = 0 ] && verifies && ok "base64 in lines of 76: rc 0" || bad "base64 lines: rc $RC: $OUT"

echo "== 3. PEM text with a blank line and spaces before it (a paste in the web UI)"
run "$(printf '\n  %s' "$(cat "$W/a.key")")" "$W/a.pub"
[ $RC = 0 ] && verifies && ok "pasted PEM: rc 0" || bad "pasted PEM: rc $RC: $OUT"

echo "== 4. no secret: a warning, rc 0, no signature"
run "" "$W/a.pub"
[ $RC = 0 ] && [ ! -e "$W/SHA256SUMS.sig" ] && case "$OUT" in "::warning::no secret"*) true;; *) false;; esac && ok "empty: warning, no .sig" || bad "empty: rc $RC: $OUT"

echo "== 5. failures: rc 1 and no signature left"
touch "$W/SHA256SUMS.sig"
run 'not*base64*at*all' "$W/a.pub"
[ $RC = 1 ] && [ ! -e "$W/SHA256SUMS.sig" ] && case "$OUT" in *"::error::"*"not PEM text and not valid base64"*) true;; *) false;; esac && ok "bad base64: rc 1" || bad "bad base64: rc $RC: $OUT"
run "$(printf 'hello world\n' | base64 -w0)" "$W/a.pub"
[ $RC = 1 ] && [ ! -e "$W/SHA256SUMS.sig" ] && case "$OUT" in *"does not hold a PEM private key"*) true;; *) false;; esac && ok "base64 of text that is not a key: rc 1" || bad "not a key: rc $RC: $OUT"
run "$(printf -- '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n')" "$W/a.pub"
[ $RC = 1 ] && [ ! -e "$W/SHA256SUMS.sig" ] && case "$OUT" in *"cannot sign"*) true;; *) false;; esac && ok "a broken PEM key: rc 1" || bad "broken PEM: rc $RC: $OUT"
run "$(cat "$W/b.key")" "$W/a.pub"
[ $RC = 1 ] && [ ! -e "$W/SHA256SUMS.sig" ] && case "$OUT" in *"holds another key"*) true;; *) false;; esac && ok "another key: rc 1" || bad "another key: rc $RC: $OUT"
MARK=$(sed -n 2p "$W/b.key" | cut -c1-24); noleak "another key"
run "$(cat "$W/a.key")" "$W/missing.pub"
[ $RC = 1 ] && [ ! -e "$W/SHA256SUMS.sig" ] && ok "no public key file: rc 1" || bad "no pub: rc $RC: $OUT"

echo "== 6. two public keys: one match is enough"
run "$(cat "$W/a.key")" "$W/b.pub" "$W/a.pub"
[ $RC = 0 ] && verifies && ok "b.pub then a.pub: rc 0" || bad "two keys: rc $RC: $OUT"

echo "== 7. usage"
TSX_SIGNING_KEY= sh "$S" "$W/SHA256SUMS" >/dev/null 2>&1; [ $? = 2 ] && ok "no PUBKEY: rc 2" || bad "usage rc"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-sign-sums || echo FAIL test-sign-sums
exit $F
