#!/bin/sh
# Host test of tsx-als (fake IIO + backlight sysfs) and of the tsx-mqtt ALS
# entities (dry-run mode). No compiler needed; busybox/dash sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/../../rootfs/overlay
ALS=$O/usr/local/sbin/tsx-als
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/iio/iio:device0" "$T/bl/mp3309c" "$T/run" "$T/bin"
printf '#!/bin/sh\n:\n' > "$T/bin/usleep"; chmod +x "$T/bin/usleep"
echo max44009 > "$T/iio/iio:device0/name"
echo 17 > "$T/bl/mp3309c/brightness"; echo "on 17" > "$T/idled"
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
lux() { echo "$1" > "$T/iio/iio:device0/in_illuminance_input"; }
run() {  # run LOOPS [extra conf lines]
	printf 'ALS_SMOOTH=1\nALS_HOLD=0\nALS_RAMP_MS=10\nALS_START_WAIT=0\n%s\n' "${2:-}" > "$T/als.conf"
	PATH=$T/bin:$PATH TSX_ALS_CONF=$T/als.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_RUN_DIR=$T/run \
	TSX_IIO_DIR=$T/iio TSX_BACKLIGHT_DIR=$T/bl TSX_IDLED_STATE=$T/idled TSX_ALS_LOOPS=$1 TSX_ALS_NOW=1000 \
		sh "$ALS" >> "$T/log" 2>&1
}
st() { sed -n "s/^$1 //p" "$T/run/als.state"; }
bl() { cat "$T/bl/mp3309c/brightness"; }

# 1. curve points and interpolation (default curve 0:3 5:5 20:8 80:12 300:17 1000:21 3000:23)
for c in "0.000000 3" "5.000000 5" "12.500000 7" "300.000000 17" "650.000000 19" "3000.000000 23" "90000.000000 23"; do
	set -- $c; rm -f "$T/run/"*; lux "$1"; run 1
	[ "$(cat "$T/run/als-level")" = "$2" ] && ok "curve $1 lx -> $2" || bad "curve $1 lx -> $(cat "$T/run/als-level"), want $2"
done
# 2. ramp: screen lit, backlight moved to the level
[ "$(bl)" = 23 ] && ok "ramp wrote backlight 23" || bad "backlight $(bl), want 23"
# 2b. start: 0 lx before the sensor's first conversion is not a level yet
rm -f "$T/run/"*; echo 13 > "$T/bl/mp3309c/brightness"; lux 0.000000; run 3 "ALS_START_WAIT=3"
[ ! -e "$T/run/als-level" ] && [ "$(bl)" = 13 ] && ok "start: 0 lx waits (no level, backlight kept)" || bad "start 0 lx: level $(cat "$T/run/als-level" 2>/dev/null), bl $(bl)"
rm -f "$T/run/"*; run 4 "ALS_START_WAIT=3"
[ "$(cat "$T/run/als-level" 2>/dev/null)" = 3 ] && ok "start: still 0 lx after ALS_START_WAIT: dark room level 3" || bad "start wait over: level $(cat "$T/run/als-level" 2>/dev/null)"
rm -f "$T/run/"*; echo 13 > "$T/bl/mp3309c/brightness"; lux 135.000000; run 1 "ALS_START_WAIT=3"
[ "$(cat "$T/run/als-level")" = 13 ] && ok "start: a real reading is used at once" || bad "start 135 lx: level $(cat "$T/run/als-level")"
# 3. hysteresis: 300 lx -> 17; 340 lx (+13 %) stays 17; 450 lx (+50 %) moves
# (hysteresis state lives inside one daemon run: feed values while it runs)
rm -f "$T/run/"*; echo 17 > "$T/bl/mp3309c/brightness"
printf 'ALS_SMOOTH=1\nALS_HOLD=0\nALS_RAMP_MS=0\n' > "$T/als.conf"
( i=0; for v in 300.0 340.0 340.0 450.0 450.0; do lux $v; sleep 0.3; done ) &
PATH=$T/bin:$PATH TSX_ALS_CONF=$T/als.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_RUN_DIR=$T/run \
	TSX_IIO_DIR=$T/iio TSX_BACKLIGHT_DIR=$T/bl TSX_IDLED_STATE=$T/idled TSX_ALS_NOW=1000 \
	sh -c 'trap "exit 0" TERM; exec sh "$0"' "$ALS" >> "$T/log" 2>&1 &
P=$!; sleep 0.5; l1=$(cat "$T/run/als-level"); sleep 0.35; l2=$(cat "$T/run/als-level"); sleep 0.7; l3=$(cat "$T/run/als-level"); kill $P; wait $P 2>/dev/null || true; wait
[ "$l1" = 17 ] && [ "$l2" = 17 ] && [ "$l3" = 18 ] && ok "hysteresis 300->340 keeps 17, 450 -> 18" || bad "hysteresis levels $l1 $l2 $l3, want 17 17 18"
# 4. blank: no backlight writes
rm -f "$T/run/"*; echo 0 > "$T/bl/mp3309c/brightness"; echo blank > "$T/idled"; lux 3000.0; run 1
[ "$(bl)" = 0 ] && ok "blank: backlight untouched" || bad "blank: backlight $(bl)"
echo "on 17" > "$T/idled"; echo 17 > "$T/bl/mp3309c/brightness"
# 5. manual override: level file written, backlight untouched
rm -f "$T/run/"*; echo 10 > "$T/run/brightness"; lux 3000.0; run 1
[ "$(bl)" = 17 ] && [ "$(cat "$T/run/als-level")" = 23 ] && ok "manual override: backlight untouched, level 23 offered" || bad "override: bl $(bl)"
# 5b. manual offset (key-strip slide / overlay): ramp to level + offset, clamped
rm -f "$T/run/"*; echo 17 > "$T/bl/mp3309c/brightness"; echo -4 > "$T/run/brightness-offset"; lux 300.0; run 1
[ "$(bl)" = 13 ] && [ "$(cat "$T/run/als-level")" = 17 ] && ok "offset -4: level 17 offered, backlight ramped to 13" || bad "offset -4: bl $(bl), level $(cat "$T/run/als-level")"
echo 9 > "$T/run/brightness-offset"; lux 3000.0; run 1
[ "$(bl)" = 23 ] && ok "offset +9 on level 23: clamped to BACKLIGHT_MAX 23" || bad "offset +9: bl $(bl)"
echo 'x;y' > "$T/run/brightness-offset"; lux 300.0; run 1
[ "$(bl)" = 17 ] && ok "garbage offset ignored" || bad "garbage offset: bl $(bl)"
TSX_RUN_DIR=$T/run sh "$ALS" status | grep -q '^manual offset x;y' && ok "status shows the offset file" || bad "status without offset"
# 6. auto off (config and runtime switch)
rm -f "$T/run/"*; run 1 "ALS_AUTO=0"
[ ! -e "$T/run/als-level" ] && [ "$(st auto)" = off ] && ok "ALS_AUTO=0: no als-level, auto off" || bad "ALS_AUTO=0"
TSX_RUN_DIR=$T/run sh "$ALS" auto on >/dev/null; [ ! -e "$T/run/brightness" ] || bad "auto on kept override"
run 1 "ALS_AUTO=0"; [ -e "$T/run/als-level" ] && ok "runtime auto on beats ALS_AUTO=0" || bad "runtime auto on"
TSX_RUN_DIR=$T/run sh "$ALS" auto off >/dev/null; run 1; [ ! -e "$T/run/als-level" ] && ok "runtime auto off" || bad "runtime auto off"
rm -f "$T/run/als-auto"
# 6b. auto off keeps the level on the glass (fixed level), auto on clears the manual settings
rm -f "$T/run/"*; printf 'level 9\nbase 5\noffset 4\n' > "$T/run/brightness.state"; echo 4 > "$T/run/brightness-offset"
TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled sh "$ALS" auto off >/dev/null
[ "$(cat "$T/run/brightness" 2>/dev/null)" = 9 ] && [ ! -e "$T/run/brightness-offset" ] && ok "auto off: level 9 kept as a fixed level, offset dropped" || bad "auto off: brightness '$(cat "$T/run/brightness" 2>/dev/null)'"
echo 3 > "$T/run/brightness-offset"
TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled sh "$ALS" auto on >/dev/null
[ ! -e "$T/run/brightness" ] && [ ! -e "$T/run/brightness-offset" ] && ok "auto on: fixed level and offset dropped" || bad "auto on left a manual setting"
echo blank > "$T/idled"; rm -f "$T/run/"*; printf 'level 9\n' > "$T/run/brightness.state"
TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled sh "$ALS" auto off >/dev/null
[ ! -e "$T/run/brightness" ] && ok "auto off while blank: no fixed level" || bad "auto off while blank wrote a level"
echo "on 17" > "$T/idled"; rm -f "$T/run/"*
# 7. backlight compensation: 20 lx raw at step 17 with 0.5 lx/step -> 11.5 lx -> between 5:5 and 20:8
rm -f "$T/run/"*; echo 17 > "$T/bl/mp3309c/brightness"; lux 20.0; run 1 "ALS_BL_COMP=5"
[ "$(st lux)" = 12 ] && ok "compensation 20 - 17*0.5 = 11.5 lx (reported 12)" || bad "compensation lux $(st lux)"
# 8. night cap
rm -f "$T/run/"*; lux 3000.0
printf 'NIGHT_START=0\nNIGHT_END=0\nBACKLIGHT_MAX=23\n' > "$T/k0"; printf 'NIGHT_START=%s\nNIGHT_END=%s\n' "$(date +%H | sed 's/^0//')" $(( ($(date +%H | sed 's/^0//') + 1) % 24 )) > "$T/k1"
printf 'ALS_SMOOTH=1\nALS_NIGHT_CAP=8\n' > "$T/als.conf"
TSX_ALS_CONF=$T/als.conf TSX_KIOSK_CONF=$T/k1 TSX_RUN_DIR=$T/run TSX_IIO_DIR=$T/iio TSX_BACKLIGHT_DIR=$T/bl TSX_IDLED_STATE=$T/idled TSX_ALS_LOOPS=1 PATH=$T/bin:$PATH sh "$ALS" >>"$T/log" 2>&1
[ "$(cat "$T/run/als-level")" = 8 ] && ok "night cap 8" || bad "night cap level $(cat "$T/run/als-level")"
# 9. status / lux CLI
TSX_IIO_DIR=$T/iio sh "$ALS" lux | grep -qx '3000.0' && ok "tsx-als lux" || bad "tsx-als lux"
TSX_RUN_DIR=$T/run sh "$ALS" status | grep -q '^level 8' && ok "tsx-als status" || bad "status"
# 10. MQTT entities (dry run)
printf 'NODE_ID=tsx-kiosk\n' > "$T/mqtt.conf"; : > "$T/buttons.conf"
printf 'lux 250\nraw 250\nreport 248\nlevel 16\nauto on\n' > "$T/run/als.state"
echo 'tsx/tsx-kiosk/als_auto/set OFF' | PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run \
	TSX_IDLED_STATE=$T/idled TSX_BUTTONS_CONF=$T/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_ALS_CONF=$O/etc/tsx/als.conf \
	TSX_BACKLIGHT_DIR=$T/bl PATH=$O/usr/local/sbin:$T/bin:$PATH sh "$O/usr/local/sbin/tsx-mqtt" > "$T/mq" 2>&1 || true
grep '/config ' "$T/mq" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || echo "FAIL bad JSON $t"; done
grep -q 'homeassistant/sensor/tsx-kiosk/illuminance/config .*"dev_cla":"illuminance"' "$T/mq" && ok "mqtt: illuminance discovery" || bad "mqtt discovery sensor"
grep -q 'homeassistant/switch/tsx-kiosk/als_auto/config' "$T/mq" && ok "mqtt: auto brightness discovery" || bad "mqtt discovery switch"
grep -q 'tsx/tsx-kiosk/als/lux 248' "$T/mq" && grep -q 'tsx/tsx-kiosk/als_auto/state ON' "$T/mq" && ok "mqtt: lux 248, auto ON published" || bad "mqtt state"
[ "$(cat "$T/run/als-auto" 2>/dev/null)" = off ] && ok "mqtt: als_auto/set OFF -> tsx-als auto off" || bad "mqtt als_auto command"
# 11. MQTT volume number (fake sound card + amixer stub)
mkdir -p "$T/asound/TSW1060"
printf '#!/bin/sh\ncase "$*" in *sget*) echo "  Front Left: 128 [42%%]";; *) echo "AMIXER $*" >&2;; esac\n' > "$T/bin/amixer"; chmod +x "$T/bin/amixer"
echo 'tsx/tsx-kiosk/volume/set 55' | PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run \
	TSX_IDLED_STATE=$T/idled TSX_BUTTONS_CONF=$T/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_ASOUND_DIR=$T/asound \
	TSX_BACKLIGHT_DIR=$T/bl sh "$O/usr/local/sbin/tsx-mqtt" > "$T/mv" 2>&1 || true
grep '/config ' "$T/mv" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || echo "FAIL bad JSON $t"; done
grep -q 'homeassistant/number/tsx-kiosk/volume/config' "$T/mv" && grep -q 'tsx/tsx-kiosk/volume/state 42' "$T/mv" && grep -q 'AMIXER -q -c TSW1060 sset Master 55%' "$T/mv" \
	&& ok "mqtt: volume number (discovery, state 42 %, set 55 %)" || { bad "mqtt volume"; cat "$T/mv"; }
TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled TSX_BUTTONS_CONF=$T/buttons.conf \
	TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_ASOUND_DIR=$T/none sh "$O/usr/local/sbin/tsx-mqtt" < /dev/null 2>&1 | grep -q volume \
	&& bad "volume published without a sound card" || ok "mqtt: no volume entity without the sound card"
[ $fail = 0 ] && echo "PASS tsx-als" || { echo "--- log"; cat "$T/log"; exit 1; }
