#!/bin/sh
# xx60 kiosk uninstaller. Runs ON THE PANEL in the rescue system (boot it
# from the kiosk with: touch /etc/tsx/force-rescue; reboot), as root.
#
#   uninstall.sh [--p5-image FILE|-] [--p5-mkfs] [--keep-bootimg]
#
#   (default)        remove p1:tsxboot.img, so U-Boot's hook (if installed)
#                    falls through to the stock Android boot. p5 is left as is.
#   --p5-image F|-   restore p5 from a full partition image (exactly
#                    3055616 sectors), e.g. the slice of the 2026-09-25 backup:
#                    host: dd if=tsw1060-mmcblk0.img bs=512 skip=1847297 count=3055616
#   --p5-mkfs        recreate an empty ext2 "sdcard" fs with the original UUID
#                    (Android recreates its folders; the two raw images that
#                    lived there, update boot.img + golden copy, are gone)
#   --keep-bootimg   leave tsxboot.img, just disable it (p1:tsxboot.off)
# Afterwards revert the U-Boot env (REPORT.md "Revert"), then power-cycle.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tsx-disk.sh"
die() { echo "uninstall.sh: ERROR: $*" >&2; exit 1; }
say() { echo "uninstall.sh: $*" >&2; }
[ "$(id -u)" = 0 ] || die "run as root"
disk=$(tsx_find_disk) || die "no mmcblk device with the Crestron partition layout"
P1=/dev/${disk}p1 P5=/dev/${disk}p5
IMG= MKFS=0 KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--p5-image) IMG=$2; shift;;
	--p5-mkfs) MKFS=1;;
	--keep-bootimg) KEEP=1;;
	*) die "unknown option $1";;
	esac; shift
done
tsx_is_mounted "$P5" && die "$P5 is mounted (boot the rescue system first)"

mkdir -p /mnt/p1; mount -t vfat "$P1" /mnt/p1 || die "mount $P1"
[ -f /mnt/p1/boot.img ] || say "WARNING: no golden boot.img on p1"
if [ $KEEP = 1 ]; then touch /mnt/p1/tsxboot.off; say "p1:tsxboot.off created (mainline disabled)"
else rm -f /mnt/p1/tsxboot.img /mnt/p1/tsxboot.new /mnt/p1/tsxboot.off; say "p1:tsxboot.img removed"; fi
sync; umount /mnt/p1

if [ -n "$IMG" ]; then
	want=$((TSX_P5_SECTORS * 512))
	say "restoring $P5 from ${IMG} ($want bytes)"
	if [ "$IMG" = - ]; then dd of="$P5" bs=1M conv=fsync 2>/tmp/dd.log; else
		[ "$(stat -c %s "$IMG")" = "$want" ] || die "image size is not $want"
		dd if="$IMG" of="$P5" bs=1M conv=fsync 2>/tmp/dd.log; fi
	got=$(grep -o '^[0-9]* bytes' /tmp/dd.log | cut -d' ' -f1)
	[ -z "$got" ] || [ "$got" = "$want" ] || die "wrote $got bytes, expected $want"
	say "p5 restored: $(blkid -o export "$P5" | tr '\n' ' ')"
elif [ $MKFS = 1 ]; then
	mkfs.ext2 -F -q -L sdcard -U 2bf7e68f-89fa-40d2-9929-eb4a022e01b3 -b 4096 "$P5"
	say "p5 = empty ext2 sdcard"
else
	say "p5 left as is ($(blkid -o export "$P5" | tr '\n' ' '))"
fi
cat >&2 <<'T'
uninstall.sh: if the U-Boot hook was installed, revert it at the U-Boot prompt
  (serial; uboot/tsx-boot-hook.txt, REPORT.md "Revert"):
    setenv switch_bootmode 'usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;'
    setenv tsx_boot
    saveenv
  Without the revert the hook finds no tsxboot.img and Android boots anyway.
T
