#!/bin/sh
# Host test of tsx-mqtt (tsx-linux-common) in dry-run mode with the xx60 board
# files of this repository. The xx60 front panel has five keys with their own
# LEDs (buttons-board.conf, the board layer), a backlight with the range 1 to
# 23 and a LED bar tool. The test checks the discovery JSON (jq), the key
# events, the key LED light and the backlight range that these files give. The
# stub of tsx-panelctl logs "send". tsx-mqtt does not touch the hardware.
set -eu
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/run" "$T/bl/x"
# the stub of tsx-panelctl: the LED bar and the key LEDs are there, `send` logs, `get volume` has no value
cat > "$T/bin/tsx-panelctl" <<'EOF2'
#!/bin/sh
case "$1" in
has) case "$2" in ledbar|keyleds) exit 0;; *) exit 1;; esac;;
get) exit 1;;
send) echo "CALL tsx-panelctl $*" >&2;;
esac
EOF2
chmod +x "$T/bin/tsx-panelctl"
printf 'want 0 0 40\nlast 0 0 40\nout 0 0 40\n' > "$T/run/ledbar.state"
# The key LEDs show LED_BLANK (24) on a blank screen. The light reports the awake level (128).
printf 'screen blank\nleds yes\nled 24 blank\nled_awake 128 day\nled_blank 24\nlast home short 12:00:01\n' > "$T/run/buttons.state"
echo "on 17" > "$T/idled"; echo 0 > "$T/bl/x/brightness"
echo 120 > "$T/run/blank-timeout"; date +%s > "$T/run/last-input"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mqtt.conf"
printf '%s\n' 'tsx/tsx-kiosk/key_leds/brightness/set 40' 'tsx/tsx-kiosk/key_leds/set OFF' \
	'tsx/tsx-kiosk/screen/set OFF' 'tsx/tsx-kiosk/backlight/set 30' 'tsx/tsx-kiosk/backlight/set 0' 'tsx/tsx-kiosk/backlight/set 12' |
PATH=$T/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_BUTTONS_BOARD_CONF=$XX60_BUTTONS TSX_KIOSK_CONF=$(P etc/kiosk.conf) \
	TSX_PANEL_BOARD_CONF=$XX60_PANEL_BOARD TSX_BACKLIGHT_DIR=$T/bl \
	TSX_MQTT_PREV_KEY="power short 11:59:00" sh "$(P usr/local/sbin/tsx-mqtt)" > "$T/out" 2>&1
fail=0
chk() { grep -qF -- "$1" "$T/out" || { echo "FAIL: missing: $1"; fail=1; }; }
n=0; grep '/config ' "$T/out" | while read -r _ _ t j; do echo "$j" | jq -e . >/dev/null || { echo "FAIL: bad JSON $t"; exit 1; }; done
n=$(grep -c '/config ' "$T/out"); [ "$n" = 22 ] || { echo "FAIL: $n discovery configs, want 22"; fail=1; }

# the five keys of the xx60 front panel, top to bottom
for k in power home lights up down; do
	chk "PUB (retained) homeassistant/event/tsx-kiosk/key_$k/config {"
	chk "PUB (retained) homeassistant/device_automation/tsx-kiosk/key_${k}_short/config {"
	chk "PUB (retained) homeassistant/device_automation/tsx-kiosk/key_${k}_long/config {"
done
[ "$(grep -c 'homeassistant/event/tsx-kiosk/key_' "$T/out")" = 5 ] || { echo "FAIL: the xx60 has five key events"; fail=1; }
grep -q 'homeassistant/event/tsx-kiosk/key_[^pHhlud]' "$T/out" && { echo "FAIL: a sixth key event"; fail=1; }
# the last press of buttons.state goes out as an event, once
chk 'PUB tsx/tsx-kiosk/key/home {"event_type":"short"}'
chk 'PUB tsx/tsx-kiosk/trigger/home/short short'
grep -q '^PUB tsx/tsx-kiosk/key/power' "$T/out" && { echo "FAIL: the old key press (TSX_MQTT_PREV_KEY) was sent again"; fail=1; }
# the key LED light: one light for the five LEDs. It shows the awake level, not the blank level.
chk 'PUB (retained) homeassistant/light/tsx-kiosk/key_leds/config {'
chk 'PUB (retained) tsx/tsx-kiosk/key_leds/brightness 128'
chk 'CALL tsx-panelctl send keypad led 40'
chk 'CALL tsx-panelctl send keypad led off'
# the backlight range is the one of panel-board.conf (1 to 23)
grep 'number/tsx-kiosk/backlight/config ' "$T/out" | grep -q '"min":1,"max":23' || { echo "FAIL: the backlight number is not 1..23"; fail=1; }
chk 'PUB (retained) tsx/tsx-kiosk/backlight/state 17'
chk 'CALL tsx-panelctl send backlight 23'
chk 'CALL tsx-panelctl send backlight 12'
grep -q 'send backlight 30' "$T/out" && { echo "FAIL: a backlight level above 23 was sent"; fail=1; }
grep -q 'send backlight 0' "$T/out" && { echo "FAIL: backlight 0 was sent (the lowest level is 1)"; fail=1; }
chk 'CALL tsx-panelctl send blank on'
# the LED bar tool is there, so the light is announced
chk 'PUB (retained) homeassistant/light/tsx-kiosk/ledbar/config {'
# the model name comes from the board file
chk '"mdl":"xx60 (mainline Linux)"'
# parts that the xx60 lacks
grep -qE 'presence|distance|lightbar|usb_power|poe_class|/tag/' "$T/out" && { echo "FAIL: entities announced for parts this panel does not have"; fail=1; }
grep -qE 'emmc' "$T/out" && { echo "FAIL: eMMC entities announced without emmc.state"; fail=1; }

# the xx60 keys come from the board layer: with the template of buttons.conf only, no key
# entity is announced. The stub of tsx-panelctl then says no key LEDs, and the topic of the light is cleared
mkdir -p "$T/bin-nokeys"; printf '#!/bin/sh\ncase "$1" in has) exit 1;; esac\n' > "$T/bin-nokeys/tsx-panelctl"; chmod +x "$T/bin-nokeys/tsx-panelctl"
PATH=$T/bin-nokeys:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mqtt.conf TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled \
	TSX_BUTTONS_CONF=$(P etc/tsx/buttons.conf) TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) \
	TSX_PANEL_BOARD_CONF=$XX60_PANEL_BOARD TSX_BACKLIGHT_DIR=$T/bl \
	sh "$(P usr/local/sbin/tsx-mqtt)" < /dev/null > "$T/outnokeys" 2>&1
grep -qx 'PUB (retained) homeassistant/light/tsx-kiosk/key_leds/config ' "$T/outnokeys" || { echo "FAIL: no board layer: the key LED entity is not cleared"; fail=1; }
grep -q 'homeassistant/event/' "$T/outnokeys" && { echo "FAIL: no board layer: key events announced"; fail=1; }

[ $fail = 0 ] && echo "PASS common/mqtt-dry ($n discovery configs, JSON valid)"
exit $fail
