#!/bin/bash
# Host: assemble one kernel flavor's slice of the v2 install payload (the
# BUNDLE_DIR installer/steps/tsx-rescue-install reads): root.img (from
# mk-tsxroot-emmc.sh) + the already-built eMMC boot image (kernel/mkimage.sh's
# output for that flavor, e.g. hwtest/<flavor>/tsxboot-emmc.img) + one
# manifest tying them together with a byte count and both sha256sums.
#
#   mk-v2-bundle.sh --root-img FILE --boot-img FILE --flavor lts|stable --out-dir DIR
set -euo pipefail
ROOT= BOOT= FLAVOR= OUT=
while [ $# -gt 0 ]; do case $1 in --root-img) ROOT=$2; shift;; --boot-img) BOOT=$2; shift;; --flavor) FLAVOR=$2; shift;; --out-dir) OUT=$2; shift;; *) sed -n '2,8p' "$0"; exit 2;; esac; shift; done
[ -f "$ROOT" ] && [ -f "$BOOT" ] && [ -n "$FLAVOR" ] && [ -n "$OUT" ] || { sed -n '2,8p' "$0" >&2; exit 2; }
mkdir -p "$OUT"
cp "$ROOT" "$OUT/root.img"; cp "$BOOT" "$OUT/boot.img"
RSHA=$(sha256sum < "$OUT/root.img" | cut -d' ' -f1); BSHA=$(sha256sum < "$OUT/boot.img" | cut -d' ' -f1)
RBYTES=$(stat -c %s "$OUT/root.img")
{ echo "format=tsx-rescue-install-1"; echo "kernel_flavor=$FLAVOR"; echo "root_bytes=$RBYTES"; echo "root_sha256=$RSHA"; echo "boot_sha256=$BSHA"; } > "$OUT/manifest"
(cd "$OUT" && sha256sum root.img boot.img > SHA256SUMS)
echo "mk-v2-bundle.sh: $OUT ($FLAVOR): root $RBYTES bytes ($RSHA), boot $(stat -c %s "$OUT/boot.img") bytes ($BSHA)"
