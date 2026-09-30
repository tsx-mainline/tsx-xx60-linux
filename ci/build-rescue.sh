#!/bin/bash
# Build the v2 rescue image (installer/tsx-install-mainline's PAYLOAD/rescue.img).
# It is the golden-slot and one-shot mainline rescue, and both kernel flavors
# share it. It only runs stage 2 (the eMMC writer) and then reboots into the
# flavor that the install picked (see docs/install.md "What runs where").
# The script chains pieces that exist but had no single driver:
#   1. rootfs/mkbootimg.sh (KDIR)        -> rootfs/out/tsxboot.img
#      (needs rootfs/out/initramfs-switchroot.cpio.gz, for example from
#      rootfs/build-rootfs.sh initramfs)
#   2. installer/initramfs/build-initramfs.sh -> installer/out/initramfs-switchroot-autoinstall.cpio.gz
#   3. installer/initramfs/repack-bootimg.py   -> installer/out/tsxboot-audio-autoinstall.img
#      (the kernel and DTB of step 1, with the stage-2 initramfs swapped in)
#   4. installer/rescue/mkrescue.sh            -> installer/rescue/out/tsx-rescue-tsw1060.img
#   5. installer/rescue-v2/mkrescue-v2.sh       -> OUT (stamps the version)
#      The rescue screen itself is in the base initramfs.
#
#   ci/build-rescue.sh --kdir OUT_DIR --out RESCUE.img [--flavor NAME]
#     --kdir OUT_DIR   the OUT_DIR of a kbuild.sh "image" step (zImage, board
#                      DTB, kernel.release). The flavor of the kernel in the
#                      rescue is cosmetic (see NOTE below). The default flavor
#                      tag in the image is "shared".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KDIR= OUT= FLAVOR=shared
while [ $# -gt 0 ]; do case $1 in
	--kdir) KDIR=$2; shift;; --out) OUT=$2; shift;; --flavor) FLAVOR=$2; shift;;
	*) sed -n '2,21p' "$0"; exit 2;;
esac; shift; done
[ -n "$KDIR" ] && [ -f "$KDIR/zImage" ] || { echo "build-rescue.sh: --kdir OUT_DIR required (a kbuild.sh image-step output)" >&2; exit 2; }
[ -n "$OUT" ] || { echo "build-rescue.sh: --out RESCUE.img required" >&2; exit 2; }

# NOTE: the rescue never boots the kernel of a flavor end to end. It only runs
# installer/steps/tsx-rescue-install (write eMMC boot and root, fold the card,
# reboot), or, on the golden path, arms a one-shot into the same step. Users
# cannot see which flavor's zImage and DTB are packed into it. The caller
# picks one (release.yml uses lts, the default flavor). This gives exactly one
# rescue image to build, verify and ship, and not two images that differ only
# in the kernel.
[ -f "$REPO/rootfs/out/initramfs-switchroot.cpio.gz" ] || { echo "build-rescue.sh: rootfs/out/initramfs-switchroot.cpio.gz missing (run rootfs/build-rootfs.sh initramfs first)" >&2; exit 2; }

echo "build-rescue.sh: 1/5 rootfs/mkbootimg.sh (KDIR=$KDIR)"
KDIR="$KDIR" "$REPO/rootfs/mkbootimg.sh"

echo "build-rescue.sh: 2/5 installer/initramfs/build-initramfs.sh"
"$REPO/installer/initramfs/build-initramfs.sh"

echo "build-rescue.sh: 3/5 repack-bootimg.py (stage 2 initramfs into the boot image)"
mkdir -p "$REPO/installer/out"
python3 "$REPO/installer/initramfs/repack-bootimg.py" \
	"$REPO/rootfs/out/tsxboot.img" \
	"$REPO/installer/out/initramfs-switchroot-autoinstall.cpio.gz" \
	"$REPO/installer/out/tsxboot-audio-autoinstall.img"

echo "build-rescue.sh: 4/5 installer/rescue/mkrescue.sh"
mkdir -p "$REPO/installer/rescue/out"
"$REPO/installer/rescue/mkrescue.sh" \
	--base "$REPO/installer/out/tsxboot-audio-autoinstall.img" \
	--out "$REPO/installer/rescue/out/tsx-rescue-tsw1060.img"

echo "build-rescue.sh: 5/5 installer/rescue-v2/mkrescue-v2.sh (flavor tag: $FLAVOR)"
mkdir -p "$(dirname "$OUT")"
"$REPO/installer/rescue-v2/mkrescue-v2.sh" \
	--base "$REPO/installer/rescue/out/tsx-rescue-tsw1060.img" \
	--flavor "$FLAVOR" --out "$OUT"
echo "build-rescue.sh: $OUT ready ($(stat -c %s "$OUT") bytes)"
