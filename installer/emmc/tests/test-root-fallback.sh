#!/bin/bash
# Host test for the eMMC-boot root-selection fallback fix (2026-09-27) in
# rootfs/initramfs/overlay/init. Without tsx.root=, init tries LABEL=tsxroot-emmc
# and then LABEL=tsxroot. It uses a candidate only if the candidate mounts
# and has an init. A stale tsxroot-emmc superblock (left by an earlier eMMC
# install, the file system since overwritten) must fall through to the card.
# It must not drop to rescue.
# The test extracts the real selection code (up(), find_dev(), the candidate
# loop) from the init script by line range. It runs the code unmodified
# against loop-mounted ext4 images in a privileged Alpine 3.24 container
# (same pattern as installer/tests/test-factory.sh).
# Host only: no panel and no serial port.
#   tests/test-root-fallback.sh
set -uo pipefail
EMMC=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$EMMC/../.." && pwd)
INIT=$ROOT/rootfs/initramfs/overlay/init
W=${TMPDIR:-/var/tmp}/tsx-rootfallback-test; rm -rf "$W"; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT

# Extract the real selection logic verbatim, so the test tracks the shipped
# code instead of a reimplementation of it. Bounds: from "up() { cut ..." (the
# helper find_dev() depends on) through the final "no usable root" rescue call,
# just before switch_root.
SEL_START=$(grep -n '^up() { cut' "$INIT" | head -1 | cut -d: -f1)
SEL_END=$(grep -n 'rescue "no usable root found among' "$INIT" | head -1 | cut -d: -f1)
[ -n "$SEL_START" ] && [ -n "$SEL_END" ] || { echo "FAIL: could not locate the selection block (up()..no usable root) in $INIT"; exit 1; }
sed -n "${SEL_START},${SEL_END}p" "$INIT" > "$W/selection.sh"
echo "extracted $INIT lines $SEL_START-$SEL_END into selection.sh ($(wc -l < "$W/selection.sh") lines)"

# Build the ext4 test images (mke2fs -d copies files into a fresh fs image
# directly, no loop device or root needed on the host).
mkdir -p "$W/withinit/sbin" "$W/noinit"
printf '#!/bin/sh\nexit 0\n' > "$W/withinit/sbin/init"; chmod 755 "$W/withinit/sbin/init"
mke2fs -q -F -L tsxroot-emmc -d "$W/noinit"   "$W/emmc-stale.img" 16M
mke2fs -q -F -L tsxroot-emmc -d "$W/withinit" "$W/emmc-valid.img" 16M
mke2fs -q -F -L tsxroot       -d "$W/noinit"   "$W/card-noinit.img" 16M
mke2fs -q -F -L tsxroot       -d "$W/withinit" "$W/card-valid.img" 16M

. "$(dirname "$0")/../../../ci/loopcheck.sh"; loop_mark "$W/loops0"
docker run --rm --privileged --platform linux/amd64 -v "$W:/w:rw" alpine:3.24 sh -c '
trap '"'"'[ -n "${le:-}" ] && losetup -d "$le" 2>/dev/null; [ -n "${lc:-}" ] && losetup -d "$lc" 2>/dev/null'"'"' EXIT
apk add -q --no-cache e2fsprogs util-linux blkid busybox-extras >/dev/null 2>&1
for i in $(seq 0 31); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir -p /newroot

# stand-ins for the two functions defined earlier in the real init (not part
# of the extracted range): msg() is harmless as-is. Rescue() here records
# that it was called instead of exec-ing /sbin/init (there is none in this
# sandbox).
msg() { echo "MSG: $*"; }
rescue() { echo "RESCUE-CALLED: $*"; RESCUED=1; }
# This host is shared. Other loop-mounted tsx disk images are visible here,
# and some carry the labels tsxroot or tsxroot-emmc. Loop devices are a global
# kernel resource, not a per-container one. The real findfs would find those
# images too, and the test would fail for a reason that is not in the
# selection logic. So this findfs limits the LABEL lookup to the two devices
# this test run attached. The extracted selection code (find_dev, the
# candidate loop, the fsck, mount and init checks, the rescue fallback)
# runs unmodified.
findfs() {
	want=${1#LABEL=}
	for cand in "$le" "$lc"; do
		[ -n "$cand" ] || continue
		[ "$(blkid -o value -s LABEL "$cand" 2>/dev/null)" = "$want" ] && { echo "$cand"; return 0; }
	done
	return 1
}

run_case() {  # name emmc-img card-img expect(LABEL=... or RESCUE)
	name=$1; eimg=$2; cimg=$3; expect=$4
	echo "-- case: $name"
	RESCUED= dev= used= root= wait=10 init=/sbin/init
	le=$(losetup -f --show "/w/$eimg")
	lc=$(losetup -f --show "/w/$cimg")
	. /w/selection.sh
	if [ "$expect" = RESCUE ]; then
		if [ -n "$RESCUED" ] && [ -z "$dev" ]; then echo "PASS: $name"; else echo "FAIL: $name (dev=$dev used=$used RESCUED=$RESCUED)"; fi
	else
		if [ "$used" = "$expect" ] && [ -z "$RESCUED" ]; then echo "PASS: $name (used=$used dev=$dev)"; else echo "FAIL: $name (used=$used dev=$dev expect=$expect RESCUED=$RESCUED)"; fi
	fi
	mountpoint -q /newroot 2>/dev/null && umount /newroot
	losetup -d "$le" 2>/dev/null; losetup -d "$lc" 2>/dev/null
}

run_case "stale tsxroot-emmc (no /sbin/init) + valid tsxroot -> falls through to the card" \
	emmc-stale.img card-valid.img LABEL=tsxroot
run_case "valid tsxroot-emmc -> used directly, card never needed" \
	emmc-valid.img card-noinit.img LABEL=tsxroot-emmc
run_case "neither candidate has /sbin/init -> RESCUE" \
	emmc-stale.img card-noinit.img RESCUE
' | tee "$W/docker.txt"
leak=$(loop_new "$W/loops0")
[ -z "$leak" ] || { echo "FAIL: loop devices left attached: $leak"; exit 1; }
echo "  ok: no loop device left attached"

N=$(grep -c "^PASS" "$W/docker.txt")
F=$(grep -c "^FAIL" "$W/docker.txt")
echo "== $N ok, $F failed"
[ "$F" = 0 ] && [ "$N" = 3 ] && echo "PASS test-root-fallback" || { echo "FAIL test-root-fallback (expected 3 ok)"; exit 1; }
