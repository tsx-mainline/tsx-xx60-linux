#!/bin/sh
# Re-syncs the installer stage-2 tool set (tsx-autoinstall incl. the R1 p4
# order, the factory restore tsx-factory-restore + crestron-fs.sh, and the
# shared tsx-lib.sh) from their canonical source
# locations (this dir, installer/android, installer/factory)
# into the rootfs switch_root initramfs overlay, in case any of them was
# edited without re-copying. Idempotent: safe to run again.
# Then rebuild: tools/build/remote-build.sh initramfs (or
# rootfs/tests/qemu/mkinitramfs.sh here) and the boot image (rootfs/mkbootimg.sh,
# or installer/initramfs/repack-bootimg.py here to keep a given kernel + DTB
# byte-identical).
#   integrate.sh [--check]     --check only reports which files are out of sync
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOTFS_DIR=$(cd "$HERE/../../rootfs" && pwd)
if [ "${1:-}" = --check ]; then
	for p in usr/sbin/tsx-autoinstall=tsx-autoinstall usr/share/tsx/tsx-lib.sh=../android/tsx-lib.sh usr/sbin/tsx-factory-restore=../factory/tsx-factory-restore usr/share/tsx/crestron-fs.sh=../factory/crestron-fs.sh; do
		f=${p%%=*}; cmp -s "$ROOTFS_DIR/initramfs/overlay/$f" "$HERE/${p#*=}" && echo "overlay/$f up to date" || echo "overlay/$f MISSING or differs"
	done
	exit 0
fi
install -D -m 755 "$HERE/tsx-autoinstall" "$ROOTFS_DIR/initramfs/overlay/usr/sbin/tsx-autoinstall"
install -D -m 644 "$HERE/../android/tsx-lib.sh" "$ROOTFS_DIR/initramfs/overlay/usr/share/tsx/tsx-lib.sh"
install -D -m 755 "$HERE/../factory/tsx-factory-restore" "$ROOTFS_DIR/initramfs/overlay/usr/sbin/tsx-factory-restore"   # factory restore from the .puf
install -D -m 644 "$HERE/../factory/crestron-fs.sh" "$ROOTFS_DIR/initramfs/overlay/usr/share/tsx/crestron-fs.sh"
echo "synced; rebuild the initramfs and the boot image"
