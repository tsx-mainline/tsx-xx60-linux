#!/bin/sh
# Print the stamp of the rescue initramfs sources: one sha-256 over the
# content of every file that rootfs/initramfs/mkinitramfs-switchroot.sh puts
# into the image from this checkout. The build writes the stamp into the image
# as /usr/share/tsx/initramfs.stamp. check-boot-images.py compares it with the
# stamp of this checkout. A boot image whose stamp differs was built from
# older (or other) sources.
# The initramfs gets the rescue tools, the splash and the board files from
# packages. The stamp leaves out those source files. It covers
# initramfs/packages.pin instead, which names the exact package versions. The
# stamp must stay the same until the next release of the kernel packages,
# because each kernel package carries an initramfs with this stamp. So do not
# change a file of rootfs/initramfs, install.sh or tsx-disk.sh without a new
# kernel package.
# Usage: initramfs-stamp.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
{
	find initramfs -type f ! -path initramfs/overlay/usr/sbin/tsx-rescue-status \
		! -path initramfs/overlay/usr/sbin/tsx-rescue-login ! -path initramfs/overlay/usr/sbin/tsx-confont
	for f in install.sh tsx-disk.sh; do
		echo "$f"
	done
} | LC_ALL=C sort | while read -r f; do
	printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
done | sha256sum | cut -d' ' -f1
