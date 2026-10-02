#!/bin/bash
# Host test of installer/lib/tsx-ledstock.sh: the stock LED bar firmware image
# (statussign_*.upg) that the rescue takes from the panel itself
# (tsx-rescue-install ledstock) and copies to /data/tsx/vendor/. The test uses
# made-up S-record files only, never the vendor file. A directory stands in
# for the root device and for tsxdata. The functions run under busybox sh, as
# in the rescue.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # installer/lib
LIB=$HERE/tsx-ledstock.sh
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-ledstock: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export TSX_RUN=$W/run
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkupg() {  # mkupg FILE SEED: a made-up S-record file with the tag record first
	{ printf 'S30DBAD0ADD0444D00E5%s00\r\n' "$2"
	  for i in $(seq 1 60); do printf 'S3150802000%02d0102030405060708090A0B0C0D%s\r\n' "$i" "$2"; done; } > "$1"
}
run() {  # run SNIPPET: source the library under busybox sh and run SNIPPET
	busybox sh -c ". '$LIB'; $1"
}
busybox sh -n "$LIB" && ok "busybox sh -n" || bad "busybox sh -n"

echo "== validation =="
mkupg "$W/good.upg" 11
out=$(run "tsx_ledstock_validate '$W/good.upg'"); rc=$?
[ $rc = 0 ] && case "$out" in "sha256 "*" bytes") true;; *) false;; esac && ok "a made-up image: rc 0, with hash and size" || bad "good: rc $rc, $out"
run "tsx_ledstock_validate '$W/missing.upg'" >/dev/null; [ $? = 2 ] && ok "a missing file: rejected" || bad "missing accepted"
head -c 70 "$W/good.upg" > "$W/small.upg"
run "tsx_ledstock_validate '$W/small.upg'" >/dev/null; [ $? = 2 ] && ok "under 1 KiB: rejected" || bad "small accepted"
head -c 1100000 /dev/zero | tr '\0' 'a' > "$W/huge.upg"
run "tsx_ledstock_validate '$W/huge.upg'" >/dev/null; [ $? = 2 ] && ok "over 1 MiB: rejected" || bad "huge accepted"
{ cat "$W/good.upg"; printf '\001\002\n'; } > "$W/binary.upg"
run "tsx_ledstock_validate '$W/binary.upg'" >/dev/null; [ $? = 2 ] && ok "binary bytes: rejected" || bad "binary accepted"
{ cat "$W/good.upg"; echo "not a record"; } > "$W/text.upg"
run "tsx_ledstock_validate '$W/text.upg'" >/dev/null; [ $? = 2 ] && ok "a line that is no S-record: rejected" || bad "text line accepted"
{ printf 'S30D00DEADBE000000280000%s\r\n' 00; tail -n +2 "$W/good.upg"; } > "$W/notag.upg"
run "tsx_ledstock_validate '$W/notag.upg'" >/dev/null; [ $? = 2 ] && ok "no application tag record (a bootloader image): rejected" || bad "notag accepted"

echo "== sources =="
AND=$W/android-system; AND2=$W/android-nested; EMPTY=$W/empty-root
mkdir -p "$AND/vendor/firmware" "$AND2/system/vendor/firmware" "$EMPTY/usr"
printf 'ro.build.display.id=TEST-BUILD-2\n' > "$AND/build.prop"
cp "$AND/build.prop" "$AND2/build.prop"
mkupg "$AND/vendor/firmware/statussign_1.0001.00001.upg" 22
mkupg "$AND/vendor/firmware/statussign_1.0001.00002.upg" 33
mkupg "$AND2/system/vendor/firmware/statussign_1.0001.00003.upg" 44

out=$(run "tsx_ledstock_collect '$W/out1' '$AND'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=android-system ok=1" ] \
	&& cmp -s "$W/out1/statussign_1.0001.00002.upg" "$AND/vendor/firmware/statussign_1.0001.00002.upg" && [ ! -e "$W/out1/statussign_1.0001.00001.upg" ] \
	&& ok "stock Android: vendor/firmware, the last name wins, the file copied" || bad "android: $out"
grep -qx 'firmware=Android TEST-BUILD-2' "$W/out1/SOURCE" && grep -qx 'file=statussign_1.0001.00002.upg' "$W/out1/SOURCE" \
	&& grep -q '^sha256=[0-9a-f]\{64\}$' "$W/out1/SOURCE" && ok "SOURCE keeps the build id, the name and the sha256" || bad "SOURCE: $(cat "$W/out1/SOURCE")"
out=$(run "tsx_ledstock_collect '$W/out2' '$AND2'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=android-system ok=1" ] && [ -f "$W/out2/statussign_1.0001.00003.upg" ] \
	&& ok "stock Android: system/vendor/firmware is searched too" || bad "nested: $out"
out=$(run "tsx_ledstock_collect '$W/out3' '$EMPTY' '$W/out1'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=earlier ok=1" ] && [ -f "$W/out3/statussign_1.0001.00002.upg" ] \
	&& ok "a re-run after the root was overwritten: the earlier file is kept" || bad "earlier: $out"
out=$(run "tsx_ledstock_collect '$W/out1' '$EMPTY' '$W/out1'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=earlier ok=1" ] && [ -f "$W/out1/statussign_1.0001.00002.upg" ] \
	&& ok "OUTDIR = EARLIERDIR (as the rescue calls it): the file survives" || bad "same dir: $out"
out=$(run "tsx_ledstock_collect '$W/out4' '$EMPTY'"); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=none ok=0" ] && [ ! -e "$W/out4" ] \
	&& [ "$(printf '%s\n' "$out" | grep -c '^ledstock: no stock LED bar firmware image')" = 1 ] \
	&& ok "no image: one clear line, source=none, exit 0 (not an error)" || bad "none: rc $rc, $out"
mkdir -p "$W/android-noprop/vendor/firmware"; mkupg "$W/android-noprop/vendor/firmware/statussign_1.0001.00009.upg" 55
out=$(run "tsx_ledstock_collect '$W/out5' '$W/android-noprop'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=none ok=0" ] && ok "a root with no build.prop is not stock Android: ignored" || bad "noprop: $out"
mkdir -p "$W/android-bad/vendor/firmware"; cp "$AND/build.prop" "$W/android-bad/"; cp "$W/text.upg" "$W/android-bad/vendor/firmware/statussign_1.0001.00001.upg"
out=$(run "tsx_ledstock_collect '$W/out6' '$W/android-bad'")
[ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=none ok=0" ] && [ ! -e "$W/out6" ] && printf '%s\n' "$out" | grep -q REJECTED \
	&& ok "only a broken file: rejected, no OUTDIR, source=none" || bad "broken only: $out"
out=$(run "tsx_ledstock_collect '$W/out7' '$W/does-not-exist'"); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | tail -n 1)" = "LEDSTOCK-RESULT source=none ok=0" ] \
	&& ok "a root that does not mount: source=none, exit 0 (never fatal)" || bad "no root: rc $rc, $out"

echo "== deploy to tsxdata =="
D=$W/data1; mkdir -p "$D"
out=$(run "tsx_ledstock_deploy '$W/out1' '$D'")
V=$D/tsx/vendor
cmp -s "$V/statussign_1.0001.00002.upg" "$W/out1/statussign_1.0001.00002.upg" && [ "$(stat -c %a "$V/statussign_1.0001.00002.upg")" = 644 ] \
	&& [ -f "$V/statussign_1.0001.00002.upg.source" ] && [ ! -e "$V/statussign_1.0001.00002.upg.new" ] \
	&& printf '%s\n' "$out" | grep -q 'copied to /data/tsx/vendor/' \
	&& ok "the image is copied to tsx/vendor/ with a progress line and a source record" || bad "deploy: $out"
D=$W/data2; mkdir -p "$D/tsx/vendor"; cp "$W/out1/statussign_1.0001.00002.upg" "$D/tsx/vendor/"
out=$(run "tsx_ledstock_deploy '$W/no-such-dir' '$D'"); rc=$?
[ $rc = 0 ] && [ -f "$D/tsx/vendor/statussign_1.0001.00002.upg" ] && printf '%s\n' "$out" | grep -q 'kept the copy on tsxdata' \
	&& ok "a reinstall that keeps /data: the old copy stays, and the output says so" || bad "kept: rc $rc, $out"
D=$W/data3; mkdir -p "$D"
out=$(run "tsx_ledstock_deploy '$W/no-such-dir' '$D'"); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && printf '%s\n' "$out" | grep -q 'no stock LED bar firmware image to keep' && [ ! -e "$D/tsx/vendor" ] \
	&& ok "no image anywhere: one clear line, nothing created, exit 0" || bad "none: rc $rc, $out"
mkupg "$W/out8.upg" 66; mkdir -p "$W/out8"; cp "$W/out8.upg" "$W/out8/statussign_1.0001.00002.upg"
D=$W/data2
out=$(run "tsx_ledstock_deploy '$W/out8' '$D'")
cmp -s "$D/tsx/vendor/statussign_1.0001.00002.upg" "$W/out8/statussign_1.0001.00002.upg" \
	&& ok "a new image replaces the old one of the same name" || bad "replace failed"
D=$W/data4; mkdir -p "$D"; touch "$D/tsx"; chmod 500 "$D"
out=$(run "tsx_ledstock_deploy '$W/out8' '$D'" 2>/dev/null); rc=$?; chmod 700 "$D"
if [ "$(id -u)" = 0 ]; then ok "copy failure test skipped (running as root)"
else [ $rc = 0 ] && printf '%s\n' "$out" | grep -q 'WARNING: ledstock' && ok "a failed copy: a warning, exit 0 (never fatal)" || bad "copy failure: rc $rc, $out"; fi

echo "== no vendor file in the repo =="
if git -C "$HERE" ls-files 2>/dev/null | grep -qi 'statussign.*\.upg'; then bad "a statussign image is tracked"; else ok "no statussign image is tracked"; fi

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-tsx-ledstock || echo FAIL test-tsx-ledstock
exit $F
