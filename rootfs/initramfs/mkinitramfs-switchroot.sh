#!/bin/sh
# Runs INSIDE an armv7 Alpine container (see ../build-rootfs.sh initramfs).
# The rescue initramfs (same packages, rcS, inittab, root password
# "tsx") with a switch_root /init, plus the tools install.sh needs.
# Usage: mkinitramfs-switchroot.sh <out.cpio.gz> [authorized_keys]
set -eu
OUT=$1; KEYS=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
R=/tmp/rootfs; rm -rf $R; mkdir -p $R
apk add --root $R --initdb --no-cache -q \
    --repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
    alpine-baselayout busybox busybox-binsh dropbear i2c-tools evtest e2fsprogs \
    e2fsprogs-extra dosfstools util-linux-misc blkid sfdisk u-boot-tools
    # e2fsprogs-extra: resize2fs (installer/steps/tsx-rescue-install grows the
    # compact eMMC root to fill p8 after writing it; e2fsck/mke2fs/mkfs.ext4
    # are in e2fsprogs above, blkdiscard is in util-linux-misc)
cp -a "$HERE"/overlay/. $R/
# installer stage 2: the rootfs installer inside the initramfs (tsx-autoinstall uses it)
mkdir -p $R/usr/share/tsx
cp "$HERE"/../install.sh "$HERE"/../tsx-disk.sh $R/usr/share/tsx/
chmod 755 $R/usr/share/tsx/install.sh
[ -x $R/usr/sbin/tsx-autoinstall ] || { echo "tsx-autoinstall missing in the overlay"; exit 1; }
chmod 755 $R/init $R/etc/init.d/rcS
rm -f $R/etc/fw_env.config     # never let fw_setenv default to Android's mmcblk0 copy
if [ -n "$KEYS" ] && [ -s "$KEYS" ]; then
  mkdir -p $R/root/.ssh; cp "$KEYS" $R/root/.ssh/authorized_keys
  chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi
H=$(echo tsx | mkpasswd -m sha-512 -s); case "$H" in \$6\$*) ;; *) echo "password hash failed"; exit 1;; esac
sed -i "s|^root:[^:]*:|root:$H:|" $R/etc/shadow
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar
(cd $R && find . | cpio -o -H newc --quiet | gzip -9) > "$OUT"
ls -l "$OUT"
