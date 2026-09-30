#!/bin/bash
# Host end-to-end test of the Android installer on a loop device. The device
# has the exact Crestron MBR (rootfs/tests/crestron-mbr.sfdisk). It also has
# the REAL stock U-Boot env block of the TSW-1060 at 0x100000
# (captures/.../tsw1060-mmcblk0p3-env.img, taken 2026-09-25 before the hook).
#
# Stage 1 (tsx-android-install.sh) runs under the STOCK Android /system/bin/bash
# 3.2. The bash is the ARM binary from system.img, run through qemu-user
# binfmt. Two tools are stand-ins. The busybox is the Alpine one
# (check-android-tools.sh checks the stock applet set). fw_printenv and
# fw_setenv come from u-boot-tools, because the stock ones are bionic
# binaries that do not run under qemu-user.
# The mainline initramfs (tsx-autoinstall) runs under Alpine busybox sh with
# rootfs/install.sh. The test also runs that path directly, independent of
# tsx-android-install.sh. It covers the tsx-install/GO reinstall and the U-Boot
# jabil boot triggers, which do not go through the Android-side script.
# The payloads are small fakes built here: a rootfs tarball, a boot image
# whose ramdisk contains usr/sbin/tsx-autoinstall, and a p5-sized ext4 image.
# The test needs docker --privileged (losetup) and about 20 s.
# Usage: tests/test-android-install.sh
set -euo pipefail
INSTALLER_DIR=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS_DIR=$(cd "$INSTALLER_DIR/../rootfs" && pwd)
CAPTURES=${CAPTURES_DIR:-}
SYSIMG=${SYSIMG:-}   # required: the real Crestron system.img (no default here)
ENVIMG=$CAPTURES/tsw-1060/backup/tsw1060-mmcblk0p3-env.img
if [ -z "$CAPTURES" ] || [ ! -f "$ENVIMG" ] || [ ! -f "$SYSIMG" ]; then
	echo "SKIPPED: needs the real stock U-Boot env capture (CAPTURES_DIR) and the Crestron system.img (SYSIMG). Not present here"
	exit 0
fi
W=${TMPDIR:-/tmp}/tsx-android-install-test; rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT

# ---- host side: stock bash, fake payloads, the stick contents (mkpayload)
debugfs -R "dump /bin/bash $W/android-bash" "$SYSIMG" >/dev/null 2>&1; chmod 755 "$W/android-bash"
dd if="$ENVIMG" of="$W/env-stock.bin" bs=65536 count=1 2>/dev/null
mkdir -p "$W/fr/etc/tsx" "$W/fr/sbin" "$W/fr/var/lib/kiosk"
echo "ENV_VERIFIED=yes" > "$W/fr/etc/tsx/uboot-env.conf"
echo 'KIOSK_URL="https://ha.example"' > "$W/fr/etc/kiosk.conf"; echo 3.24.2 > "$W/fr/etc/alpine-release"
: > "$W/fr/etc/fstab"; printf '#!/bin/sh\n' > "$W/fr/sbin/init"; chmod 755 "$W/fr/sbin/init"
tar -C "$W/fr" -czf "$W/rootfs.tar.gz" .
mkdir -p "$W/rd/usr/sbin"; cp "$INSTALLER_DIR/initramfs/tsx-autoinstall" "$W/rd/usr/sbin/"
(cd "$W/rd" && find . | cpio -o -H newc --quiet | gzip -9) > "$W/rd.gz"
mkdir -p "$W/rdr/etc/tsx"; echo test > "$W/rdr/etc/tsx/rescue-image"; (cd "$W/rdr" && find . | cpio -o -H newc --quiet | gzip -9) > "$W/rdr.gz"
for out in tsxboot.img:rd rescue.img:rdr; do python3 - "$W/${out#*:}.gz" "$W/${out%:*}" <<'PY'
import struct, sys, os
rd = open(sys.argv[1], 'rb').read(); k = os.urandom(5000); ps = 2048
pad = lambda b: b + b'\0' * ((-len(b)) % ps)
hdr = b'ANDROID!' + struct.pack('<8I', len(k), 0x208000, len(rd), 0x1000000, 0, 0xf00000, 0x100, ps)
open(sys.argv[2], 'wb').write(pad(hdr) + pad(k) + pad(rd))
PY
done
mkdir -p "$W/stick"
truncate -s 16M "$W/p2.ext4"; mkfs.ext4 -q -F -L tsxroot "$W/p2.ext4"; P2SHA=$(sha256sum < "$W/p2.ext4" | cut -d" " -f1)   # stand-in for out/rootfs-p2.ext4
TOKEN=$W/token.txt; echo "eyJ0ZXN0IjoxfQ.token" > "$TOKEN"
"$INSTALLER_DIR/payload/mkpayload" --out "$W/stick" --rootfs "$W/rootfs.tar.gz" --bootimg-tsw1060 "$W/tsxboot.img" \
	--rescue-tsw1060 "$W/rescue.img" --rootfs-p2 "$W/p2.ext4" --url https://ha.test/lovelace/0 --token-file "$TOKEN" 2>&1 | sed 's/^/  host: /'

docker run --rm --privileged --platform linux/amd64 -v "$INSTALLER_DIR:/installer:ro" -v "$ROOTFS_DIR:/rootfs:ro" -v "$W:/w" \
	-e P2SHA="$P2SHA" alpine:3.24 sh -euc '
apk add -q --no-cache sfdisk e2fsprogs e2fsprogs-extra dosfstools blkid util-linux-misc losetup u-boot-tools bash python3 mtools coreutils >/dev/null
for i in $(seq 0 63); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
truncate -s $((7774208 * 512)) /w/disk.img
sfdisk -q /w/disk.img < /rootfs/tests/crestron-mbr.sfdisk
L=$(losetup -P -f --show /w/disk.img); n=${L#/dev/}
S=$(losetup -f --show /w/stick.img 2>/dev/null || true)
cleanup() { rm -rf /w/disk.img.sha256; umount /mnt/media_rw/udisk0 /mnt/sdcard/x /mnt/extsd /mnt/sdcard 2>/dev/null || true; umount /mnt/media_rw/udisk0 2>/dev/null || true; losetup -d $L; [ -n "${SL:-}" ] && losetup -d $SL; true; }
trap cleanup EXIT
sleep 1
for p in /sys/block/$n/${n}p*; do b=${p##*/}; [ -b /dev/$b ] || mknod /dev/$b b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev); done
dd if=/w/env-stock.bin of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null
mkfs.vfat -F 16 /dev/${n}p1 >/dev/null
mkdir -p /mnt/p1; mount /dev/${n}p1 /mnt/p1
{ printf "ANDROID!"; head -c 8300000 /dev/urandom; } > /mnt/p1/boot.img; G=$(sha256sum < /mnt/p1/boot.img); cp /mnt/p1/boot.img /tmp/golden.img; umount /mnt/p1
mkfs.ext2 -q -F -L sdcard -U 2bf7e68f-89fa-40d2-9929-eb4a022e01b3 -b 4096 /dev/${n}p5
mkdir -p /mnt/sdcard /mnt/extsd; mount /dev/${n}p5 /mnt/sdcard; mkdir -p /mnt/sdcard/ROMDISK/user; echo project > /mnt/sdcard/ROMDISK/user/p.vtz
# the stick: FAT32 image with the mkpayload output, mounted where vold puts it
truncate -s 1G /w/stick.img; mkfs.vfat -F 32 /w/stick.img >/dev/null; SL=$(losetup -f --show /w/stick.img)
mkdir -p /mnt/media_rw/udisk0; mount -t vfat $SL /mnt/media_rw/udisk0; cp -r /w/stick/. /mnt/media_rw/udisk0/; sync
# Android stand-ins
echo "$L 0x100000 0x10000" > /etc/fw_env.config
mkdir -p /fwa /system/bin; cp /w/android-bash /system/bin/bash
printf "#!/bin/sh\nexec /usr/bin/fw_printenv -c /etc/fw_env.config \"\$@\"\n" > /fwa/fw_printenv
printf "#!/bin/sh\nexec /usr/bin/fw_setenv -c /etc/fw_env.config \"\$@\"\n" > /fwa/fw_setenv; chmod 755 /fwa/*
export TSX_BB=/bin/busybox TSX_FWENV=/fwa/fw_printenv TSX_SYSBLOCK=/sys/block/$n TSX_DEVDIR=/dev TSX_WORKDIR=/tmp/tsxinst LC_ALL=C
AI="/system/bin/bash /mnt/media_rw/udisk0/tsx-install/android/tsx-android-install.sh"
AU="/system/bin/bash /mnt/media_rw/udisk0/tsx-install/android/tsx-android-uninstall.sh"
FP="/usr/bin/fw_printenv -c /etc/fw_env.config"
ok() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }
envhash() { $FP | grep -v "^boot_retry=\|^golden_boot_retry=" | sha256sum; }
STOCK_SW=$($FP -n switch_bootmode)
echo "== stock bash: $(/system/bin/bash --version | head -1)"

echo "== 1. preflight (read only)"
H0=$(dd if=$L bs=1M count=8 2>/dev/null | sha256sum)
$AI preflight > /tmp/pf.txt 2>&1 || { cat /tmp/pf.txt; fail preflight; }
grep -q "preflight OK" /tmp/pf.txt && ok "preflight OK"; grep -E "  (ok|FAIL) " /tmp/pf.txt | sed "s/^tsx-install: /    /"
[ "$(dd if=$L bs=1M count=8 2>/dev/null | sha256sum)" = "$H0" ] && ok "preflight wrote nothing (first 8 MiB unchanged)"

echo "== 2. refusals"
TSX_SYSBLOCK=/sys/block/loopnone $AI preflight >/dev/null 2>&1 && fail "accepted a missing disk" || ok "wrong/missing disk layout refused"
cp /w/env-stock.bin /tmp/e; printf "X" | dd of=$L bs=1 seek=$((0x100000 + 100)) conv=notrunc 2>/dev/null
$AI preflight > /tmp/r.txt 2>&1 && fail "accepted a bad env CRC" || { grep -q "CRC" /tmp/r.txt && ok "bad env CRC refused"; }
dd if=/w/env-stock.bin of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null
/usr/bin/fw_setenv -c /etc/fw_env.config lcdsize 7inch
$AI preflight > /tmp/r.txt 2>&1 && fail "accepted a model mismatch" || { grep -q "unknown model" /tmp/r.txt && ok "model mismatch (lcdsize 7inch on a TSW-1060 env) refused"; }
dd if=/w/env-stock.bin of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null
/usr/bin/fw_setenv -c /etc/fw_env.config switch_bootmode "usb start 0;run something_else"
$AI preflight > /tmp/r.txt 2>&1 && fail "accepted a foreign switch_bootmode" || ok "foreign switch_bootmode refused"
dd if=/w/env-stock.bin of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null
R=/mnt/media_rw/udisk0/tsx-install/rootfs.tar.gz; SZ=$(stat -c %s $R); printf x >> $R
$AI preflight > /tmp/r.txt 2>&1 && fail "accepted a corrupt payload" || { grep -q "payload corrupt" /tmp/r.txt && ok "corrupt stick payload refused"; }
truncate -s $SZ $R
[ "$(dd if=$L bs=1M count=8 2>/dev/null | sha256sum)" = "$H0" ] && ok "disk head back to the start state"
$AI install --direct-p5 --yes --no-reboot > /tmp/d1.txt 2>&1 && fail "--direct-p5 accepted" || { grep -q "was removed" /tmp/d1.txt && ok "--direct-p5 refused"; }
[ "$(dd if=$L bs=1M count=8 2>/dev/null | sha256sum)" = "$H0" ] && ok "refusal wrote nothing"

echo "== 3. stage-2 order written directly (e.g. by a network deploy tool), not by tsx-android-install.sh"
mkdir -p /share; cp /installer/android/tsx-lib.sh /rootfs/install.sh /rootfs/tsx-disk.sh /share/
echo "rootfstype=ramfs init=/init console=ttyAML0" > /tmp/cmdline
export TSX_SHARE=/share TSX_STICK=/mnt/media_rw/udisk0 TSX_NO_REBOOT=1 TSX_CMDLINE=/tmp/cmdline TSX_DT_MODEL="Crestron TSW-1060" TSX_RUN=/tmp/run
AUTO="sh /installer/initramfs/tsx-autoinstall"
mkdir -p /mnt/p1w; mount -o rw /dev/${n}p1 /mnt/p1w
{ echo "# written directly, not by tsx-android-install.sh. Read by tsx-autoinstall in the mainline initramfs"
  echo "SOURCE=usb"; echo "MODEL=tsw1060"; echo "UNIT=test"; echo "BOOTIMG_SHA256=$(sha256sum < /w/tsxboot.img | cut -d" " -f1)"; echo "ANDROID_BACKUP=/tmp"; } > /mnt/p1w/tsxinst.cfg
umount /mnt/p1w
$AUTO > /tmp/s2.txt 2>&1 || { cat /tmp/s2.txt /tmp/run/tsx-autoinstall.log; fail "stage 2"; }
grep "tsx-autoinstall:" /tmp/s2.txt | sed "s/^/    /" | head -12
blkid /dev/${n}p5 | grep -q "LABEL=\"tsxroot\"" && ok "p5 = ext4 tsxroot"
mkdir -p /mnt/r; mount -o ro /dev/${n}p5 /mnt/r
[ -x /mnt/r/sbin/init ] && grep -q "ha.test/lovelace/0" /mnt/r/etc/kiosk.conf && [ -s /mnt/r/var/lib/kiosk/pending-token ] && ok "rootfs extracted, KIOSK_URL + token from the stick"
umount /mnt/r
mount -o ro /dev/${n}p1 /mnt/p1; [ -f /mnt/p1/tsxinst.done ] && [ ! -f /mnt/p1/tsxinst.cfg ] && ok "p1:tsxinst.cfg consumed (tsxinst.done)"; umount /mnt/p1
ls -d /mnt/media_rw/udisk0/tsx-install/backup/*-mainline >/dev/null && ls /mnt/media_rw/udisk0/tsx-install/log/*autoinstall.log >/dev/null && ok "stage 2 backup + log on the stick"
[ "$($FP -n switch_bootmode)" = "${STOCK_SW}if itest \${boot_retry} -lt 6; then run tsx_boot; fi" ] && ok "hook installed by stage 2 (fallback variant)"

echo "== 4. stage 2 with no trigger does nothing"
P5H=$(dd if=/dev/${n}p5 bs=1M count=4 2>/dev/null | sha256sum)
$AUTO > /tmp/s3.txt 2>&1 && [ "$(dd if=/dev/${n}p5 bs=1M count=4 2>/dev/null | sha256sum)" = "$P5H" ] && ok "exit 0, p5 untouched (stick present, no GO, no tsxinst.cfg)"

echo "== 4b. no order: the USB wait (option 3: the LED bar in the socket ends it at once)"
mkusb() { rm -rf /tmp/usb; mkdir -p /tmp/usb; for d in "$@"; do set -- $(echo $d | tr ":" " "); mkdir -p /tmp/usb/$1 /tmp/usb/$1:1.0
	echo $2 > /tmp/usb/$1/idVendor; echo $3 > /tmp/usb/$1/idProduct; echo $4 > /tmp/usb/$1/bDeviceClass; echo $5 > /tmp/usb/$1:1.0/bInterfaceClass; done; }
uw() { rm -f /tmp/run/tsx-autoinstall.log; a=$(cut -d" " -f1 /proc/uptime); env -u TSX_STICK TSX_USB_SYSFS=/tmp/usb TSX_STICK_WAIT=0 $AUTO >/dev/null 2>&1; r=$?
	b=$(cut -d" " -f1 /proc/uptime); EL=$(awk -v a=$a -v b=$b "BEGIN{printf \"%.1f\", b-a}"); LAST=$(tail -n 1 /tmp/run/tsx-autoinstall.log 2>/dev/null); return $r; }
long() { awk -v e=$EL "BEGIN{exit !(e >= 1.9)}"; }   # the cap is 3 s in whole uptime seconds = 2..3 s
mkusb; uw && long && echo "$LAST" | grep -q "no mass storage" && ok "nothing in the socket: full wait (${EL} s), exit 0"
mkusb 1-1:14be:001b:00:ff; uw && ! long && echo "$LAST" | grep -q "LED bar in the socket" && ok "LED bar 14be:001b in the socket: wait ends at once (${EL} s)"
mkusb 1-1:05e3:0608:09:09 1-1.1:14be:001b:00:ff; uw && long && ok "LED bar behind a hub: full wait (${EL} s, a stick could be on the hub)"
mkusb 1-1:046d:c077:00:03; uw && long && ok "another device (keyboard) in the socket: full wait (${EL} s)"
mkusb 1-1:0781:5567:00:08; uw && ! long && echo "$LAST" | grep -q "mass storage seen" && ok "mass-storage device: goes on to look for tsx-install/GO (${EL} s)"
P5N=$(dd if=/dev/${n}p5 bs=1M count=4 2>/dev/null | sha256sum); [ "$P5N" = "$P5H" ] && ok "p5 untouched by the USB-wait runs"

echo "== 5. hands-off reinstall: tsx-install/GO on the stick"
echo armed > /mnt/media_rw/udisk0/tsx-install/GO
$AUTO > /tmp/s4.txt 2>&1 || { cat /tmp/run/tsx-autoinstall.log; fail "GO reinstall"; }
[ ! -f /mnt/media_rw/udisk0/tsx-install/GO ] && ls /mnt/media_rw/udisk0/tsx-install/GO.done-* >/dev/null && ok "reinstalled, GO renamed"
[ "$(dd if=/dev/${n}p5 bs=1M count=4 2>/dev/null | sha256sum)" != "$P5H" ] && ok "p5 was rewritten"

echo "== 6. Android-side uninstall"
$AU --yes > /tmp/u.txt 2>&1 || { cat /tmp/u.txt; fail uninstall; }
[ "$($FP -n switch_bootmode)" = "$STOCK_SW" ] && ! $FP -n tsx_boot >/dev/null 2>&1 && ok "switch_bootmode stock, tsx_boot deleted"
mount -o ro /dev/${n}p1 /mnt/p1; [ ! -e /mnt/p1/tsxboot.img ] && [ "$(sha256sum < /mnt/p1/boot.img)" = "$G" ] && ok "p1:tsxboot.img removed, golden intact"; umount /mnt/p1
B=$(ls -d /mnt/media_rw/udisk0/tsx-install/backup/*/ | head -n1)
$AU --yes --restore-env $B/env-0x100000.bin > /tmp/u2.txt 2>&1 || { cat /tmp/u2.txt; fail restore-env; }
dd if=$L bs=65536 skip=16 count=1 2>/dev/null | cmp -s - /w/env-stock.bin && ok "--restore-env: env block byte-exact = before the install"
printf "garbage" > /tmp/bad.bin; $AU --yes --restore-env /tmp/bad.bin >/dev/null 2>&1 && fail "restored garbage" || ok "--restore-env refuses a file that is not a 64 KiB yushan env"

echo "== 7. stock env + U-Boot jabil boot from the stick (only if U-Boot USB works)"
echo "rootfstype=ramfs init=/init androidboot.selinux=permissive" > /tmp/cmdline
mkfs.ext2 -q -F -L sdcard /dev/${n}p5
$AUTO > /tmp/s5.txt 2>&1 || { cat /tmp/run/tsx-autoinstall.log; fail "jabil path"; }
[ "$($FP -n switch_bootmode)" = "${STOCK_SW}if itest \${boot_retry} -lt 6; then run tsx_boot; fi" ] && $FP -n tsx_boot >/dev/null && ok "hook installed by stage 2 (stock env before)"
[ "$($FP -n DataRecoveryDone)" = 1 ] && ok "stage 2 set DataRecoveryDone=1 (stick default DEFUSE_GOLDEN=1)"
[ -f /mnt/media_rw/udisk0/jabil.txt.done ] && [ ! -f /mnt/media_rw/udisk0/jabil.txt ] && ok "jabil.txt renamed: a stick left in does not boot again"
mv /mnt/media_rw/udisk0/jabil.txt.done /mnt/media_rw/udisk0/jabil.txt
blkid /dev/${n}p5 | grep -q tsxroot && ok "p5 = tsxroot"

echo "== 8. the whole conversion from the Android root shell (the only supported install path)"
dd if=/w/env-stock.bin of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null
mount /dev/${n}p1 /mnt/p1; cp /tmp/golden.img /mnt/p1/boot.img; rm -f /mnt/p1/tsxboot.img /mnt/p1/tsxinst.cfg; umount /mnt/p1
mkfs.ext2 -q -F -L sdcard /dev/${n}p5; mount /dev/${n}p5 /mnt/sdcard; mkdir -p /mnt/sdcard/ROMDISK/user; echo project > /mnt/sdcard/ROMDISK/user/p.vtz
dd if=$L of=/tmp/mbr0.bin bs=512 count=1 2>/dev/null
$AI preflight > /tmp/p12.txt 2>&1 && grep -q "MBR entry 4 type 0x05" /tmp/p12.txt && grep -q "preflight OK" /tmp/p12.txt && ok "preflight: stick has rootfs-p2 + rescue, p2 free, MBR entry 4 = 0x05, p1 room"
$AI install --yes --no-reboot > /tmp/i12.txt 2>&1 || { cat /tmp/i12.txt; fail "install"; }
grep -E "p2 written|p1:boot.img = mainline rescue|MBR: entry 4|DONE" /tmp/i12.txt | sed "s/^/    /"
[ "$(dd if=/dev/${n}p2 bs=1M count=16 2>/dev/null | sha256sum | cut -d" " -f1)" = "$P2SHA" ] && ok "p2 = the kiosk rootfs image (sha256 of the written range)"
mount -o ro /dev/${n}p1 /mnt/p1
cmp -s /mnt/p1/boot.img /w/rescue.img && cmp -s /mnt/p1/tsxboot.img /w/tsxboot.img && ok "p1: boot.img = rescue, tsxboot.img = kiosk image"
grep -q "^MKDATA=p4" /mnt/p1/tsxlayout.cfg && [ ! -e /mnt/p1/tsxinst.cfg ] && ok "p1:tsxlayout.cfg orders the p4 format. No stage-2 install order"
MKUUID12=$(sed -n "s/^MKDATA_UUID=//p" /mnt/p1/tsxlayout.cfg)
[ -n "$MKUUID12" ] && ok "p1:tsxlayout.cfg carries a fresh MKDATA_UUID ($MKUUID12)"
umount /mnt/p1
B12=$(ls -d /mnt/media_rw/udisk0/tsx-install/backup/*/ | tail -n 1)
cmp -s $B12/golden-boot.img /tmp/golden.img && ls /data/local/tsx-backup/*/golden-boot.img >/dev/null && ok "Crestron golden boot.img saved to the stick and /data/local/tsx-backup"
tar tzf $B12/android-sdcard.tar.gz | grep -q ROMDISK/user/p.vtz && ok "Android sdcard archived to the stick before the MBR change"
[ "$($FP -n switch_bootmode)" = "${STOCK_SW}if itest \${boot_retry} -lt 6; then run tsx_boot; fi" ] && [ "$($FP -n boot_retry)" = 0 ] && ok "env: fallback hook, boot_retry 0"
dd if=$L of=/tmp/mbr1.bin bs=512 count=1 2>/dev/null
[ "$(od -An -tx1 -j 498 -N 1 /tmp/mbr1.bin | tr -d " ")" = 83 ] && [ "$(od -An -tx1 -j 498 -N 1 /tmp/mbr0.bin | tr -d " ")" = 05 ] && cmp -s -n 498 /tmp/mbr0.bin /tmp/mbr1.bin && [ "$(tail -c 13 /tmp/mbr0.bin | od -An -tx1)" = "$(tail -c 13 /tmp/mbr1.bin | od -An -tx1)" ] && ok "MBR: only byte 498 changed (entry 4 type 0x05 -> 0x83)"
umount /mnt/sdcard; umount /mnt/extsd 2>/dev/null || true
# the next boot: the kernel reads the new table
partx -d $L 2>/dev/null || true; losetup -d $L; L=$(losetup -P -f --show /w/disk.img); n=${L#/dev/}; sleep 1
for p in /sys/block/$n/${n}p*; do b=${p##*/}; rm -f /dev/$b; mknod /dev/$b b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev); done
echo "$L 0x100000 0x10000" > /etc/fw_env.config; export TSX_SYSBLOCK=/sys/block/$n
[ ! -e /sys/block/$n/${n}p5 ] && [ "$(cat /sys/block/$n/${n}p4/size)" = 5928959 ] && blkid /dev/${n}p2 | grep -q "LABEL=\"tsxroot\"" && ok "kernel view after the reboot: p1..p4, p4 = 5928959 sectors, p2 = tsxroot, no p5..p8"
env -u TSX_STICK $AUTO > /tmp/a12.txt 2>&1; blkid /dev/${n}p4 | grep -q "LABEL=\"tsxdata\"" && mount -o ro /dev/${n}p1 /mnt/p1 && [ -f /mnt/p1/tsxlayout.done ] && [ ! -f /mnt/p1/tsxlayout.cfg ] && ok "first mainline boot (initramfs): p4 formatted as tsxdata once, order renamed"; umount /mnt/p1
[ "$(blkid -s UUID -o value /dev/${n}p4)" = "$MKUUID12" ] && ok "p4 formatted with -U = the MKDATA_UUID of the order"
mount /dev/${n}p4 /mnt/r; echo keep > /mnt/r/marker; umount /mnt/r
mount /dev/${n}p1 /mnt/p1; mv /mnt/p1/tsxlayout.done /mnt/p1/tsxlayout.cfg; umount /mnt/p1
env -u TSX_STICK $AUTO > /tmp/a13.txt 2>&1; mount -o ro /dev/${n}p4 /mnt/r; [ -f /mnt/r/marker ] && ok "a repeated order does not format p4 again (tsxdata already there)"; umount /mnt/r
rm -f /mnt/media_rw/udisk0/tsx-install/GO; env -u TSX_STICK $AUTO > /tmp/a14.txt 2>&1 && ok "later boots: tsx-autoinstall exits 0, nothing to do"

echo "== 8b. stale tsxdata superblock survives a factory restore (bug of 2026-09-27) -- MKDATA_UUID tells it apart"
# (a) p4 now holds a real, not corrupt, tsxdata fs with LABEL=tsxdata (from
# 8/8a above). It stands in for the stale superblock that a factory restore
# leaves behind. A fresh order has a new MKDATA_UUID, as a real installer run
# writes. The installer must format over the fs and must not trust the label.
NEWUUID=$(cat /proc/sys/kernel/random/uuid)
[ "$NEWUUID" != "$MKUUID12" ] && ok "fresh MKDATA_UUID for the new order differs from the stale UUID of p4"
mount /dev/${n}p1 /mnt/p1; rm -f /mnt/p1/tsxlayout.done
{ echo "MKDATA=p4"; echo "MKDATA_UUID=$NEWUUID"; echo "RESCUE_SHA256=x"; echo "ROOTFS_P2_SHA256=x"; } > /mnt/p1/tsxlayout.cfg; umount /mnt/p1
env -u TSX_STICK $AUTO > /tmp/a15.txt 2>&1
grep -q "does not match the MKDATA_UUID in this order" /tmp/run/tsx-autoinstall.log && ok "(a) stale UUID of p4 != MKDATA_UUID of the new order: mismatch detected"
mount -o ro /dev/${n}p4 /mnt/r 2>/dev/null; RC=$?; [ $RC = 0 ] && [ ! -f /mnt/r/marker ] && ok "(a) stale tsxdata reformatted: old marker gone"; umount /mnt/r 2>/dev/null || true
[ "$(blkid -s UUID -o value /dev/${n}p4)" = "$NEWUUID" ] && ok "(a) p4 UUID now = the MKDATA_UUID of the new order"

# (b) idempotent: p4 already has the MKDATA_UUID of THIS order -> not formatted again
mount /dev/${n}p4 /mnt/r; echo keep2 > /mnt/r/marker; umount /mnt/r
mount /dev/${n}p1 /mnt/p1; mv /mnt/p1/tsxlayout.done /mnt/p1/tsxlayout.cfg; umount /mnt/p1
env -u TSX_STICK $AUTO > /tmp/a16.txt 2>&1
grep -q "matches the MKDATA_UUID in this order" /tmp/run/tsx-autoinstall.log && ok "(b) p4 UUID matches the MKDATA_UUID of the order: not reformatted"
mount -o ro /dev/${n}p4 /mnt/r; [ -f /mnt/r/marker ] && ok "(b) marker2 survives: idempotent skip confirmed"; umount /mnt/r

# (c) old-style cfg (no MKDATA_UUID, as an older installer would leave) + a
# CORRUPT stale tsxdata (label intact, e2fsck -fn fails): must still format,
# because this is the exact shape of the reported bug (label-only check
# missed a corrupt survivor). Corrupt the inode/journal area a few MiB in.
# The superblock at byte 1024 is untouched, so blkid still reports tsxdata.
mkfs.ext4 -F -q -O ^metadata_csum_seed,^orphan_file -L tsxdata -m 1 /dev/${n}p4
dd if=/dev/zero of=/dev/${n}p4 bs=4096 seek=1 count=2048 conv=notrunc 2>/dev/null   # zero 8 MiB of group-0 metadata (descriptors, bitmaps, inode table) right after the superblock block, leaving byte 1024 (the superblock itself, so blkid still sees tsxdata)
blkid -s LABEL -o value /dev/${n}p4 | grep -qx tsxdata && ! e2fsck -fn /dev/${n}p4 >/dev/null 2>&1 && ok "(c) corrupted p4: blkid still says tsxdata, e2fsck -fn fails (reproduces the starting state of the bug)"
mount /dev/${n}p1 /mnt/p1; rm -f /mnt/p1/tsxlayout.done
{ echo "MKDATA=p4"; echo "RESCUE_SHA256=x"; echo "ROOTFS_P2_SHA256=x"; } > /mnt/p1/tsxlayout.cfg; umount /mnt/p1
env -u TSX_STICK $AUTO > /tmp/a17.txt 2>&1
grep -q "no MKDATA_UUID in this order" /tmp/run/tsx-autoinstall.log && grep -q "or e2fsck -fn failed: formatting" /tmp/run/tsx-autoinstall.log && ok "(c) old cfg + corrupt stale tsxdata: formatted (this is the bug from hardware 2026-09-27)"
e2fsck -fn /dev/${n}p4 >/dev/null 2>&1 && ok "(c) p4 now passes e2fsck -fn (freshly formatted)"

# (d) An old-style cfg (no MKDATA_UUID) and a CLEAN stale tsxdata (label
# intact, e2fsck -fn clean). The installer must not format again. The label
# check was first meant to give this idempotency. It must still work for an
# order that an older installer left.
mkfs.ext4 -F -q -O ^metadata_csum_seed,^orphan_file -L tsxdata -m 1 /dev/${n}p4
mount /dev/${n}p4 /mnt/r; echo keep3 > /mnt/r/marker; umount /mnt/r
mount /dev/${n}p1 /mnt/p1; rm -f /mnt/p1/tsxlayout.done
{ echo "MKDATA=p4"; echo "RESCUE_SHA256=x"; echo "ROOTFS_P2_SHA256=x"; } > /mnt/p1/tsxlayout.cfg; umount /mnt/p1
env -u TSX_STICK $AUTO > /tmp/a18.txt 2>&1
grep -q "e2fsck -fn clean, not formatted again" /tmp/run/tsx-autoinstall.log && ok "(d) old cfg + clean stale tsxdata: not formatted (label + e2fsck -fn idempotency preserved)"
mount -o ro /dev/${n}p4 /mnt/r; [ -f /mnt/r/marker ] && ok "(d) marker3 survives: not reformatted"; umount /mnt/r

echo "== 9. --guard nogolden and --no-defuse-golden (re-run on the already-converted card)"
/usr/bin/fw_setenv -c /etc/fw_env.config DataRecoveryDone 0
$AI install --yes --no-reboot --guard nogolden --no-defuse-golden --no-sdcard-backup > /tmp/g.txt 2>&1 || { cat /tmp/g.txt; fail nogolden; }
[ "$($FP -n switch_bootmode)" = "${STOCK_SW}if itest \${boot_retry} -lt 6 || itest \${boot_retry} -gt 9; then run tsx_boot; fi" ] && [ "$($FP -n DataRecoveryDone)" = 0 ] && ok "nogolden guard, DataRecoveryDone left at 0 with --no-defuse-golden"
grep -q "already holds the kiosk rootfs" /tmp/g.txt && ok "re-install on an already-converted card: p2 rewritten from the stick (idempotent, not --p2-written)"

echo "== 10. --p2-written (p2 written by another means, e.g. a direct write to /dev/block/mmcblk0p2)"
umount /mnt/sdcard /mnt/p1 2>/dev/null || true
losetup -d $L
truncate -s $((7774208 * 512)) /w/disk.img
sfdisk -q /w/disk.img < /rootfs/tests/crestron-mbr.sfdisk
L=$(losetup -P -f --show /w/disk.img); n=${L#/dev/}; sleep 1
for p in /sys/block/$n/${n}p*; do b=${p##*/}; rm -f /dev/$b; mknod /dev/$b b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev); done
echo "$L 0x100000 0x10000" > /etc/fw_env.config; export TSX_SYSBLOCK=/sys/block/$n
[ -e /sys/block/$n/${n}p8 ] && ok "card back to the Crestron layout (p5..p8) for the p2-written test"
dd if=/w/env-stock.bin of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null
mkfs.vfat -F 16 /dev/${n}p1 >/dev/null
mount /dev/${n}p1 /mnt/p1; cp /tmp/golden.img /mnt/p1/boot.img; umount /mnt/p1
mkfs.ext2 -q -F -L sdcard /dev/${n}p5; mount /dev/${n}p5 /mnt/sdcard; mkdir -p /mnt/sdcard/ROMDISK/user; echo project > /mnt/sdcard/ROMDISK/user/p.vtz
dd if=/dev/urandom of=/dev/${n}p2 bs=1M count=16 2>/dev/null; sync
# the "stick" is a plain directory (e.g. a direct copy target such as /logs/tsx-stick) WITHOUT the rootfs archive
rm -rf /w/extstick; mkdir -p /w/extstick; (cd /w/stick && tar cf - --exclude=tsx-install/rootfs-p2.ext4.gz .) | (cd /w/extstick && tar xf -)
[ ! -e /w/extstick/tsx-install/rootfs-p2.ext4.gz ] && [ -f /w/extstick/tsx-install/rescue-tsw1060.img ] && ok "stick dir: no rootfs-p2.ext4.gz, everything else present"
$AI preflight --stick /w/extstick > /tmp/p13a.txt 2>&1 && fail "gz-less stick accepted without --p2-written" || { grep -q "no rootfs-p2 image on the stick" /tmp/p13a.txt && ok "without --p2-written a stick dir without the rootfs archive is refused"; }
$AI preflight --stick /w/extstick --p2-written > /tmp/p13c.txt 2>&1 && fail "wrong p2 content accepted" || { grep -q "p2 does not hold the rootfs image" /tmp/p13c.txt && grep -q "rootfs archive excluded" /tmp/p13c.txt && ok "--p2-written: p2 with other content refused (payload check skipped the absent archive)"; }
dd if=/w/p2.ext4 of=/dev/${n}p2 bs=1M 2>/dev/null; sync     # stands in for a direct write of rootfs-p2.ext4 to /dev/block/mmcblk0p2
H13=$(dd if=$L bs=1M count=8 2>/dev/null | sha256sum)
$AI preflight --stick /w/extstick --p2-written > /tmp/p13d.txt 2>&1 && grep -q "p2 already holds the kiosk rootfs" /tmp/p13d.txt && grep -q "preflight OK" /tmp/p13d.txt && ok "--p2-written preflight OK once p2 holds the image (sha256 from the card)"
[ "$(dd if=$L bs=1M count=8 2>/dev/null | sha256sum)" = "$H13" ] && ok "--p2-written preflight wrote nothing"
$AI install --stick /w/extstick --p2-written --yes --no-reboot > /tmp/i13.txt 2>&1 || { cat /tmp/i13.txt; fail "--p2-written install"; }
grep -E "nothing written to p2|p1:boot.img = mainline rescue|MBR: entry 4|DONE" /tmp/i13.txt | sed "s/^/    /"
grep -q "nothing written to p2" /tmp/i13.txt && [ "$(dd if=/dev/${n}p2 bs=1M count=16 2>/dev/null | sha256sum | cut -d" " -f1)" = "$P2SHA" ] && ok "install left p2 as pushed (sha256 unchanged)"
mount -o ro /dev/${n}p1 /mnt/p1
cmp -s /mnt/p1/boot.img /w/rescue.img && cmp -s /mnt/p1/tsxboot.img /w/tsxboot.img && grep -q "^MKDATA=p4" /mnt/p1/tsxlayout.cfg && grep -q "^ROOTFS_P2_SHA256=$P2SHA" /mnt/p1/tsxlayout.cfg && ok "p1: rescue in the golden slot, kiosk image, tsxlayout.cfg with the p2 sha256"
umount /mnt/p1
B13=$(ls -d /w/extstick/tsx-install/backup/*/ | tail -n 1)
cmp -s $B13/golden-boot.img /tmp/golden.img && ok "Crestron golden boot.img saved into the stick dir (goes to /logs on the panel)"
[ "$(dd if=$L bs=512 count=1 2>/dev/null | od -An -tx1 -j 498 -N 1 | tr -d " ")" = 83 ] && [ "$($FP -n boot_retry)" = 0 ] && ok "MBR entry 4 = 0x83 and boot_retry 0 after the --p2-written install"
umount /mnt/sdcard 2>/dev/null || true
rm -rf /w/extstick   # a plain dir bind-mounted from the host: remove it here as root, or the
                     # host-side cleanup trap (unprivileged) cannot remove these root-owned files
echo "PASS test-android-install"
' | tee "$W/out.txt"
N=$(grep -c "  ok: " "$W/out.txt")
echo "ok checks: $N"
[ "$N" -gt 0 ] && grep -q "^PASS" "$W/out.txt" || { echo "FAIL: a check was skipped or failed"; exit 1; }
