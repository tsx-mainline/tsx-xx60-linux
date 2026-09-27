#!/bin/sh
# ON THE PANEL (mainline kiosk booted from the SD card with the mainline kernel):
# make the eMMC root and boot partition. Idempotent enough to re-run.
#   sh migrate-to-emmc.sh /data/tmp/tsxboot-emmc.img SHA256
set -eu
IMG=$1 SHA=$2 ROOT=/dev/mmcblk1p8 BOOT=/dev/mmcblk1p7 M=/data/mnt/emmc S=/data/mnt/rootsrc
say() { echo "migrate: $(date +%T) $*"; }
[ "$(sha256sum < "$IMG" | cut -d' ' -f1)" = "$SHA" ] || { echo "image sha mismatch"; exit 1; }
# leftovers of an interrupted run of this script
grep -q " $S " /proc/mounts && umount "$S"
grep -q "^$ROOT $M " /proc/mounts && umount "$M"
grep -q " $ROOT \| $BOOT " /proc/mounts && { echo "$ROOT or $BOOT mounted"; exit 1; }
[ "$(cat /sys/class/block/mmcblk1p8/size)" = 6004736 ] || { echo "unexpected p8 size"; exit 1; }
say "discarding Android cache (p3) and recovery (p5)"
blkdiscard /dev/mmcblk1p3 2>&1 || say "blkdiscard p3 failed (continuing)"
blkdiscard /dev/mmcblk1p5 2>&1 || say "blkdiscard p5 failed (continuing)"
say "mkfs.ext4 -L tsxroot-emmc $ROOT"
mkfs.ext4 -F -q -L tsxroot-emmc "$ROOT"
mkdir -p "$M"; mount "$ROOT" "$M"
say "stopping the kiosk for a consistent profile copy"
rc-service kiosk stop >/dev/null 2>&1 || true
say "copying the root filesystem"
cd /
# copy from a plain (non-recursive) bind of / : the SD root as it is, WITHOUT the tsx-data
# bind mounts from /data on top (var/log, var/lib/kiosk, root, ...), which stay on /data
mkdir -p "$S"; mount --bind / "$S"
for d in bin etc lib media opt sbin srv usr var root home; do [ -e "$S/$d" ] && cp -a "$S/$d" "$M/"; done
umount "$S"
for d in data dev proc sys run tmp mnt; do mkdir -p "$M/$d"; done; chmod 1777 "$M/tmp"
# state that tsx-data bind-mounts from /data at boot: leave the mount points empty on the new root
for d in var/log var/lib/tsx var/lib/sendspin root home; do rm -rf "$M/$d"; mkdir -p "$M/$d"; done
# the live Chromium profile (HA login): on a root without tsx-data binds it is on the SD root, so
# make /data's copy current (tsx-data's bind shows it from the next boot); when /var/lib/kiosk is
# already bound from /data (rootfs with tsx-data, 2026-09-27) the two are the SAME directory:
# nothing to do (the old unconditional "rm -rf /data/var/lib/kiosk/*" deleted the live profile)
if grep -q " /var/lib/kiosk " /proc/mounts; then say "Chromium profile already on /data (bind mount), not copied"
else
	rm -rf /data/var/lib/kiosk.new; mkdir -p /data/var/lib/kiosk.new; cp -a /var/lib/kiosk/. /data/var/lib/kiosk.new/
	rm -rf /data/var/lib/kiosk; mv /data/var/lib/kiosk.new /data/var/lib/kiosk; chown -R kiosk:kiosk /data/var/lib/kiosk
fi
sed -i 's#^LABEL=tsxroot  *#LABEL=tsxroot-emmc   #' "$M/etc/fstab"; grep -n "tsxroot" "$M/etc/fstab"
{ echo "root=emmc"; echo "migrated=$(date -Iseconds) from /dev/mmcblk0p2 by migrate-to-emmc.sh"; echo "boot_partition=$BOOT image_sha256=$SHA"; } > "$M/etc/tsx/emmc-root.info"
sync; df -k "$M" | tail -1; umount "$M"
say "fsck of the new root"; e2fsck -fn "$ROOT" 2>&1 | tail -1
say "writing $IMG into $BOOT (32 MiB partition)"
dd if="$IMG" of="$BOOT" bs=1M conv=fsync 2>&1 | tail -1
sync; echo 3 > /proc/sys/vm/drop_caches
got=$(dd if="$BOOT" bs=1M count=$(( ( $(stat -c %s "$IMG") + 1048575 ) / 1048576 )) 2>/dev/null | head -c "$(stat -c %s "$IMG")" | sha256sum | cut -d' ' -f1)
[ "$got" = "$SHA" ] && say "boot partition verified ($got)" || { say "BOOT READBACK MISMATCH $got"; exit 1; }
rc-service kiosk start >/dev/null 2>&1 || true
say "done: next boot with p1:tsxboot.off takes the stock path (eMMC boot partition) and the initramfs picks LABEL=tsxroot-emmc"
