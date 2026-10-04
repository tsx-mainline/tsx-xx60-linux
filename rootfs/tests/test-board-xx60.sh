#!/bin/sh
# Host test for the board file of the xx60 (rootfs/overlay/usr/local/lib/tsx/board.sh)
# and the tsx-board wrapper. It needs no panel and no compiler.
#   - the values of the xx60, and that a value from the environment wins
#   - sourcing the file prints nothing
#   - the functions, with a made-up U-Boot env
#   - tsx-board get and call
#   - the shared scripts name no family, model, sound card or DRM driver
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BOARD=$HERE/overlay/usr/local/lib/tsx/board.sh
TB=$HERE/overlay/usr/local/bin/tsx-board
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
# sh_run CODE: run CODE in a clean shell that has sourced the board file
sh_run() { env -i PATH="$PATH" "$@" sh -c ". '$BOARD'; $SH_CODE"; }

echo "== syntax =="
busybox sh -n "$BOARD" 2>/dev/null && ok "board.sh passes busybox sh -n" || bad "board.sh: busybox sh -n"
busybox sh -n "$TB" 2>/dev/null && ok "tsx-board passes busybox sh -n" || bad "tsx-board: busybox sh -n"

echo "== sourcing prints nothing and the values are the xx60 values =="
out=$(env -i PATH="$PATH" sh -c ". '$BOARD'" 2>&1); eq "$out" "" "no output when sourced"
for kv in TSX_FAMILY=xx60 TSX_APK_CATEGORY=xx60 TSX_HA_MODEL=xx60 TSX_SOUND_CARD=TSW1060 'TSX_DISPLAY_DRM=meson*' \
	'TSX_RENDER_DRM=lima panfrost' TSX_RENDER_ES2_DRM=lima TSX_BT_PROXY_DEFAULT=off TSX_BT_MAC_SETTABLE=yes \
	TSX_MAC_SOURCE=uboot TSX_MAC_DEV=/dev/mmcblk0 TSX_SERIAL_CONSOLE=ttyAML0 TSX_RENDER_ENV= TSX_BROWSER_GL_FLAGS= TSX_VOLUME_CMD= \
	'TSX_DISPLAY_ENV=WLR_DRM_NO_MODIFIERS=1 CAGE_RENDER_FORMAT=argb8888' \
	TSX_BT_CHIP=/usr/local/lib/tsx/bt-chip-csr8811.sh; do
	k=${kv%%=*}; v=${kv#*=}
	SH_CODE="printf '%s' \"\$$k\""; eq "$(sh_run)" "$v" "$k"
done
SH_CODE='printf "%s" "$TSX_SOUND_CARD/$TSX_BT_CHIP"'
eq "$(sh_run TSX_SOUND_CARD=OTHER TSX_BT_LIB=/x)" "OTHER//x/bt-chip-csr8811.sh" "a value in the environment wins, and TSX_BT_LIB moves the chip file"

SH_CODE='tsx_board_ha_model'
eq "$(sh_run)" "xx60" "tsx_board_ha_model gives TSX_HA_MODEL"
SH_CODE='tsx_board_ha_model'
eq "$(sh_run TSX_HA_MODEL=other)" "other" "tsx_board_ha_model follows a changed TSX_HA_MODEL"

echo "== the kiosk board file =="
KB=$HERE/overlay/etc/tsx/panel-board.conf
busybox sh -n "$KB" 2>/dev/null && ok "panel-board.conf passes busybox sh -n" || bad "panel-board.conf: busybox sh -n"
eq "$(env -i PATH="$PATH" sh -c ". '$KB'; echo \"\$KIOSK_GPU \$BACKLIGHT_MAX \$BRIGHTNESS_DAY \$BRIGHTNESS_NIGHT \$CPUFREQ_AWAKE \$CPUFREQ_BLANK\"")" \
	"browser 23 17 8 performance schedutil" "panel-board.conf holds the xx60 values"
grep -q '^OVERLAY_GESTURE' "$KB" && bad "panel-board.conf sets OVERLAY_GESTURE (the default fivefinger applies)" || ok "panel-board.conf leaves OVERLAY_GESTURE to the default"
for k in KIOSK_GPU BACKLIGHT_MAX BRIGHTNESS_DAY BRIGHTNESS_NIGHT CPUFREQ_AWAKE CPUFREQ_BLANK; do
	a=$(sed -n "s/^$k=//p" "$HERE/overlay/etc/kiosk.conf" | tail -n 1); b=$(sed -n "s/^$k=//p" "$KB" | tail -n 1)
	eq "$b" "$a" "$k: the board file and kiosk.conf agree"
done
grep -q 'env/boot' "$HERE/overlay/etc/tsx/motd.board" && ok "motd.board has the boot status line" || bad "motd.board"

echo "== the functions, with a made-up U-Boot env =="
ENV='product_name=TSS-10_[v3.002.1061,_#0A1B2C3D]
lan_hostname=lobby-panel
ethaddr=00:10:7F:00:00:01
tsid=0A1B2C3D'
SH_CODE='echo "model=$(tsx_board_model) fw=$(tsx_board_stock_fw) unit=$(tsx_board_unit_id) mac=$(tsx_board_mac) hint=$(tsx_board_hostname_hint) src=$(tsx_board_mac_source) extra=$(tsx_board_rescue_extra)"'
eq "$(sh_run "TSX_BOARD_ENV=$ENV")" "model=TSS-10 fw=v3.002.1061 unit=00107f000001 mac=00:10:7F:00:00:01 hint=lobby-panel src=uboot extra=" "model, firmware, unit id, MAC, host name hint, MAC source, no extra rescue line"
eq "$(sh_run "TSX_BOARD_ENV=tsid=0A1B2C3D
ethaddr=bad")" "model= fw= unit=bad mac= hint= src=uboot extra=" "a bad ethaddr gives no MAC"
eq "$(sh_run "TSX_BOARD_ENV=tsid=0A1B2C3D")" "model= fw= unit=tsid-0A1B2C3D mac= hint= src=uboot extra=" "no ethaddr: the unit id comes from the tsid"
eq "$(sh_run TSX_BOARD_ENV=)" "model= fw= unit=unknown mac= hint= src=uboot extra=" "an empty env: unit id unknown, nothing else"
SH_CODE='tsx_env() { echo "$1" | tr a-z A-Z; }; tsx_board_model'
eq "$(sh_run TSX_BOARD_ENV=product_name=wrong)" "PRODUCT_NAME" "with tsx-lib.sh loaded (tsx_env), the functions read through tsx_env"

echo "== tsx_board_mac_early reads the env area of the disk =="
{ dd if=/dev/zero bs=64k count=16 2>/dev/null; printf 'ethaddr=00:10:7f:00:00:02\0other=1\n'; } > "$T/disk"
SH_CODE='tsx_board_mac_early'
eq "$(sh_run TSX_MMCBLK0="$T/disk")" "00:10:7f:00:00:02" "valid ethaddr"
{ dd if=/dev/zero bs=64k count=16 2>/dev/null; printf 'ethaddr=zz\0'; } > "$T/disk2"
eq "$(sh_run TSX_MMCBLK0="$T/disk2")" "" "an invalid ethaddr gives nothing"
eq "$(sh_run TSX_MMCBLK0="$T/none")" "" "no device gives nothing"

echo "== tsx_board_load with no env config leaves the data empty =="
SH_CODE='tsx_board_load; echo "rc=$? [$TSX_BOARD_ENV]"'
eq "$(sh_run TSX_ENV_CONF="$T/none.conf")" "rc=0 []" "no config: rc 0, empty"

echo "== tsx-board =="
tb() { env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" "$@" sh "$TB" $TBARGS; }
TBARGS="get TSX_SOUND_CARD"; eq "$(tb)" "TSW1060" "get a variable"
TBARGS="get TSX_DISPLAY_DRM"; eq "$(tb)" 'meson*' "get does not expand a pattern"
TBARGS="get TSX_NOPE"; tb >/dev/null; eq "$?" "1" "an unknown variable fails"
TBARGS="get TSX_SOUND_CARD"; eq "$(tb TSX_SOUND_CARD=X)" "X" "the environment wins"
TBARGS="call tsx_board_mac_source"; eq "$(tb)" "uboot" "call a board function"
TBARGS="call rm"; tb >/dev/null; eq "$?" "1" "call refuses another name"
TBARGS="get 'a b'"; tb >/dev/null 2>&1; eq "$?" "2" "a bad name is an error"

echo "== tsx-board call loads the env first =="
# A board file whose tsx_board_load fills the env from a fixture, as a running
# panel does from the U-Boot env. Without the load, the same functions print nothing.
cat > "$T/board-fx.sh" <<EOF
. "$BOARD"
tsx_board_load() {
	echo loaded >> "$T/load.log"
	TSX_BOARD_ENV='product_name=TSS-10_[v3.002.1061,_#0A1B2C3D]
ethaddr=00:10:7f:00:00:01'
}
EOF
tbl() { : > "$T/load.log"; env -i PATH="$PATH" TSX_BOARD_CONF="$T/board-fx.sh" sh "$TB" call "$1"; }
eq "$(tbl tsx_board_model)" "TSS-10" "call tsx_board_model prints the model on a running system"
eq "$(tbl tsx_board_stock_fw)" "v3.002.1061" "call tsx_board_stock_fw prints the firmware"
eq "$(tbl tsx_board_unit_id)" "00107f000001" "call tsx_board_unit_id prints the unit id"
eq "$(tbl tsx_board_mac)" "00:10:7f:00:00:01" "call tsx_board_mac prints the MAC"
eq "$(tbl tsx_board_mac_source)" "uboot" "call tsx_board_mac_source needs no env and still works"
[ ! -s "$T/load.log" ] && ok "a function that needs no env does not read it" || bad "tsx_board_mac_source read the env"
tbl tsx_board_model >/dev/null; [ "$(wc -l < "$T/load.log" | tr -d ' ')" = 1 ] && ok "the env is read once per call" || bad "load count: $(cat "$T/load.log")"
# the bug: without the load, the model function prints an empty line
eq "$(env -i PATH="$PATH" sh -c ". '$BOARD'; tsx_board_model")" "" "without tsx_board_load the function prints nothing (the old tsx-board call)"
# a failed load still ends in the normal output of the function, no crash
cat > "$T/board-fail.sh" <<EOF
. "$BOARD"
tsx_board_load() { TSX_BOARD_ENV=; echo "fw_printenv failed" >&2; return 1; }
EOF
out=$(env -i PATH="$PATH" TSX_BOARD_CONF="$T/board-fail.sh" sh "$TB" call tsx_board_model 2>/dev/null); rc=$?
eq "$rc:$out" "0:" "a failed load: the call still finishes with an empty line"

echo "== the shared code names no family, model, sound card or DRM driver =="
# Comment lines and the board glue of the xx60 (audio, tfa, boot update, LED bar) stay out.
SHARED="overlay/usr/local/bin/kiosk-session overlay/usr/local/sbin/tsx-mqtt overlay/usr/local/sbin/tsx-panelctl
overlay/usr/local/bin/tsx-voice-hook overlay/usr/local/sbin/tsx-config overlay/usr/local/sbin/tsx-autoupdate
overlay/usr/local/sbin/tsx-bt overlay/etc/init.d/tsx-bt overlay/etc/init.d/tsx-voice overlay/etc/init.d/tsx-sendspin
overlay/etc/init.d/tsx-hostname overlay/etc/init.d/tsx-setup initramfs/overlay/usr/sbin/tsx-rescue-status
initramfs/overlay/etc/init.d/rcS voice/shim/tsx_panel/backend.py voice/shim/tsx_panel/esphome_server.py
voice/shim/tsx_panel/device.py"
for f in $SHARED; do
	hits=$(grep -nE 'xx60|TSW-?1060|TSS-10|meson|lima|panfrost' "$HERE/$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '#.*(xx60|TSW|lima|meson)' || true)
	[ -z "$hits" ] && ok "$f" || bad "$f: $(echo "$hits" | head -n 2 | tr '\n' ' ')"
done

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS test-board-xx60" || { echo "FAIL test-board-xx60"; exit 1; }
