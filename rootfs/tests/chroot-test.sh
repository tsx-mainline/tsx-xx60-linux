#!/bin/bash
# Host test of the rootfs under qemu-user: the tarball is imported as an armv7
# docker image (a chroot with /proc, /sys, /dev) and inspected.
# Checks services per runlevel, key binaries, script syntax, the invisible
# cursor theme, the U-Boot env safety.
# Usage: tests/chroot-test.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG=tsx-rootfs:test
docker import --platform linux/arm/v7 "$HERE/out/rootfs.tar.gz" $IMG >/dev/null
RUN=(docker run --rm --platform linux/arm/v7 $IMG)
pass=0; failn=0
t() { local d=$1; shift; if out=$("$@" 2>&1); then echo "  ok   $d${out:+: $(echo "$out" | head -3 | tr '\n' ' ')}"; pass=$((pass+1)); else echo "  FAIL $d: $(echo "$out" | tail -5 | tr '\n' ' ')"; failn=$((failn+1)); fi; }

echo "== runlevels"
"${RUN[@]}" sh -c 'for l in sysinit boot default shutdown; do printf "%-9s" $l; ls /etc/runlevels/$l | tr "\n" " "; echo; done'
echo "== binaries"
t "alpine release" "${RUN[@]}" cat /etc/alpine-release
t "chromium --version" "${RUN[@]}" chromium-browser --version
t "cage (patched, from source)" "${RUN[@]}" sh -c 'cage -v 2>&1; cat /usr/share/tsx-cage.version; ldd /usr/bin/cage | grep -c "not found" | grep -qx 0'
t "seatd present" "${RUN[@]}" sh -c 'command -v seatd'
t "fw_printenv present" "${RUN[@]}" sh -c 'command -v fw_printenv && command -v fw_setenv'
t "no default /etc/fw_env.config" "${RUN[@]}" sh -c '! test -e /etc/fw_env.config'
t "tsx-idled runs (no backlight)" "${RUN[@]}" sh -c 'TSX_BACKLIGHT_DIR=/nonexistent TSX_STATE_FILE=/tmp/st timeout 2 /usr/local/sbin/tsx-idled -c /etc/kiosk.conf; cat /tmp/st'
t "brightnessctl evtest kmscube eglinfo" "${RUN[@]}" sh -c 'for b in brightnessctl evtest kmscube eglinfo wlr-randr fw_setenv; do command -v $b >/dev/null || { echo "missing $b"; exit 1; }; done; echo all present'
t "mesa lima driver" "${RUN[@]}" sh -c 'ls /usr/lib/xorg/modules/dri/lima_dri.so 2>/dev/null || ls /usr/lib/dri/lima_dri.so 2>/dev/null || (ls /usr/lib/gbm /usr/lib/dri 2>/dev/null | grep -i -m3 -e lima -e gallium)'
t "kernel modules (optional)" "${RUN[@]}" sh -c 'ls /lib/modules 2>/dev/null || echo "none shipped (display, touch, backlight, lima are built in)"'
t "on-screen keyboard (sway, squeekboard, wvkbd, dbus, grim)" "${RUN[@]}" sh -c 'for b in sway swaymsg squeekboard wvkbd-mobintl dbus-daemon dbus-send grim; do command -v $b >/dev/null || { echo "missing $b"; exit 1; }; done; sway --version; grep "^KIOSK_OSK=\|^OSK_GESTURE=" /etc/kiosk.conf'
t "script syntax" "${RUN[@]}" sh -c 'for f in /usr/local/bin/* /usr/local/sbin/tsx-boot-ok /usr/local/sbin/tsx-wait-time /etc/init.d/kiosk /etc/init.d/tsx-*; do sh -n $f || exit 1; done; echo all'
t "blank cursor theme" "${RUN[@]}" sh -c 'test "$(head -c 4 /usr/share/tsx/cursors/blank/cursors/left_ptr)" = Xcur && stat -c %s /usr/share/tsx/cursors/blank/cursors/left_ptr'
t "kiosk user groups" "${RUN[@]}" id kiosk
t "chromium policy" "${RUN[@]}" sh -c 'grep -c Enabled /etc/chromium/policies/managed/tsx-kiosk.json'
t "tsx-boot-ok refuses (env not verified)" "${RUN[@]}" sh -c '! /usr/local/sbin/tsx-boot-ok 2>&1 | grep -q .; /usr/local/sbin/tsx-boot-ok 2>&1 | grep -q "not verified"'
echo "== size"
"${RUN[@]}" sh -c 'du -smx / 2>/dev/null | tail -1'

# kiosk-set-token is tested in the qemu-system VM (tests/qemu-virt.sh): under
# qemu-user Chromium cannot start its GPU/renderer child processes (launch
# error 1002) and --single-process dies with a QEMU internal SIGTRAP.
echo "== $pass passed, $failn failed"
[ $failn = 0 ]
