#!/bin/bash
# Chroot test of the move and bind logic of etc/init.d/tsx-data (installer p2
# space fix). A fixed 800 MiB p2 leaves almost no headroom once packages are
# installed. So /var/lib/kiosk, /var/log, /var/lib/tsx, /var/lib/sendspin,
# /root and /home must live on /data (p4, tsxdata). The script moves them
# there once and bind-mounts them at every boot.
# This is a dedicated chroot test and not an addition to the qemu boot of
# test-initramfs-qemu.sh. That harness boots a whole-disk rootfs-p2.ext4 image
# with no spare partition to stand in for tsxdata. A loop-mounted ext4 in a
# privileged container is the cheap way to exercise the real script. The test
# reads the script straight from the rootfs overlay and not from a copy. It
# checks real bind mounts, ownership and the marker (idempotency) file.
# The test needs docker --privileged. Usage: tests/test-tsx-data.sh
set -uo pipefail
ROOTFS_DIR=$(cd "$(dirname "$0")/../../rootfs" && pwd)
SCRIPT="$ROOTFS_DIR/overlay/etc/init.d/tsx-data"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

docker run --rm --privileged --platform linux/amd64 -v "$SCRIPT:/tsx-data.src:ro" alpine:3.24 sh -euc '
apk add -q --no-cache e2fsprogs >/dev/null
for i in $(seq 0 15); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done

# ---- /r : a minimal busybox root the script will actually run against ----
mkdir -p /r/etc/apk
printf "https://dl-cdn.alpinelinux.org/alpine/v3.24/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.24/community\n" > /r/etc/apk/repositories
apk add -q --root /r --initdb --no-cache --keys-dir /etc/apk/keys --repositories-file /r/etc/apk/repositories busybox busybox-suid >/dev/null
mkdir -p /r/etc/init.d /r/data /r/proc /r/run
cp /tsx-data.src /r/etc/init.d/tsx-data; chmod 755 /r/etc/init.d/tsx-data

# fake openrc logging functions + a driver that sources the real script and
# calls start(), exactly as /sbin/openrc-run would
cat > /r/run/drive.sh <<'"'"'EOF'"'"'
ebegin() { echo "  begin: $*"; }
eend() { :; }
einfo() { echo "  info: $*"; }
eerror() { echo "  ERROR: $*" >&2; }
. /etc/init.d/tsx-data
start
EOF
chmod +x /r/run/drive.sh

mkfs.ext4 -q -F -L tsxdata /tmp/tsxdata.img 2>/dev/null || { truncate -s 24M /tmp/tsxdata.img; mkfs.ext4 -q -F -L tsxdata /tmp/tsxdata.img; }

N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

seed() {   # seed R : populate the 5 tracked dirs under R with owned content
	R=$1
	mkdir -p "$R/var/lib/kiosk" "$R/var/log" "$R/var/lib/tsx" "$R/var/lib/sendspin" "$R/root/.ssh" "$R/home/nobody"
	head -c 20000 /dev/urandom > "$R/var/lib/kiosk/profile.bin"
	ln -s profile.bin "$R/var/lib/kiosk/current"
	chown -R 1000:1000 "$R/var/lib/kiosk"; chmod 755 "$R/var/lib/kiosk"
	echo "boot 1" > "$R/var/log/messages"; chmod 755 "$R/var/log"
	echo "installed=(card stage)" > "$R/var/lib/tsx/install.info"
	echo "state" > "$R/var/lib/sendspin/state.json"; chown -R 1000:29 "$R/var/lib/sendspin"; chmod 750 "$R/var/lib/sendspin"
	echo "ssh-ed25519 AAAAtest" > "$R/root/.ssh/authorized_keys"; chmod 700 "$R/root" "$R/root/.ssh"
	echo "hi" > "$R/home/nobody/file"; chmod 755 "$R/home"
}

echo "== 1: fresh /data present (tsxdata, ext4) -> first-boot move + bind"
seed /r
mount -o loop /tmp/tsxdata.img /r/data
mount -t proc proc /r/proc
mkdir -p /r/dev; mount --bind /dev /r/dev
K0=$(sha256sum /r/var/lib/kiosk/profile.bin | cut -d" " -f1)
chroot /r /bin/sh /run/drive.sh > /tmp/out1.txt 2>&1 || { cat /tmp/out1.txt; bad "start() exited nonzero"; }
sed "s/^/    /" /tmp/out1.txt
grep -q "moving /var/lib/kiosk" /tmp/out1.txt && ok "moved /var/lib/kiosk (logged)"
[ -f /r/data/var/lib/kiosk/.tsx-moved ] && ok "marker written: /data/var/lib/kiosk/.tsx-moved"
[ "$(sha256sum /r/data/var/lib/kiosk/profile.bin | cut -d" " -f1)" = "$K0" ] && ok "content on /data matches the original (sha256)"
[ "$(readlink /r/data/var/lib/kiosk/current)" = profile.bin ] && ok "symlink carried over correctly"
chroot /r /bin/sh -c "grep -q \" /var/lib/kiosk \" /proc/mounts" && ok "/var/lib/kiosk is now a mountpoint (bind)"
chroot /r /bin/sh -c "grep -q \" /var/log \" /proc/mounts && grep -q \" /var/lib/tsx \" /proc/mounts && grep -q \" /var/lib/sendspin \" /proc/mounts && grep -q \" /root \" /proc/mounts && grep -q \" /home \" /proc/mounts" \
	&& ok "all 6 dirs bind-mounted (kiosk, log, tsx, sendspin, root, home)"
[ "$(cat /r/var/lib/kiosk/profile.bin | sha256sum | cut -c1-64)" = "$K0" ] && ok "content readable through the bind mount at the original path"
[ "$(stat -c %u:%g:%a /r/var/lib/kiosk)" = "1000:1000:755" ] && ok "ownership+mode preserved on /var/lib/kiosk (1000:1000 0755)"
[ "$(stat -c %a /r/root)" = 700 ] && ok "mode preserved on /root (0700)"
[ "$(stat -c %u:%g:%a /r/var/lib/sendspin)" = "1000:29:750" ] && ok "ownership+mode preserved on /var/lib/sendspin (1000:29 0750)"

echo "== 2: rootfs copy actually freed (unmount and look underneath)"
for d in var/lib/kiosk var/log var/lib/tsx var/lib/sendspin root home; do umount "/r/$d"; done
[ -z "$(find /r/var/lib/kiosk -mindepth 1 2>/dev/null)" ] && ok "rootfs copy of /var/lib/kiosk is empty (content actually moved, not duplicated)"
[ -z "$(find /r/root -mindepth 1 2>/dev/null)" ] && ok "rootfs copy of /root is empty"

echo "== 3: second boot (marker already present): bind-mount only, no re-copy"
echo "grown after first boot" > /r/data/var/lib/kiosk/grown-while-mounted
chroot /r /bin/sh /run/drive.sh > /tmp/out2.txt 2>&1 || { cat /tmp/out2.txt; bad "start() (2nd boot) exited nonzero"; }
grep -q "moving /var/lib/kiosk" /tmp/out2.txt && bad "second boot re-ran the move (should have used the marker)" || ok "second boot: no re-copy of /var/lib/kiosk (marker honoured)"
[ "$(cat /r/var/lib/kiosk/grown-while-mounted)" = "grown after first boot" ] && ok "data written on /data between boots survived across the second boot bind mount"
for d in var/lib/kiosk var/log var/lib/tsx var/lib/sendspin root home; do umount "/r/$d" 2>/dev/null || true; done
umount /r/dev /r/proc /r/data

echo "== 4: no /data mounted: service does nothing, no data loss"
rm -rf /r2; mkdir -p /r2/etc/init.d /r2/etc/apk /r2/run /r2/data /r2/proc
cp /r/etc/apk/repositories /r2/etc/apk/repositories
cp /tsx-data.src /r2/etc/init.d/tsx-data; chmod 755 /r2/etc/init.d/tsx-data
cp /r/run/drive.sh /r2/run/drive.sh 2>/dev/null || true
cat > /r2/run/drive.sh <<'"'"'EOF'"'"'
ebegin() { echo "  begin: $*"; }
eend() { :; }
einfo() { echo "  info: $*"; }
eerror() { echo "  ERROR: $*" >&2; }
. /etc/init.d/tsx-data
start
EOF
apk add -q --root /r2 --initdb --no-cache --keys-dir /etc/apk/keys --repositories-file /r2/etc/apk/repositories busybox busybox-suid >/dev/null
seed /r2
mount -t proc proc /r2/proc
mkdir -p /r2/dev; mount --bind /dev /r2/dev
chroot /r2 /bin/sh /run/drive.sh > /tmp/out3.txt 2>&1
grep -q "not mounted" /tmp/out3.txt && ok "no /data mounted: logged and skipped"
[ -f /r2/var/lib/kiosk/profile.bin ] && [ ! -e /r2/data/var/lib/kiosk ] && ok "no /data mounted: /var/lib/kiosk untouched, nothing written under /data"
umount /r2/dev /r2/proc

echo "== 5: crash resume (partial first run: /data/<dir> exists, no marker, source still intact)"
truncate -s 24M /tmp/tsxdata2.img; mkfs.ext4 -q -F -L tsxdata /tmp/tsxdata2.img
rm -rf /r3; mkdir -p /r3/etc/init.d /r3/etc/apk /r3/run /r3/data /r3/proc
cp /r/etc/apk/repositories /r3/etc/apk/repositories
cp /tsx-data.src /r3/etc/init.d/tsx-data; chmod 755 /r3/etc/init.d/tsx-data
cp /r2/run/drive.sh /r3/run/drive.sh
apk add -q --root /r3 --initdb --no-cache --keys-dir /etc/apk/keys --repositories-file /r3/etc/apk/repositories busybox busybox-suid >/dev/null
seed /r3
K1=$(sha256sum /r3/var/lib/tsx/install.info | cut -d" " -f1)
mount -o loop /tmp/tsxdata2.img /r3/data
mkdir -p /r3/data/var/lib/tsx
echo "stale partial copy" > /r3/data/var/lib/tsx/install.info   # partial/wrong content, no .tsx-moved marker
mount -t proc proc /r3/proc
mkdir -p /r3/dev; mount --bind /dev /r3/dev
chroot /r3 /bin/sh /run/drive.sh > /tmp/out4.txt 2>&1 || { cat /tmp/out4.txt; bad "resume run exited nonzero"; }
[ "$(sha256sum /r3/data/var/lib/tsx/install.info | cut -d" " -f1)" = "$K1" ] && ok "interrupted move resumed: source re-copied over the stale partial content"
[ -f /r3/data/var/lib/tsx/.tsx-moved ] && ok "resume: marker written on completion"
chroot /r3 /bin/sh -c "grep -q \" /var/lib/tsx \" /proc/mounts" && ok "resume: /var/lib/tsx bind-mounted after completing the interrupted move"
umount /r3/var/lib/tsx /r3/var/lib/kiosk /r3/var/log /r3/var/lib/sendspin /r3/root /r3/home 2>/dev/null || true
umount /r3/dev /r3/proc /r3/data 2>/dev/null || true

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-tsx-data || echo FAIL test-tsx-data
exit $F
'
