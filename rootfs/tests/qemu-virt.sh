#!/bin/bash
# Boot the kiosk rootfs under qemu-system-arm -M virt with the switch_root
# initramfs and a virt test kernel (build-virt-kernel.sh).
# The test proves that:
#  - the initramfs finds LABEL=tsxroot and runs switch_root
#  - OpenRC reaches the default runlevel
#  - the kiosk service runs cage and Chromium on virtio-gpu
#
#   tests/qemu-virt.sh start   boot in the background (serial log in $W/serial.log)
#   tests/qemu-virt.sh ssh CMD run CMD in the guest (root/tsx, port 2222)
#   tests/qemu-virt.sh shot F  save a screenshot of the guest display to F (.png)
#   tests/qemu-virt.sh stop
# The script does not modify the rootfs image. The guest writes to a qcow2
# overlay. The overlay gets a getty on ttyAMA0 and a test kiosk.conf (with
# debugfs).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=${W:-${TMPDIR:-/tmp}/tsx-qemu}
KERNEL=${KERNEL:-$HERE/build-virt/arch/arm/boot/zImage}
MEM=${MEM:-2048}
SSHP=(sshpass -p tsx ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1)
mon() { python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); import os; os.chdir(os.path.dirname(sys.argv[1])); s.connect(os.path.basename(sys.argv[1])); time.sleep(0.3); s.recv(4096); s.sendall((sys.argv[2]+"\n").encode()); time.sleep(1); print(s.recv(65536).decode(errors="replace"))' "$W/mon.sock" "$1"; }

case "${1:-}" in
start)
	mkdir -p "$W"; rm -f "$W"/disk.* "$W/serial.log"
	cp --sparse=always "$HERE/out/rootfs.ext4" "$W/disk.raw"
	cat > "$W/inittab" <<'I'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyAMA0::respawn:/sbin/getty -L 115200 ttyAMA0 vt100
::shutdown:/sbin/openrc shutdown
I
	sed -e "s|^BLANK_TIMEOUT=.*|BLANK_TIMEOUT=${BLANK_TIMEOUT:-600}|" -e "s|^KIOSK_URL=.*|KIOSK_URL=\"${KIOSK_URL:-https://ha.example.org}\"|" \
		"$HERE/rootfs/overlay/etc/kiosk.conf" > "$W/kiosk.conf"
	[ -n "${KIOSK_EXTRA:-}" ] && printf '%s\n' "$KIOSK_EXTRA" >> "$W/kiosk.conf"
	debugfs -w "$W/disk.raw" -f - >/dev/null <<D
rm /etc/inittab
write $W/inittab /etc/inittab
rm /etc/kiosk.conf
write $W/kiosk.conf /etc/kiosk.conf
D
	qemu-img create -q -f qcow2 -F raw -b "$W/disk.raw" "$W/disk.qcow2"
	cd "$W"   # the monitor socket path is relative (UNIX socket paths are limited to 108 bytes)
	qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 4 -m "$MEM" -accel tcg,thread=multi \
		-kernel "$KERNEL" -initrd "$HERE/out/initramfs-switchroot.cpio.gz" \
		-append "console=ttyAMA0 tsx.rootwait=15 ${APPEND:-}" \
		-drive if=none,id=d0,file="$W/disk.qcow2",format=qcow2 -device virtio-blk-device,drive=d0 \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-device,netdev=n0 \
		${QEMU_GPU:--device bochs-display,xres=1280,yres=800} -device virtio-tablet-device -device virtio-keyboard-device \
		-device i6300esb -device virtio-rng-device -global virtio-mmio.force-legacy=false \
		${QEMU_DISPLAY:--display vnc=127.0.0.1:57} -monitor unix:mon.sock,server,nowait \
		-serial file:"$W/serial.log" -daemonize -pidfile "$W/qemu.pid"
	echo "qemu started (pid $(cat "$W/qemu.pid")), serial log $W/serial.log";;
ssh) shift; "${SSHP[@]}" "$@";;
mon) shift; mon "$*" >/dev/null;;
shot)
	# a VNC client forces a fresh frame. QEMU's screendump alone returns a stale
	# surface when no display client is connected
	if command -v gvnccapture >/dev/null; then timeout 60 gvnccapture 127.0.0.1:57 "$2" >/dev/null 2>&1
	else mon "screendump shot.ppm" >/dev/null; sleep 1; python3 -c "from PIL import Image; Image.open('$W/shot.ppm').save('$2')"; fi
	echo "saved $2";;
stop) mon quit >/dev/null || kill "$(cat "$W/qemu.pid")"; echo stopped;;
*) sed -n '2,15p' "$0"; exit 2;;
esac
