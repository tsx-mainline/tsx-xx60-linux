#!/bin/bash
# Host unit test for tsx-idled: fake MP3309C backlight (0..31) in a temp dir,
# a FIFO as input device, events in the host's struct input_event layout.
# Usage: tests/test-idled.sh [path-to-tsx-idled-binary]   (default: builds it with host gcc)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PID=; trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf $T' EXIT
BIN=${1:-}
if [ -z "$BIN" ]; then gcc -O2 -Wall -o $T/tsx-idled $HERE/src/tsx-idled.c; BIN=$T/tsx-idled; fi
mkdir -p $T/bl/mp3309c $T/input
echo 31 > $T/bl/mp3309c/max_brightness; echo 17 > $T/bl/mp3309c/brightness
mkfifo $T/input/event0
cat > $T/kiosk.conf <<C
BLANK_TIMEOUT=2
BRIGHTNESS_DAY=10
BRIGHTNESS_NIGHT=10
BACKLIGHT_MAX=23
NIGHT_START=0
NIGHT_END=0
WAKE_SWALLOW_MS=300
POWER_KEY=blank
OSK_GESTURE=threefinger
OSK_TAP_MS=500
OSK_TOGGLE_CMD="echo x >> $T/osk"
OVERLAY_GESTURE=fourfinger
OVERLAY_CMD="echo y >> $T/ovl"
DISPLAY_POWER_CMD=
C
exec 7<>$T/input/event0     # keep a writer open so the FIFO does not hit EOF
ev() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&7; }
# evs "type code value" ... : one frame, SYN_REPORT at the end
evs() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(b"".join(struct.pack("llHHi",int(t),0,*map(int,a.split())) for a in sys.argv[1:]+["0 0 0"]))' "$@" >&7; }
# two-finger tap: slots 0 and 1 go down at (x,y) and (x2,y2), then up after $1 s. $2 = move finger 2 by px
tap2() { evs "3 47 0" "3 57 11" "3 53 100" "3 54 100" "3 47 1" "3 57 12" "3 53 300" "3 54 100" "1 330 1"
	 [ "$2" != 0 ] && evs "3 47 1" "3 53 $((300 + $2))"
	 sleep $1; evs "3 47 0" "3 57 -1" "3 47 1" "3 57 -1" "1 330 0"; }
# three-finger tap (the default OSK_GESTURE), up after $1 s. $2 = move finger 3 by px
tap3() { evs "3 47 0" "3 57 21" "3 53 100" "3 54 100" "3 47 1" "3 57 22" "3 53 300" "3 54 100" "3 47 2" "3 57 23" "3 53 500" "3 54 100" "1 330 1"
	 [ "${2:-0}" != 0 ] && evs "3 47 2" "3 53 $((500 + $2))"
	 sleep $1; evs "3 47 0" "3 57 -1" "3 47 1" "3 57 -1" "3 47 2" "3 57 -1" "1 330 0"; }
# four-finger tap (OVERLAY_GESTURE), up after $1 s
tap4() { evs "3 47 0" "3 57 31" "3 53 100" "3 54 100" "3 47 1" "3 57 32" "3 53 300" "3 54 100" "3 47 2" "3 57 33" "3 53 500" "3 54 100" "3 47 3" "3 57 34" "3 53 700" "3 54 100" "1 330 1"
	 sleep $1; evs "3 47 0" "3 57 -1" "3 47 1" "3 57 -1" "3 47 2" "3 57 -1" "3 47 3" "3 57 -1" "1 330 0"; }
osk() { [ -f $T/osk ] && wc -l < $T/osk || echo 0; }
ovl() { [ -f $T/ovl ] && wc -l < $T/ovl || echo 0; }
mkdir -p $T/run
TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/state TSX_RUN_DIR=$T/run $BIN -c $T/kiosk.conf -v 2>$T/log &
PID=$!
fail() { echo "FAIL: $*"; cat $T/log; exit 1; }
b() { cat $T/bl/mp3309c/brightness; }
sleep 0.5; [ "$(b)" = 10 ] || fail "initial level $(b), want 10"
sleep 2.2; [ "$(b)" = 0 ] || fail "not blanked after timeout: $(b)"; grep -q blank $T/state || fail state
ev 1 330 1                  # BTN_TOUCH down
sleep 0.3; [ "$(b)" = 10 ] || fail "no wake on touch: $(b)"
sleep 0.5
ev 1 116 1; sleep 0.2; [ "$(b)" = 0 ] || fail "power key press did not blank: $(b)"
ev 1 116 0; sleep 0.3; [ "$(b)" = 0 ] || fail "power key release woke the screen: $(b)"
ev 1 116 1; sleep 0.3; [ "$(b)" = 10 ] || fail "second power key press did not wake: $(b)"
kill -USR2 $PID; sleep 1.2; [ "$(b)" = 0 ] || fail "USR2 did not blank"
kill -USR1 $PID; sleep 0.4; [ "$(b)" = 10 ] || fail "USR1 did not wake"
# front-panel race: tsx-buttons blanks (USR2) on a front key, then its release arrives
kill -USR2 $PID; sleep 1.2; ev 1 183 0; sleep 0.3; [ "$(b)" = 0 ] || fail "key release (KEY_F13 0) woke the screen: $(b)"
kill -USR1 $PID; sleep 0.4; [ "$(b)" = 10 ] || fail "USR1 did not wake (after release test)"
tap2 0.1 0; sleep 0.3; [ "$(osk)" = 0 ] || fail "two-finger tap ran OSK_TOGGLE_CMD (OSK_GESTURE=threefinger)"
tap3 0.1; sleep 0.3; [ "$(osk)" = 1 ] || fail "three-finger tap did not run OSK_TOGGLE_CMD ($(osk))"
evs "3 47 0" "3 57 13" "3 53 50" "3 54 50" "1 330 1"; sleep 0.1; evs "3 57 -1" "1 330 0"
sleep 0.3; [ "$(osk)" = 1 ] || fail "one-finger tap ran OSK_TOGGLE_CMD"
tap3 0.8; sleep 0.3; [ "$(osk)" = 1 ] || fail "slow three-finger press ran OSK_TOGGLE_CMD"
tap3 0.1 80; sleep 0.3; [ "$(osk)" = 1 ] || fail "three-finger swipe ran OSK_TOGGLE_CMD"
tap4 0.1; sleep 0.3; [ "$(ovl)" = 1 ] || fail "four-finger tap did not run OVERLAY_CMD ($(ovl))"
[ "$(osk)" = 1 ] || fail "four-finger tap ran OSK_TOGGLE_CMD ($(osk))"
tap3 0.1; sleep 0.3; [ "$(ovl)" = 1 ] || fail "three-finger tap ran OVERLAY_CMD (OVERLAY_GESTURE=fourfinger)"
[ "$(osk)" = 2 ] || fail "three-finger tap did not run OSK_TOGGLE_CMD again ($(osk))"
tap4 0.8; sleep 0.3; [ "$(ovl)" = 1 ] || fail "slow four-finger press ran OVERLAY_CMD"
kill -USR2 $PID; sleep 0.3; tap3 0.1; sleep 0.9; [ "$(osk)" = 2 ] || fail "wake touch (three fingers) ran OSK_TOGGLE_CMD"
[ "$(b)" = 10 ] || fail "three-finger wake: $(b)"
echo 16 > $T/bl/mp3309c/brightness   # drm unblank restores 16 behind our back
for i in 1 2 3 4 5 6; do ev 1 330 1; sleep 1; done
[ "$(b)" = 10 ] || fail "external change not corrected: $(b)"
sed -i 's/BRIGHTNESS_DAY=10/BRIGHTNESS_DAY=40/;s/BRIGHTNESS_NIGHT=10/BRIGHTNESS_NIGHT=40/' $T/kiosk.conf
kill -HUP $PID; sleep 0.4; [ "$(b)" = 23 ] || fail "HUP reload / cap: $(b), want 23 (cap)"
kill $PID; wait $PID || true; PID=
[ "$(b)" = 23 ] || fail "exit did not leave the backlight on"
# the board layer: a second -c file wins over the first one, a file that is missing is no error
printf 'BRIGHTNESS_DAY=7\nBRIGHTNESS_NIGHT=7\n' > $T/board.conf
TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/state2 TSX_RUN_DIR=$T/run $BIN -c $T/kiosk.conf -c $T/board.conf -c $T/none.conf -v 2>$T/log2 &
PID=$!
sleep 0.6; [ "$(b)" = 7 ] || fail "the board file did not win: $(b), want 7"
kill $PID; wait $PID || true; PID=
grep -q 'no .*none.conf' $T/log2 && fail "a missing board file was reported"
# no value in any config: the levels are shares of max_brightness (day 55 %, night 26 %, cap 74 %)
run_defaults() { # MAX CONF-OR-none; prints the level and the max of brightness.state
	rm -rf $T/bl2 $T/run2; mkdir -p $T/bl2/pwm $T/run2
	echo "$1" > $T/bl2/pwm/max_brightness; echo "$1" > $T/bl2/pwm/brightness
	TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl2 TSX_STATE_FILE=$T/state3 TSX_RUN_DIR=$T/run2 $BIN -c "$2" -v 2>$T/log3 &
	PID=$!; sleep 0.6; kill $PID; wait $PID || true; PID=
	echo "$(cat $T/bl2/pwm/brightness) $(sed -n 's/^max //p' $T/run2/brightness.state)"
}
printf 'NIGHT_START=0\nNIGHT_END=0\n' > $T/day.conf
[ "$(run_defaults 4095 $T/day.conf)" = "2252 3030" ] || fail "defaults on 0..4095: $(run_defaults 4095 $T/day.conf), want 2252 3030"
[ "$(run_defaults 31 $T/day.conf)" = "17 23" ] || fail "defaults on 0..31: $(run_defaults 31 $T/day.conf), want 17 23"
printf 'NIGHT_START=0\nNIGHT_END=0\nBRIGHTNESS_DAY=2400\n' > $T/day2.conf
[ "$(run_defaults 4095 $T/day2.conf)" = "2400 3030" ] || fail "BRIGHTNESS_DAY only: $(run_defaults 4095 $T/day2.conf), want 2400 3030"
set -- $(run_defaults 4095 $T/none.conf)
[ "$1" -le 3030 ] && [ "$1" -ge 1065 ] || fail "no config file on 0..4095: level $1 is outside 1065..3030"
# a manual offset has the range of the backlight: -1000 on a 0..4095 base of 2400 gives 1400
rm -rf $T/bl2 $T/run2; mkdir -p $T/bl2/pwm $T/run2
echo 4095 > $T/bl2/pwm/max_brightness; echo 4095 > $T/bl2/pwm/brightness; echo -1000 > $T/run2/brightness-offset
printf 'NIGHT_START=0\nNIGHT_END=0\nBRIGHTNESS_DAY=2400\nBRIGHTNESS_NIGHT=2400\nBACKLIGHT_MAX=4095\n' > $T/off.conf
TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl2 TSX_STATE_FILE=$T/state3 TSX_RUN_DIR=$T/run2 $BIN -c $T/off.conf -v 2>$T/log3 &
PID=$!; sleep 0.6; kill $PID; wait $PID || true; PID=
[ "$(cat $T/bl2/pwm/brightness)" = 1400 ] || fail "offset -1000 on 2400 of 0..4095: $(cat $T/bl2/pwm/brightness), want 1400"
echo "PASS tsx-idled"; sed 's/^/  log: /' $T/log
