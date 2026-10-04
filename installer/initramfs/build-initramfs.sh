#!/bin/bash
# Build the rootfs switch_root initramfs (with installer stage 2 integrated) into
# installer/out instead of rootfs/out, so nobody's default artifact changes.
# The recipe is the same as rootfs/build-rootfs.sh initramfs (armv7 alpine:3.24
# container, Alpine v3.24 packages). A host of another architecture runs the
# container under qemu-user. The rootfs is mounted read-only. It takes ~1-2 min.
#   initramfs/build-initramfs.sh [OUT.cpio.gz]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOTFS_DIR=$(cd "$HERE/../../rootfs" && pwd)
OUTF=${1:-$HERE/../out/initramfs-switchroot-autoinstall.cpio.gz}
mkdir -p "$(dirname "$OUTF")"; OD=$(cd "$(dirname "$OUTF")" && pwd); ON=$(basename "$OUTF")
"$HERE/integrate.sh" --check | grep -q "MISSING or differs" && { echo "overlay not in sync: run initramfs/integrate.sh first"; exit 1; }
ALPINE=${ALPINE:-v3.24}
docker run --rm --platform linux/arm/v7 -v "$ROOTFS_DIR:/w:ro" -v "$OD:/o" -e ALPINE="$ALPINE" -e TSX_DEV_RESCUE_HASH="${TSX_DEV_RESCUE_HASH:-}" alpine:3.24 sh -euc "
	printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' $ALPINE $ALPINE > /etc/apk/repositories
	apk add -q --no-cache cpio mkpasswd >/dev/null
	/w/initramfs/mkinitramfs-switchroot.sh /o/$ON /w/authorized_keys
	chown $(id -u):$(id -g) /o/$ON"
(cd "$OD" && sha256sum "$ON" > "$ON.sha256")
echo "contents check:"; zcat "$OUTF" | cpio -it 2>/dev/null | grep -E '^(init|usr/sbin/tsx-autoinstall|usr/share/tsx/.*)$'
cat "$OUTF.sha256"
