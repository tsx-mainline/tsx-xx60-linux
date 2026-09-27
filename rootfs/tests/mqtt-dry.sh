#!/bin/sh
# Host test of tsx-mqtt in dry-run mode: discovery JSON (jq), state mapping,
# command handling (tsx-ledbar/tsx-keypad/tsx-blank are stubs that log calls).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/../../rootfs/overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/run" "$T/bl/x"
for c in tsx-ledbar tsx-keypad tsx-blank; do printf '#!/bin/sh\necho "CALL %s $*" >&2\n' $c > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf 'want 0 0 40\nlast 0 0 40\nout 0 0 40\n' > "$T/run/ledbar.state"
printf 'screen awake\nled 128 day\nlast home short 12:00:01\n' > "$T/run/buttons.state"
echo "on 17" > "$T/idled"; echo 0 > "$T/bl/x/brightness"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"
printf '%s\n' 'tsx/tsx-kiosk/ledbar/rgb/set 255,0,0' 'tsx/tsx-kiosk/ledbar/brightness/set 128' \
	'tsx/tsx-kiosk/ledbar/set ON' 'tsx/tsx-kiosk/ledbar/set OFF' 'tsx/tsx-kiosk/keypad/brightness/set 40' \
	'tsx/tsx-kiosk/keypad/set OFF' 'tsx/tsx-kiosk/screen/set OFF' 'tsx/tsx-kiosk/backlight/set 30' 'tsx/tsx-kiosk/bogus/set x' |
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$O/etc/tsx/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_BACKLIGHT_DIR=$T/bl \
	TSX_MQTT_PREV_KEY="power short 11:59:00" sh "$O/usr/local/sbin/tsx-mqtt" > "$T/out" 2>&1
fail=0
chk() { grep -qF -- "$1" "$T/out" || { echo "FAIL: missing: $1"; fail=1; }; }
n=0; grep '/config ' "$T/out" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done
n=$(grep -c '/config ' "$T/out"); [ "$n" = 19 ] || { echo "FAIL: $n discovery configs, want 19"; fail=1; }
chk 'PUB (retained) tsx/tsx-kiosk/ledbar/state ON'
chk 'PUB (retained) tsx/tsx-kiosk/ledbar/brightness 102'
chk 'PUB (retained) tsx/tsx-kiosk/ledbar/rgb 0,0,255'
chk 'PUB (retained) tsx/tsx-kiosk/keypad/brightness 128'
chk 'PUB (retained) tsx/tsx-kiosk/screen/state ON'
chk 'PUB (retained) tsx/tsx-kiosk/backlight/state 17'
chk 'CALL tsx-ledbar set 40 0 0'
chk 'CALL tsx-ledbar set 50 0 0'
chk 'CALL tsx-ledbar off'
chk 'CALL tsx-keypad led 40'
chk 'CALL tsx-keypad led off'
chk 'CALL tsx-blank on'
chk 'PUB tsx/tsx-kiosk/key/home {"event_type":"short"}'
chk 'PUB tsx/tsx-kiosk/trigger/home/short short'
[ "$(grep -c 'CALL tsx-ledbar' "$T/out")" = 3 ] || { echo "FAIL: ON after brightness must not send again"; fail=1; }
[ "$(cat "$T/run/brightness")" = 23 ] || { echo "FAIL: backlight not clamped to BACKLIGHT_MAX"; fail=1; }
[ "$(cat "$T/bl/x/brightness")" = 23 ] || { echo "FAIL: backlight sysfs not written"; fail=1; }
# unconfigured: exits 0 quietly
out=$(TSX_MQTT_CONF=/nonexistent sh "$O/usr/local/sbin/tsx-mqtt"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'BROKER not set' || { echo "FAIL: unconfigured run rc=$rc '$out'"; fail=1; }
[ $fail = 0 ] && echo "PASS tsx-mqtt dry run ($n discovery configs, JSON valid)"
exit $fail
