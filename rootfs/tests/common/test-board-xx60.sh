#!/bin/bash
# Host test: the shared panel software of tsx-linux-common on the xx60 board
# files of this repository. The xx60 board file names the display driver
# (meson) and the GPU without a display (lima). It also names the sound card,
# the Bluetooth chip file and the ESPHome model. The test runs the real
# scripts of tsx-linux-common against these files. It checks what each script
# takes from the board:
#   - the values of the board file, read with tsx-board
#   - the kiosk renderer selection, with a fake sysfs, and the kiosk hook
#     kiosk.d/es2.sh (the ES2 browser mode of the Mali-450)
#   - the browser flags that the hook gives to kiosk-session
#   - the model name and the volume entity in tsx-mqtt (dry run)
#   - the Home Assistant model, the keys and the backlight range in the ESPHome shim
#   - tsx-bt with the CSR8811 chip file, on a panel with and without the module
#   - the kernel package name in tsx-autoupdate
#   - the serial console, and its line in the securetty file of the board package
#   - the service order that the board gives in /etc/conf.d
#   - the helper file of the rescue system that board.sh loads
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
# The hook of the xx60. The copy has the modes that the image gives it (root owns it, nobody else writes it).
HOOK_SRC=$XX60/rootfs/overlay/usr/local/lib/tsx/kiosk.d/es2.sh
[ -r "$HOOK_SRC" ] && ok "the xx60 overlay has the kiosk hook kiosk.d/es2.sh" || bad "no kiosk hook at $HOOK_SRC"
busybox sh -n "$HOOK_SRC" && ok "the hook passes busybox sh -n" || bad "es2.sh: busybox sh -n"
mkdir -p "$T/kiosk.d"; cp "$HOOK_SRC" "$T/kiosk.d/es2.sh"; chmod 755 "$T/kiosk.d"; chmod 644 "$T/kiosk.d/es2.sh"
mkdir -p "$T/drivers/lima" "$T/drivers/panfrost" "$T/drivers/meson" "$T/drivers/simple-framebuffer"
# mkdrm DIR [CARD:DRIVER...] render:DRIVER
mkdrm() { d=$1; shift; rm -rf "$d"; mkdir -p "$d"
	for a in "$@"; do
		case "$a" in
		render:*) drv=${a#render:}; mkdir -p "$d/renderD128/device"; ln -s "$T/drivers/$drv" "$d/renderD128/device/driver";;
		*) c=${a%%:*}; drv=${a#*:}; mkdir -p "$d/$c/device"; ln -s "$T/drivers/$drv" "$d/$c/device/driver"
			# a display driver has a connector inside its card. A GPU with no display (lima) has none.
			case "$drv" in lima|panfrost) ;; *) mkdir -p "$d/$c/$c-LVDS-1";; esac;;
		esac
	done; }
# sel DRMDIR [KIOSK_GPU] [ES2_CHECK] [HOOKDIR]: ES2_CHECK is the exit status of "tsx-chromium-es2 check" (default 0).
# HOOKDIR is the kiosk.d folder (default: the hook of the xx60). KIOSK_DISABLE_FEATURES in the environment is the starting value.
sel() {
	printf '#!/bin/sh\nexit %s\n' "${3:-0}" > "$T/es2-check"; chmod +x "$T/es2-check"
	env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" TSX_DRM_SYS="$1" KIOSK_GPU="${2:-auto}" KIOSK_RENDER_ENV=auto \
		TSX_KIOSK_HOOK_DIR="${4:-$T/kiosk.d}" TSX_KIOSK_HOOK_UID="$(id -u)" TSX_ES2_TOOL="$T/es2-check" KIOSK_DISABLE_FEATURES="${KIOSK_DISABLE_FEATURES:-}" sh -c '
		set -u   # as in kiosk-session
		KIOSK_OSK=off KIOSK_URL=u ROLE=session
		log() { echo "log: $*"; }
		. "$TSX_BOARD_CONF"
		. '"$T"'/sel.sh
		echo "WLR_RENDERER=$WLR_RENDERER WLR_DRM_DEVICES=${WLR_DRM_DEVICES:-} NOMOD=${WLR_DRM_NO_MODIFIERS:-} FMT=${CAGE_RENDER_FORMAT:-}"
		echo "comp_gl=$comp_gl browser_gl=$browser_gl flags=$KIOSK_BROWSER_GL_FLAGS features=$KIOSK_DISABLE_FEATURES"' 2>&1; }
# on the xx60, lima is card0 and meson is card2
mkdrm "$T/drm" card0:lima card2:meson render:lima
out=$(sel "$T/drm")
echo "$out" | grep -q "^log: display=/dev/dri/card2 (meson) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=0" && ok "auto: meson display (card2), lima render node, GLES in the compositor, software browser" || bad "auto: $out"
echo "$out" | grep -q "WLR_DRM_DEVICES=/dev/dri/card2 NOMOD=1 FMT=argb8888" && ok "auto: the display variables of the board are exported (no modifiers, ARGB8888)" || bad "auto, variables: $out"
echo "$out" | grep -q "log: GPU is lima (GLES 2.0)" && ok "auto: the hook notes that lima has GLES 2.0 only" || bad "auto, note: $out"
echo "$out" | grep -q "^comp_gl=1 browser_gl=0 flags= features=$" && ok "auto: the hook changes nothing but the browser mode" || bad "auto, names: $out"
out=$(sel "$T/drm" auto 0 "$T/no-kiosk.d")
echo "$out" | grep -q "browser_gpu=1" && ok "auto without the hook: stock Chromium would get the GPU (the rule is in the hook)" || bad "auto without the hook: $out"
out=$(sel "$T/drm" browser 0)
echo "$out" | grep -q "^log: display=/dev/dri/card2 (meson) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=1" && ok "browser: GPU browser on lima through the ES2 path" || bad "browser: $out"
echo "$out" | grep -q "^log: es2 hook: KIOSK_GPU=browser, the Chromium ES2 patch is present" && ok "browser: the hook logs one line" || bad "browser, hook line: $out"
echo "$out" | grep -q "^comp_gl=1 browser_gl=1 flags=--use-gl=angle --use-angle=gles --disable-webgl2 features=AllowANGLEPassthroughShaders$" && ok "browser: GLES compositor, GPU browser, ANGLE on GLES, WebGL2 off, passthrough shaders off" || bad "browser, names: $out"
out=$(KIOSK_DISABLE_FEATURES=Prerender2,BackForwardCache sel "$T/drm" browser 0)
echo "$out" | grep -q "features=AllowANGLEPassthroughShaders,Prerender2,BackForwardCache$" && ok "browser: the passthrough shaders go first, the features of kiosk.conf stay" || bad "browser, features: $out"
out=$(KIOSK_DISABLE_FEATURES=Prerender2,AllowANGLEPassthroughShaders sel "$T/drm" browser 0)
echo "$out" | grep -q "features=Prerender2,AllowANGLEPassthroughShaders$" && ok "browser: the passthrough shaders are not listed twice" || bad "browser, double feature: $out"
out=$(sel "$T/drm" browser 1)
echo "$out" | grep -q "browser_gpu=0" && echo "$out" | grep -q "Chromium ES2 patch is not present" && ok "browser, no ES2 patch: software browser, with a log line" || bad "browser without the patch: $out"
echo "$out" | grep -q "^comp_gl=1 browser_gl=0 flags= features=$" && ok "browser, no ES2 patch: GLES compositor, no GPU flags, features as they were" || bad "browser without the patch, names: $out"
out=$(sel "$T/drm" browser 0 "$T/no-kiosk.d")
echo "$out" | grep -q "browser_gpu=1" && echo "$out" | grep -q "^comp_gl=1 browser_gl=1 flags= features=$" && ok "browser without the hook: the value counts as auto (no ES2 flags)" || bad "browser without the hook: $out"
mkdrm "$T/drm3" card2:meson
out=$(sel "$T/drm3" browser 0)
echo "$out" | grep -q "browser_gpu=0" && echo "$out" | grep -q "^comp_gl=1 " && ok "browser with no render node: GLES compositor, software browser" || bad "browser, no render node: $out"
out=$(sel "$T/drm" on)
echo "$out" | grep -q "browser_gpu=1" && ok "on: forces the GPU browser on lima (stock flags)" || bad "on: $out"
echo "$out" | grep -q "GLES 2.0\|es2 hook" && bad "on: the hook speaks" || ok "on: the hook stays silent"
mkdrm "$T/drmp" card0:panfrost card2:meson render:panfrost
out=$(sel "$T/drmp")
echo "$out" | grep -q "browser_gpu=1" && ok "auto on panfrost: the GPU browser stays (only lima has GLES 2.0 only)" || bad "auto on panfrost: $out"
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
# flags DRMDIR KIOSK_GPU ES2_CHECK: the selection (with the hook of the xx60) and the browser section in one shell
flags() {
	printf '#!/bin/sh\nexit %s\n' "${3:-0}" > "$T/es2-check"; chmod +x "$T/es2-check"
	env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" TSX_DRM_SYS="$1" KIOSK_GPU="${2:-auto}" KIOSK_RENDER_ENV=auto \
		TSX_KIOSK_HOOK_DIR="$T/kiosk.d" TSX_KIOSK_HOOK_UID="$(id -u)" TSX_ES2_TOOL="$T/es2-check" KIOSK_DISABLE_FEATURES="${KIOSK_DISABLE_FEATURES:-}" sh -c '
		set -u   # as in kiosk-session
		KIOSK_OSK=off KIOSK_URL=u ROLE=browser
		log() { :; }
		. "$TSX_BOARD_CONF"
		. '"$T"'/sel.sh
		KIOSK_PROFILE='"$T"'/profile KIOSK_SCALE=1 KIOSK_NO_SANDBOX=1
		. '"$T"'/browser.sh
		echo "$@"' 2>&1; }
# count FLAG LIST: how often the word FLAG is in LIST
count() { printf '%s\n' "$2" | tr ' ' '\n' | grep -cx -- "$1"; }
f=$(flags "$T/drm" browser 0)
for w in --use-gl=angle --use-angle=gles --ignore-gpu-blocklist --disable-webgl2; do
	eq "$(count "$w" "$f")" 1 "ES2: the flag $w is on the command line once"
done
case "$f" in *--disable-features=*,AllowANGLEPassthroughShaders*) ok "ES2: ANGLE passthrough shaders off (the Mali-450 has no vertex texture units)";; *) bad "ES2 passthrough shaders: $f";; esac
case "$f" in *--disable-gpu-compositing*) bad "ES2: software flags: $f";; *) ok "ES2: GPU compositing stays on";; esac
f=$(KIOSK_DISABLE_FEATURES=Prerender2 flags "$T/drm" browser 0)
case "$f" in *--disable-features=*PasswordManagerOnboarding,AllowANGLEPassthroughShaders,Prerender2*) ok "ES2: --disable-features lists the passthrough shaders, then the features of kiosk.conf";; *) bad "ES2 feature list: $f";; esac
f=$(flags "$T/drm" auto 0)
case "$f" in *--disable-gpu-compositing*) ok "software browser: GPU compositing off";; *) bad "software flags: $f";; esac
case "$f" in *AllowANGLEPassthroughShaders*|*--use-angle=gles*) bad "software browser: ES2 flags: $f";; *) ok "software browser: the passthrough shaders stay as they are, no ANGLE flags";; esac
f=$(flags "$T/drm" browser 1)
case "$f" in *--disable-gpu-compositing*) ok "browser without the patch: software flags";; *) bad "browser without the patch, flags: $f";; esac

echo "== tsx-mqtt (dry run) =="
mkdir -p "$T/mq/run" "$T/mq/bin" "$T/mq/asound/TSW1060" "$T/mq/asound-other/Other"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mq/mqtt.conf"
# tsx-mqtt asks tsx-panelctl whether the sound card of the board is there
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$(P usr/local/sbin/tsx-panelctl)" > "$T/mq/bin/tsx-panelctl"; chmod +x "$T/mq/bin/tsx-panelctl"
mq() { echo | PATH=$T/mq/bin:$PATH TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mq/mqtt.conf TSX_RUN_DIR=$T/mq/run TSX_ASOUND_DIR=$1 \
	TSX_BUTTONS_CONF=$T/none TSX_BUTTONS_BOARD_CONF=$T/none TSX_KIOSK_CONF=$(P etc/kiosk.conf) TSX_PANEL_BOARD_CONF=$XX60_PANEL_BOARD sh "$(P usr/local/sbin/tsx-mqtt)" 2>&1; }
out=$(mq "$T/mq/asound")
echo "$out" | grep -q '"mdl":"xx60 (mainline Linux)"' && ok "the device model comes from the board file" || bad "mdl: $(echo "$out" | grep -m1 mdl | cut -c1-120)"
echo "$out" | grep -q 'number/tsx-kiosk/volume/config' && ok "the volume entity follows the sound card of the board (TSW1060)" || bad "no volume entity with the card TSW1060"
out=$(mq "$T/mq/asound-other")
echo "$out" | grep -q 'number/tsx-kiosk/volume/config {' && bad "a volume entity without the card TSW1060" || ok "no volume entity without the card of the board"

echo "== the ESPHome shim =="
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/shim/run" "$T/shim/bl/x"
env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" TSX_BOARD_BIN="$TSX_BOARD_BIN" TSX_RUN_DIR="$T/shim/run" TSX_BACKLIGHT_DIR="$T/shim/bl" \
	TSX_BUTTONS_CONF="$(P etc/tsx/buttons.conf)" TSX_BUTTONS_BOARD_CONF="$XX60_BUTTONS" TSX_KIOSK_CONF="$(P etc/kiosk.conf)" \
	TSX_PANEL_BOARD_CONF="$XX60_PANEL_BOARD" TSX_PANELCTL_BIN=/nonexistent \
	python3 - "$COMMON/ha/voice/shim" <<'PY' 2>&1 | sed 's/^/  /'
import sys
sys.path.insert(0, sys.argv[1])
from tsx_panel.backend import PanelBackend, board_call, board_value, esphome_model
b = PanelBackend()
model = esphome_model(board_call("tsx_board_ha_model"), board_value("TSX_HA_MODEL"))
assert model == "xx60 panel", model
print("ok: the ESPHome model is", model)
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
grep -qx 'reason=government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module' "$T/bt/run/bt.state" && ok "government=1: the reason is the REASON text of hw.conf" || bad "government=1 reason: $(grep reason "$T/bt/run/bt.state")"
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
# The board package ships /etc/securetty: the list of the Alpine busybox package
# plus the serial console of the board file. No boot script edits the file (apk
# would leave a securetty.apk-new at each upgrade). tsx-linux-common ships no
# securetty and no script that changes it.
SEC=$XX60/rootfs/overlay/etc/securetty
[ -f "$SEC" ] && ok "the board has a securetty file" || bad "no rootfs/overlay/etc/securetty"
[ -z "$(find "$COMMON" -path "$COMMON/.git" -prune -o -path "$COMMON/tests" -prune -o -name securetty -print)" ] && ok "tsx-linux-common ships no securetty" || bad "tsx-linux-common ships a securetty file"
for c in $(env -i PATH="$PATH" sh -c ". '$BOARD'; echo \"\$TSX_SERIAL_CONSOLE\""); do
	eq "$(grep -cx "$c" "$SEC")" 1 "securetty lists the serial console $c of the board file once"
done
eq "$(sort "$SEC" | uniq -d | tr '\n' ' ')" "" "securetty has no duplicate line"
[ -z "$(tail -c 1 "$SEC")" ] && ok "securetty ends with a newline" || bad "securetty has no final newline"
[ "$(grep -c '^ttyAMA0$' "$SEC")" = 1 ] && grep -qx console "$SEC" && grep -qx tty1 "$SEC" && ok "securetty keeps the generic Alpine names" || bad "securetty lost its generic names"
grep -q '[[:space:]]' "$SEC" && bad "securetty has a blank or a comment" || ok "securetty has only device names, one on each line"
# the init script of the service no longer touches it: start() leaves a securetty file as it is
mkdir -p "$T/svc-bin"
for tool in tsx-hw tsx-emmc-state tsx-config; do printf '#!/bin/sh\nexit 0\n' > "$T/svc-bin/$tool"; chmod 755 "$T/svc-bin/$tool"; done
sed -e "s|/usr/local/sbin/|$T/svc-bin/|g" "$(P etc/init.d/tsx-config)" > "$T/tsx-config.init"
cp "$SEC" "$T/securetty.init"
out=$(env -i PATH="$PATH" TSX_BOARD_CONF="$BOARD" TSX_SECURETTY="$T/securetty.init" busybox sh -c '. "$1"; checkpath() { :; }; ebegin() { :; }; eend() { :; }; ewarn() { echo "ewarn: $*"; }; start' sh "$T/tsx-config.init" 2>&1)
[ -z "$out" ] && cmp -s "$SEC" "$T/securetty.init" && ok "start() of the tsx-config service leaves securetty as it is" || bad "tsx-config start(): '$out'"

echo "== the service order of the board =="
# tsx-linux-common names no service of a board. The board package gives the
# order of its light service in /etc/conf.d (rc_after).
for svc in tsx-panelctl tsx-esphome tsx-mqtt; do
	f=$XX60/rootfs/overlay/etc/conf.d/$svc
	grep -qx 'rc_after="tsx-als"' "$f" 2>/dev/null && ok "conf.d/$svc: rc_after=\"tsx-als\"" || bad "conf.d/$svc has no rc_after for tsx-als"
	busybox sh -n "$f" && ok "conf.d/$svc passes busybox sh -n" || bad "conf.d/$svc: busybox sh -n"
done
for init in base/etc/init.d/tsx-panelctl ha/etc/init.d/tsx-esphome ha/etc/init.d/tsx-mqtt; do
	grep -q 'tsx-als' "$COMMON/$init" && bad "$init of tsx-linux-common names tsx-als" || ok "$init of tsx-linux-common names no service of the xx60"
done

echo "== board.sh loads the helper file of the rescue system =="
# The shared scripts source only board.sh. On the rescue system, board.sh loads
# tsx-lib.sh by itself (TSX_LIB is the path). Without the file, it loads nothing and does not fail.
printf 'tsx_env() { echo from-helper-$1; }\n' > "$T/lib-stub.sh"
eq "$(env -i PATH="$PATH" TSX_LIB="$T/lib-stub.sh" busybox sh -c ". '$BOARD'; type tsx_env >/dev/null 2>&1 && tsx_env x")" "from-helper-x" "board.sh sources the helper file: tsx_env is defined"
eq "$(env -i PATH="$PATH" TSX_LIB="$T/lib-stub.sh" TSX_BOARD_ENV=product_name=wrong busybox sh -c ". '$BOARD'; tsx_board_model")" "from-helper-product_name" "with the helper file, the board functions read through tsx_env"
out=$(env -i PATH="$PATH" TSX_LIB="$T/no-such-lib.sh" busybox sh -c "set -eu; . '$BOARD'; echo loaded; type tsx_env >/dev/null 2>&1 && echo has-helper" 2>&1)
eq "$out" "loaded" "no helper file: board.sh loads, defines no tsx_env and does not stop the script (set -eu)"
eq "$(env -i PATH="$PATH" TSX_LIB="$T/lib-stub.sh" busybox sh -c ". '$BOARD'; echo \"\${_tb_lib:-unset}\"")" "unset" "board.sh leaves no scratch variable"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS common/test-board-xx60" || { echo "FAIL common/test-board-xx60"; exit 1; }
