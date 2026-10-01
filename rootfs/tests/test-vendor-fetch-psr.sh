#!/bin/bash
# Host test of ../vendor-fetch.sh --psr: the Bluetooth PSR file from the .puf.
# The test makes its own package with the same layers as the Crestron .puf:
# an outer zip, a tsx-*.zip in it, an image_*.zip in that, and a raw ext4
# system.img with a made-up /bin/PSR-CSR8811.psr. It never uses the real
# file or the real package, and it needs no network: the made-up package is
# already in the download cache, with its sha256 pinned through TFA_PUF_SHA256.
# Needs: mke2fs and debugfs (e2fsprogs), unzip, python3 (to make the zips).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # .../rootfs
FETCH=$HERE/vendor-fetch.sh
PATH=$PATH:/sbin:/usr/sbin
for t in mke2fs debugfs unzip python3; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED test-vendor-fetch-psr: no $t on this host"; exit 0; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkpsr() {  # mkpsr FILE SEED: a made-up PSR text file
	{ echo "// made-up PSR $2"; echo "&003c = 04$2"; echo "&212c = 0000 c4$2 5714 0018"; echo "&01f9 = 0001"; } > "$1"
}
mkzip() {  # mkzip OUT.zip DIR: a zip of the files in DIR, with no directory part
	python3 - "$1" "$2" <<'EOF'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for n in sorted(os.listdir(sys.argv[2])):
        z.write(os.path.join(sys.argv[2], n), n)
EOF
}
mkpuf() {  # mkpuf OUT.puf SYSDIR: the package with system.img made from SYSDIR
	local d=$W/mk; rm -rf "$d"; mkdir -p "$d/img" "$d/tsx" "$d/puf"
	printf 'ANDROID!' > "$d/img/boot.img"
	truncate -s 4M "$d/img/system.img"
	mke2fs -q -F -t ext4 -d "$2" "$d/img/system.img" >/dev/null 2>&1 || { echo "mke2fs -d failed"; return 1; }
	mkzip "$d/tsx/image_9.999.0001_r1.zip" "$d/img"
	mkzip "$d/puf/tsx-xx60_9.999.0001.zip" "$d/tsx"
	mkzip "$1" "$d/puf"
	rm -rf "$d"
}
fetch() {  # fetch PUF [ARGS...]: vendor-fetch.sh with the made-up package in its cache
	local puf=$1; shift
	TMPDIR=$W/tmp TFA_PUF_URL=http://127.0.0.1:9/test.puf TFA_PUF_CACHE=$W/cache-$(basename "$puf" .puf) \
		TFA_PUF_SHA256=$(sha256sum < "$puf" | cut -d' ' -f1) PSR_VENDOR_LOCAL=$W/out \
		sh "$FETCH" "$@"
}
cache() {  # cache PUF: put PUF into its own download cache as test.puf
	mkdir -p "$W/cache-$(basename "$1" .puf)"; cp "$1" "$W/cache-$(basename "$1" .puf)/test.puf"
}
mkdir -p "$W/tmp" "$W/sys/bin" "$W/sys-nofile/bin"
sh -n "$FETCH" && ok "sh -n vendor-fetch.sh" || bad "sh -n vendor-fetch.sh"

echo "== a package with the file"
mkpsr "$W/sys/bin/PSR-CSR8811.psr" 42
echo "ro.build.display.id=TEST" > "$W/sys/build.prop"
PIN=$(sha256sum < "$W/sys/bin/PSR-CSR8811.psr" | cut -d' ' -f1)
mkpuf "$W/good.puf" "$W/sys" || bad "could not make the package"
cache "$W/good.puf"
out=$(PSR_SHA256=$PIN fetch "$W/good.puf" --psr 2>&1); rc=$?
[ $rc = 0 ] && cmp -s "$W/out/PSR-CSR8811.psr" "$W/sys/bin/PSR-CSR8811.psr" \
	&& ok "--psr: the file of system.img, byte for byte" || bad "--psr: rc $rc, $out"
echo "$out" | grep -q "using cached" && ok "no download: the cached package with the pinned sha256" || bad "cache not used: $out"
[ -z "$(ls -A "$W/tmp")" ] && ok "the temporary directory is empty again (no system.img left)" || bad "left in TMPDIR: $(ls -A "$W/tmp")"
[ ! -e "$W/out/stereo.cnt" ] && [ -z "$(ls -d "$W"/out/settings_* 2>/dev/null)" ] && ok "--psr writes no DSP files" || bad "--psr wrote DSP files"
out=$(PSR_SHA256=$PIN fetch "$W/good.puf" --psr --check 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "ok      PSR-CSR8811.psr" && ok "--psr --check: exit 0" || bad "--check: rc $rc, $out"
out=$(PSR_SHA256=$PIN fetch "$W/good.puf" --psr 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "nothing to do" && ok "a second run does nothing" || bad "re-run: rc $rc, $out"
out=$(PSR_SHA256=0000 fetch "$W/good.puf" --check --psr 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "MISMATCH PSR-CSR8811.psr" && ok "--check with another pin: MISMATCH, exit 1" || bad "--check mismatch: rc $rc, $out"

echo "== the pin does not match the file in the package"
rm -rf "$W/out"
out=$(PSR_SHA256=1111 fetch "$W/good.puf" --psr --force 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "sha256 $PIN != pinned 1111" && [ ! -e "$W/out/PSR-CSR8811.psr" ] \
	&& ok "wrong sha256: an error, and no file" || bad "wrong pin: rc $rc, $out"
[ -z "$(ls -A "$W/tmp")" ] && ok "the temporary directory is empty after the error" || bad "left in TMPDIR after an error: $(ls -A "$W/tmp")"

echo "== a package without the file"
echo "ro.build.display.id=TEST" > "$W/sys-nofile/build.prop"
mkpuf "$W/nofile.puf" "$W/sys-nofile" || bad "could not make the package"
cache "$W/nofile.puf"
out=$(PSR_SHA256=$PIN fetch "$W/nofile.puf" --psr 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "system.img has no /bin/PSR-CSR8811.psr" && ok "no file in system.img: an error" || bad "no file: rc $rc, $out"

echo "== bad arguments"
fetch "$W/good.puf" --psr --cloud >"$W/o.txt" 2>&1 && bad "--cloud accepted" || { grep -q "usage:.*--psr" "$W/o.txt" && ok "an unknown option: usage with --psr" || bad "no usage: $(cat "$W/o.txt")"; }

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-vendor-fetch-psr || echo FAIL test-vendor-fetch-psr
exit $F
