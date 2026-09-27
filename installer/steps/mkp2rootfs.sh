#!/bin/bash
# Card stage: make the kiosk rootfs image for p2 (800 MiB) from the rootfs build,
# without rebuilding it: copy rootfs/out/rootfs.ext4 (1492 MiB, ~670 MiB
# used), copy its files into a new ext4 of exactly p2's size, then (debugfs)
#   /etc/fstab     + /dev/mmcblk0p1 on /media/bootfat (noauto) + LABEL=tsxdata on /data (nofail)
#   /data          mount point for p4 (formatted by the first mainline boot)
#   /usr/local/sbin/tsx-boot-ok, /etc/tsx/uboot-env.conf   = the current work/rootfs
#                  overlay (finds the env disk on the card-stage layout too)
#   /var/lib/tsx/install.info   the card-stage source image hashes
# Output: out/rootfs-p2.ext4 (+ .sha256). Android never mounts p2, so the ext4
# features of the rootfs build are kept.
#   mkp2rootfs.sh [--rootfs-ext4 IMG] [--out IMG] [--url URL] [--token-file F]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); INSTALLER_DIR=$(cd "$HERE/.." && pwd); ROOTFS_DIR=$(cd "$INSTALLER_DIR/../rootfs" && pwd)
SRC=$ROOTFS_DIR/out/rootfs.ext4 OUT=$INSTALLER_DIR/out/rootfs-p2.ext4 URL= TOKEN=
while [ $# -gt 0 ]; do case $1 in --rootfs-ext4) SRC=$2; shift;; --out) OUT=$2; shift;; --url) URL=$2; shift;;
	--token-file) TOKEN=$2; shift;; *) sed -n '2,15p' "$0"; exit 2;; esac; shift; done
P2BYTES=$((1638400 * 512))
W=$(mktemp -d "${TMPDIR:-/var/tmp}/mkp2.XXXX"); trap 'rm -rf "$W"' EXIT
# resize2fs cannot shrink the 1492 MiB build below ~1240 MiB (inode tables), so
# the files are copied into a new 800 MiB ext4 with mke2fs -d (owners, modes,
# setuid bits and xattrs kept), in a privileged container that mounts the build
# read-only through a loop device. Same mke2fs options as rootfs/mkrootfs.sh.
truncate -s $P2BYTES "$W/p2.ext4"
docker run --rm --privileged --platform linux/amd64 -v "$(dirname "$SRC"):/src:ro" -v "$W:/w" alpine:3.24 sh -euc "
	apk add -q --no-cache e2fsprogs e2fsprogs-extra >/dev/null
	for i in \$(seq 0 63); do [ -b /dev/loop\$i ] || mknod /dev/loop\$i b 7 \$i; done
	mkdir -p /mnt/r; mount -o ro,loop,noload /src/$(basename "$SRC") /mnt/r
	mke2fs -q -F -t ext4 -O ^metadata_csum_seed,^orphan_file -L tsxroot -m 0 -d /mnt/r /w/p2.ext4
	umount /mnt/r; chown $(id -u):$(id -g) /w/p2.ext4"
dbg() { debugfs -w -R "$1" "$W/p2.ext4" >> "$W/debugfs.log" 2>&1; }
put() { dbg "rm $2" || true; dbg "write $1 $2"; dbg "sif $2 uid 0"; dbg "sif $2 gid 0"; dbg "sif $2 mode $3"; }
debugfs -R "cat /etc/fstab" "$W/p2.ext4" 2>/dev/null | grep -v '/media/bootfat\|^LABEL=tsxdata' > "$W/fstab"
echo "/dev/mmcblk0p1  /media/bootfat  vfat    noauto,rw,noatime,umask=022  0 0" >> "$W/fstab"
echo "LABEL=tsxdata   /data           ext4    rw,noatime,nofail         0      0" >> "$W/fstab"
put "$W/fstab" /etc/fstab 0100644
dbg "mkdir /data" || true; dbg "mkdir /media/bootfat" || true
put "$ROOTFS_DIR/overlay/usr/local/sbin/tsx-boot-ok" /usr/local/sbin/tsx-boot-ok 0100755
put "$ROOTFS_DIR/overlay/etc/tsx/uboot-env.conf" /etc/tsx/uboot-env.conf 0100644
if [ -n "$URL" ]; then
	debugfs -R "cat /etc/kiosk.conf" "$W/p2.ext4" 2>/dev/null | sed "s|^KIOSK_URL=.*|KIOSK_URL=\"$URL\"|" > "$W/kiosk.conf"; put "$W/kiosk.conf" /etc/kiosk.conf 0100644
fi
[ -n "$TOKEN" ] && put "$TOKEN" /var/lib/kiosk/pending-token 0100600
{ echo "installed=(card-stage image, mkp2rootfs.sh $(date -Iseconds))"; echo "disk=/dev/mmcblk0"
  echo "rootfs_ext4_sha256=$(sha256sum < "$SRC" | cut -d' ' -f1)"; } > "$W/install.info"
dbg "mkdir /var/lib/tsx" || true; put "$W/install.info" /var/lib/tsx/install.info 0100644
e2fsck -fn "$W/p2.ext4" > "$W/fsck2.log" 2>&1 || { cat "$W/fsck2.log"; exit 1; }
[ "$(debugfs -R 'cat /usr/local/sbin/tsx-boot-ok' "$W/p2.ext4" 2>/dev/null | sha256sum)" = "$(sha256sum < "$ROOTFS_DIR/overlay/usr/local/sbin/tsx-boot-ok")" ] || { echo "tsx-boot-ok not injected"; exit 1; }
# -m 0 above leaves no reserved blocks (root has no separate quota on p2), so
# all free space is headroom for ssh-keygen host keys, apk, logs, etc. at
# first boot. Fail the build if that headroom is too thin to be useful.
FREE_MIB=$(dumpe2fs -h "$W/p2.ext4" 2>/dev/null | awk -F: '/^Free blocks/{f=$2}END{printf "%d", f*4/1024}')
echo "p2 free space: ${FREE_MIB} MiB"
[ "$FREE_MIB" -ge 40 ] || { echo "ERROR: only ${FREE_MIB} MiB free on p2 (need >= 40 MiB)"; exit 1; }
mv "$W/p2.ext4" "$OUT"; (cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$(basename "$OUT"): $(stat -c %s "$OUT") bytes, $(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '/^Free blocks/{f=$2}/^Block count/{c=$2}END{printf "%d MiB used of %d MiB", (c-f)*4/1024, c*4/1024}'), sha256 $(cut -c1-12 "$OUT.sha256")"
