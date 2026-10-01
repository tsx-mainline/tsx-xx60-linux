#!/bin/sh
# Host test of tsx-mqtt in dry-run mode: discovery JSON (jq), state mapping,
# command handling (tsx-ledbar/tsx-keypad/tsx-blank are stubs that log calls).
set -eu
# The board file (rootfs/overlay/usr/local/lib/tsx/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/lib/tsx/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/../../rootfs/overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/run" "$T/bl/x"
for c in tsx-ledbar tsx-keypad tsx-blank tsx-autoupdate tsx-config; do printf '#!/bin/sh\necho "CALL %s $*" >&2\n' $c > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf 'want 0 0 40\nlast 0 0 40\nout 0 0 40\n' > "$T/run/ledbar.state"
printf 'screen awake\nled 128 day\nlast home short 12:00:01\n' > "$T/run/buttons.state"
echo "on 17" > "$T/idled"; echo 0 > "$T/bl/x/brightness"
echo 120 > "$T/run/blank-timeout"; date +%s > "$T/run/last-input"
printf '%s' '{"installed_version":"abc123","latest_version":"abc123+2pending","title":"TSX test packages","release_summary":"musl (1.2.5-r0 -> 1.2.5-r1)","in_progress":false}' > "$T/run/update-ha-state.json"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"
printf '%s\n' 'tsx/tsx-kiosk/ledbar/rgb/set 255,0,0' 'tsx/tsx-kiosk/ledbar/brightness/set 128' \
	'tsx/tsx-kiosk/ledbar/set ON' 'tsx/tsx-kiosk/ledbar/set OFF' 'tsx/tsx-kiosk/keypad/brightness/set 40' \
	'tsx/tsx-kiosk/keypad/set OFF' 'tsx/tsx-kiosk/screen/set OFF' 'tsx/tsx-kiosk/backlight/set 30' 'tsx/tsx-kiosk/bogus/set x' \
	'tsx/tsx-kiosk/update/set INSTALL' 'tsx/tsx-kiosk/blank_timeout/set 600.0' 'tsx/tsx-kiosk/blank_timeout/set 99999' |
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$O/etc/tsx/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_BACKLIGHT_DIR=$T/bl \
	TSX_MQTT_PREV_KEY="power short 11:59:00" sh "$O/usr/local/sbin/tsx-mqtt" > "$T/out" 2>&1
sleep 0.3   # let the backgrounded "tsx-autoupdate now &" (update/set) finish logging
fail=0
chk() { grep -qF -- "$1" "$T/out" || { echo "FAIL: missing: $1"; fail=1; }; }
n=0; grep '/config ' "$T/out" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done
n=$(grep -c '/config ' "$T/out"); [ "$n" = 22 ] || { echo "FAIL: $n discovery configs, want 22"; fail=1; }
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
chk 'PUB (retained) tsx/tsx-kiosk/update/state {"installed_version":"abc123","latest_version":"abc123+2pending","title":"TSX test packages","release_summary":"musl (1.2.5-r0 -> 1.2.5-r1)","in_progress":false}'
chk 'CALL tsx-autoupdate now'
chk 'PUB (retained) tsx/tsx-kiosk/blank_timeout/state 120'
chk 'PUB (retained) tsx/tsx-kiosk/touched_recently/state ON'
chk 'CALL tsx-config set BLANK_TIMEOUT 600'
chk 'CALL tsx-config apply'
grep -q 'BLANK_TIMEOUT 99999' "$T/out" && { echo "FAIL: blank timeout above 86400 accepted"; fail=1; }
[ "$(grep -c 'CALL tsx-ledbar' "$T/out")" = 3 ] || { echo "FAIL: ON after brightness must not send again"; fail=1; }
[ "$(cat "$T/run/brightness")" = 23 ] || { echo "FAIL: backlight not clamped to BACKLIGHT_MAX"; fail=1; }
[ "$(cat "$T/bl/x/brightness")" = 23 ] || { echo "FAIL: backlight sysfs not written"; fail=1; }
# a panel without a LED bar tool, front keys and eMMC wear: those entities are
# not announced, and an older discovery topic of them is cleared
mkdir -p "$T/bin-bare"; for c in tsx-blank tsx-autoupdate tsx-config; do cp "$T/bin/$c" "$T/bin-bare/"; done
PATH=$T/bin-bare:/usr/bin:/bin TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$T/none TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_BACKLIGHT_DIR=$T/bl \
	sh "$O/usr/local/sbin/tsx-mqtt" < /dev/null > "$T/outbare" 2>&1
grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/ledbar/config ' "$T/outbare" || { echo "FAIL: bare: the LED bar entity is not cleared"; fail=1; }
grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/keypad/config ' "$T/outbare" || { echo "FAIL: bare: the key LED entity is not cleared"; fail=1; }
grep -q 'homeassistant/event/' "$T/outbare" && { echo "FAIL: bare: key events announced without keys"; fail=1; }
grep -qE 'emmc|illuminance' "$T/outbare" && { echo "FAIL: bare: entities announced for parts this panel does not have"; fail=1; }
grep '/config {' "$T/outbare" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done || fail=1
grep -qE 'emmc' "$T/out" && { echo "FAIL: eMMC entities announced without emmc.state"; fail=1; }

# eMMC health from /run/tsx/emmc.state (tsx-emmc-state)
T3=$T/hw; mkdir -p "$T3/run"
printf 'life_a 0x01\nlife_b 0x0b\neol 0x02\n' > "$T3/run/emmc.state"
printf 'raw 12.50\nreport 12.5\nauto on\n' > "$T3/run/als.state"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T3/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$O/etc/tsx/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_BACKLIGHT_DIR=$T/bl \
	sh "$O/usr/local/sbin/tsx-mqtt" < /dev/null > "$T3/out" 2>&1
chk3() { grep -qF -- "$1" "$T3/out" || { echo "FAIL: emmc: missing: $1"; fail=1; }; }
grep '/config {' "$T3/out" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done || fail=1
for t in sensor/tsx-kiosk/emmc_life_a sensor/tsx-kiosk/emmc_life_b sensor/tsx-kiosk/emmc_eol sensor/tsx-kiosk/illuminance switch/tsx-kiosk/als_auto; do
	chk3 "PUB (retained) homeassistant/$t/config {"
done
chk3 'PUB (retained) tsx/tsx-kiosk/emmc/life_a 10'
chk3 'PUB (retained) tsx/tsx-kiosk/emmc/life_b 110'
chk3 'PUB (retained) tsx/tsx-kiosk/emmc/eol warning'
chk3 'PUB (retained) tsx/tsx-kiosk/als/lux 12.5'
printf 'life_a 0x00\nlife_b 0x03\neol 0x03\n' > "$T3/run/emmc.state"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T3/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$O/etc/tsx/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_BACKLIGHT_DIR=$T/bl \
	sh "$O/usr/local/sbin/tsx-mqtt" < /dev/null > "$T3/out2" 2>&1
grep -qF 'PUB (retained) tsx/tsx-kiosk/emmc/life_a none' "$T3/out2" && grep -qF 'PUB (retained) tsx/tsx-kiosk/emmc/life_b 30' "$T3/out2" \
	&& grep -qF 'PUB (retained) tsx/tsx-kiosk/emmc/eol urgent' "$T3/out2" || { echo "FAIL: emmc: unreported life must be none, 0x03 must be 30 and urgent"; fail=1; }

# unconfigured: exits 0 quietly
out=$(TSX_MQTT_CONF=/nonexistent sh "$O/usr/local/sbin/tsx-mqtt"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'BROKER not set' || { echo "FAIL: unconfigured run rc=$rc '$out'"; fail=1; }

# panel.conf override: /run/tsx/mqtt.conf (written by `tsx-config apply` from
# MQTT_HOST/MQTT_PORT/panel.conf) must win over the static /etc/tsx/mqtt.conf,
# same precedence as kiosk-session's /etc/kiosk.conf + /run/tsx/kiosk.conf
T2=$(mktemp -d); mkdir -p "$T2/run"
printf 'BROKER=base.example\nPORT=1883\n' > "$T2/mqtt.conf"
printf 'BROKER=override.example\nPORT=8883\n' > "$T2/run/mqtt.conf"
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T2/mqtt.conf TSX_RUN_DIR=$T2/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$O/etc/tsx/buttons.conf TSX_KIOSK_CONF=$O/etc/kiosk.conf TSX_BACKLIGHT_DIR=$T/bl \
	sh "$O/usr/local/sbin/tsx-mqtt" < /dev/null > "$T2/out" 2>&1
grep -q '^-h override.example$' "$T2/run/mqtt/mosquitto_pub" || { echo "FAIL: panel.conf override: BROKER not read from /run/tsx/mqtt.conf ($(cat "$T2/run/mqtt/mosquitto_pub" 2>/dev/null))"; fail=1; }
grep -q '^-p 8883$' "$T2/run/mqtt/mosquitto_pub" || { echo "FAIL: panel.conf override: PORT not read from /run/tsx/mqtt.conf"; fail=1; }
rm -rf "$T2"

[ $fail = 0 ] && echo "PASS tsx-mqtt dry run ($n discovery configs, JSON valid)"
exit $fail
