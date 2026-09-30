#!/bin/bash
# Build the mainline Android boot image for the installed system.
# kernel/mkimage.sh packs the LVDS kernel (drm/meson LVDS), the switch_root
# initramfs and the DTBs of both panel sizes. With --board-dtbs, U-Boot picks
# the TSW-760 or TSW-1060 DTB by its env aml_dt.
# Output: out/tsxboot.img (for FAT p1, see the U-Boot hook notes) and its
# sha256. The script only reads the kernel, from KDIR (default: the own out/
# of the kernel fork checkout, a sibling of this repo).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
KDIR=${KDIR:-$(cd "$REPO/.." && pwd)/out}
docker image inspect tsx-mainline >/dev/null 2>&1 || docker build -q -t tsx-mainline -f "$REPO/ci/Dockerfile.mainline" "$REPO/ci"
docker run --rm -u "$(id -u):$(id -g)" -v "$TOP:$TOP" -w "$HERE" tsx-mainline \
	"$REPO/kernel/mkimage.sh" --kernel "$KDIR/zImage" --board-dtbs "$KDIR" \
	--initrd "$HERE/out/initramfs-switchroot.cpio.gz" --out "$HERE/out/tsxboot.img"
(cd "$HERE/out" && sha256sum tsxboot.img > tsxboot.img.sha256)
echo "kernel: $KDIR/zImage (built from $(cat "$KDIR/../build/include/config/kernel.release" 2>/dev/null || echo '?'))"
ls -l "$HERE/out/tsxboot.img"; cat "$HERE/out/tsxboot.img.sha256"
