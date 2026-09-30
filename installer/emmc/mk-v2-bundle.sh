#!/bin/bash
# Host: assemble the slice of the v2 install payload for one kernel flavor (the
# BUNDLE_DIR that installer/steps/tsx-rescue-install reads). The slice holds
# root.img (from mk-tsxroot-emmc.sh), the already-built eMMC boot image (the
# output of kernel/mkimage.sh for that flavor, e.g. hwtest/<flavor>/tsxboot-emmc.img)
# and one manifest. The manifest ties them together with a byte count and both sha256sums.
#
#   mk-v2-bundle.sh --root-img FILE --boot-img FILE --flavor lts|stable --out-dir DIR
#
# root_bytes is the size of ROOT.IMG itself (compact), not the size of the eMMC
# p8 partition. mk-tsxroot-emmc.sh sizes root.img to content plus a margin, well
# under the ~2.9 GiB of p8 (see docs/boot.md). If ROOT has a sibling
# ROOT.manifest-fragment (an output of mk-tsxroot-emmc.sh, next to the image
# it built), the script also carries its root_partition_min_bytes into this manifest.
# So installer/steps/tsx-rescue-install can refuse an unexpectedly small p8,
# although it no longer checks for an exact size match against root_bytes.
set -euo pipefail
ROOT= BOOT= FLAVOR= OUT=
while [ $# -gt 0 ]; do case $1 in --root-img) ROOT=$2; shift;; --boot-img) BOOT=$2; shift;; --flavor) FLAVOR=$2; shift;; --out-dir) OUT=$2; shift;; *) sed -n '2,14p' "$0"; exit 2;; esac; shift; done
[ -f "$ROOT" ] && [ -f "$BOOT" ] && [ -n "$FLAVOR" ] && [ -n "$OUT" ] || { sed -n '2,14p' "$0" >&2; exit 2; }
mkdir -p "$OUT"
cp "$ROOT" "$OUT/root.img"; cp "$BOOT" "$OUT/boot.img"
RSHA=$(sha256sum < "$OUT/root.img" | cut -d' ' -f1); BSHA=$(sha256sum < "$OUT/boot.img" | cut -d' ' -f1)
RBYTES=$(stat -c %s "$OUT/root.img")
MINPART=
[ -f "$ROOT.manifest-fragment" ] && MINPART=$(sed -n 's/^root_partition_min_bytes=//p' "$ROOT.manifest-fragment" | tail -n 1)
{
	echo "format=tsx-rescue-install-1"; echo "kernel_flavor=$FLAVOR"; echo "root_bytes=$RBYTES"
	[ -n "$MINPART" ] && echo "root_partition_min_bytes=$MINPART"
	echo "root_sha256=$RSHA"; echo "boot_sha256=$BSHA"
} > "$OUT/manifest"
(cd "$OUT" && sha256sum root.img boot.img > SHA256SUMS)
echo "mk-v2-bundle.sh: $OUT ($FLAVOR): root $RBYTES bytes ($RSHA)${MINPART:+, partition floor $MINPART bytes}, boot $(stat -c %s "$OUT/boot.img") bytes ($BSHA)"
