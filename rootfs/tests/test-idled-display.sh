#!/bin/bash
# Host test for the display output control of tsx-idled (DISPLAY_POWER_CMD)
# and for its helper tsx-display-power. It uses a fake backlight sysfs, a FIFO
# as the input device, a fake swaymsg and fake framebuffer blank files. It
# runs locally with gcc (no hardware).
# tsx-idled:
#  - blank: the backlight goes to 0 before the command gets "off"
#  - wake (signal and touch): the command gets "on" while the backlight is
#    still 0, and the backlight comes on after it
#  - "off" repeats while the screen stays blank
#  - a command that hangs does not hold the wake longer than
#    DISPLAY_POWER_TIMEOUT_MS
#  - an empty DISPLAY_POWER_CMD runs nothing
#  - start and a stop while blank run "on"
# tsx-display-power:
#  - it sends the request again when sway refuses the first "power on"
#  - it skips a stale socket, reports failure after TSX_DISPLAY_TRIES, and
#    uses the framebuffer when no sway runs
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../rootfs/src/tsx-idled.c
DP=$HERE/../../rootfs/overlay/usr/local/bin/tsx-display-power
T=$(mktemp -d); PID=; trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf $T' EXIT
gcc -O2 -Wall -Werror -o $T/tsx-idled $SRC
mkdir -p $T/bl/mp3309c $T/input $T/run
echo 31 > $T/bl/mp3309c/max_brightness; echo 17 > $T/bl/mp3309c/brightness
mkfifo $T/input/event0
# The fake command writes "<arg> <brightness at call time>" per call.
cat > $T/disp <<EOF
#!/bin/sh
[ -n "\${DISP_SLEEP:-}" ] && sleep "\$DISP_SLEEP"
echo "\$1 \$(cat $T/bl/mp3309c/brightness)" >> $T/calls
EOF
chmod +x $T/disp
conf() {
	printf 'BLANK_TIMEOUT=0\nBRIGHTNESS_DAY=10\nBRIGHTNESS_NIGHT=10\nBACKLIGHT_MAX=23\nNIGHT_START=0\nNIGHT_END=0\nWAKE_SWALLOW_MS=200\n' > $T/kiosk.conf
	printf '%s\n' "$@" >> $T/kiosk.conf
}
exec 7<>$T/input/event0
ev() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&7; }
start() {
	TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/state TSX_RUN_DIR=$T/run \
		TSX_DISPLAY_REPEAT_MS=${REPEAT_MS:-600000} $T/tsx-idled -c $T/kiosk.conf -v >> $T/log 2>&1 &
	PID=$!
}
stop() { kill $PID; wait $PID || true; PID=; }
fail=0; b() { cat $T/bl/mp3309c/brightness; }
pass() { echo "ok   $*"; }
no() { echo "FAIL $*"; fail=1; }
calls() { [ -f $T/calls ] && tr '\n' ',' < $T/calls || true; }
expect() { if [ "$(calls)" = "$1" ]; then pass "$2 ($1)"; else no "$2: calls '$(calls)', want '$1'"; fi; }

# 1. order of backlight and display output
conf "DISPLAY_POWER_CMD=$T/disp"
start; sleep 0.5
expect "on 17," "start runs on (before the first level)"
[ "$(b)" = 10 ] && pass "start level 10" || no "start level $(b)"
rm -f $T/calls
kill -USR2 $PID; sleep 0.4
expect "off 0," "blank: backlight 0, then off"
kill -USR1 $PID; sleep 0.4
expect "off 0,on 0," "wake: on while the backlight is still 0"
[ "$(b)" = 10 ] && pass "wake: level 10 after on" || no "wake: level $(b)"
rm -f $T/calls
kill -USR2 $PID; sleep 0.4
ev 1 330 1; sleep 0.1; ev 1 330 0; sleep 0.4
expect "off 0,on 0," "touch wake: on before the backlight"
[ "$(b)" = 10 ] && pass "touch wake: level 10" || no "touch wake: level $(b)"
rm -f $T/calls
kill -USR2 $PID; sleep 0.4; stop
expect "off 0,on 0," "stop while blank runs on"
[ "$(b)" = 10 ] && pass "stop: level 10" || no "stop: level $(b)"

# 2. "off" repeats while blank
rm -f $T/calls; REPEAT_MS=500 start; sleep 0.3; rm -f $T/calls
kill -USR2 $PID; sleep 2.3
n=$(grep -c '^off' $T/calls || true)
[ "$n" -ge 3 ] && pass "off repeats while blank ($n calls in 2.3 s)" || no "off repeat: $n calls, want >= 3"
kill -USR1 $PID; sleep 0.3; rm -f $T/calls; sleep 1.2
[ ! -f $T/calls ] && pass "no repeat while awake" || no "calls while awake: $(calls)"
stop

# 3. a command that hangs
conf "DISPLAY_POWER_CMD=$T/disp" "DISPLAY_POWER_TIMEOUT_MS=300"
rm -f $T/calls; DISP_SLEEP=5 start; sleep 0.6
kill -USR2 $PID; sleep 0.5
t0=$(date +%s%N); kill -USR1 $PID
while [ "$(b)" != 10 ] && [ $(( ($(date +%s%N) - t0) / 1000000 )) -lt 3000 ]; do sleep 0.05; done
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
[ "$ms" -lt 1000 ] && pass "hung command: wake after $ms ms" || no "hung command: wake took $ms ms"
grep -q "no result after" $T/log && pass "hung command logged" || no "hung command not logged"
stop

# 4. empty DISPLAY_POWER_CMD
conf "DISPLAY_POWER_CMD="
rm -f $T/calls; start; sleep 0.3
kill -USR2 $PID; sleep 0.3; [ "$(b)" = 0 ] && pass "empty command: blank" || no "empty command: level $(b)"
kill -USR1 $PID; sleep 0.3; [ "$(b)" = 10 ] && pass "empty command: wake" || no "empty command: level $(b)"
stop
[ ! -f $T/calls ] && pass "empty command runs nothing" || no "empty command ran: $(calls)"

# 5. tsx-display-power with a fake sway: the first "power on" after "power
#    off" fails (as on the Meson display), the second one works.
mkdir -p $T/ru/$(id -u) $T/fb/fb0
echo 0 > $T/fb/fb0/blank
mksock() { python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"; }
mksock $T/ru/$(id -u)/sway-ipc.1.1.sock
cat > $T/swaymsg <<EOF
#!/bin/sh
st=$T/sway.\${SWAYSOCK##*.1.}
[ -f $T/stale ] && [ "\${SWAYSOCK##*/}" = "\$(cat $T/stale)" ] && exit 1
[ -f "\$st" ] || echo true > "\$st"
case "\$*" in
"-t get_outputs -r") echo "[ { \"name\": \"LVDS-1\", \"power\": \$(cat "\$st") } ]";;
"output * power off") echo false > "\$st"; rm -f "\$st.tried";;
"output * power on")
	if [ -f $T/never ]; then :
	elif [ "\$(cat "\$st")" = false ] && [ ! -f "\$st.tried" ]; then touch "\$st.tried"
	else echo true > "\$st"; fi
	echo "\$*" >> $T/sway-calls;;
esac
EOF
chmod +x $T/swaymsg
dp() { TSX_SWAYMSG=$T/swaymsg TSX_RUN_USER_DIR=$T/ru TSX_KIOSK_USER=$(id -un) TSX_FB_DIR=$T/fb sh $DP "$@"; }
dp off && [ "$(dp status)" = "sway off" ] && pass "display-power off" || no "display-power off: $(dp status)"
rm -f $T/sway-calls
dp on 2>$T/dp.err && [ "$(dp status)" = "sway on" ] && pass "display-power on" || no "display-power on: $(dp status)"
[ "$(wc -l < $T/sway-calls)" = 2 ] && pass "second power on request after a refused one" || no "power on requests: $(wc -l < $T/sway-calls)"
grep -q "after 2 requests" $T/dp.err && pass "retry reported" || no "retry not reported: $(cat $T/dp.err)"
touch $T/never; dp off
if dp on 2>$T/dp.err; then no "display-power on succeeded with a sway that never turns on"; else pass "display-power on fails when sway never turns on"; fi
grep -q "not on after 3 requests" $T/dp.err && pass "failure reported" || no "failure not reported: $(cat $T/dp.err)"
rm -f $T/never; dp on 2>/dev/null
# a stale socket next to a live one
mksock $T/ru/$(id -u)/sway-ipc.1.0.sock; echo sway-ipc.1.0.sock > $T/stale
dp off && pass "stale socket skipped (off)" || no "stale socket: off failed"
dp on 2>/dev/null && pass "stale socket skipped (on)" || no "stale socket: on failed"
rm -f $T/ru/$(id -u)/sway-ipc.*.sock
# no sway: framebuffer
dp off && [ "$(cat $T/fb/fb0/blank)" = 4 ] && pass "no sway: fb blank 4" || no "no sway: fb blank $(cat $T/fb/fb0/blank)"
dp on && [ "$(cat $T/fb/fb0/blank)" = 0 ] && pass "no sway: fb blank 0" || no "no sway: fb blank $(cat $T/fb/fb0/blank)"
rm -rf $T/fb/fb0
if dp off; then no "no output: exit 0"; else pass "no output: exit 1"; fi
st=0; dp bogus 2>/dev/null || st=$?
[ "$st" = 2 ] && pass "usage error: exit 2" || no "usage error: exit $st"

if [ $fail = 0 ]; then echo "PASS tsx-idled display power"; else echo "FAILED"; sed 's/^/  log: /' $T/log; exit 1; fi
