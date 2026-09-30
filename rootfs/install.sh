#!/bin/sh
# The xx60 kiosk installer. It runs on the panel, as root, in the rescue
# system (the rootfs switch_root initramfs or the rescue initramfs).
# deploy.sh normally drives it from the host. See REPORT.md "On-panel procedure".
#
#   install.sh check                       verify the disk layout, print what would happen
#   install.sh backup-p5head               write the first MiB of p5 to stdout
#   install.sh install [options]           format p5 and install the rootfs
#      --rootfs FILE|-        rootfs.tar.gz (- = stdin)                    (required)
#      --sha256 HEX           expected sha256 of the tarball               (required)
#      --p5-backup-sha256 HEX sha256 of the first MiB of p5 as backed up   (required)
#      --url URL              HA dashboard URL (default: rootfs kiosk.conf)
#      --token-file FILE      HA long-lived token, seeded at first kiosk start
#      --config-file FILE     panel.conf (installer/panel.conf.example). The
#                             installer seeds it as /etc/tsx/panel.conf.seed.
#                             tsx-config apply promotes it to
#                             /data/tsx/panel.conf on the first boot that has
#                             /data mounted. This card stage has no /data yet
#                             (see docs/rootfs.md).
#      --bootimg FILE         also copy the mainline boot image to FAT p1 as
#                             tsxboot.img (the golden boot.img stays as it is)
#      --bootimg-sha256 HEX   expected sha256 of --bootimg
#      --force-fs             allow a p5 filesystem other than ext2 "sdcard"/ext4 "tsxroot"
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tsx-disk.sh"
die() { echo "install.sh: ERROR: $*" >&2; exit 1; }
say() { echo "install.sh: $*" >&2; }

[ "$(id -u)" = 0 ] || die "run as root"
disk=$(tsx_find_disk) || die "no mmcblk device with the Crestron partition layout (see tsx-disk.sh). Does the kernel DT enable the SD controller?"
P1=/dev/${disk}p1 P5=/dev/${disk}p5
[ -b "$P5" ] || die "$P5 is not a block device"

p5_fs() { blkid -o export "$P5" 2>/dev/null | tr '\n' ' '; }
check() {
	say "boot disk: /dev/$disk (layout matches RUNBOOK), p5 = $P5"
	say "p5 now: $(p5_fs)"
	tsx_is_mounted "$P5" && die "$P5 is mounted"
	case "$(blkid -s TYPE -o value "$P5" 2>/dev/null):$(blkid -s LABEL -o value "$P5" 2>/dev/null)" in
	ext2:sdcard) say "p5 holds the Android sdcard fs (expected on first install)";;
	ext4:tsxroot) say "p5 already holds a tsxroot fs (re-install)";;
	*) [ "${FORCE_FS:-0}" = 1 ] || die "unexpected fs on p5: $(p5_fs) (use --force-fs)";;
	esac
	# Check that this is the rescue system. / must be the initramfs, not p5.
	[ "$(awk '$2=="/"{print $3}' /proc/mounts | tail -1)" = rootfs ] || say "WARNING: / is not the initramfs"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
check) check; say "check OK"; exit 0;;
backup-p5head) dd if="$P5" bs=1M count=1 2>/dev/null; exit 0;;
install) ;;
*) sed -n '2,23p' "$0"; exit 2;;
esac

ROOTFS= SHA= P5SHA= URL= TOKF= CONFF= BOOTIMG= BOOTSHA= FORCE_FS=0
while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) ROOTFS=$2; shift;;
	--sha256) SHA=$2; shift;;
	--p5-backup-sha256) P5SHA=$2; shift;;
	--url) URL=$2; shift;;
	--token-file) TOKF=$2; shift;;
	--config-file) CONFF=$2; shift;;
	--bootimg) BOOTIMG=$2; shift;;
	--bootimg-sha256) BOOTSHA=$2; shift;;
	--force-fs) FORCE_FS=1;;
	*) die "unknown option $1";;
	esac; shift
done
[ -n "$ROOTFS" ] && [ -n "$SHA" ] && [ -n "$P5SHA" ] || die "--rootfs, --sha256 and --p5-backup-sha256 are required"
check

# 1. The operator must hold a backup of the first MiB of p5 (deploy.sh pulls it).
now=$(dd if="$P5" bs=1M count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$now" = "$P5SHA" ] || die "first MiB of p5 ($now) does not match --p5-backup-sha256. Pull a fresh backup first"
say "p5 head backup verified ($now)"

# 2. The optional boot image goes to FAT p1 first. It is small and easy to verify.
if [ -n "$BOOTIMG" ]; then
	[ -n "$BOOTSHA" ] || die "--bootimg needs --bootimg-sha256"
	[ "$(sha256sum < "$BOOTIMG" | cut -d' ' -f1)" = "$BOOTSHA" ] || die "boot image sha256 mismatch"
	mkdir -p /mnt/p1; mount -t vfat "$P1" /mnt/p1 || die "mount $P1"
	[ -f /mnt/p1/boot.img ] || { umount /mnt/p1; die "no golden boot.img on $P1: wrong partition?"; }
	need=$(( $(stat -c %s "$BOOTIMG") / 1024 + 1024 )); free=$(df -k /mnt/p1 | awk 'NR==2{print $4}')
	old=0; [ -f /mnt/p1/tsxboot.img ] && old=$(( $(stat -c %s /mnt/p1/tsxboot.img) / 1024 ))
	[ $((free + old)) -gt $need ] || { umount /mnt/p1; die "not enough space on p1 (${free} KiB free)"; }
	gsha=$(sha256sum < /mnt/p1/boot.img | cut -d' ' -f1)
	# p1 (40 MiB) cannot hold two mainline images next to the golden one. On a
	# re-install, drop the old tsxboot.img first (found on the panel 2026-09-26).
	# Without that image, the U-Boot hook falls through to Android, so this is safe.
	if [ "$free" -le "$need" ] && [ "$old" -gt 0 ]; then
		say "not enough room for a side-by-side copy (${free} KiB free): removing the old p1:tsxboot.img first"
		rm -f /mnt/p1/tsxboot.img; sync
	fi
	cp "$BOOTIMG" /mnt/p1/tsxboot.new && sync
	[ "$(sha256sum < /mnt/p1/tsxboot.new | cut -d' ' -f1)" = "$BOOTSHA" ] || { rm -f /mnt/p1/tsxboot.new; umount /mnt/p1; die "copy to p1 corrupt"; }
	mv /mnt/p1/tsxboot.new /mnt/p1/tsxboot.img; rm -f /mnt/p1/tsxboot.off; sync
	[ "$(sha256sum < /mnt/p1/boot.img | cut -d' ' -f1)" = "$gsha" ] || say "WARNING: golden boot.img changed?!"
	umount /mnt/p1
	say "boot image installed as p1:tsxboot.img (golden boot.img untouched, sha $gsha)"
fi

# 3. Format p5 and extract the tarball. Check the tarball hash on the fly.
say "mkfs.ext4 -L tsxroot $P5"
# Do not use metadata_csum_seed or orphan_file. The vendor 3.10 kernel rejects them.
mkfs.ext4 -F -q -O ^metadata_csum_seed,^orphan_file -L tsxroot -m 1 "$P5"
mkdir -p /mnt/tsxroot; mount -t ext4 "$P5" /mnt/tsxroot
T=$(mktemp -d); mkfifo "$T/f"
sha256sum < "$T/f" | cut -d' ' -f1 > "$T/sum" &
say "extracting rootfs"
if [ "$ROOTFS" = - ]; then tee "$T/f" | tar -C /mnt/tsxroot -xzf -; else tee "$T/f" < "$ROOTFS" | tar -C /mnt/tsxroot -xzf -; fi
wait
got=$(cat "$T/sum")
if [ "$got" != "$SHA" ]; then
	rm -f /mnt/tsxroot/sbin/init; umount /mnt/tsxroot
	die "rootfs sha256 mismatch ($got): removed /sbin/init so the initramfs stays in rescue"
fi
say "rootfs extracted, sha256 OK"

# 4. Configure the rootfs.
R=/mnt/tsxroot
kver=$(uname -r)
[ -d "$R/lib/modules/$kver" ] || say "WARNING: rootfs has no modules for the running kernel $kver ($(ls $R/lib/modules 2>/dev/null | tr '\n' ' ')). touch/backlight/lima modules will not load"
[ -n "$URL" ] && sed -i "s|^KIOSK_URL=.*|KIOSK_URL=\"$URL\"|" $R/etc/kiosk.conf
if [ -n "$TOKF" ]; then install -m 600 "$TOKF" $R/var/lib/kiosk/pending-token; chown 0:0 $R/var/lib/kiosk/pending-token; fi
if [ -n "$CONFF" ]; then
	mkdir -p $R/etc/tsx
	install -m 600 "$CONFF" $R/etc/tsx/panel.conf.seed
	say "panel.conf seeded as /etc/tsx/panel.conf.seed (promoted to /data/tsx/panel.conf by tsx-config apply once /data exists)"
fi
p1uuid=$(blkid -s UUID -o value "$P1")
[ -n "$p1uuid" ] && echo "UUID=$p1uuid  /media/bootfat  vfat  noauto,rw,noatime,umask=022  0 0" >> $R/etc/fstab && mkdir -p $R/media/bootfat
if [ -s /root/.ssh/authorized_keys ]; then mkdir -p $R/root/.ssh; cat /root/.ssh/authorized_keys >> $R/root/.ssh/authorized_keys; chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys; fi
mkdir -p $R/var/lib/tsx
{ echo "installed=$(date -Iseconds 2>/dev/null || date)"; echo "disk=/dev/$disk"; echo "rootfs_sha256=$SHA"
  echo "p5_head_backup_sha256=$P5SHA"; echo "kernel_at_install=$kver"; [ -n "$BOOTIMG" ] && echo "bootimg_sha256=$BOOTSHA"; } > $R/var/lib/tsx/install.info
sync; umount /mnt/tsxroot
say "done. p5 = tsxroot. Next: U-Boot must boot the mainline image (REPORT.md, 'Boot image location')."
