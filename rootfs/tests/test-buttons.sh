#!/bin/bash
# Host test for tsx-buttons. It also covers the brightness override and offset
# of tsx-idled, the key-strip slide and the overlay FIFO. The fixtures are
# fake LED and backlight sysfs dirs and a FIFO as the key input device. They
# also include a fake HA REST API and a fake Chromium DevTools endpoint
# (fakesrv.py). The real tsx-idled does the blanking.
# Usage: tests/test-buttons.sh      (builds both daemons with host gcc)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../rootfs/src
T=$(mktemp -d); PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf $T' EXIT
gcc -O2 -Wall -o $T/tsx-buttons $SRC/tsx-buttons.c
gcc -O2 -Wall -o $T/tsx-idled $SRC/tsx-idled.c
HA_PORT=$((20000 + RANDOM % 10000)); CDP_PORT=$((HA_PORT + 1))
mkdir -p $T/bl/mp3309c $T/input $T/idled-input $T/run $T/log
for l in tsx:keypad tsx:key1 tsx:key2 tsx:key3 tsx:key4 tsx:key5; do mkdir -p "$T/leds/$l"; echo 0 > "$T/leds/$l/brightness"; done
echo 31 > $T/bl/mp3309c/max_brightness; echo 17 > $T/bl/mp3309c/brightness
mkfifo $T/input/event0
echo "test-token-123" > $T/ha-token
cat > $T/kiosk.conf <<C
KIOSK_URL="http://127.0.0.1:$HA_PORT/lovelace/0"
BLANK_TIMEOUT=0
BRIGHTNESS_DAY=10
BRIGHTNESS_NIGHT=10
BACKLIGHT_MAX=23
NIGHT_START=0
NIGHT_END=0
OSK_GESTURE=off
RAMP_SLIDER_MS=0
RAMP_AUTO_MS=0
C
cat > $T/buttons.conf <<C
KIOSK_CONF=$T/kiosk.conf
HA_TOKEN_FILE=$T/ha-token
HA_EVENT=tsx_button
DEVTOOLS=127.0.0.1:$CDP_PORT
LONG_PRESS_MS=400
HOLD_REPEAT_MS=200
SLIDE_STEP=2
SLIDE_GAP_MS=200
PRESS_FEEDBACK_MS=300
LED_DAY=128
LED_NIGHT=24
LED_BLANK=5
button power  KEY_F13 led=1
button home   KEY_F14 led=2
button lights KEY_F15 led=3
button up     KEY_F16 led=4
button down   KEY_F17 led=5
on power  short blank toggle
on power  long  overlay full
on home   short home
on home   long  navigate /lovelace/lights?x="1"
on lights short ha light.toggle {"entity_id": "light.kitchen"}
on lights long  exec echo "\$TSX_BUTTON \$TSX_PRESS" > $T/exec.out
on up     short brightness +2
on down   hold  brightness -1
C
python3 $HERE/fakesrv.py $HA_PORT $CDP_PORT $T/log & PIDS="$PIDS $!"
TSX_INPUT_DIR=$T/idled-input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/idled.state TSX_RUN_DIR=$T/run \
	$T/tsx-idled -c $T/kiosk.conf -v 2>$T/idled.log & PIDS="$PIDS $!"
sleep 0.5
TSX_INPUT_DIR=$T/input TSX_LED_DIR=$T/leds TSX_BACKLIGHT_DIR=$T/bl TSX_RUN_DIR=$T/run \
	TSX_IDLED_STATE=$T/idled.state TSX_HOSTNAME=testpanel TSX_ORIENTATION_FILE=$T/orientation \
	$T/tsx-buttons -c $T/buttons.conf -v 2>$T/buttons.log & BPID=$!; PIDS="$PIDS $BPID"
exec 7<>$T/input/event0
key() { python3 -c 'import struct,sys,time; t=time.time(); sys.stdout.buffer.write(struct.pack("llHHi",int(t),0,1,int(sys.argv[1]),int(sys.argv[2]))+struct.pack("llHHi",int(t),0,0,0,0))' "$@" >&7; }
press() { key $1 1; sleep $2; key $1 0; }        # press <code> <seconds held>
ctl() { echo "$*" > $T/run/buttons.ctl; }
fail() { echo "FAIL: $*"; echo "--- tsx-buttons log"; cat $T/buttons.log; echo "--- tsx-idled log"; cat $T/idled.log; exit 1; }
led() { cat "$T/leds/tsx:$1/brightness"; }
bl() { cat $T/bl/mp3309c/brightness; }
ok() { echo "ok: $*"; }
F13=183 F14=184 F15=185 F16=186 F17=187
sleep 0.6
[ "$(led keypad)" = 128 ] || fail "initial keypad LED $(led keypad)"
[ "$(led key1)$(led key3)$(led key5)" = 111 ] || fail "key LEDs not on"
grep -q "using $T/input/event0" $T/buttons.log || fail "input device not used"
ok "initial LEDs 128, keys on"

press $F14 0.1; sleep 0.8
grep -q '"method":"Runtime.evaluate"' $T/log/cdp.log || fail "home: no CDP message"
grep -q "lovelace/0" $T/log/cdp.log || fail "home: CDP message without KIOSK_URL"
grep -q 'devtools: .*spa /test' $T/buttons.log || fail "home: CDP reply not read"
grep -q '/api/events/tsx_button|Bearer test-token-123|{"panel":"testpanel","button":"home","press":"short","code":184}' $T/log/ha.log || fail "home: no HA event"
ok "home short -> DevTools in-app navigation + HA event"

press $F14 0.6; sleep 0.8
grep -q 'lovelace/lights?x=\\\\\\"1\\\\\\"' $T/log/cdp.log || fail "home long: navigate target not escaped/sent: $(tail -1 $T/log/cdp.log)"
grep -q '"button":"home","press":"long"' $T/log/ha.log || fail "home long: no HA event"
ok "home long -> navigate /lovelace/lights (JSON escaping)"

press $F15 0.1; sleep 0.8
grep -q '^/api/services/light/toggle|Bearer test-token-123|{"entity_id": "light.kitchen"}$' $T/log/ha.log || fail "lights: no HA service call: $(cat $T/log/ha.log)"
ok "lights short -> POST /api/services/light/toggle with Bearer token"

press $F15 0.6; sleep 0.5
[ "$(cat $T/exec.out 2>/dev/null)" = "lights long" ] || fail "lights long exec: '$(cat $T/exec.out 2>/dev/null)'"
ok "lights long -> exec with TSX_BUTTON/TSX_PRESS"

[ "$(bl)" = 10 ] || fail "tsx-idled day level $(bl)"
press $F16 0.1; sleep 0.5
[ "$(bl)" = 12 ] || fail "up: brightness $(bl), want 12"
[ "$(cat $T/run/brightness-offset 2>/dev/null)" = 2 ] || fail "up: offset file '$(cat $T/run/brightness-offset 2>/dev/null)', want 2"
[ ! -e $T/run/brightness ] || fail "up: +N must not write the absolute override"
sleep 5.5; [ "$(bl)" = 12 ] || fail "tsx-idled did not keep the offset: $(bl)"
ok "up short (fires after SLIDE_GAP_MS) -> brightness +2 as an offset (10 -> 12), tsx-idled keeps it"

key $F17 1; sleep 1.1; key $F17 0; sleep 0.3
b=$(bl); [ "$b" -le 9 ] && [ "$b" -ge 7 ] || fail "down hold: brightness $b, want 7..9 (4 repeats)"
ok "down hold -> brightness repeated down to $b"

# key-strip slide, bottom -> top: +SLIDE_STEP per key, no key action fires
nh=$(wc -l < $T/log/ha.log); nc=$(wc -l < $T/log/cdp.log); b0=$(bl)
slide() { for k in "$@"; do key $k 1; sleep 0.06; key $k 0; sleep 0.05; done; }
slide $F17 $F16 $F15 $F14 $F13; sleep 0.6
[ "$(bl)" = $((b0 + 8)) ] || fail "slide up: brightness $(bl), want $((b0 + 8)) (4 steps of 2)"
[ "$(wc -l < $T/log/ha.log)/$(wc -l < $T/log/cdp.log)" = "$nh/$nc" ] || fail "slide fired key actions (HA $nh -> $(wc -l < $T/log/ha.log), CDP $nc -> $(wc -l < $T/log/cdp.log))"
grep -q '^blank' $T/idled.state && fail "slide ended on the power key: its short press (blank) fired"
[ "$(cat $T/run/brightness-offset)" = $((b0 + 8 - 10)) ] || fail "slide: offset $(cat $T/run/brightness-offset), want $((b0 + 8 - 10))"
ok "slide F17 -> F13: brightness $b0 -> $(bl) (offset $(cat $T/run/brightness-offset)), no key actions, no HA events"
echo 5 > $T/run/brightness; sleep 0.4; [ "$(bl)" = 5 ] || fail "absolute override: $(bl)"
slide $F14 $F15; sleep 0.6
[ "$(bl)" = 3 ] || fail "slide down from an override: $(bl), want 3"
[ ! -e $T/run/brightness ] && [ "$(cat $T/run/brightness-offset)" = -7 ] || fail "slide did not turn the override into an offset"
ok "slide down from an absolute override (5): starts there, -> 3 as offset -7 (override gone)"
nc=$(wc -l < $T/log/cdp.log)
press $F14 0.06; sleep 0.05; press $F17 0.06; sleep 0.6
[ "$(wc -l < $T/log/cdp.log)" = $((nc + 1)) ] && [ "$(bl)" = 3 ] || fail "keys 2 and 5 are no slide: home must fire, brightness stay ($(bl))"
ok "two taps three keys apart: no slide, home short fires"

# the panel hung flipped (ORIENTATION landscape-flipped / portrait-flipped):
# the physical top key is at the bottom / left, so the slide turns around.
# Portrait (keys below, top key on the right) keeps it. Read at every step.
echo landscape-flipped > $T/orientation
slide $F14 $F15; sleep 0.6
[ "$(bl)" = 5 ] || fail "landscape-flipped: physical down slide must be brighter: $(bl), want 5"
echo portrait-flipped > $T/orientation
slide $F15 $F14; sleep 0.6
[ "$(bl)" = 3 ] || fail "portrait-flipped: physical up slide must be darker: $(bl), want 3"
echo portrait > $T/orientation
slide $F15 $F14; sleep 0.6
[ "$(bl)" = 5 ] || fail "portrait: physical up slide (right) must be brighter: $(bl), want 5"
rm -f $T/orientation
slide $F14 $F15; sleep 0.6
[ "$(bl)" = 3 ] || fail "no orientation file: physical down slide must be darker: $(bl), want 3"
ok "slide direction: turned around for landscape-/portrait-flipped, kept for portrait and landscape"

# overlay FIFO: no reader -> OVERLAY_FALLBACK (blank toggle). A reader -> "full"/"slider"
[ -p $T/run/overlay.ctl ] || fail "no overlay FIFO $T/run/overlay.ctl"
key $F13 1; sleep 0.6; key $F13 0; sleep 0.5
grep -q '^blank' $T/idled.state || fail "overlay without a reader: fallback blank toggle did not blank"
grep -q 'no overlay running' $T/buttons.log || fail "overlay fallback not logged"
kill -USR1 $(pgrep -x tsx-idled | head -1); sleep 0.9
exec 8<>$T/run/overlay.ctl
key $F13 1; sleep 0.6; key $F13 0; sleep 0.3
read -t 2 line <&8 && [ "$line" = full ] || fail "overlay: reader got '${line:-nothing}', want full"
grep -q '^on' $T/idled.state || fail "overlay with a reader: the screen was blanked anyway"
slide $F15 $F14; sleep 0.3
read -t 2 line <&8 && [ "$line" = slider ] || fail "slide: overlay reader got '${line:-nothing}', want slider"
ctl "overlay hide"; read -t 2 line <&8 && [ "$line" = hide ] || fail "ctl overlay hide: '${line:-nothing}'"
exec 8<&-
ok "overlay: long hold -> full (reader) / fallback blank (no reader). Slide -> slider. Ctl overlay hide"
rm -f $T/run/brightness-offset; sleep 0.4

ctl "page reload"; sleep 0.8
grep -q '"method":"Page.reload"' $T/log/cdp.log || fail "ctl page reload: no Page.reload"
ok "ctl page reload -> DevTools Page.reload"

key $F13 1; sleep 0.1
[ "$(led key1)" = 0 ] || fail "press feedback: key1 LED not dark while pressed"
key $F13 0; sleep 0.8
grep -q '^blank' $T/idled.state || fail "power short: not blanked ($(cat $T/idled.state))"
[ "$(bl)" = 0 ] || fail "power: backlight $(bl)"
[ "$(led keypad)" = 5 ] || fail "blank: keypad LED $(led keypad), want LED_BLANK 5"
[ "$(led key2)" = 1 ] || fail "blank: key LED enable $(led key2), want 1 (LED_BLANK > 0)"
ok "power short -> blank via tsx-idled. Key LEDs -> LED_BLANK"

kill -USR1 $(pgrep -x tsx-idled | head -1); sleep 0.9
[ "$(led keypad)" = 128 ] || fail "wake: keypad LED $(led keypad)"
ok "wake -> key LEDs 128"

ctl "led 40"; sleep 0.3; [ "$(led keypad)" = 40 ] || fail "ctl led 40: $(led keypad)"
ctl "key lights off"; sleep 0.3; [ "$(led key3)" = 0 ] || fail "ctl key lights off"
ctl "key 3 auto"; sleep 0.3; [ "$(led key3)" = 1 ] || fail "ctl key 3 auto"
ctl "led auto"; sleep 0.3; [ "$(led keypad)" = 128 ] || fail "ctl led auto: $(led keypad)"
ctl "led 0"; sleep 0.3; [ "$(led keypad)$(led key1)" = 00 ] || fail "ctl led 0: enables should be off"
ctl "led auto"; sleep 0.3
echo 77 > "$T/leds/tsx:keypad/brightness"; sleep 5.5; [ "$(led keypad)" = 128 ] || fail "external LED change not re-applied"
ok "control FIFO: led N/auto/0, key NAME off/auto. re-apply after external change"

K=$HERE/../../rootfs/overlay/usr/local/bin/tsx-keypad
TSX_RUN_DIR=$T/run $K led 60; sleep 0.3; [ "$(led keypad)" = 60 ] || fail "tsx-keypad led 60"
TSX_RUN_DIR=$T/run $K status | grep -q '^led 60 override' || fail "tsx-keypad status"
TSX_RUN_DIR=$T/run $K led auto; sleep 0.3
ok "tsx-keypad CLI: led 60, status, led auto"
ctl "press lights short"; sleep 0.6
[ "$(grep -c '^/api/services/light/toggle' $T/log/ha.log)" = 2 ] || fail "ctl press lights"
ctl "status"; sleep 0.3; grep -q '^led 128 day' $T/run/buttons.state || fail "state: $(cat $T/run/buttons.state)"
ok "ctl press + status: $(tr '\n' ';' < $T/run/buttons.state)"

# DevTools off -> fallback: /run/tsx/kiosk-url + rc-service kiosk restart (absent on the host)
sed -i "s/^DEVTOOLS=.*/DEVTOOLS=127.0.0.1:1/" $T/buttons.conf; kill -HUP $BPID; sleep 0.5
press $F14 0.6; sleep 1
[ "$(cat $T/run/kiosk-url 2>/dev/null)" = "http://127.0.0.1:$HA_PORT/lovelace/lights?x=\"1\"" ] || fail "fallback kiosk-url: '$(cat $T/run/kiosk-url 2>/dev/null)'"
grep -q 'restarting the kiosk' $T/buttons.log || fail "fallback not logged"
press $F14 0.1; sleep 1
[ ! -e $T/run/kiosk-url ] || fail "home did not remove kiosk-url"
ok "no DevTools -> kiosk-url + restart fallback. Home clears it"

# panel.conf override: /run/tsx/kiosk.conf (tsx-config apply) wins over
# KIOSK_CONF's KIOSK_URL for the derived HA_URL -- same precedence as
# kiosk-session's /etc/kiosk.conf + /run/tsx/kiosk.conf
HA_PORT2=$((HA_PORT + 1000))
mkdir -p $T/log2
python3 $HERE/fakesrv.py $HA_PORT2 $((CDP_PORT + 1000)) $T/log2 & PIDS="$PIDS $!"
sleep 0.3
nold=$(wc -l < $T/log/ha.log)
echo "KIOSK_URL=\"http://127.0.0.1:$HA_PORT2/lovelace/0\"" > $T/run/kiosk.conf
kill -HUP $BPID; sleep 0.5
press $F15 0.1; sleep 0.6
grep -q '^/api/services/light/toggle|Bearer test-token-123' $T/log2/ha.log || fail "panel.conf override: HA action did not reach /run/tsx/kiosk.conf's origin"
[ "$(wc -l < $T/log/ha.log)" = "$nold" ] || fail "panel.conf override: HA action still went to the base kiosk.conf origin too"
ok "panel.conf override (/run/tsx/kiosk.conf) wins over KIOSK_CONF for HA_URL"
rm -f $T/run/kiosk.conf; kill -HUP $BPID; sleep 0.5

rm $T/ha-token; kill -HUP $BPID; sleep 0.5; n=$(wc -l < $T/log/ha.log)
press $F15 0.1; sleep 0.6; [ "$(wc -l < $T/log/ha.log)" = "$n" ] || fail "HA call without token"
[ ! -e $T/run/ha-auth.hdr ] || fail "auth header file left behind"
ok "no token -> HA actions skipped"
echo "ALL OK"; echo "--- tsx-buttons log"; cat $T/buttons.log
