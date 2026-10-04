#!/bin/bash
# Host test: the learning brightness daemon of tsx-linux-common
# (tsx_brightness.py als-daemon) with the real xx60 board files. The daemon has
# no built-in numbers. The xx60 gets them from rootfs/overlay/etc/tsx/als.conf
# (the start curve ALS_CURVE) and from panel-board.conf (BACKLIGHT_MAX 23,
# BACKLIGHT_MIN 1). The xx60 backlight device (mp3309c) allows 0 to 31, so the
# board value is the limit. The test checks that the xx60 curve and the top
# level 23 reach the daemon, and that the daemon uses nothing else. It needs
# no panel and no compiler.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED common/test-brightness-xx60: no python3 on this host"; exit 0; }
MOD=$COMMON/base/usr/local/lib/tsx/tsx_brightness.py
ALS=$XX60/rootfs/overlay/etc/tsx/als.conf
T=$(mktemp -d); trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
PID=
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== the xx60 board files =="
eq "$(sed -n 's/^ALS_CURVE=//p' "$ALS" | tr -d '"')" "0:3 5:5 20:8 80:12 300:17 1000:21 3000:23" "als.conf: the xx60 start curve"
eq "$(sed -n 's/^BACKLIGHT_MAX=//p' "$XX60_PANEL_BOARD")" 23 "panel-board.conf: BACKLIGHT_MAX 23"
eq "$(sed -n 's/^BACKLIGHT_MIN=//p' "$XX60_PANEL_BOARD")" 1 "panel-board.conf: BACKLIGHT_MIN 1"
eq "$(sed -n 's/^BRIGHTNESS_DAY=//p' "$XX60_PANEL_BOARD")" 17 "panel-board.conf: BRIGHTNESS_DAY 17"

echo "== the daemon with the xx60 files =="
R=$T/run; mkdir -p "$R" "$T/data" "$T/bl/dev"
printf 'BRIGHTNESS_LEARN=on\n' > "$T/kiosk.conf"
printf 'lux 150\nraw 150\nreport 150\nlevel 17\nauto on\n' > "$R/als.state"
echo "on 12" > "$T/idled.state"
# No max line in brightness.state and a device that allows 31: the 23 must come from the board file.
printf 'level 12\nbase 17\noffset -5\noverride 0\n' > "$R/brightness.state"
echo 12 > "$T/bl/dev/brightness"; echo 31 > "$T/bl/dev/max_brightness"
export TSX_RUN_DIR=$R TSX_ALS_CONF=$ALS TSX_KIOSK_CONF=$T/kiosk.conf TSX_PANEL_BOARD_CONF=$XX60_PANEL_BOARD \
	TSX_IDLED_STATE=$T/idled.state TSX_LEARN_FILE=$T/data/learn.json TSX_LEARN_TICK=0.1 TSX_LEARN_HOLD_S=0.5 \
	TSX_LEARN_RELEASE_S=0.3 TSX_LEARN_GRACE_S=0.3 TSX_BACKLIGHT_DIR=$T/bl
python3 "$MOD" als-daemon > "$T/daemon.log" 2>&1 &
PID=$!
sleep 0.6; echo -5 > "$R/brightness-offset"
for i in $(seq 1 60); do [ -s "$R/als-curve" ] && break; sleep 0.1; done
kill $PID 2>/dev/null; wait $PID 2>/dev/null
curve=$(cat "$R/als-curve" 2>/dev/null)
echo "  curve: $curve"
[ -n "$curve" ] && ok "the daemon learns a held offset and writes als-curve" || bad "no als-curve: $(cat "$T/daemon.log")"
eq "$(echo "$curve" | tr ' ' '\n' | head -n 1)" "0:3" "the curve starts with the xx60 night level 3 at 0 lux"
eq "$(echo "$curve" | tr ' ' '\n' | tail -n 1)" "3000:23" "the curve ends at the xx60 top level 23 (not the device limit 31)"
eq "$(echo "$curve" | tr ' ' '\n' | awk -F: '{ if ($2 + 0 > m + 0) m = $2 } END { print m + 0 }')" 23 "no level of the curve is above 23"
echo "$curve" | tr ' ' '\n' | grep -qx '150:12' && ok "the learned point is at 150 lux, level 12" || bad "no 150:12 in the curve"
grep -q 'no ALS_CURVE' "$T/daemon.log" && bad "the daemon found no ALS_CURVE in the xx60 als.conf" || ok "the daemon takes the start curve from als.conf"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS common/test-brightness-xx60" || { echo "FAIL common/test-brightness-xx60"; exit 1; }
