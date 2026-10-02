#!/bin/bash
# Host test for the floor and the ramp of tsx-idled. It compiles tsx-idled with
# host gcc, so run it only on a build host or in CI. A fake backlight is a
# temp directory.
#   - the floor: BACKLIGHT_MIN, and the default of 3 percent of max_brightness
#   - blanking still goes to 0
#   - the ramp of the slider (400 ms) and of the ambient light (slower), on a
#     0..4095 and on a 0..31 backlight
#   - no extra timer while the level is steady
# Usage: tests/test-idled-ramp.sh [path-to-tsx-idled-binary]
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PID=; trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf $T' EXIT
BIN=${1:-}
if [ -z "$BIN" ]; then gcc -O2 -Wall -Werror -o $T/tsx-idled $HERE/src/tsx-idled.c || exit 1; BIN=$T/tsx-idled; fi
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); cat $T/log 2>/dev/null | tail -n 5; }
mkdir -p $T/input
MS() { date +%s%3N; }

# start MAX CONF-TEXT: a fake backlight with max_brightness MAX, lit at its day level
start() {
	[ -n "$PID" ] && { kill $PID 2>/dev/null; wait $PID 2>/dev/null; PID=; }
	rm -rf $T/bl $T/run; mkdir -p $T/bl/dev $T/run
	echo "$1" > $T/bl/dev/max_brightness; echo "$1" > $T/bl/dev/brightness
	printf 'BLANK_TIMEOUT=0\nNIGHT_START=0\nNIGHT_END=0\nDISPLAY_POWER_CMD=\nALS_WATCH=1\n%b' "$2" > $T/kiosk.conf
	TSX_BOOT_HOLD=0 TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/state TSX_RUN_DIR=$T/run \
		$BIN -c $T/kiosk.conf -v 2> $T/log &
	PID=$!
	sleep 0.5
}
b() { cat $T/bl/dev/brightness; }
st() { sed -n "s/^$1 //p" $T/run/brightness.state; }
waitb() { # VALUE SECONDS
	local i; for i in $(seq 1 $(($2 * 20))); do [ "$(b)" = "$1" ] && return 0; sleep 0.05; done; return 1
}
# sample FILE SECONDS: the backlight value every 20 ms
sample() { local end=$(( $(MS) + $2 )) ; : > $1; while [ "$(MS)" -lt "$end" ]; do b >> $1; sleep 0.02; done; }

echo "== the floor"
start 4095 'BRIGHTNESS_DAY=2400\nBRIGHTNESS_NIGHT=2400\nBACKLIGHT_MAX=4095\nBACKLIGHT_MIN=123\nRAMP_SLIDER_MS=0\nRAMP_AUTO_MS=0\n'
[ "$(st min)" = 123 ] && ok "brightness.state has min 123" || bad "min line: '$(st min)'"
echo -3000 > $T/run/brightness-offset; waitb 123 2 && ok "offset -3000 stops at the floor (123)" || bad "offset below the floor: $(b)"
echo 50 > $T/run/brightness; rm -f $T/run/brightness-offset; waitb 123 2 && ok "an absolute level of 50 is raised to 123" || bad "override below the floor: $(b)"
rm -f $T/run/brightness; echo 20 > $T/run/als-level; waitb 123 7 && ok "an als-level of 20 is raised to 123" || bad "als-level below the floor: $(b)"
kill -USR2 $PID; waitb 0 2 && ok "blanking still turns the backlight off" || bad "blank: $(b)"
kill -USR1 $PID; waitb 123 2 && ok "wake: back at the floor level" || bad "wake: $(b)"
start 4095 'BRIGHTNESS_DAY=2400\nBRIGHTNESS_NIGHT=2400\nBACKLIGHT_MAX=4095\nRAMP_SLIDER_MS=0\nRAMP_AUTO_MS=0\n'
[ "$(st min)" = 123 ] && ok "default floor on 0..4095 is 123 (3 percent)" || bad "default min: '$(st min)'"
start 31 'BRIGHTNESS_DAY=17\nBRIGHTNESS_NIGHT=17\nBACKLIGHT_MAX=23\nRAMP_SLIDER_MS=0\nRAMP_AUTO_MS=0\n'
[ "$(st min)" = 1 ] && ok "default floor on 0..31 is 1" || bad "default min on 31: '$(st min)'"
echo -40 > $T/run/brightness-offset; waitb 1 2 && ok "0..31: offset -40 stops at 1" || bad "0..31 floor: $(b)"

echo "== the slider ramp, 0..4095"
start 4095 'BRIGHTNESS_DAY=2400\nBRIGHTNESS_NIGHT=2400\nBACKLIGHT_MAX=4095\nBACKLIGHT_MIN=123\nRAMP_SLIDER_MS=400\nRAMP_AUTO_MS=2000\n'
[ "$(b)" = 2400 ] && ok "the start sets the level at once" || bad "start: $(b)"
echo -1000 > $T/run/brightness-offset
sample $T/s1 900
first=$(head -n 1 $T/s1); last=$(tail -n 1 $T/s1)
distinct=$(sort -u $T/s1 | wc -l)
[ "$last" = 1400 ] && ok "ends at 1400" || bad "end level $last"
[ "$first" -gt 1400 ] && ok "does not jump (first sample $first)" || bad "first sample $first"
[ "$distinct" -ge 8 ] && ok "$distinct different levels on the way" || bad "only $distinct levels"
sort -rn $T/s1 | diff -q - $T/s1 >/dev/null && ok "the level only goes down" || bad "the level is not monotone"
[ "$(sort -n $T/s1 | head -n 1)" -ge 1400 ] && ok "no undershoot" || bad "undershoot"
reached=$(awk -v n=0 '{n++; if ($1==1400 && !f) {f=1; print n}}' $T/s1)
[ "${reached:-99}" -le 30 ] && [ "${reached:-0}" -ge 10 ] && ok "takes about 400 ms ($reached samples of 20 ms)" || bad "reached 1400 after $reached samples"
sleep 1
echo "== the ambient light ramp is slower"
start 4095 'BRIGHTNESS_DAY=2400\nBRIGHTNESS_NIGHT=2400\nBACKLIGHT_MAX=4095\nBACKLIGHT_MIN=123\nRAMP_SLIDER_MS=400\nRAMP_AUTO_MS=2000\n'
echo 1000 > $T/run/als-level
sample $T/s2 600
[ "$(tail -n 1 $T/s2)" -gt 1000 ] && ok "after 600 ms the ambient ramp is not done ($(tail -n 1 $T/s2))" || bad "ambient ramp is too fast"
waitb 1000 4 && ok "the ambient ramp ends at 1000" || bad "ambient ramp end: $(b)"

echo "== no extra timer while the level is steady"
pid=$PID
c0=$(awk '/voluntary_ctxt_switches/ && !/nonvol/ {print $2}' /proc/$pid/status)
sleep 3
c1=$(awk '/voluntary_ctxt_switches/ && !/nonvol/ {print $2}' /proc/$pid/status)
[ $((c1 - c0)) -le 8 ] && ok "$((c1 - c0)) wakeups in 3 s while steady" || bad "$((c1 - c0)) wakeups in 3 s"

echo "== the slider ramp, 0..31"
start 31 'BRIGHTNESS_DAY=17\nBRIGHTNESS_NIGHT=17\nBACKLIGHT_MAX=23\nRAMP_SLIDER_MS=400\nRAMP_AUTO_MS=2000\n'
echo 6 > $T/run/brightness-offset
sample $T/s3 800
[ "$(tail -n 1 $T/s3)" = 23 ] && ok "17 + 6 ends at 23" || bad "end $(tail -n 1 $T/s3)"
sort -n $T/s3 | diff -q - $T/s3 >/dev/null && ok "steps only go up, no oscillation" || bad "not monotone"
[ "$(sort -u $T/s3 | wc -l)" -ge 5 ] && ok "every step shows ($(sort -u $T/s3 | wc -l) levels)" || bad "steps skipped"
echo 0 > $T/run/brightness-offset; waitb 17 2 && ok "offset 0: back to 17" || bad "back: $(b)"

echo "== a ramp that a new change cuts"
start 4095 'BRIGHTNESS_DAY=2400\nBRIGHTNESS_NIGHT=2400\nBACKLIGHT_MAX=4095\nBACKLIGHT_MIN=123\nRAMP_SLIDER_MS=400\nRAMP_AUTO_MS=2000\n'
echo -2000 > $T/run/brightness-offset; sleep 0.15; echo -200 > $T/run/brightness-offset
waitb 2200 2 && ok "a second change in the middle of a ramp ends at its own level" || bad "cut ramp: $(b)"

echo "== $N passed, $F failed"
[ $F = 0 ] && echo "PASS tsx-idled ramp" || exit 1
