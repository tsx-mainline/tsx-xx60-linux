#!/bin/sh
# Runs inside an armv7 Alpine container (see ../build-rootfs.sh initramfs).
# It builds the rescue initramfs: the same packages, rcS, inittab and root
# password ("tsx"), with a switch_root /init and the tools install.sh needs.
# Usage: mkinitramfs-switchroot.sh <out.cpio.gz> [authorized_keys]
set -eu
OUT=$1; KEYS=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
R=/tmp/rootfs; rm -rf $R; mkdir -p $R
apk add --root $R --initdb --no-cache -q \
    --repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
    alpine-baselayout busybox busybox-binsh dropbear i2c-tools evtest e2fsprogs \
    e2fsprogs-extra dosfstools util-linux-misc blkid sfdisk u-boot-tools
    # e2fsprogs-extra has resize2fs. installer/steps/tsx-rescue-install uses it
    # to grow the compact eMMC root to fill p8 after it writes the root.
    # e2fsck, mke2fs and mkfs.ext4 come from e2fsprogs above. blkdiscard
    # comes from util-linux-misc.
cp -a "$HERE"/overlay/. $R/
# Boot splash (docs/boot.md "Boot splash"): tsx-splash and the rendered images
# and fonts. This step builds them in the build container, never on the image.
apk add -q --no-cache build-base linux-headers >/dev/null
gcc -O2 -Wall -s -o /tmp/tsx-splash "$HERE/../src/tsx-splash.c"
install -D -m 755 /tmp/tsx-splash $R/usr/sbin/tsx-splash
sh "$HERE/../splash/mksplash.sh" /tmp/splash-out >/dev/null
mkdir -p $R/usr/share/tsx/splash
cp /tmp/splash-out/*.ppm /tmp/splash-out/*.psf $R/usr/share/tsx/splash/
# Text console fonts for tsx-confont: Terminus bold, SIL OFL 1.1. tsx-confont
# picks the largest font that still gives 80x25 on the LCD. The fonts are
# uncompressed because setfont reads them that way.
apk add -q --no-cache font-terminus >/dev/null
mkdir -p $R/usr/share/tsx/consolefonts
for f in ter-116b ter-118b ter-120b ter-122b ter-124b ter-128b ter-132b; do
  zcat /usr/share/consolefonts/$f.psf.gz > $R/usr/share/tsx/consolefonts/$f.psf
done
[ -x $R/usr/sbin/tsx-confont ] || { echo "tsx-confont missing in the overlay"; exit 1; }
[ -x $R/usr/sbin/tsx-rescue-status ] || { echo "tsx-rescue-status missing in the overlay"; exit 1; }
# The orientation table (panel.conf ORIENTATION). This is the same script as
# on the rootfs, so the initramfs and the kiosk always agree on a name.
install -m 755 "$HERE/../overlay/usr/local/bin/tsx-orientation" $R/usr/sbin/tsx-orientation
# The rescue tools: `tsx-rescue status` and `tsx-rescue done` work in both
# rescues (this initramfs and the rescue image). tsx-rescue calls tsx-boot-ok,
# which reads uboot-env.conf. Both files are the same as on the rootfs.
[ -x $R/usr/sbin/tsx-rescue ] || { echo "tsx-rescue missing in the overlay"; exit 1; }
install -D -m 755 "$HERE/../overlay/usr/local/sbin/tsx-boot-ok" $R/usr/local/sbin/tsx-boot-ok
install -D -m 644 "$HERE/../overlay/etc/tsx/uboot-env.conf" $R/etc/tsx/uboot-env.conf
grep -q '^ENV_VERIFIED=yes' $R/etc/tsx/uboot-env.conf || { echo "uboot-env.conf not verified"; exit 1; }
# Installer stage 2: the rootfs installer inside the initramfs. tsx-autoinstall
# uses it.
mkdir -p $R/usr/share/tsx
cp "$HERE"/../install.sh "$HERE"/../tsx-disk.sh $R/usr/share/tsx/
chmod 755 $R/usr/share/tsx/install.sh
[ -x $R/usr/sbin/tsx-autoinstall ] || { echo "tsx-autoinstall missing in the overlay"; exit 1; }
chmod 755 $R/init $R/etc/init.d/rcS
rm -f $R/etc/fw_env.config     # fw_setenv must not default to the Android mmcblk0 copy
if [ -n "$KEYS" ] && [ -s "$KEYS" ]; then
  mkdir -p $R/root/.ssh; cp "$KEYS" $R/root/.ssh/authorized_keys
  chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi
H=$(echo tsx | mkpasswd -m sha-512 -s); case "$H" in \$6\$*) ;; *) echo "password hash failed"; exit 1;; esac
sed -i "s|^root:[^:]*:|root:$H:|" $R/etc/shadow
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar
(cd $R && find . | cpio -o -H newc --quiet | gzip -9) > "$OUT"
ls -l "$OUT"
