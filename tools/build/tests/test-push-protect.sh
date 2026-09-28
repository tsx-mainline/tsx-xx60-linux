#!/bin/bash
# Host test: remote-build.sh's rootfs push (rsync --delete) keeps the build
# inputs that exist only on the build host (tools/build/README.md "What gets
# sent"). Runs the same rsync options with the same PROTECT rules, taken from
# remote-build.sh itself, from one local dir to another: no ssh, no host.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v rsync >/dev/null 2>&1 || { echo "SKIPPED test-push-protect: no rsync"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
eval "$(grep '^PROTECT=' "$HERE/remote-build.sh")"
[ "${#PROTECT[@]}" -gt 0 ] && ok "PROTECT rules found in remote-build.sh" || { bad "no PROTECT= line in remote-build.sh"; exit 1; }
push() { rsync -a --no-specials --no-devices --delete "${PROTECT[@]}" "$1/" "$2/"; }

# local sources (no prebuilt inputs) and the host's copy (with them + a stale file)
mkdir -p "$W/l/src/sendspin" "$W/l/voice/tflite"
echo build > "$W/l/src/sendspin/build.sh"; echo sums > "$W/l/voice/tflite/SHA256SUMS"
mkdir -p "$W/h/src/sendspin/out" "$W/h/voice/tflite"
echo bin > "$W/h/src/sendspin/out/sendspin-cli"; echo so > "$W/h/voice/tflite/libtensorflowlite_c.so"
echo old > "$W/h/src/stale.c"; echo old > "$W/h/voice/tflite/stale.txt"
push "$W/l/src" "$W/h/src"; push "$W/l/voice" "$W/h/voice"
[ -f "$W/h/src/sendspin/out/sendspin-cli" ] && ok "host sendspin-cli kept" || bad "host sendspin-cli deleted"
[ -f "$W/h/voice/tflite/libtensorflowlite_c.so" ] && ok "host libtensorflowlite_c.so kept" || bad "host libtensorflowlite_c.so deleted"
[ ! -e "$W/h/src/stale.c" ] && [ ! -e "$W/h/voice/tflite/stale.txt" ] && ok "other stale host files still deleted" || bad "--delete no longer removes stale files"
[ -f "$W/h/src/sendspin/build.sh" ] && ok "sources pushed" || bad "sources not pushed"

# a local copy of a protected file still replaces the host's
mkdir -p "$W/l/src/sendspin/out"; echo newer > "$W/l/src/sendspin/out/sendspin-cli"
push "$W/l/src" "$W/h/src"
[ "$(cat "$W/h/src/sendspin/out/sendspin-cli")" = newer ] && ok "a local sendspin-cli is still sent" || bad "local sendspin-cli not sent"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-push-protect || echo FAIL test-push-protect
exit $F
