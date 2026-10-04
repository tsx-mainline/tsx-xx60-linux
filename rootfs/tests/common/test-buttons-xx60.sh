#!/bin/bash
# Host test of tsx-buttons (tsx-linux-common) with the real xx60 board layer
# (rootfs/overlay/etc/tsx/buttons-board.conf) and the buttons.conf template of
# tsx-linux-common. The five front keys have these jobs and no other:
#  - Each press fires the Home Assistant event and writes the "last" line.
#  - Home Assistant sets the key LEDs and the screen-off level.
# A press runs no local action: no overlay, no home, no reload, no blank, no
# brightness change and no slide (SLIDE_STEP=0). A press on a blank screen
# only wakes it: tsx-idled grabs the input devices then. A FIFO cannot show
# that, so the panel check covers it.
# The fixtures are fake LED and backlight directories, a FIFO as the key
# input device and the fake Home Assistant and DevTools endpoints of
# tsx-linux-common (tests/fakesrv.py). The test compiles the daemon with the
# host gcc. Run it on a build host.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf $T' EXIT
fail() { echo "FAIL: $*"; echo "--- tsx-buttons log"; cat $T/buttons.log 2>/dev/null; exit 1; }
ok() { echo "ok: $*"; }
nl_() { if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi; }

echo "== the board layer =="
nbtn=$(grep -c '^button ' "$XX60_BUTTONS")
[ "$nbtn" = 5 ] || fail "the board layer has $nbtn button lines, want 5"
i=0
for want in "power KEY_F13 led=1" "home KEY_F14 led=2" "lights KEY_F15 led=3" "up KEY_F16 led=4" "down KEY_F17 led=5"; do
	i=$((i + 1)); line=$(grep '^button ' "$XX60_BUTTONS" | sed -n "${i}p" | tr -s ' ')
	[ "$line" = "button $want" ] || fail "key $i is '$line', want 'button $want'"
done
[ "$(sed -n 's/^LED_PWM=//p' "$XX60_BUTTONS")" = tsx:keypad ] && [ "$(sed -n 's/^LED_KEY_PREFIX=//p' "$XX60_BUTTONS")" = tsx:key ] \
	|| fail "the LED names of the board layer"
[ "$(sed -n 's/^SLIDE_STEP=//p' "$XX60_BUTTONS")" = 0 ] || fail "SLIDE_STEP of the board layer is not 0"
grep -q '^on ' "$XX60_BUTTONS" && fail "the board layer binds an action"
grep -q '^button \|^on ' "$(P etc/tsx/buttons.conf)" && fail "the template of buttons.conf has a key or an action"
ok "five keys KEY_F13 to KEY_F17 with led=1 to 5, LEDs tsx:keypad and tsx:key1 to 5, SLIDE_STEP=0, no action"

gcc -O2 -Wall -o $T/tsx-buttons "$COMMON/buttons/src/tsx-buttons.c"
HA_PORT=$((20000 + RANDOM % 10000)); CDP_PORT=$((HA_PORT + 1))
mkdir -p $T/bl/x $T/input $T/run $T/log $T/bin
for l in tsx:keypad tsx:key1 tsx:key2 tsx:key3 tsx:key4 tsx:key5; do mkdir -p "$T/leds/$l"; echo 0 > "$T/leds/$l/brightness"; done
echo 31 > $T/bl/x/max_brightness; echo 17 > $T/bl/x/brightness
mkfifo $T/input/event0
echo "test-token-123" > $T/ha-token
cat > $T/kiosk.conf <<C
KIOSK_URL="http://127.0.0.1:$HA_PORT/lovelace/0"
NIGHT_START=0
NIGHT_END=0
C
# settings only (the file that tsx-config apply writes): point the daemon at the fake servers
cat > $T/run/buttons.conf <<C
KIOSK_CONF=$T/kiosk.conf
HA_TOKEN_FILE=$T/ha-token
DEVTOOLS=127.0.0.1:$CDP_PORT
LONG_PRESS_MS=400
HOLD_REPEAT_MS=200
C
# a pkill that logs: the blank and wake actions signal tsx-idled with it
printf '#!/bin/sh\necho "pkill $*" >> %s/pkill.log\n' $T > $T/bin/pkill; chmod +x $T/bin/pkill
python3 "$COMMON/tests/fakesrv.py" $HA_PORT $CDP_PORT $T/log & PIDS="$PIDS $!"
sleep 0.3
env PATH=$T/bin:$PATH TSX_INPUT_DIR=$T/input TSX_LED_DIR=$T/leds TSX_BACKLIGHT_DIR=$T/bl TSX_RUN_DIR=$T/run \
	TSX_IDLED_STATE=$T/idled.state TSX_HOSTNAME=testpanel TSX_ORIENTATION_FILE=$T/orientation \
	TSX_BUTTONS_BOARD_CONF="$XX60_BUTTONS" TSX_PANEL_BOARD_CONF="$XX60_PANEL_BOARD" \
	$T/tsx-buttons -c "$(P etc/tsx/buttons.conf)" -v 2>$T/buttons.log & BPID=$!; PIDS="$PIDS $BPID"
exec 7<>$T/input/event0
exec 8<>$T/run/overlay.ctl
key() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,1,int(sys.argv[1]),int(sys.argv[2]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&7; }
press() { key $1 1; sleep $2; key $1 0; }
ctl() { echo "$*" > $T/run/buttons.ctl; }
led() { cat "$T/leds/tsx:$1/brightness"; }
st() { sed -n "s/^$1 //p" $T/run/buttons.state; }
# KEY_F13 to KEY_F17
CODES="183 184 185 186 187"; NAMES="power home lights up down"
sleep 0.6

echo "== the daemon with the real board layer =="
grep -q '^tsx-buttons: 5 buttons, 0 bindings, 5 key LEDs, .*slide off$' $T/buttons.log || fail "start line: $(grep ' buttons, ' $T/buttons.log | tail -n 1)"
grep -qE 'bad |unknown setting|ignored|only KEY=VALUE' $T/buttons.log && fail "the daemon refused a line: $(grep -E 'bad |unknown setting|ignored|only KEY=VALUE' $T/buttons.log)"
[ "$(st leds)" = yes ] || fail "state: leds '$(st leds)', want yes"
[ "$(led keypad)" = 128 ] && [ "$(led key1)$(led key2)$(led key3)$(led key4)$(led key5)" = 11111 ] || fail "key LEDs: level $(led keypad), enables $(led key1)$(led key2)$(led key3)$(led key4)$(led key5)"
ok "5 buttons, 0 bindings, 5 key LEDs, slide off, leds yes, the LEDs tsx:keypad 128 and tsx:key1 to 5 on"

echo "== each key fires the Home Assistant event and nothing else =="
n=1
for name in $NAMES; do
	code=$(echo $CODES | cut -d' ' -f$n); n=$((n + 1))
	press $code 0.1; sleep 0.4
	grep -q "/api/events/tsx_button|Bearer test-token-123|{\"panel\":\"testpanel\",\"button\":\"$name\",\"press\":\"short\",\"code\":$code}" $T/log/ha.log \
		|| fail "$name short: no HA event: $(tail -n 2 $T/log/ha.log 2>/dev/null)"
	[ "$(st last | cut -d' ' -f1,2)" = "$name short" ] || fail "$name short: last line '$(st last)'"
	press $code 0.6; sleep 0.4
	grep -q "\"button\":\"$name\",\"press\":\"long\",\"code\":$code}" $T/log/ha.log || fail "$name long: no HA event"
	[ "$(st last | cut -d' ' -f1,2)" = "$name long" ] || fail "$name long: last line '$(st last)'"
done
[ "$(nl_ $T/log/ha.log)" = 10 ] || fail "want 10 HA calls (5 short, 5 long), got $(nl_ $T/log/ha.log): $(cut -c1-60 $T/log/ha.log)"
grep -q '^/api/events/' $T/log/ha.log || fail "no event call"
grep -vq '^/api/events/tsx_button|' $T/log/ha.log && fail "a call that is no key event: $(grep -v '^/api/events/tsx_button|' $T/log/ha.log)"
ok "short and long press of power, home, lights, up and down: ten HA events and the last line, no HA service call"

echo "== no local action =="
[ "$(nl_ $T/log/cdp.log)" = 0 ] || fail "a key reached the browser (home, reload or navigate): $(cat $T/log/cdp.log)"
[ "$(nl_ $T/pkill.log)" = 0 ] || fail "a key blanked or woke the screen: $(cat $T/pkill.log)"
read -t 0.3 line <&8 && fail "a key sent a command to the overlay: '$line'"
[ ! -e $T/run/brightness ] && [ ! -e $T/run/brightness-offset ] || fail "a key changed the brightness"
[ "$(cat $T/bl/x/brightness)" = 17 ] || fail "a key changed the backlight: $(cat $T/bl/x/brightness)"
ok "no overlay, no home, no reload, no navigate, no blank, no brightness change"

echo "== no slide =="
nh=$(nl_ $T/log/ha.log)
for code in 187 186 185 184 183; do key $code 1; sleep 0.06; key $code 0; sleep 0.05; done; sleep 0.6
[ "$(( $(nl_ $T/log/ha.log) - nh ))" = 5 ] || fail "a pass over the five keys made $(( $(nl_ $T/log/ha.log) - nh )) events, want 5 (no slide)"
[ ! -e $T/run/brightness-offset ] && [ "$(cat $T/bl/x/brightness)" = 17 ] || fail "a pass over the keys changed the brightness"
read -t 0.3 line <&8 && fail "a pass over the keys showed the slider: '$line'"
ok "a finger over all five keys: five presses, no brightness change, no slider"

echo "== Home Assistant sets the key LEDs and the screen-off level =="
ctl "led 40"; sleep 0.3
[ "$(led keypad)" = 40 ] && [ "$(st led_awake)" = "40 override" ] || fail "led 40: level $(led keypad), $(tr '\n' ';' < $T/run/buttons.state)"
ctl "led off"; sleep 0.3
[ "$(led keypad)$(led key1)$(led key5)" = 000 ] || fail "led off: level $(led keypad)"
ctl "led auto"; sleep 0.3
[ "$(led keypad)" = 128 ] || fail "led auto: level $(led keypad)"
printf 'LED_BLANK=9\n' >> $T/run/buttons.conf; kill -HUP $BPID; sleep 0.5
[ "$(st led_blank)" = 9 ] || fail "LED_BLANK=9 of the panel.conf override: $(tr '\n' ';' < $T/run/buttons.state)"
echo blank > $T/idled.state; sleep 1.0
[ "$(led keypad)" = 9 ] && [ "$(led key3)" = 1 ] || fail "blank screen: level $(led keypad), key3 $(led key3), want the screen-off level 9"
ok "led 40, off and auto reach tsx:keypad. LED_BLANK=9 is the level of a blank screen"
echo "ALL OK"
