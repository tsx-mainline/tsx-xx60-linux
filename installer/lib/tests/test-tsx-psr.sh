#!/bin/bash
# Host test of installer/lib/tsx-psr.sh: the Bluetooth PSR file that the
# rescue takes from the panel itself (tsx-rescue-install psr). The test uses
# made-up PSR files only, never the vendor file. The pinned-sha256 path uses
# TSX_PSR_PINNED with the hash of a made-up file. A directory stands in for
# the root device. The functions run under busybox sh, as in the rescue.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # installer/lib
LIB=$HERE/tsx-psr.sh
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-psr: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export TSX_RUN=$W/run
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkpsr() {  # mkpsr FILE SEED: a made-up PSR text file
	{ echo "// made-up PSR $2"; echo "&003c = 04$2"; echo "//&0001 = 0000 0000 0000 0000"
	  echo "&212c = 0000 c4$2 5714 0018"; echo ""; echo "&01f9 = 0001"; } > "$1"
}
run() {  # run SNIPPET: source the library under busybox sh and run SNIPPET
	busybox sh -c ". '$LIB'; $1"
}
busybox sh -n "$LIB" && ok "busybox sh -n" || bad "busybox sh -n"

echo "== validation =="
mkpsr "$W/good.psr" 11
PIN=$(sha256sum < "$W/good.psr" | cut -d' ' -f1)
out=$(TSX_PSR_PINNED=$PIN run "tsx_psr_validate '$W/good.psr'"); rc=$?
[ $rc = 0 ] && case "$out" in *pinned*) true;; *) false;; esac && ok "the pinned sha256: rc 0" || bad "pinned: rc $rc, $out"
out=$(run "tsx_psr_validate '$W/good.psr'"); rc=$?
[ $rc = 1 ] && case "$out" in *"NOT the pinned one"*"3 keys"*) true;; *) false;; esac && ok "an unknown but sane PSR: rc 1, with the hash and key count" || bad "unpinned: rc $rc, $out"
printf '&003c = 04zz\n' > "$W/badkey.psr"
run "tsx_psr_validate '$W/badkey.psr'" >/dev/null; [ $? = 2 ] && ok "a broken key line: rejected" || bad "broken key line accepted"
printf '// only comments\n' > "$W/nokeys.psr"
run "tsx_psr_validate '$W/nokeys.psr'" >/dev/null; [ $? = 2 ] && ok "no key: rejected" || bad "no key accepted"
printf '&003c = 0426\n\001\002\n' > "$W/binary.psr"
run "tsx_psr_validate '$W/binary.psr'" >/dev/null; [ $? = 2 ] && ok "binary bytes: rejected" || bad "binary accepted"
head -c 70000 /dev/zero | tr '\0' 'a' > "$W/huge.psr"
run "tsx_psr_validate '$W/huge.psr'" >/dev/null; [ $? = 2 ] && ok "over 64 KiB: rejected" || bad "huge accepted"
run "tsx_psr_validate '$W/missing.psr'" >/dev/null; [ $? = 2 ] && ok "a missing file: rejected" || bad "missing accepted"

echo "== sources =="
MAIN=$W/mainline-root; AND=$W/android-system; EMPTY=$W/empty-root
mkdir -p "$MAIN/usr/local/share/tsx/csr8811" "$AND/bin" "$EMPTY/usr"
mkpsr "$MAIN/usr/local/share/tsx/csr8811/PSR-CSR8811.psr" 22
printf 'source=android-system\nfirmware=Android TEST-1\nsha256=x unpinned\n' > "$MAIN/usr/local/share/tsx/csr8811/SOURCE"
printf 'ro.build.display.id=TEST-BUILD-2\n' > "$AND/build.prop"
mkpsr "$AND/bin/PSR-CSR8811.psr" 33

out=$(run "tsx_psr_collect '$W/out1' '$MAIN'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "PSR-RESULT source=root ok=1" ] && cmp -s "$W/out1/PSR-CSR8811.psr" "$MAIN/usr/local/share/tsx/csr8811/PSR-CSR8811.psr" \
	&& ok "a mainline root: source root, the file copied" || bad "mainline root: $out"
grep -qx 'firmware=Android TEST-1' "$W/out1/SOURCE" && grep -q '^sha256=[0-9a-f]\{64\} unpinned$' "$W/out1/SOURCE" \
	&& ok "SOURCE keeps the firmware line of the old root and the sha256" || bad "SOURCE: $(cat "$W/out1/SOURCE")"
out=$(run "tsx_psr_collect '$W/out2' '$AND'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "PSR-RESULT source=android-system ok=1" ] && grep -qx 'firmware=Android TEST-BUILD-2' "$W/out2/SOURCE" \
	&& ok "stock Android: bin/PSR-CSR8811.psr of the system partition, with the build id" || bad "android: $out"
out=$(run "tsx_psr_collect '$W/out3' '$EMPTY' '$W/out2'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "PSR-RESULT source=earlier ok=1" ] && cmp -s "$W/out3/PSR-CSR8811.psr" "$AND/bin/PSR-CSR8811.psr" \
	&& ok "a re-run after the root was overwritten: the earlier file is kept" || bad "earlier: $out"
out=$(run "tsx_psr_collect '$W/out2' '$EMPTY' '$W/out2'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "PSR-RESULT source=earlier ok=1" ] && [ -f "$W/out2/PSR-CSR8811.psr" ] \
	&& ok "OUTDIR = EARLIERDIR (as the rescue calls it): the file survives" || bad "same dir: $out"
printf '&003c = 04zz\n' > "$AND/bin/PSR-CSR8811.psr"
out=$(run "tsx_psr_collect '$W/out4' '$AND'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "PSR-RESULT source=none ok=0" ] && [ ! -e "$W/out4" ] && printf '%s\n' "$out" | grep -q REJECTED \
	&& ok "only a broken file: rejected, no OUTDIR, source=none" || bad "broken only: $out"
out=$(run "tsx_psr_collect '$W/out5' '$W/does-not-exist'"); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | tail -n 1)" = "PSR-RESULT source=none ok=0" ] \
	&& ok "a root that does not mount: source=none, exit 0 (never fatal)" || bad "no root: rc $rc, $out"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-tsx-psr || echo FAIL test-tsx-psr
exit $F
