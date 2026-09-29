#!/bin/bash
# Build the mainline RESCUE image for the golden slot (p1:boot.img).
# U-Boot's golden bootcmd is "fatload mmc 0 ${loadaddr} boot.img;
# bootm", so the rescue is an Android v0 boot image exactly like tsxboot.img:
# same kernel + DTB (byte-identical, from BASE), initramfs = BASE's initramfs
# (rootfs switch_root initramfs with installer stage 2) + a second cpio archive
# appended (the kernel unpacks concatenated archives in order) that adds:
#   /etc/tsx/rescue-image      flag: /init goes straight to the rescue system
#   /usr/sbin/tsx-rescue       status / done / banner (IP on the screen)
#   /usr/local/sbin/tsx-boot-ok + /etc/tsx/uboot-env.conf   (from work/rootfs overlay)
#   /etc/inittab               BASE's + "::once:/usr/sbin/tsx-rescue banner"
#   rescue/mkrescue.sh [--base IMG] [--model tsw1060] [--out IMG]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); INSTALLER_DIR=$(cd "$HERE/.." && pwd); ROOTFS_DIR=$(cd "$INSTALLER_DIR/../rootfs" && pwd)
BASE=$INSTALLER_DIR/out/tsxboot-audio-autoinstall.img MODEL=tsw1060 OUT=
while [ $# -gt 0 ]; do case $1 in --base) BASE=$2; shift;; --model) MODEL=$2; shift;; --out) OUT=$2; shift;; *) sed -n '2,13p' "$0"; exit 2;; esac; shift; done
OUT=${OUT:-$INSTALLER_DIR/out/tsx-rescue-$MODEL.img}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
python3 - "$BASE" "$W/base-rd.gz" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(); h = struct.unpack_from('<8s10I', d, 0); assert h[0] == b'ANDROID!'
ks, rs, ps = h[1], h[3], h[8]; pad = lambda n: (n + ps - 1) // ps * ps
open(sys.argv[2], 'wb').write(d[ps + pad(ks): ps + pad(ks) + rs])
PY
mkdir -p "$W/base"; (cd "$W/base" && zcat "$W/base-rd.gz" | cpio -id --quiet init etc/inittab etc/init.d/rcS usr/sbin/tsx-autoinstall 2>/dev/null) || true
grep -q '/etc/tsx/rescue-image' "$W/base/init" || { echo "BASE's /init has no rescue-image check: rebuild the initramfs after integrate.sh"; exit 1; }
grep -q 'ethaddr' "$W/base/etc/init.d/rcS" 2>/dev/null || { echo "BASE's rcS does not set the eth0 MAC from the U-Boot env: rebuild the initramfs"; exit 1; }
R=$W/ov; mkdir -p "$R"; cp -a "$HERE/overlay/." "$R/"
install -D -m 755 "$ROOTFS_DIR/overlay/usr/local/sbin/tsx-boot-ok" "$R/usr/local/sbin/tsx-boot-ok"
install -D -m 644 "$ROOTFS_DIR/overlay/etc/tsx/uboot-env.conf" "$R/etc/tsx/uboot-env.conf"
grep -q '^ENV_VERIFIED=yes' "$R/etc/tsx/uboot-env.conf" || { echo "uboot-env.conf not verified"; exit 1; }
{ cat "$W/base/etc/inittab"; echo "::once:/usr/sbin/tsx-rescue banner"; } > "$R/etc/inittab"
chmod 755 "$R/usr/sbin/tsx-rescue"
(cd "$R" && find . -mindepth 1 | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > "$W/ov.gz"
cat "$W/base-rd.gz" "$W/ov.gz" > "$W/rd.gz"
python3 "$INSTALLER_DIR/initramfs/repack-bootimg.py" "$BASE" "$W/rd.gz" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" && cat "$(basename "$OUT").sha256")
echo "rescue overlay: $(cd "$R" && find . -type f | sort | tr '\n' ' ')"
