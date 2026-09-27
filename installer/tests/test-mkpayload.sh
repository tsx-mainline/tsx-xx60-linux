#!/bin/bash
# mkpayload refuses payloads that must not go on a stick:
#   - a rootfs without ENV_VERIFIED=yes (stale build: tsx-boot-ok would not reset boot_retry)
#   - a boot image whose initramfs has no tsx-autoinstall (today's p1 image
#     rootfs/out/tsxboot.img = the current audio-bring-up image, built without stage 2)
# accepts the same kernel repacked with the stage-2 initramfs
# (installer/out/tsxboot-audio-autoinstall.img, initramfs/repack-bootimg.py),
# and reports what the current rootfs/out/rootfs.tar.gz contains. Also checks
# the --usb and --recovery layouts (installer/emmc/tsx-usb-recovery round trip
# is in installer/emmc/tests/test-usb-recovery.sh) against synthetic fixtures,
# so those checks run without a real build.
set -uo pipefail
INSTALLER_DIR=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$INSTALLER_DIR/.." && pwd)
MKPAYLOAD=$INSTALLER_DIR/payload/mkpayload
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rc=0
mk() { mkdir -p "$W/fr$1/etc/tsx"; echo "ENV_VERIFIED=$1" > "$W/fr$1/etc/tsx/uboot-env.conf"; tar -C "$W/fr$1" -czf "$W/$1.tar.gz" .; }
mk yes; mk no

# a fake Android boot image whose initramfs cpio contains the given path
# (as a bare cpio "file name\0" entry: bootimg_check only greps for it, does
# not actually unpack the cpio, so this is enough to fake either direction)
fakeimg() {   # fakeimg OUT PATH-IN-INITRAMFS
	python3 - "$1" "$2" <<'PY'
import struct, sys, gzip, os
cp = b'070701' + b'0'*104 + sys.argv[2].encode() + b'\0'
rd = gzip.compress(cp); ps = 2048; k = os.urandom(100)
pad = lambda b: b + b'\0' * ((-len(b)) % ps)
open(sys.argv[1], 'wb').write(pad(b'ANDROID!' + struct.pack('<8I', len(k), 0, len(rd), 0, 0, 0, 0, ps)) + pad(k) + pad(rd))
PY
}
fakeimg "$W/auto.img" usr/sbin/tsx-autoinstall
fakeimg "$W/rescue.img" etc/tsx/rescue-image
fakeimg "$W/rescue760.img" etc/tsx/rescue-image
truncate -s 16M "$W/p2.ext4"; mkfs.ext4 -q -F -L tsxroot "$W/p2.ext4" 2>/dev/null || { echo "SKIPPED: mkfs.ext4 not available"; exit 0; }
echo "ENV_VERIFIED=yes" > "$W/uboot-env.conf"
debugfs -w -R "mkdir /etc" "$W/p2.ext4" >/dev/null 2>&1
debugfs -w -R "mkdir /etc/tsx" "$W/p2.ext4" >/dev/null 2>&1
debugfs -w -R "write $W/uboot-env.conf /etc/tsx/uboot-env.conf" "$W/p2.ext4" >/dev/null 2>&1

I=$ROOT/rootfs/out/tsxboot.img; R=$ROOT/rootfs/out/rootfs.tar.gz
IA=$INSTALLER_DIR/out/tsxboot-audio-autoinstall.img
mkdir -p "$W/o1" "$W/o2" "$W/o3" "$W/o4" "$W/o5"
"$MKPAYLOAD" --out "$W/o1" --rootfs "$W/no.tar.gz" --bootimg-tsw1060 "$W/auto.img" > "$W/1.txt" 2>&1
grep -q "stale build" "$W/1.txt" && echo "  ok: rootfs with ENV_VERIFIED=no refused" || { echo "  FAIL stale"; cat "$W/1.txt"; rc=1; }
if [ -f "$I" ]; then
	"$MKPAYLOAD" --out "$W/o2" --rootfs "$W/yes.tar.gz" --bootimg-tsw1060 "$I" > "$W/2.txt" 2>&1
	grep -q "no /usr/sbin/tsx-autoinstall" "$W/2.txt" && echo "  ok: today's p1 image $(basename "$I") ($(sha256sum < "$I" | cut -c1-12)) refused: no tsx-autoinstall" || { echo "  FAIL noauto"; cat "$W/2.txt"; rc=1; }
else echo "  info: $I not built here; skipping the real-p1-image refusal check"; fi
"$MKPAYLOAD" --out "$W/o3" --rootfs "$W/yes.tar.gz" --bootimg-tsw1060 "$W/auto.img" > "$W/3.txt" 2>&1 && [ -f "$W/o3/tsx-install/SHA256SUMS" ] && echo "  ok: good payload accepted" || { echo "  FAIL good"; cat "$W/3.txt"; rc=1; }

echo "== --usb layout (synthetic fixtures)"
"$MKPAYLOAD" --out "$W/o5" --rootfs-p2 "$W/p2.ext4" --bootimg-tsw1060 "$W/auto.img" --rescue-tsw1060 "$W/rescue.img" --usb > "$W/5.txt" 2>&1 \
	|| { echo "  FAIL --usb build"; cat "$W/5.txt"; rc=1; }
[ -x "$W/o5/tsx-install-usb" ] && [ -x "$W/o5/tsx-usb-recovery" ] && echo "  ok: --usb copies tsx-install-usb and tsx-usb-recovery to the stick root, executable" || { echo "  FAIL --usb: helper scripts missing/not executable"; rc=1; }
cmp -s "$W/o5/tsx-install-usb" "$INSTALLER_DIR/android/tsx-install-usb" && echo "  ok: tsx-install-usb on the stick matches installer/android/tsx-install-usb" || { echo "  FAIL --usb: tsx-install-usb content mismatch"; rc=1; }
(cd "$W/o5" && sha256sum -c --quiet tsx-install/SHA256SUMS) && echo "  ok: --usb SHA256SUMS covers tsx-install-usb/tsx-usb-recovery and verifies" || { echo "  FAIL --usb: SHA256SUMS does not verify"; rc=1; }
grep -q '^tsx-install-usb$' <(cd "$W/o5" && sh -c "sed -n 's/^\\(.*\\)  tsx-install-usb\$/tsx-install-usb/p' tsx-install/SHA256SUMS") && echo "  ok: tsx-install-usb is listed in SHA256SUMS" || { echo "  FAIL --usb: tsx-install-usb not in SHA256SUMS"; rc=1; }
mkdir -p "$W/o3b"
"$MKPAYLOAD" --out "$W/o3b" --rootfs "$W/yes.tar.gz" --bootimg-tsw1060 "$W/auto.img" --usb > "$W/5b.txt" 2>&1 \
	&& { echo "  FAIL: --usb accepted without --rootfs-p2/--rescue-tsw1060"; rc=1; } || { grep -q "needs --rootfs-p2\|needs --rescue-tsw1060" "$W/5b.txt" && echo "  ok: --usb without --rootfs-p2/--rescue-tsw1060 refused"; }

echo "== --recovery layout (synthetic fixtures)"
mkdir -p "$W/o6"
"$MKPAYLOAD" --recovery --out "$W/o6" --rescue-tsw1060 "$W/rescue.img" --rescue-tsw760 "$W/rescue760.img" > "$W/6.txt" 2>&1 \
	|| { echo "  FAIL --recovery build"; cat "$W/6.txt"; rc=1; }
cmp -s "$W/o6/tsxboot-tsw1060.img" "$W/rescue.img" && cmp -s "$W/o6/tsxboot-tsw760.img" "$W/rescue760.img" && echo "  ok: --recovery writes the rescue image(s) under the jabil.txt names" || { echo "  FAIL --recovery: image content"; rc=1; }
[ ! -e "$W/o6/tsx-install" ] && echo "  ok: --recovery writes no tsx-install/ tree (nothing to install)" || { echo "  FAIL --recovery: unexpected tsx-install/ tree"; rc=1; }
grep -qx tsxboot-tsw760.img "$W/o6/jabil.txt" && grep -qx tsxboot-tsw1060.img "$W/o6/jabil.txt" && echo "  ok: --recovery jabil.txt names both models' images" || { echo "  FAIL --recovery: jabil.txt"; rc=1; }
(cd "$W/o6" && sha256sum -c --quiet SHA256SUMS) && echo "  ok: --recovery SHA256SUMS verifies" || { echo "  FAIL --recovery: SHA256SUMS"; rc=1; }
mkdir -p "$W/o7"
"$MKPAYLOAD" --recovery --out "$W/o7" --rescue-tsw1060 "$W/rescue.img" --rootfs "$W/yes.tar.gz" > "$W/7.txt" 2>&1 \
	&& { echo "  FAIL: --recovery accepted --rootfs"; rc=1; } || { grep -q "takes no --rootfs" "$W/7.txt" && echo "  ok: --recovery + --rootfs refused (installs nothing)"; }
mkdir -p "$W/o8"
"$MKPAYLOAD" --recovery --out "$W/o8" > "$W/8.txt" 2>&1 && { echo "  FAIL: --recovery accepted without --rescue-tsw1060"; rc=1; } || { grep -q "needs --rescue-tsw1060" "$W/8.txt" && echo "  ok: --recovery without --rescue-tsw1060 refused"; }

if [ -f "$IA" ]; then
	RS=$INSTALLER_DIR/out/tsx-rescue-tsw1060.img
	"$MKPAYLOAD" --out "$W/o5r" --rootfs "$W/yes.tar.gz" --bootimg-tsw1060 "$W/auto.img" --rescue-tsw1060 "$IA" > "$W/5r.txt" 2>&1 \
		&& { echo "  FAIL: kiosk image accepted as rescue"; rc=1; } || { grep -q "is not a rescue image" "$W/5r.txt" && echo "  ok: a kiosk image is refused as --rescue-tsw1060"; }
	"$MKPAYLOAD" --out "$W/o4" --rootfs "$R" --bootimg-tsw1060 "$IA" --rescue-tsw1060 "$RS" > "$W/4.txt" 2>&1 && grep -q "^DEFUSE_GOLDEN=1" "$W/o4/tsx-install/tsx-install.conf" \
		&& grep -q "^RESCUE_tsw1060=tsx-install/rescue-tsw1060.img" "$W/o4/tsx-install/tsx-install.conf" \
		&& (cd "$W/o4" && sha256sum -c --quiet tsx-install/SHA256SUMS) \
		&& echo "  ok: real payload accepted: $(basename "$IA") ($(sha256sum < "$IA" | cut -c1-12)) + rescue $(sha256sum < "$RS" | cut -c1-12) + current rootfs.tar.gz; DEFUSE_GOLDEN=1, RESCUE_tsw1060; SHA256SUMS verify" \
		|| { echo "  FAIL real payload"; cat "$W/4.txt"; rc=1; }
else echo "  info: $IA not built here (initramfs/build-initramfs.sh + repack-bootimg.py); skipping the real-payload check"; fi
if [ -f "$R" ]; then echo "  info: rootfs/out/rootfs.tar.gz ($(sha256sum < "$R" | cut -c1-12), $(stat -c %y "$R" | cut -c1-16)) has $(tar -xzOf "$R" ./etc/tsx/uboot-env.conf 2>/dev/null | grep ^ENV_VERIFIED)"; fi
[ $rc = 0 ] && echo PASS test-mkpayload || echo FAIL test-mkpayload; exit $rc
