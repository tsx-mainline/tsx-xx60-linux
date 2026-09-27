#!/bin/bash
# Host test for the eMMC-boot root-selection fallback fix (2026-09-27) in
# rootfs/initramfs/overlay/init: without tsx.root=, try LABEL=tsxroot-emmc
# then LABEL=tsxroot, using a candidate only if it mounts AND has an init,
# so a stale tsxroot-emmc superblock (left behind by an earlier eMMC install,
# fs since overwritten) falls through to the card instead of dropping to
# rescue. Extracts the real selection code (up()/find_dev()/candidate loop)
# from the init script by line range and runs it, unmodified, against
# loop-mounted ext4 images in a privileged Alpine 3.24 container (pattern:
# installer/tests/test-factory.sh). Host-only, no panel/serial involved.
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

docker run --rm --privileged --platform linux/amd64 -v "$W:/w:rw" alpine:3.24 sh -c '
apk add -q --no-cache e2fsprogs util-linux blkid busybox-extras >/dev/null 2>&1
for i in $(seq 0 31); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir -p /newroot

# stand-ins for the two functions defined earlier in the real init (not part
# of the extracted range): msg() is harmless as-is; rescue() here records
# that it was called instead of exec-ing /sbin/init (there is none in this
# sandbox).
msg() { echo "MSG: $*"; }
rescue() { echo "RESCUE-CALLED: $*"; RESCUED=1; }
# This host is shared (other loop-mounted tsx disk images, some also labelled
# tsxroot/tsxroot-emmc, are visible here -- loop devices are a global kernel
# resource, not per-container). Real findfs would pick those up too and make
# the test flaky/wrong through no fault of the selection logic, so scope the
# LABEL lookup to only the two devices this test run itself attached; the
# extracted selection code (find_dev, the candidate loop, fsck/mount/init
# checks, rescue fallback) runs completely unmodified.
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

N=$(grep -c "^PASS" "$W/docker.txt")
F=$(grep -c "^FAIL" "$W/docker.txt")
echo "== $N ok, $F failed"
[ "$F" = 0 ] && [ "$N" = 3 ] && echo "PASS test-root-fallback" || { echo "FAIL test-root-fallback (expected 3 ok)"; exit 1; }
