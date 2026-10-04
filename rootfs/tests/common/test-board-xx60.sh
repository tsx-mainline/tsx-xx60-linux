#!/bin/bash
# Host test: the shared panel software of tsx-linux-common on the xx60 board
# files of this repository. The xx60 board file names the display driver
# (meson) and the GPU without a display (lima). It also names the sound card,
# the Bluetooth chip file and the ESPHome model. The test runs the real
# scripts of tsx-linux-common against these files. It checks what each script
# takes from the board:
#   - the values of the board file, read with tsx-board
#   - the kiosk renderer selection, with a fake sysfs, and the browser flags
#   - the model name and the volume entity in tsx-mqtt (dry run)
#   - the Home Assistant model, the keys and the backlight range in the ESPHome shim
#   - tsx-bt with the CSR8811 chip file, on a panel with and without the module
#   - the kernel package name in tsx-autoupdate
#   - the serial console
# The test needs no panel and no compiler.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED common/test-board-xx60: no busybox on this host"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
BOARD=$TSX_BOARD_CONF

echo "== the board values, read with tsx-board of tsx-linux-common =="
tb() { env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" busybox sh "$TSX_BOARD_BIN" "$@"; }
eq "$(tb get TSX_FAMILY)" xx60 "TSX_FAMILY"
eq "$(tb get TSX_APK_CATEGORY)" xx60 "TSX_APK_CATEGORY"
eq "$(tb get TSX_SOUND_CARD)" TSW1060 "TSX_SOUND_CARD"
eq "$(tb get TSX_DISPLAY_DRM)" 'meson*' "TSX_DISPLAY_DRM"
eq "$(tb get TSX_RENDER_DRM)" 'lima panfrost' "TSX_RENDER_DRM"
eq "$(tb get TSX_RENDER_ES2_DRM)" lima "TSX_RENDER_ES2_DRM"
eq "$(tb get TSX_SERIAL_CONSOLE)" ttyAML0 "TSX_SERIAL_CONSOLE"
eq "$(tb get TSX_BT_CHIP)" /usr/local/lib/tsx/bt-chip-csr8811.sh "TSX_BT_CHIP names the CSR8811 chip file"
eq "$(tb get TSX_BT_PROXY_DEFAULT)" off "TSX_BT_PROXY_DEFAULT"
eq "$(tb get TSX_MAC_SOURCE)" uboot "TSX_MAC_SOURCE"
eq "$(tb call tsx_board_ha_model)" xx60 "tsx_board_ha_model"
eq "$(tb call tsx_board_mac_source)" uboot "tsx_board_mac_source"

echo "== kiosk renderer selection (fake sysfs) =="
KS=$(P usr/local/bin/kiosk-session)
sed -n '/^# --- renderer selection/,/^log "display=/p' "$KS" > "$T/sel.sh"
[ "$(wc -l < "$T/sel.sh")" -gt 20 ] && ok "the renderer selection is in kiosk-session" || bad "cannot find the renderer selection"
mkdir -p "$T/drivers/lima" "$T/drivers/meson" "$T/drivers/simple-framebuffer"
# mkdrm DIR [CARD:DRIVER...] render:DRIVER
mkdrm() { d=$1; shift; rm -rf "$d"; mkdir -p "$d"
	for a in "$@"; do
		case "$a" in
		render:*) drv=${a#render:}; mkdir -p "$d/renderD128/device"; ln -s "$T/drivers/$drv" "$d/renderD128/device/driver";;
		*) c=${a%%:*}; drv=${a#*:}; mkdir -p "$d/$c/device"; ln -s "$T/drivers/$drv" "$d/$c/device/driver"
			# a display driver has a connector inside its card. A GPU with no display (lima) has none.
			case "$drv" in lima) ;; *) mkdir -p "$d/$c/$c-LVDS-1";; esac;;
		esac
	done; }
# sel DRMDIR [KIOSK_GPU] [ES2_CHECK]: ES2_CHECK is the exit status of "tsx-chromium-es2 check" (default 0)
sel() {
	printf '#!/bin/sh\nexit %s\n' "${3:-0}" > "$T/es2-check"; chmod +x "$T/es2-check"
	sed "s|/usr/local/sbin/tsx-chromium-es2|$T/es2-check|" "$T/sel.sh" > "$T/sel2.sh"
	env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" TSX_DRM_SYS="$1" KIOSK_GPU="${2:-auto}" KIOSK_RENDER_ENV=auto sh -c '
		KIOSK_OSK=off KIOSK_URL=u ROLE=session
		log() { echo "log: $*"; }
		. "$TSX_BOARD_CONF"
		. '"$T"'/sel2.sh
		echo "WLR_RENDERER=$WLR_RENDERER WLR_DRM_DEVICES=${WLR_DRM_DEVICES:-} NOMOD=${WLR_DRM_NO_MODIFIERS:-} FMT=${CAGE_RENDER_FORMAT:-}"
		echo "comp_gl=$comp_gl browser_gl=$browser_gl es2=$es2"' 2>&1; }
# on the xx60, lima is card0 and meson is card2
mkdrm "$T/drm" card0:lima card2:meson render:lima
out=$(sel "$T/drm")
echo "$out" | grep -q "^log: display=/dev/dri/card2 (meson) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=0" && ok "auto: meson display (card2), lima render node, GLES in the compositor, software browser" || bad "auto: $out"
echo "$out" | grep -q "WLR_DRM_DEVICES=/dev/dri/card2 NOMOD=1 FMT=argb8888" && ok "auto: the display variables of the board are exported (no modifiers, ARGB8888)" || bad "auto, variables: $out"
echo "$out" | grep -q "log: GPU is lima (GLES 2.0)" && ok "auto: the GLES 2.0 note names lima" || bad "auto, note: $out"
out=$(sel "$T/drm" browser 0)
echo "$out" | grep -q "^log: display=/dev/dri/card2 (meson) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=1 es2=1" && ok "browser: GPU browser on lima through the ES2 path" || bad "browser: $out"
echo "$out" | grep -q "comp_gl=1 browser_gl=1 es2=1" && ok "browser: GLES compositor, GPU browser, ES2" || bad "browser, flags: $out"
out=$(sel "$T/drm" browser 1)
echo "$out" | grep -q "browser_gpu=0 es2=0" && echo "$out" | grep -q "Chromium ES2 patch is not present" && ok "browser, no ES2 patch: software browser, with a log line" || bad "browser without the patch: $out"
out=$(sel "$T/drm" off)
echo "$out" | grep -q "renderer=pixman" && ok "off: pixman" || bad "off: $out"
mkdrm "$T/drm1" card0:simple-framebuffer
out=$(sel "$T/drm1")
echo "$out" | grep -q "renderer=pixman" && ok "only the firmware framebuffer: pixman" || bad "simple framebuffer: $out"
mkdrm "$T/drm2" card0:lima render:lima
out=$(sel "$T/drm2")
echo "$out" | grep -q "display=none\|display= " && ok "lima alone has no display" || bad "lima alone: $out"

echo "== the browser flags of the ES2 path =="
# The browser part of kiosk-session, from the top of the browser section to the memory check.
sed -n '/^# --- browser ---/,/^mem=\$(awk/p' "$KS" | sed '$d' > "$T/browser.sh"
[ "$(wc -l < "$T/browser.sh")" -gt 30 ] && ok "the browser section is in kiosk-session" || bad "cannot find the browser section"
flags() { # ES2 BROWSER_GL
	env -i PATH="$PATH" sh -c '
		log() { :; }
		KIOSK_PROFILE='"$T"'/profile KIOSK_SCALE=1 KIOSK_NO_SANDBOX=1 es2='"$1"' browser_gl='"$2"' TSX_BROWSER_GL_FLAGS=
		. '"$T"'/browser.sh
		echo "$@"' 2>&1; }
f=$(flags 1 1)
case " $f " in *" --use-gl=angle --use-angle=gles --ignore-gpu-blocklist --disable-webgl2 "*) ok "ES2: ANGLE on GLES, WebGL2 off";; *) bad "ES2 flags: $f";; esac
case "$f" in *--disable-features=*AllowANGLEPassthroughShaders*) ok "ES2: ANGLE passthrough shaders off (the Mali-450 has no vertex texture units)";; *) bad "ES2 passthrough shaders: $f";; esac
f=$(flags 0 0)
case "$f" in *--disable-gpu-compositing*) ok "software browser: GPU compositing off";; *) bad "software flags: $f";; esac
case "$f" in *AllowANGLEPassthroughShaders*) bad "software browser: passthrough shaders turned off";; *) ok "software browser: the passthrough shaders stay as they are";; esac

echo "== tsx-mqtt (dry run) =="
mkdir -p "$T/mq/run" "$T/mq/bin" "$T/mq/asound/TSW1060" "$T/mq/asound-other/Other"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mq/mqtt.conf"
# tsx-mqtt asks tsx-panelctl whether the sound card of the board is there
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$(P usr/local/sbin/tsx-panelctl)" > "$T/mq/bin/tsx-panelctl"; chmod +x "$T/mq/bin/tsx-panelctl"
mq() { echo | PATH=$T/mq/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mq/mqtt.conf TSX_RUN_DIR=$T/mq/run TSX_ASOUND_DIR=$1 \
	TSX_BUTTONS_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_PANEL_BOARD_CONF=$XX60_PANEL_BOARD sh "$(P usr/local/sbin/tsx-mqtt)" 2>&1; }
out=$(mq "$T/mq/asound")
echo "$out" | grep -q '"mdl":"xx60 (mainline Linux)"' && ok "the device model comes from the board file" || bad "mdl: $(echo "$out" | grep -m1 mdl | cut -c1-120)"
echo "$out" | grep -q 'number/tsx-kiosk/volume/config' && ok "the volume entity follows the sound card of the board (TSW1060)" || bad "no volume entity with the card TSW1060"
out=$(mq "$T/mq/asound-other")
echo "$out" | grep -q 'number/tsx-kiosk/volume/config {' && bad "a volume entity without the card TSW1060" || ok "no volume entity without the card of the board"

echo "== the ESPHome shim =="
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/shim/run" "$T/shim/bl/x"
env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" TSX_BOARD_BIN="$TSX_BOARD_BIN" TSX_RUN_DIR="$T/shim/run" TSX_BACKLIGHT_DIR="$T/shim/bl" \
	TSX_BUTTONS_CONF="$XX60_BUTTONS" TSX_KIOSK_CONF="$(P etc/kiosk.conf)" TSX_PANEL_BOARD_CONF="$XX60_PANEL_BOARD" TSX_PANELCTL_BIN=/nonexistent \
	python3 - "$COMMON/ha/voice/shim" <<'PY' 2>&1 | sed 's/^/  /'
import sys
sys.path.insert(0, sys.argv[1])
from tsx_panel.backend import PanelBackend, board_call, board_value, esphome_model
b = PanelBackend()
model = esphome_model(board_call("tsx_board_ha_model"), board_value("TSX_HA_MODEL"))
assert model == "xx60 panel", model
print("ok: the ESPHome model is", model)
assert b.keypad_present()
assert b.key_names() == ["power", "home", "lights", "up", "down"], b.key_names()
print("ok: the five keys of the xx60:", " ".join(b.key_names()))
assert b.get_backlight_max() == 23, b.get_backlight_max()
print("ok: the backlight range of the xx60 ends at", b.get_backlight_max())
PY
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && ok "the ESPHome shim reads the model, the keys and the backlight range from the xx60 files" || bad "the ESPHome shim check (exit $rc)"

echo "== tsx-bt with the CSR8811 chip file =="
BTLIB=$XX60/rootfs/overlay/usr/local/lib/tsx
[ -r "$BTLIB/bt-chip-csr8811.sh" ] && [ -r "$BTLIB/csr_psload.py" ] && ok "the chip file and the PSR loader are in the xx60 files" || bad "no chip file or PSR loader in $BTLIB"
busybox sh -n "$BTLIB/bt-chip-csr8811.sh" && ok "the chip file passes busybox sh -n" || bad "chip file: busybox sh -n"
grep -q 'TTY=${TSX_BT_TTY:-/dev/ttyAML1}' "$BTLIB/bt-chip-csr8811.sh" && ok "the chip file talks to /dev/ttyAML1" || bad "the chip file names another UART"
mkdir -p "$T/bt/proc" "$T/bt/bin" "$T/bt/sys/class/bluetooth"
printf '#!/bin/sh\nexit 0\n' > "$T/bt/bin/logger"; chmod +x "$T/bt/bin/logger"
hw() { echo "$1" > "$T/bt/proc/cmdline"; env PATH="$T/bt/bin:$PATH" TSX_RUN_DIR="$T/bt/run" TSX_PROC="$T/bt/proc" busybox sh "$XX60_HW" detect >/dev/null; }
btup() { env PATH="$T/bt/bin:$PATH" TSX_RUN_DIR="$T/bt/run" TSX_SYSFS="$T/bt/sys" TSX_PROC="$T/bt/proc" TSX_BT_LIB="$BTLIB" TSX_BT_WAIT=1 \
	TSX_BOARD_CONF="$BOARD" busybox sh "$(P usr/local/sbin/tsx-bt)" "$@"; }
mkdir -p "$T/bt/run"
# a TSW-760-NC (government=1) has no module: tsx-bt never touches the chip
hw "console=tty0 androidboot.government=1"
out=$(btup up 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx 'state=absent' "$T/bt/run/bt.state" && ok "government=1: tsx-bt up ends with state=absent and exit 0" || bad "government=1: exit $rc, $(cat "$T/bt/run/bt.state" 2>/dev/null)"
grep -qx 'reason=no Bluetooth module on this panel (government=1)' "$T/bt/run/bt.state" && ok "government=1: the reason comes from the chip file" || bad "government=1 reason: $(grep reason "$T/bt/run/bt.state")"
# a panel with the module: the chip file runs. A host has no /dev/ttyAML1, so chip_up stops at once.
hw "console=tty0 androidboot.government=0"
rm -f "$T/bt/run/bt.state"
out=$(btup up 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qx 'state=failed' "$T/bt/run/bt.state" && ok "government=0: the chip file runs and fails on a host (no UART)" || bad "government=0: exit $rc, $(cat "$T/bt/run/bt.state" 2>/dev/null)"
grep -q '^reason=/dev/ttyAML1 does not exist' "$T/bt/run/bt.state" && ok "government=0: the chip file names /dev/ttyAML1" || bad "government=0 reason: $(grep reason "$T/bt/run/bt.state")"
# the Bluetooth address is the eth0 MAC
mkdir -p "$T/bt/sys/class/net/eth0"; echo "00:10:7f:00:00:09" > "$T/bt/sys/class/net/eth0/address"
eq "$(btup mac 2>&1)" "00:10:7F:00:00:09" "tsx-bt mac: the Bluetooth address is the eth0 MAC, in upper case"

echo "== tsx-autoupdate =="
BIN=$(P usr/local/sbin/tsx-autoupdate)
for p in tsx-xx60-kernel-lts tsx-xx60-kernel-stable; do
	TSX_BOARD_CONF=$BOARD busybox sh "$BIN" __needs_reboot "$p"; eq $? 0 "$p needs a reboot"
done
TSX_BOARD_CONF=$BOARD busybox sh "$BIN" __needs_reboot "tsx-base"; eq $? 1 "tsx-base needs no reboot"

echo "== the serial console =="
eq "$(env -i PATH="$PATH" sh -c ". '$BOARD'; . '$(P usr/local/lib/tsx/serial.sh)'; echo \"\$TSX_SERIAL_CONSOLE\"")" ttyAML0 "the board gives the serial console to serial.sh"
grep -qx ttyAML0 "$XX60/rootfs/overlay/etc/securetty" && ok "securetty of the xx60 lists ttyAML0 (root login on the serial console)" || bad "securetty of the xx60 has no ttyAML0"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS common/test-board-xx60" || { echo "FAIL common/test-board-xx60"; exit 1; }
