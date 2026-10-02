#!/bin/bash
# Host test for the learning brightness curve (overlay/usr/local/lib/tsx/
# tsx_brightness.py, docs/adaptive-brightness.md). No compiler, no hardware.
#   1. the curve, the user points, the monotone correction, the file, the
#      reset and the Learner (tests/brightness-learn-check.py)
#   2. the xx60 daemon "als-daemon" against fake files: it learns a held
#      offset, writes /run/tsx/als-curve, removes the offset, and forgets on
#      the reset flag
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
MOD=$HERE/overlay/usr/local/lib/tsx/tsx_brightness.py
T=$(mktemp -d); trap 'rm -rf $T' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
python3 "$HERE/tests/brightness-learn-check.py" "$MOD" && ok "brightness-learn-check.py" || bad "brightness-learn-check.py"

echo "== als-daemon (xx60)"
R=$T/run; mkdir -p $R $T/data
printf 'ALS_CURVE="0:3 5:5 20:8 80:12 300:17 1000:21 3000:23"\n' > $T/als.conf
printf 'BACKLIGHT_MAX=23\nBACKLIGHT_MIN=1\n' > $T/kiosk.conf
printf 'lux 150\nraw 150\nreport 150\nlevel 15\nauto on\n' > $R/als.state
echo "on 15" > $T/idled.state
printf 'level 9\nbase 15\noffset -6\noverride 0\nmax 23\nmin 1\n' > $R/brightness.state
mkdir -p $T/bl/dev; echo 9 > $T/bl/dev/brightness
export TSX_RUN_DIR=$R TSX_ALS_CONF=$T/als.conf TSX_KIOSK_CONF=$T/kiosk.conf TSX_PANEL_BOARD_CONF=$T/none \
	TSX_IDLED_STATE=$T/idled.state TSX_LEARN_FILE=$T/data/learn.json TSX_LEARN_TICK=0.1 TSX_LEARN_HOLD_S=0.5 TSX_LEARN_RELEASE_S=0.3 TSX_LEARN_GRACE_S=0.3 TSX_BACKLIGHT_DIR=$T/bl
python3 "$MOD" als-daemon > $T/daemon.log 2>&1 &
PID=$!
sleep 0.6; echo -6 > $R/brightness-offset   # a manual change after the start
for i in $(seq 1 60); do [ -s $R/als-curve ] && break; sleep 0.1; done
[ -s $R/als-curve ] && ok "als-curve written after a held offset" || bad "no als-curve"
curve=$(cat $R/als-curve 2>/dev/null)
echo "  curve: $curve"
echo "$curve" | grep -Eq '^[0-9]+:[0-9]+( [0-9]+:[0-9]+)*$' && ok "als-curve has the form tsx-als reads" || bad "als-curve form"
lvl=$(awk -v t=150 'BEGIN{RS=" "} {split($0,a,":"); if (a[1]+0<=t) {pl=a[1]; ps=a[2]} else if (!d) {d=1; nl=a[1]; ns=a[2]}} END{printf "%d", ps+(ns-ps)*(t-pl)/(nl-pl)+0.5}' $R/als-curve)
[ "$lvl" -ge 8 ] && [ "$lvl" -le 10 ] && ok "the curve gives about 9 at 150 lux ($lvl)" || bad "level at 150 lux: $lvl"
for i in $(seq 1 40); do [ ! -e $R/brightness-offset ] && break; sleep 0.1; done
[ ! -e $R/brightness-offset ] && ok "the offset goes after the curve is out" || bad "offset left"
[ -s $T/data/learn.json ] && ok "the point is in the file" || bad "no file"
touch $R/brightness-learn.reset
for i in $(seq 1 30); do [ ! -e $R/als-curve ] && break; sleep 0.1; done
[ ! -e $R/als-curve ] && [ ! -e $T/data/learn.json ] && ok "reset: als-curve and the file are gone" || bad "reset left files"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
# an offset that was there before the start never learns
rm -f $R/als-curve $T/data/learn.json; echo -6 > $R/brightness-offset
python3 "$MOD" als-daemon > $T/daemon3.log 2>&1 &
PID=$!
sleep 2
[ ! -e $R/als-curve ] && [ ! -e $T/data/learn.json ] && [ -e $R/brightness-offset ] && ok "an offset from before the start is not learned" || bad "learned a stale offset"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
rm -f $R/brightness-offset
# a new start loads a saved file
python3 - "$MOD" "$T/data/learn.json" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tb", sys.argv[1]); tb = importlib.util.module_from_spec(spec); spec.loader.exec_module(tb)
c = tb.Curve([(0, 3), (5, 5), (20, 8), (80, 12), (300, 17), (1000, 21), (3000, 23)], 1, 23)
c.add_user_point(tb.lux_to_x(40), 4, 1)
open(sys.argv[2], "w").write(c.to_json())
PY
rm -f $R/brightness-offset
python3 "$MOD" als-daemon > $T/daemon2.log 2>&1 &
PID=$!
for i in $(seq 1 30); do [ -s $R/als-curve ] && break; sleep 0.1; done
[ -s $R/als-curve ] && ok "a start with a saved file publishes the curve" || bad "no curve after start"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "== $N passed, $F failed"
[ $F = 0 ] && echo "PASS brightness learn" || exit 1
