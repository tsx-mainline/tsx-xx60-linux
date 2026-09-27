#!/bin/bash
# Host check of the Android-side installer against the REAL stock tool set in
# system.img (3.002.1061): extracts /system/bin + /system/xbin read-only with
# debugfs, then
#   1. every busybox applet the scripts use exists in the stock busybox
#      (applet table parsed from the binary: the bionic busybox hangs under
#      qemu-user in a futex, so it cannot simply be asked with --list),
#   2. bash, fw_printenv, fw_setenv exist; fw_env.config points at mmcblk0 0x100000,
#   3. `bash -n` of every script with the stock static bash 3.2 (qemu-arm),
#   4. no bash-4 syntax slipped in (bash 3.2 has no ${x,,} / ${x^^} / mapfile / |&).
# Usage: tests/check-android-tools.sh [system.img]   (default: $SYSIMG)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:-${SYSIMG:-}}
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	echo "SKIPPED: needs the real Crestron system.img (arg 1 or \$SYSIMG); not present here"
	exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/system"
for d in bin xbin etc; do debugfs -R "rdump /$d $W/system" "$IMG" >/dev/null 2>&1 || true; done
rc=0
ok() { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; rc=1; }

echo "== 1. busybox applets ($(strings "$W/system/bin/busybox" | grep -m1 'BusyBox v'))"
python3 - "$W/system/bin/busybox" > "$W/applets.txt" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b"[\0[[\0"); out = []
while True:
    e = d.find(b"\0", i); n = d[i:e]
    if not n or not all(32 < c < 127 for c in n): break
    out.append(n.decode()); i = e + 1
print("\n".join(out))
PY
echo "  stock busybox has $(wc -l < "$W/applets.txt") applets"
. "$HERE/android/tsx-lib.sh"
used="$TSX_APPLETS sort fuser blkid tar reboot"
# applets called as "$BB <applet>" anywhere in the Android scripts
used="$used $(grep -ho '"\$BB" [a-z0-9]*' "$HERE"/android/*.sh | awk '{print $2}' | sort -u | tr '\n' ' ')"
for a in $(echo $used | tr ' ' '\n' | sort -u); do
	case "$a" in grep|--list) [ "$a" = --list ] && continue;; esac
	grep -qx "$a" "$W/applets.txt" && ok "applet $a" || bad "applet $a missing in stock busybox"
done

echo "== 2. stock tools"
for f in bin/bash bin/busybox bin/fw_printenv; do [ -e "$W/system/$f" ] && ok "/system/$f" || bad "/system/$f missing"; done
[ "$(readlink "$W/system/bin/fw_setenv")" = fw_printenv ] && ok "/system/bin/fw_setenv -> fw_printenv" || bad "fw_setenv link"
grep -E '^[^#]' "$W/system/etc/fw_env.config" | grep -q '^/dev/block/mmcblk0[[:space:]]\+0x100000[[:space:]]\+0x10000' \
	&& ok "fw_env.config: /dev/block/mmcblk0 0x100000 0x10000 (the env U-Boot reads)" || bad "fw_env.config differs"

echo "== 3. bash -n with the stock bash ($(env -i LC_ALL=C qemu-arm "$W/system/bin/bash" --version | head -1))"
for f in "$HERE"/android/*.sh; do
	env -i LC_ALL=C qemu-arm "$W/system/bin/bash" -n "$f" && ok "bash 3.2 -n $(basename "$f")" || bad "bash 3.2 -n $(basename "$f")"
done

echo "== 4. bash-4-only syntax"
if grep -nE '\$\{[a-zA-Z_]+(,,|\^\^)\}|mapfile|readarray|\|&|declare -A|\[\[.*=~' "$HERE"/android/*.sh; then bad "bash-4 syntax above"; else ok "none"; fi
[ $rc = 0 ] && echo "PASS check-android-tools" || echo "FAIL check-android-tools"
exit $rc
