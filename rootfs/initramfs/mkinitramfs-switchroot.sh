#!/bin/sh
# Runs inside an armv7 Alpine container (see ../build-rootfs.sh initramfs).
# It builds the rescue initramfs: the same packages, rcS and inittab, with a
# switch_root /init and the tools install.sh needs. The image has no root
# password: tsx-rescue-login chooses the login at each rescue boot (the panel's
# own hash and key from /data, or a one-time password on the screen).
# Usage: mkinitramfs-switchroot.sh <out.cpio.gz> [authorized_keys]
# TSX_FROM_PACKAGES=1 takes the rescue tools (tsx-rescue-ui), the splash
# (tsx-splash) and the board files (tsx-xx60-board, and tsx-orientation from
# tsx-kiosk) from the packages that packages.pin names, in the local apk tree
# TSX_APK_LOCAL (the directory that holds <ALPINE>/common and <ALPINE>/xx60).
# The script compiles nothing then. The default 0 builds them from the sources
# in this checkout.
# Test builds only: TSX_DEV_RESCUE_HASH (a crypt(3) hash that becomes the root
# password of the rescue, never in a public image) and the optional
# authorized_keys file (a developer key that dropbear accepts at every boot).
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
FROMPKG=${TSX_FROM_PACKAGES:-0}
cp -a "$HERE"/overlay/. $R/
if [ "$FROMPKG" = 1 ]; then
	: "${TSX_APK_LOCAL:?TSX_FROM_PACKAGES=1 needs TSX_APK_LOCAL}"
	: "${ALPINE:?TSX_FROM_PACKAGES=1 needs ALPINE}"
	# The packages replace these three source copies, so the build must not
	# keep an old one by accident.
	rm -f $R/usr/sbin/tsx-rescue-status $R/usr/sbin/tsx-rescue-login $R/usr/sbin/tsx-confont
	cp "$HERE"/../overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
	PINS=$(grep -v -e '^#' -e '^[[:space:]]*$' "$HERE/packages.pin" | tr '\n' ' ')
	echo "packages: $PINS"
	rm -rf /tmp/pk-x; mkdir -p /tmp/pk-x
	# Unpack the exact package files that packages.pin names, without their
	# dependencies. The tree has one directory for each category.
	for pin in $PINS; do
		n=${pin%%=*}; v=${pin#*=}
		f=$(ls "$TSX_APK_LOCAL/$ALPINE"/*/armv7/"$n-$v.apk" 2>/dev/null | head -n 1)
		[ -n "$f" ] || { echo "packages.pin: no $n-$v.apk in $TSX_APK_LOCAL/$ALPINE"; exit 1; }
		mkdir -p "/tmp/pk-x/$n-$v"
		apk extract --destination "/tmp/pk-x/$n-$v" "$f"
	done
	pk() { d=$(ls -d /tmp/pk-x/$1-[0-9]* | head -n 1); [ -d "$d" ] || { echo "no package $1 in packages.pin"; exit 1; }; echo "$d"; }
	# tsx-rescue-ui and tsx-splash: all their files (the rescue tools, the
	# splash tool, the images and the fonts).
	cp -a "$(pk tsx-rescue-ui)"/. $R/
	cp -a "$(pk tsx-splash)"/. $R/
else
# Boot splash (docs/boot.md "Boot splash"): tsx-splash and the rendered images
# and fonts. This step builds them in the build container, never on the image.
apk add -q --no-cache build-base linux-headers >/dev/null
gcc -O2 -Wall -s -o /tmp/tsx-splash "$HERE/../src/tsx-splash.c"
install -D -m 755 /tmp/tsx-splash $R/usr/local/bin/tsx-splash
sh "$HERE/../splash/mksplash.sh" /tmp/splash-out >/dev/null
mkdir -p $R/usr/share/tsx/splash
cp /tmp/splash-out/*.ppm /tmp/splash-out/*.psf $R/usr/share/tsx/splash/
fi
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
[ -x $R/usr/sbin/tsx-rescue-login ] || { echo "tsx-rescue-login missing in the overlay"; exit 1; }
[ -x $R/usr/sbin/tsx-rescue-backlight ] || { echo "tsx-rescue-backlight missing in the overlay"; exit 1; }
# The orientation table (panel.conf ORIENTATION). This is the same script as
# on the rootfs, so the initramfs and the kiosk always agree on a name.
if [ "$FROMPKG" = 1 ]; then
	install -m 755 "$(pk tsx-kiosk)/usr/local/bin/tsx-orientation" $R/usr/sbin/tsx-orientation
else
	install -m 755 "$HERE/../overlay/usr/local/bin/tsx-orientation" $R/usr/sbin/tsx-orientation
fi
# The board file (the rescue screen and rcS read it). It is the same file as on
# the rootfs.
if [ "$FROMPKG" = 1 ]; then
	install -D -m 644 "$(pk tsx-xx60-board)/usr/local/lib/tsx/board.sh" $R/usr/local/lib/tsx/board.sh
else
	install -D -m 644 "$HERE/../overlay/usr/local/lib/tsx/board.sh" $R/usr/local/lib/tsx/board.sh
fi
# The rescue tools: `tsx-rescue status` and `tsx-rescue done` work in both
# rescues (this initramfs and the rescue image). tsx-rescue calls tsx-boot-ok,
# which reads uboot-env.conf. Both files are the same as on the rootfs.
[ -x $R/usr/sbin/tsx-rescue ] || { echo "tsx-rescue missing in the overlay"; exit 1; }
if [ "$FROMPKG" = 1 ]; then
	BOARD=$(pk tsx-xx60-board)
	install -D -m 755 "$BOARD/usr/local/sbin/tsx-boot-ok" $R/usr/local/sbin/tsx-boot-ok
	install -D -m 644 "$BOARD/etc/tsx/uboot-env.conf" $R/etc/tsx/uboot-env.conf
else
	install -D -m 755 "$HERE/../overlay/usr/local/sbin/tsx-boot-ok" $R/usr/local/sbin/tsx-boot-ok
	install -D -m 644 "$HERE/../overlay/etc/tsx/uboot-env.conf" $R/etc/tsx/uboot-env.conf
fi
grep -q '^ENV_VERIFIED=yes' $R/etc/tsx/uboot-env.conf || { echo "uboot-env.conf not verified"; exit 1; }
# Installer stage 2: the rootfs installer inside the initramfs. tsx-autoinstall
# uses it.
mkdir -p $R/usr/share/tsx
cp "$HERE"/../install.sh "$HERE"/../tsx-disk.sh $R/usr/share/tsx/
chmod 755 $R/usr/share/tsx/install.sh
[ -x $R/usr/sbin/tsx-autoinstall ] || { echo "tsx-autoinstall missing in the overlay"; exit 1; }
chmod 755 $R/init $R/etc/init.d/rcS
# The stamp of these sources. The kernel packages carry this image, and
# rootfs/check-boot-images.py refuses a package whose stamp is not the stamp of
# the checkout.
mkdir -p $R/usr/share/tsx
TSX_FROM_PACKAGES=$FROMPKG sh "$HERE/../initramfs-stamp.sh" > $R/usr/share/tsx/initramfs.stamp
rm -f $R/etc/fw_env.config     # fw_setenv must not default to the Android mmcblk0 copy
if [ -n "$KEYS" ] && [ -s "$KEYS" ]; then
  mkdir -p $R/root/.ssh; cp "$KEYS" $R/root/.ssh/authorized_keys
  chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi
# The root field is locked. tsx-rescue-login sets the real login at boot.
if [ -n "${TSX_DEV_RESCUE_HASH:-}" ]; then
  case "$TSX_DEV_RESCUE_HASH" in \$6\$*) ;; *) echo "TSX_DEV_RESCUE_HASH is not a sha-512 crypt hash"; exit 1;; esac
  sed -i "s|^root:[^:]*:|root:$TSX_DEV_RESCUE_HASH:|" $R/etc/shadow
  echo "rescue root password: TSX_DEV_RESCUE_HASH (test build, do not publish)"
else
  sed -i "s|^root:[^:]*:|root:*:|" $R/etc/shadow
  echo "rescue root password: none (tsx-rescue-login chooses at boot)"
fi
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar
(cd $R && find . | cpio -o -H newc --quiet | gzip -9) > "$OUT"
ls -l "$OUT"
