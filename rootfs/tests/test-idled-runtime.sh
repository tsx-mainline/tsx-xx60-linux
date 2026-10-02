#!/bin/bash
# Host test for the runtime files of tsx-idled in /run/tsx (TSX_RUN_DIR). It
# covers these files and settings:
#  - the brightness offset, which is the local manual setting of the key-strip
#    slide and the quick-settings overlay. It applies on top of ALS and the
#    schedule.
#  - the absolute override, which wins over the offset
#  - the blank-timeout override (panel.conf BLANK_TIMEOUT, the HA
#    "Blank timeout")
#  - last-input ("touched recently") and brightness.state
# A change to brightness, brightness-offset or blank-timeout must apply at
# once (inotify) and not at the next 5 s tick. The test uses a fake backlight
# sysfs and a FIFO as the input device. It runs locally with gcc (no hardware).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../rootfs/src/tsx-idled.c
T=$(mktemp -d); PID=; trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf $T' EXIT
gcc -O2 -Wall -Werror -o $T/tsx-idled $SRC
mkdir -p $T/bl/mp3309c $T/input $T/run
echo 31 > $T/bl/mp3309c/max_brightness; echo 17 > $T/bl/mp3309c/brightness
mkfifo $T/input/event0
printf 'RAMP_SLIDER_MS=0\nRAMP_AUTO_MS=0\nBLANK_TIMEOUT=0\nBRIGHTNESS_DAY=10\nBRIGHTNESS_NIGHT=10\nBACKLIGHT_MAX=23\nNIGHT_START=0\nNIGHT_END=0\nWAKE_SWALLOW_MS=200\nDISPLAY_POWER_CMD=\n' > $T/kiosk.conf
exec 7<>$T/input/event0
ev() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&7; }
TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/state TSX_RUN_DIR=$T/run $T/tsx-idled -c $T/kiosk.conf -v > $T/log 2>&1 &
PID=$!
fail=0; b() { cat $T/bl/mp3309c/brightness; }
st() { sed -n "s/^$1 //p" $T/run/brightness.state; }
pass() { echo "ok   $*"; }
no() { echo "FAIL $*"; fail=1; }
chk() { if [ "$(b)" = "$1" ]; then pass "$2 ($1)"; else no "$2: $(b), want $1"; fi; }
sleep 1; chk 10 "day level"
[ "$(st level)/$(st base)/$(st offset)/$(st override)/$(st max)/$(st blank_timeout)" = 10/10/0/0/23/0 ] \
	&& pass "brightness.state: level 10 base 10 offset 0 override 0 max 23 blank_timeout 0" || no "brightness.state: $(tr '\n' ' ' < $T/run/brightness.state)"

echo 3 > $T/run/brightness-offset; sleep 0.4; chk 13 "offset +3 applies at once (inotify)"
[ "$(st offset)" = 3 ] && pass "state offset 3" || no "state offset $(st offset)"
echo -12 > $T/run/brightness-offset; sleep 0.4; chk 1 "offset -12 clamped to 1"
echo 40 > $T/run/brightness-offset; sleep 0.4; chk 23 "offset +40 capped by BACKLIGHT_MAX"
echo 2 > $T/run/brightness-offset.tmp; mv $T/run/brightness-offset.tmp $T/run/brightness-offset; sleep 0.4
chk 12 "offset written by rename (tmp + mv) applies at once"
echo 12 > $T/run/als-level; sleep 5.5; chk 14 "offset on top of a fresh als-level (12 + 2)"
[ "$(st base)" = 12 ] && pass "state base = ALS level 12" || no "state base $(st base)"
echo 5 > $T/run/brightness; sleep 0.4; chk 5 "absolute override wins over ALS + offset, at once"
[ "$(st override)/$(st level)" = 5/5 ] && pass "state override 5, level 5" || no "state override/level $(st override)/$(st level)"
rm $T/run/brightness; sleep 0.4; chk 14 "override removed: ALS + offset again, at once"
rm $T/run/brightness-offset; sleep 0.4; chk 12 "offset removed: ALS level"
echo garbage > $T/run/brightness-offset; sleep 0.4; chk 12 "garbage offset ignored"
# ALS_WATCH=1: a light sensor service that writes als-level only when the level changes
printf 'ALS_WATCH=1\n' >> $T/kiosk.conf; kill -HUP $PID; sleep 0.4
echo 20 > $T/run/als-level; sleep 0.4; chk 20 "ALS_WATCH=1: a new als-level applies at once"
rm -f $T/run/brightness-offset $T/run/als-level
sed -i '/^ALS_WATCH=1$/d' $T/kiosk.conf; kill -HUP $PID; sleep 0.4

echo 1 > $T/run/blank-timeout; sleep 2; chk 0 "blank-timeout 1 s (runtime file) blanks"
grep -q 'blank timeout 1s (runtime override)' $T/log && pass "override logged" || no "no log line for the override"
grep -q '^blank' $T/state && pass "state blank" || no "state: $(cat $T/state)"
echo 30 > $T/run/blank-timeout; rm -f $T/run/last-input   # no second blank during the checks below
ev 1 330 1; sleep 0.5
[ "$(b)" -gt 0 ] && pass "touch wakes ($(b))" || no "no wake on touch"
li=$(cat $T/run/last-input 2>/dev/null || echo 0); now=$(date +%s)
[ $((now - li)) -le 2 ] && pass "last-input written ($li, now $now)" || no "last-input '$li', now $now"
rm $T/run/blank-timeout; sleep 0.3
[ "$(st blank_timeout)" = 0 ] && pass "blank-timeout removed: BLANK_TIMEOUT 0 again" || no "state blank_timeout $(st blank_timeout)"
sleep 2; [ "$(b)" -gt 0 ] && pass "no blanking with BLANK_TIMEOUT=0" || no "blanked without a timeout"
echo 1 > $T/run/blank-timeout; kill -HUP $PID; sleep 2; chk 0 "HUP keeps the runtime blank-timeout"
kill $PID; wait $PID || true; PID=
[ $fail = 0 ] && echo "PASS tsx-idled runtime files" || { cat $T/log; exit 1; }
