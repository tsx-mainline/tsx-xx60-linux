#!/bin/bash
# Host test for tsx-hw, the one place that reads the government flag and
# writes /run/tsx/hw.conf (docs/hardware.md "Panel variants"). It uses a fake
# kernel command line (TSX_PROC) and a temporary run directory
# (TSX_RUN_DIR). No hardware, no compile, busybox only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HW=$HERE/../overlay/usr/local/sbin/tsx-hw
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-hw: no busybox on this host"; exit 0; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
mkdir -p "$W/proc" "$W/bin"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"; chmod +x "$W/bin/logger"
hw() { env PATH="$W/bin:$PATH" TSX_RUN_DIR="$W/run" TSX_PROC="$W/proc" busybox sh "$HW" "$@"; }
facts() { tr '\n' ' ' < "$W/run/hw.conf" | sed 's/ REASON=.*//'; }

echo "== tsx-hw detect =="
echo 'rootfstype=ramfs androidboot.lcdsize=7inch androidboot.government=1 console=tty0' > "$W/proc/cmdline"
out=$(hw detect); rc=$?
[ $rc = 0 ] && [ "$(facts)" = "GOVERNMENT=1 MIC=no BT=no CAMERA=no PRESENCE=no" ] \
	&& ok "government=1: GOVERNMENT=1 MIC=no BT=no CAMERA=no PRESENCE=no" || bad "government=1: exit $rc, $(cat "$W/run/hw.conf")"
grep -q '^REASON=government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module$' "$W/run/hw.conf" \
	&& ok "government=1: REASON names the flag and the parts" || bad "REASON: $(grep REASON "$W/run/hw.conf")"
[ "$out" = "tsx-hw: GOVERNMENT=1 MIC=no BT=no CAMERA=no PRESENCE=no" ] && ok "detect prints one summary line" || bad "detect output: $out"
[ "$(stat -c %a "$W/run/hw.conf")" = 644 ] && ok "hw.conf is mode 644 (the kiosk and tsx-setup users read it)" || bad "mode $(stat -c %a "$W/run/hw.conf")"
ls "$W/run" | grep -q tmp && bad "a temporary file is left in the run directory" || ok "no temporary file left"

echo 'console=tty0 androidboot.government=0 loglevel=7' > "$W/proc/cmdline"
hw detect >/dev/null
[ "$(facts)" = "GOVERNMENT=0 MIC=yes BT=yes CAMERA=yes PRESENCE=no" ] && grep -qx 'REASON=' "$W/run/hw.conf" \
	&& ok "government=0: all parts, empty REASON" || bad "government=0: $(cat "$W/run/hw.conf")"

echo 'console=tty0 loglevel=7' > "$W/proc/cmdline"
hw detect >/dev/null
[ "$(facts)" = "GOVERNMENT=unknown MIC=yes BT=yes CAMERA=yes PRESENCE=no" ] && ok "no flag on the command line: GOVERNMENT=unknown, all parts" || bad "no flag: $(cat "$W/run/hw.conf")"

echo 'androidboot.government=yes x.androidboot.government=1' > "$W/proc/cmdline"
hw detect >/dev/null
[ "$(facts)" = "GOVERNMENT=unknown MIC=yes BT=yes CAMERA=yes PRESENCE=no" ] && ok "a bad value or a longer word is not the flag" || bad "bad value: $(cat "$W/run/hw.conf")"

echo 'androidboot.government=0 androidboot.government=1' > "$W/proc/cmdline"
hw detect >/dev/null
[ "$(facts)" = "GOVERNMENT=1 MIC=no BT=no CAMERA=no PRESENCE=no" ] && ok "two values: the last one counts" || bad "two values: $(cat "$W/run/hw.conf")"

echo "== tsx-hw get / show =="
[ "$(hw get BT)" = no ] && [ "$(hw get GOVERNMENT)" = 1 ] && ok "get BT / get GOVERNMENT" || bad "get: $(hw get BT) $(hw get GOVERNMENT)"
hw get WIFI >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "get of a key that is not there: exit 1" || bad "get WIFI: exit $rc"
hw get 'B.*' >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "get of a bad key name: exit 2" || bad "get 'B.*': exit $rc"
[ "$(hw show | wc -l)" = 6 ] && ok "show prints the six lines" || bad "show: $(hw show)"
rm -f "$W/run/hw.conf"
hw get BT >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "get with no hw.conf: exit 1" || bad "get with no file: exit $rc"
hw show >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "show with no hw.conf: exit 1" || bad "show with no file: exit $rc"
hw >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "no command: usage, exit 2" || bad "no command: exit $rc"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-hw || echo FAIL test-hw
exit $F
