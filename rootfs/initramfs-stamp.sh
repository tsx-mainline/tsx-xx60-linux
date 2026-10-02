#!/bin/sh
# Print the stamp of the rescue initramfs sources: one sha-256 over the
# content of every file that rootfs/initramfs/mkinitramfs-switchroot.sh puts
# into the image. The build writes the stamp into the image as
# /usr/share/tsx/initramfs.stamp. check-boot-images.py compares it with the
# stamp of this checkout. A boot image whose stamp differs was built from
# older (or other) sources.
# With TSX_FROM_PACKAGES=1 the initramfs gets the rescue tools, the splash and
# the board files from packages. The stamp then leaves out those source files.
# It covers initramfs/packages.pin instead, which names the exact package
# versions. A boot image made in one mode does not match the stamp of the
# other mode.
# Usage: initramfs-stamp.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
{
	if [ "${TSX_FROM_PACKAGES:-0}" = 1 ]; then
		find initramfs -type f ! -path initramfs/overlay/usr/sbin/tsx-rescue-status \
			! -path initramfs/overlay/usr/sbin/tsx-rescue-login ! -path initramfs/overlay/usr/sbin/tsx-confont
		for f in install.sh tsx-disk.sh; do
			echo "$f"
		done
	else
		find initramfs splash -type f
		for f in overlay/usr/local/lib/tsx/board.sh overlay/usr/local/bin/tsx-orientation \
			overlay/usr/local/sbin/tsx-boot-ok overlay/etc/tsx/uboot-env.conf \
			install.sh tsx-disk.sh src/tsx-splash.c; do
			echo "$f"
		done
	fi
} | LC_ALL=C sort | while read -r f; do
	printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
done | sha256sum | cut -d' ' -f1
