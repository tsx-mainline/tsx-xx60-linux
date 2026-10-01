#!/bin/bash
# Host test of ../vendor-fetch.sh. The script fetches (or reuses) the public
# Crestron tsw-xx60 firmware .puf and extracts the TFA9890 DSP containers
# from it. The test checks the three stereo.cnt files against the sha256
# values pinned in the script. The purpose of vendor-fetch.sh is that the public
# package and the proprietary Android vendor tree carry byte-identical
# containers.
#
# Usage: tests/test-vendor-fetch.sh
#   PUF=/path/to/tsw-xx60_3.002.1061.001.puf   reuse an already-downloaded
#                                                copy instead of downloading
#                                                357 MB again
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # .../rootfs
W=${TMPDIR:-/tmp}/test-vendor-fetch.$$
rm -rf "$W"; mkdir -p "$W/cache" "$W/vendor-local"
trap 'rm -rf "$W"' EXIT

URL_NAME=tsw-xx60_3.002.1061.001.puf
if [ -n "${PUF:-}" ]; then
	[ -r "$PUF" ] || { echo "test-vendor-fetch: FAIL: PUF=$PUF not readable"; exit 1; }
	echo "test-vendor-fetch: reusing $PUF (no download)"
	cp "$PUF" "$W/cache/$URL_NAME"
else
	echo "test-vendor-fetch: no PUF given, vendor-fetch.sh will download 357 MB"
fi

echo "== vendor-fetch.sh (fetch) =="
TFA_PUF_CACHE="$W/cache" TFA_VENDOR_LOCAL="$W/vendor-local" "$HERE/vendor-fetch.sh"

fail=0
declare -A WANT=(
	[settings_yushan]=b479300ed44a7663afe04fd271b8e059ea4d6e1778939a18e87d004613288de8
	[settings_yushan_2nd]=fe5157aa0213b640a3e40fa4bc79ce88849b2589361079fefcfcda14b0ad0c14
	[settings_yushan_3rd]=6d5952abe66ca83d0c08cbc77ae8e56eb95eef18e5ad6a33ed6f19f981071067
)
echo "== checking extracted stereo.cnt sha256s =="
for v in "${!WANT[@]}"; do
	f="$W/vendor-local/$v/stereo.cnt"
	if [ ! -r "$f" ]; then
		echo "test-vendor-fetch: FAIL: $v/stereo.cnt missing after fetch"
		fail=1
		continue
	fi
	got=$(sha256sum < "$f" | cut -d' ' -f1)
	if [ "$got" = "${WANT[$v]}" ]; then
		echo "test-vendor-fetch: PASS: $v/stereo.cnt = ${WANT[$v]}"
	else
		echo "test-vendor-fetch: FAIL: $v/stereo.cnt = $got, want ${WANT[$v]}"
		fail=1
	fi
done

echo "== vendor-fetch.sh --check (should exit 0, no network) =="
if TFA_VENDOR_LOCAL="$W/vendor-local" "$HERE/vendor-fetch.sh" --check; then
	echo "test-vendor-fetch: PASS: --check exit 0"
else
	echo "test-vendor-fetch: FAIL: --check exit nonzero on freshly-verified files"
	fail=1
fi

echo "== idempotent re-run (no --force: should skip, not re-download) =="
out=$(TFA_PUF_CACHE="$W/cache" TFA_VENDOR_LOCAL="$W/vendor-local" "$HERE/vendor-fetch.sh" 2>&1)
if echo "$out" | grep -q "nothing to do"; then
	echo "test-vendor-fetch: PASS: re-run short-circuited"
else
	echo "test-vendor-fetch: FAIL: re-run did not short-circuit:"
	echo "$out"
	fail=1
fi

if [ "$fail" = 0 ]; then
	echo "test-vendor-fetch: ALL PASS"
	exit 0
else
	echo "test-vendor-fetch: FAILED"
	exit 1
fi
