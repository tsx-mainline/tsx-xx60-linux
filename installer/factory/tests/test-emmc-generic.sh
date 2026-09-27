#!/usr/bin/env bash
# Host test for the NO-BACKUP path: mkbundle.sh without --emmc-raw/--boot0
# (boot0_sha256=any, recovery/misc/data/gaps zero, cache = empty ext4, logo head:)
# + tsx-emmc-restore on a SYNTHETIC eMMC image in the post-eMMC-migration state
# (mainline boot image in "boot", ext4 LABEL=tsxroot-emmc from 796 MiB to the end,
# random bytes in bootloader/secure-store/reserved areas that must survive).
# Workstation only: no panel, no container, no backup of any unit.
#
#   tests/test-emmc-generic.sh [BUNDLE_DIR]   (default: build one in $T from dl/*.puf
#                                              and out/env-live-20260926-2153.bin)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); FACTORY_DIR=$(cd "$HERE/.." && pwd); WORK=$(cd "$FACTORY_DIR/.." && pwd)
T=${TMPDIR:-/var/tmp}/tsx-factory-generic; mkdir -p "$T"
RES=$HERE/results/test-emmc-generic.txt; mkdir -p "$HERE/results"
M=1048576; N=0; F=0
ok()   { N=$((N+1)); echo "  ok: $*"; }
fail() { N=$((N+1)); F=$((F+1)); echo "  FAIL: $*"; }
sha_range() { dd if="$1" bs=$M skip="$2" count="$3" status=none | sha256sum | cut -d' ' -f1; }
exec > >(tee "$RES") 2>&1
echo "# test-emmc-generic $(date -Iseconds)"

B=${1:-}
if [ -z "$B" ]; then
	B=$T/bundle
	rm -rf "$B"
	PUF=${PUF_FILE:-$FACTORY_DIR/dl/tsw-xx60_3.002.1061.001.puf}
	ENVFILE=${ENV_LIVE_FILE:-$FACTORY_DIR/out/env-live-20260926-2153.bin}
	if [ ! -f "$PUF" ] || [ ! -f "$ENVFILE" ]; then
		echo "SKIPPED: needs the Crestron .puf (PUF_FILE) and a live env capture (ENV_LIVE_FILE); not present here"
		exit 0
	fi
	"$FACTORY_DIR/mkbundle.sh" --puf "$PUF" --env "$ENVFILE" --out "$B" > "$T/mkbundle.log" 2>&1 \
		&& ok "mkbundle.sh without a backup" || { fail "mkbundle.sh (see $T/mkbundle.log)"; exit 1; }
fi
MF=$B/emmc.manifest
grep -q '^boot0_sha256=any$' "$MF" && ok "manifest: boot0_sha256=any" || fail "manifest boot0 line"
for r in recovery misc data; do grep -q "^region $r [0-9]* [0-9]* zero " "$MF" && ok "manifest: $r = zero" || fail "manifest: $r not zero"; done
grep -q '^region logo 628 48 head:logo.img ' "$MF" && ok "manifest: logo head:logo.img" || fail "manifest logo"
[ ! -e "$B/recovery.img.gz" ] && [ ! -e "$B/data.img.gz" ] && ok "no recovery/data images in the bundle" || fail "stale recovery/data image in the bundle"
(cd "$B" && sha256sum -c --quiet SHA256SUMS) && ok "SHA256SUMS" || fail "SHA256SUMS"

# the cache image: factory parameters, empty, clean
gzip -dc "$B/cache.img.gz" > "$T/cache.img"
e2fsck -fn "$T/cache.img" > /dev/null 2>&1 && ok "cache ext4 e2fsck clean" || fail "cache e2fsck"
feat=$(dumpe2fs -h "$T/cache.img" 2>/dev/null | sed -n 's/^Filesystem features: *//p')
[ "$feat" = "has_journal ext_attr resize_inode filetype extent sparse_super large_file uninit_bg" ] && ok "cache features = factory ($feat)" || fail "cache features: $feat"
for k in 'Block count:131072' 'Inode count:32768' 'Inode size:256' 'Block size:4096' 'Reserved block count:0'; do
	dumpe2fs -h "$T/cache.img" 2>/dev/null | tr -d ' ' | grep -qx "$(echo "$k" | tr -d ' ')" && ok "cache $k" || fail "cache $k"
done
[ "$(debugfs -R 'ls' "$T/cache.img" 2>/dev/null | tr -s ' \n' ' ' | grep -o 'lost+found' | wc -l)" = 1 ] && ok "cache holds only lost+found" || fail "cache content"
rm -f "$T/cache.img"

# synthetic eMMC in the post-eMMC-migration state
IMG=$T/emmc.img B0=$T/boot0.img
rm -f "$IMG"; truncate -s $((3728 * M)) "$IMG"
head -c $((4 * M)) /dev/urandom > "$B0"
dd if="$B0" of="$IMG" bs=$M conv=notrunc status=none                                     # bootloader area 0..4M
head -c $M /dev/urandom | dd of="$IMG" bs=$M seek=12 conv=notrunc status=none            # secure store (dig/DSS) at 12M
head -c $((2 * M)) /dev/urandom | dd of="$IMG" bs=$M seek=36 conv=notrunc status=none     # reserved 36M+64M
head -c $((2 * M)) /dev/urandom | dd of="$IMG" bs=$M seek=98 conv=notrunc status=none
for r in "108 3" "684 5" "716 1" "1900 7"; do set -- $r; head -c $(( $2 * M )) /dev/urandom | dd of="$IMG" bs=$M seek=$1 conv=notrunc status=none; done
{ cat "$B/logo.img"; head -c $M /dev/urandom; } | dd of="$IMG" bs=$M seek=628 conv=notrunc status=none   # logo + stale tail
TB=$WORK/emmc/out/tsxboot-emmc.img; [ -f "$TB" ] && dd if="$TB" of="$IMG" bs=$M seek=764 conv=notrunc status=none
mkfs.ext4 -F -q -L tsxroot-emmc -E offset=$((796 * M)) "$IMG" $((2932 * 1024)) > /dev/null 2>&1 \
	&& ok "synthetic post-eMMC-migration state (ext4 tsxroot-emmc at 796M)" || fail "mkfs at offset"
LOGO_TAIL=$(dd if="$IMG" bs=1 skip=$((628 * M + $(stat -c %s "$B/logo.img"))) count=4096 status=none | sha256sum)
KEEP_BL=$(sha_range "$IMG" 0 4) KEEP_SS=$(sha_range "$IMG" 4 32) KEEP_RES=$(sha_range "$IMG" 36 64)
B0SHA=$(sha256sum < "$B0" | cut -d' ' -f1)

# run the panel-side script under the panel's shell (busybox ash): bash differs, e.g. a background job keeps a
# pipe as stdin under bash but gets /dev/null under ash (2026-09-27 pr_dd bug, invisible under bash)
PSH="${TSX_PANEL_SH:-$(command -v busybox >/dev/null && echo 'busybox sh' || echo sh)}"; ok "panel shell: $PSH"
export TSX_EMMC=$IMG TSX_BOOT0=$B0 TSX_EMMC_SECTORS=7634944 TSX_RUN=$T/run
out=$($PSH "$B/tsx-emmc-restore" check "$B" 2>&1); rc=$?
[ $rc = 0 ] && ok "check rc 0" || fail "check rc $rc: $out"
printf '%s\n' "$out" | grep -q 'logo: already as wanted' && ok "check: logo head already factory" || fail "check logo: $(printf '%s\n' "$out" | grep logo)"
printf '%s\n' "$out" | grep -q 'gap796: differs' && ok "check: gap796 (mainline ext4 head) differs" || fail "check gap796"
t0=$(date +%s); out=$($PSH "$B/tsx-emmc-restore" run "$B" --yes 2>&1); rc=$?
[ $rc = 0 ] && ok "run rc 0 ($(( $(date +%s) - t0 )) s)" || fail "run rc $rc: $(printf '%s\n' "$out" | tail -5)"
printf '%s\n' "$out" | grep -q 'U-Boot untouched: boot0 still' && ok "run: boot0 unchanged message" || fail "run boot0 message"
grep '^region ' "$MF" | while read -r _ name off len src want; do
	case $src in head:*) got=$(dd if="$IMG" bs=$M skip=$off count=$len status=none | head -c "$(stat -c %s "$B/${src#head:}")" | sha256sum | cut -d' ' -f1);;
	*) got=$(sha_range "$IMG" "$off" "$len");; esac
	[ "$got" = "$want" ] && echo "  ok: region $name = manifest" || echo "  FAIL: region $name $got != $want"
done > "$T/regions.txt"; cat "$T/regions.txt"; N=$((N + $(wc -l < "$T/regions.txt"))); F=$((F + $(grep -c FAIL "$T/regions.txt")))
[ "$(sha_range "$IMG" 0 4)" = "$KEEP_BL" ] && ok "bootloader area 0..4M untouched" || fail "bootloader area changed"
[ "$(sha_range "$IMG" 4 32)" = "$KEEP_SS" ] && ok "4M..36M (secure store) untouched" || fail "4M..36M changed"
[ "$(sha_range "$IMG" 36 64)" = "$KEEP_RES" ] && ok "reserved 36M+64M untouched" || fail "reserved changed"
[ "$(sha256sum < "$B0" | cut -d' ' -f1)" = "$B0SHA" ] && ok "boot0 untouched" || fail "boot0 changed"
[ "$(dd if="$IMG" bs=1 skip=$((628 * M + $(stat -c %s "$B/logo.img"))) count=4096 status=none | sha256sum)" = "$LOGO_TAIL" ] && ok "logo tail left alone (head: writes only the file)" || fail "logo tail changed"
blkid -p -O $((796 * M + 1024 - 1024)) "$IMG" 2>/dev/null | grep -q tsxroot-emmc && fail "LABEL=tsxroot-emmc still found at 796M" || ok "no tsxroot-emmc label left"
out=$($PSH "$B/tsx-emmc-restore" run "$B" --yes 2>&1); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'already as wanted, skipped')" = "$(grep -c '^region ' "$MF")" ] && ok "second run: every region skipped" || fail "second run not a no-op: $(printf '%s\n' "$out" | grep -v skipped | tail -3)"
# wrong device size and a changed bundle are refused
TSX_EMMC_SECTORS=7634943 $PSH "$B/tsx-emmc-restore" check "$B" > /dev/null 2>&1 && fail "wrong size accepted" || ok "wrong eMMC size refused"
cp -a "$B" "$T/badb"; printf x >> "$T/badb/cache.img.gz"
$PSH "$T/badb/tsx-emmc-restore" check "$T/badb" > /dev/null 2>&1 && fail "corrupt bundle accepted" || ok "corrupt bundle refused"
rm -rf "$T/badb" "$IMG" "$B0"
echo "# $((N - F))/$N passed"
[ $F = 0 ]
