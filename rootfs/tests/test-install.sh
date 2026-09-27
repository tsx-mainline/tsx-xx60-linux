#!/bin/bash
# Host end-to-end test of install.sh / uninstall.sh on a loop device with the
# exact Crestron MBR (tests/crestron-mbr.sfdisk, from the 2026-09-25 backup).
# Needs docker --privileged (losetup). Uses a sparse 3.7 GiB file in $TMPDIR.
# Usage: tests/test-install.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=${TMPDIR:-/tmp}/tsx-install-test; rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
docker run --rm --privileged --platform linux/amd64 -v "$HERE:/rootfs:ro" -v "$W:/w" alpine:3.24 sh -euc '
apk add -q --no-cache sfdisk e2fsprogs e2fsprogs-extra dosfstools blkid util-linux-misc losetup >/dev/null
for i in $(seq 0 63); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
truncate -s $((7774208 * 512)) /w/disk.img
sfdisk -q /w/disk.img < /rootfs/tests/crestron-mbr.sfdisk
L=$(losetup -P -f --show /w/disk.img); n=${L#/dev/}
trap "umount /mnt/p1 /mnt/tsxroot 2>/dev/null; losetup -d $L" EXIT
sleep 1
for p in /sys/block/$n/${n}p*; do b=${p##*/}; [ -b /dev/$b ] || mknod /dev/$b b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev); done
mkfs.vfat -F 16 /dev/${n}p1 >/dev/null
mkdir -p /mnt/p1; mount /dev/${n}p1 /mnt/p1; head -c 8700000 /dev/urandom > /mnt/p1/boot.img; G=$(sha256sum < /mnt/p1/boot.img); umount /mnt/p1
mkfs.ext2 -q -F -L sdcard -U 2bf7e68f-89fa-40d2-9929-eb4a022e01b3 -b 4096 /dev/${n}p5
export TSX_DISK_GLOB=/sys/block/$n
I=/rootfs/install.sh; U=/rootfs/uninstall.sh
ok() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

echo "== check"; $I check
echo "== layout mismatch is refused"
TSX_DISK_GLOB=/sys/block/loopnone $I check 2>/dev/null && fail "accepted a missing disk" || ok "missing disk refused"

$I backup-p5head > /w/p5head.img; P5SHA=$(sha256sum < /w/p5head.img | cut -d" " -f1)
[ $(stat -c %s /w/p5head.img) = 1048576 ] && ok "p5 head backup 1 MiB"
SHA=$(sha256sum < /rootfs/out/rootfs.tar.gz | cut -d" " -f1)
head -c 18000000 /dev/urandom > /w/boot.img; BSHA=$(sha256sum < /w/boot.img | cut -d" " -f1)
echo "eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJ0ZXN0In0.c2lnbmF0dXJlX3Rlc3Q" > /w/token

echo "== wrong p5 backup sha is refused"
$I install --rootfs - --sha256 $SHA --p5-backup-sha256 0000 < /rootfs/out/rootfs.tar.gz 2>/dev/null && fail "accepted" || ok refused
blkid /dev/${n}p5 | grep -q sdcard && ok "p5 untouched"

echo "== install"
time $I install --rootfs - --sha256 $SHA --p5-backup-sha256 $P5SHA --url https://example.test:8123/lovelace/0 \
	--token-file /w/token --bootimg /w/boot.img --bootimg-sha256 $BSHA < /rootfs/out/rootfs.tar.gz
blkid /dev/${n}p5 | grep -q "LABEL=\"tsxroot\"" && ok "p5 label tsxroot"
F=$(dumpe2fs -h /dev/${n}p5 2>/dev/null | sed -n "s/^Filesystem features: *//p"); echo "    p5 features: $F"
[ -n "$F" ] || fail "no ext4 feature list (dumpe2fs)"
echo " $F " | grep -qE " (metadata_csum_seed|orphan_file) " && fail "p5 has metadata_csum_seed/orphan_file" || ok "p5 without metadata_csum_seed/orphan_file"
mkdir -p /mnt/tsxroot; mount /dev/${n}p5 /mnt/tsxroot
[ -L /mnt/tsxroot/sbin/init ] || [ -x /mnt/tsxroot/sbin/init ] && ok "/sbin/init present"
grep -q "^KIOSK_URL=\"https://example.test:8123/lovelace/0\"" /mnt/tsxroot/etc/kiosk.conf && ok "URL set"
[ "$(stat -c %a /mnt/tsxroot/var/lib/kiosk/pending-token)" = 600 ] && ok "token staged (0600)"
grep -q "/media/bootfat" /mnt/tsxroot/etc/fstab && ok "fstab has p1"
cat /mnt/tsxroot/var/lib/tsx/install.info | sed "s/^/    /"
df -m /mnt/tsxroot | awk "NR==2{print \"    p5 used \" \$3 \" MiB of \" \$2 \" MiB\"}"
umount /mnt/tsxroot
mount /dev/${n}p1 /mnt/p1
[ "$(sha256sum < /mnt/p1/tsxboot.img | cut -d" " -f1)" = $BSHA ] && ok "p1:tsxboot.img written"
[ "$(sha256sum < /mnt/p1/boot.img)" = "$G" ] && ok "golden boot.img unchanged"
umount /mnt/p1

echo "== corrupt tarball hash leaves the fs unbootable (rescue)"
$I install --rootfs - --sha256 deadbeef --p5-backup-sha256 $($I backup-p5head | sha256sum | cut -d" " -f1) < /rootfs/out/rootfs.tar.gz 2>/dev/null && fail "accepted bad sha" || true
mount /dev/${n}p5 /mnt/tsxroot; [ ! -e /mnt/tsxroot/sbin/init ] && ok "/sbin/init removed"; umount /mnt/tsxroot

echo "== uninstall --p5-mkfs"
$U --p5-mkfs
blkid /dev/${n}p5 | grep -q "LABEL=\"sdcard\"" && blkid /dev/${n}p5 | grep -q 2bf7e68f && ok "p5 is ext2 sdcard with original UUID"
mount /dev/${n}p1 /mnt/p1; [ ! -e /mnt/p1/tsxboot.img ] && ok "tsxboot.img removed"; [ "$(sha256sum < /mnt/p1/boot.img)" = "$G" ] && ok "golden intact"; umount /mnt/p1
echo "== uninstall --p5-image (restore the saved head into a full image)"
dd if=/dev/zero of=/w/p5full.img bs=512 count=0 seek=3055616 2>/dev/null; dd if=/w/p5head.img of=/w/p5full.img conv=notrunc 2>/dev/null
$U --p5-image /w/p5full.img
[ "$(dd if=/dev/${n}p5 bs=1M count=1 2>/dev/null | sha256sum | cut -d" " -f1)" = $P5SHA ] && ok "p5 restored byte-exact (head)"
echo "PASS install/uninstall"
'
