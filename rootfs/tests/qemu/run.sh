#!/bin/bash
# Voice satellite test in qemu-system-arm -M virt (run locally): guest kernel
# = the audio-loopback host-test kernel (build-kernel.sh, ALSA loopback card
# with id TSW1060, virtio net), guest initramfs = mkinitramfs.sh. Nothing is
# installed on the host: qemu runs in an x86 Alpine container, the initramfs
# is built in an armv7 one. Output: results/qemu-<time>.log
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd); TOP=$(cd "$REPO/.." && pwd)
K=$HERE/build-virt/arch/arm/boot/zImage
[ -f "$K" ] || { echo "no $K (run build-kernel.sh first)"; exit 1; }
mkdir -p "$HERE/results" "$HERE/build-virt" "$HOME/.cache/tsx-lva"
LOG=$HERE/results/qemu-$(date +%Y%m%d-%H%M%S).log
IRD=$HERE/build-virt/guest-initramfs.cpio.gz
if [ "${SKIP_INITRAMFS:-0}" != 1 ]; then
	docker run --rm --platform linux/arm/v7 -v "$TOP:$TOP" -v "$HOME/.cache/tsx-lva:/build/lva" alpine:3.24 \
		sh "$HERE/mkinitramfs.sh" "$IRD"
fi
docker run --rm --platform linux/amd64 -v "$TOP:$TOP" alpine:3.24 sh -c "
	apk add -q --no-cache qemu-system-arm >/dev/null
	timeout ${QEMU_TIMEOUT:-2400} qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 4 -m 2048 -accel tcg,thread=multi \
		-kernel $K -initrd $IRD -nographic -no-reboot \
		-netdev user,id=n0 -device virtio-net-device,netdev=n0 \
		-append 'console=ttyAMA0 rdinit=/init snd_aloop.id=TSW1060 snd_aloop.pcm_substreams=4 quiet'
" 2>&1 | tr -d '\r' | tee "$LOG"
echo "log: $LOG"
grep -E '^(PASS|FAIL)' "$LOG" | awk '{print $1}' | sort | uniq -c
grep -E '^CHECK' "$LOG" | awk '{print "fake_ha", $2}' | sort | uniq -c
! grep -qE '^(FAIL|CHECK FAIL)' "$LOG"
