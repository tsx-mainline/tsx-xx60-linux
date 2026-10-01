#!/bin/bash
# Host test: the shared panel software on a board that is not the xx60. A fake
# board file with made-up values stands in for another family. The
# test runs the real scripts of the overlay against it and checks that no
# xx60 name, model or driver shows up. It needs no panel and no compiler.
#   - the rescue screen: model, firmware, unit, MAC source, extra line
#   - the kiosk renderer selection, with a fake sysfs (fakedrm board and xx60 board)
#   - tsx-config apply: repository category, Bluetooth defaults, BT_MAC
#   - tsx-mqtt: the Home Assistant model
#   - tsx-autoupdate: the package names
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
O=$HERE/overlay
BOARDX=$(mktemp -d)/board.sh; T=$(dirname "$BOARDX"); trap 'rm -rf "$T"' EXIT
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-board-fake: no busybox on this host"; exit 0; }
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

: > "$T/nolib.sh"
cat > "$BOARDX" <<'EOB'
# A made-up board file
TSX_FAMILY=fake
TSX_APK_CATEGORY=fake
TSX_HA_MODEL=FAKE-100
TSX_SOUND_CARD=FakeCard
TSX_DISPLAY_DRM="fakedrm*"
TSX_RENDER_DRM="fakedrm*"
TSX_RENDER_ES2_DRM=
TSX_DISPLAY_ENV=
TSX_BT_CHIP=none
TSX_BT_PROXY_DEFAULT=on
TSX_BT_MAC_SETTABLE=no
TSX_MAC_SOURCE=hardware
TSX_MAC_DEV=/dev/null
tsx_board_load() { :; }
tsx_board_probe() { return 0; }
tsx_board_model() { echo FAKE-100; }
tsx_board_stock_fw() { echo v1.000.0001; }
tsx_board_unit_id() { echo 0011223344; }
tsx_board_mac() { echo 00:10:7f:00:00:07; }
tsx_board_mac_early() { tsx_board_mac; }
tsx_board_mac_source() { echo "$TSX_MAC_SOURCE"; }
tsx_board_hostname_hint() { :; }
tsx_board_rescue_extra() { echo "board line   : fake"; }
EOB
busybox sh -n "$BOARDX" && ok "the fake board file is valid shell"

echo "== rescue screen =="
RS=$HERE/initramfs/overlay/usr/sbin/tsx-rescue-status
mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\necho "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' > "$T/sbin/ip"
printf '#!/bin/sh\necho 6.18.0\n' > "$T/sbin/uname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname"
echo "02:5a:11:22:33:44" > "$T/mac"; echo "quiet" > "$T/cmdline"
sed -e "s|/proc/cmdline|$T/cmdline|g; s|ip -4 -o addr show eth0|$T/sbin/ip|g; s|uname -r|$T/sbin/uname|; s|/sys/class/net/eth0/address|$T/mac|" \
    -e 's|> /dev/kmsg|> /dev/null|; s|> "\$TTY"|>> "$TTY"|' "$RS" > "$T/rs.sh"
render() { : > "$T/frame.raw"
	TSX_BOARD_CONF=$BOARDX TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw TSX_LIB=$T/nolib.sh TSX_VERFILE=$T/none TSX_STATUS_IN=$T/keys \
		TSX_STATUS_WAIT=1 sh "$T/rs.sh" once
	sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"; }
render
grep -qx 'model        : FAKE-100   stock fw v1.000.0001   unit 0011223344' "$T/frame" && ok "model, stock firmware and unit come from the board file" || bad "model line: $(grep '^model' "$T/frame")"
grep -qx 'board line   : fake' "$T/frame" && ok "the extra rescue line of the board shows" || bad "no extra rescue line"
echo hardware > "$T/run/tsx-eth0-mac-src"; render
grep -qx 'network      : eth0 192.0.2.10 (dhcp, MAC 02:5a:11:22:33:44, hardware)' "$T/frame" && ok "the MAC source name of the file is shown as written by rcS" || bad "network: $(grep '^network' "$T/frame")"
rm -f "$T/run/tsx-eth0-mac-src"; render
grep -qx 'network      : eth0 192.0.2.10 (dhcp, MAC 00:10:7f:00:00:07, hardware)' "$T/frame" && ok "before rcS has set the MAC: the MAC and the source name of the board" || bad "network: $(grep '^network' "$T/frame")"
grep -qiE 'uboot|u-boot|xx60|TSS-10|TSW-1060' "$T/frame" && bad "an xx60 name shows on the screen" || ok "no xx60 name on the screen"

echo "== kiosk renderer selection (fake sysfs) =="
KS=$O/usr/local/bin/kiosk-session
sed -n '/^# --- renderer selection/,/^log "display=/p' "$KS" > "$T/sel.sh"
[ "$(wc -l < "$T/sel.sh")" -gt 20 ] && ok "the renderer selection is in kiosk-session" || bad "cannot find the renderer selection"
mkdir -p "$T/drivers/lima" "$T/drivers/meson" "$T/drivers/fakedrm" "$T/drivers/simple-framebuffer"
# mkdrm DIR [CARD:DRIVER[:connector]...] RENDER:DRIVER
mkdrm() { d=$1; shift; rm -rf "$d"; mkdir -p "$d"
	for a in "$@"; do
		case "$a" in
		render:*) drv=${a#render:}; mkdir -p "$d/renderD128/device"; ln -s "$T/drivers/$drv" "$d/renderD128/device/driver";;
		*) c=${a%%:*}; drv=${a#*:}; mkdir -p "$d/$c/device"; ln -s "$T/drivers/$drv" "$d/$c/device/driver"; mkdir -p "$d/$c-CONN-1";;
		esac
	done; }
sel() { # DRMDIR BOARDFILE [KIOSK_GPU]
	env -i PATH="$PATH" TSX_BOARD_CONF="$2" TSX_DRM_SYS="$1" KIOSK_GPU="${3:-auto}" sh -c '
		KIOSK_OSK=off KIOSK_URL=u ROLE=session
		log() { echo "log: $*"; }
		. "$TSX_BOARD_CONF"
		. '"$T"'/sel.sh
		echo "WLR_RENDERER=$WLR_RENDERER WLR_DRM_DEVICES=${WLR_DRM_DEVICES:-} NOMOD=${WLR_DRM_NO_MODIFIERS:-} FMT=${CAGE_RENDER_FORMAT:-}"
		echo "comp_gl=$comp_gl browser_gl=$browser_gl"' 2>&1; }
BOARD60=$O/usr/local/lib/tsx/board.sh
mkdrm "$T/drm60" card0:lima card2:meson render:lima
out=$(sel "$T/drm60" "$BOARD60")
echo "$out" | grep -q "^log: display=/dev/dri/card2 (meson) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=0" && ok "xx60 board: meson display, lima render node, GLES in the compositor, software browser" || bad "xx60 board: $out"
echo "$out" | grep -q "NOMOD=1 FMT=argb8888" && ok "xx60 board: the display variables are exported" || bad "xx60 board variables: $out"
echo "$out" | grep -q "log: GPU is lima (GLES 2.0)" && ok "xx60 board: the GLES 2.0 note names the driver" || bad "xx60 board note: $out"
mkdrm "$T/drmx" card0:fakedrm render:fakedrm
out=$(sel "$T/drmx" "$BOARDX")
echo "$out" | grep -q "^log: display=/dev/dri/card0 (fakedrm) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=1" && ok "fake board: fakedrm display and render node, GPU browser" || bad "fake board: $out"
echo "$out" | grep -q "NOMOD= FMT=" && ok "fake board: no display variables" || bad "fake board variables: $out"
echo "$out" | grep -q "GLES 2.0" && bad "fake board: a GLES 2.0 note for a GPU that is not on the list" || ok "fake board: no GLES 2.0 note"
mkdrm "$T/drmxs" card0:simple-framebuffer
out=$(sel "$T/drmxs" "$BOARDX")
echo "$out" | grep -q "renderer=pixman" && ok "fake board: only a simple framebuffer: pixman" || bad "fake board, simple framebuffer: $out"
out=$(sel "$T/drm60" "$BOARDX")
echo "$out" | grep -q "^log: display=/dev/dri/card0 (lima) render=none" && ok "fake board on xx60 hardware: nothing of the xx60 is assumed" || bad "fake board on xx60 hardware: $out"

echo "== tsx-config apply =="
CFG=$T/panel.conf; FX=$T/fixture
mkdir -p "$FX/etc/apk" "$FX/etc/tsx" "$FX/root" "$FX/var/lib/kiosk"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.24/community\n' > "$FX/etc/apk/repositories"
BB=$T/bb; mkdir -p "$BB"; for a in sed grep cmp head cut mv chmod cat rm; do ln -sf "$(command -v busybox)" "$BB/$a"; done
cfg_set() { TSX_BOARD_CONF=$BOARDX TSX_CONF="$CFG" busybox sh "$O/usr/local/sbin/tsx-config" set "$@" >/dev/null; }
cfg_apply() { PATH="$BB:$PATH" TSX_BOARD_CONF=$BOARDX TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 \
	busybox sh "$O/usr/local/sbin/tsx-config" apply 2>&1; }
cfg_set PANEL_NAME FAKE-100-TEST; cfg_set APK_URL https://tsx-aports.example.org
cfg_set BT_MAC 02:00:00:00:00:01
out=$(cfg_apply)
eq "$(sed -n 2,3p "$FX/etc/apk/repositories" | tr '\n' ' ')" "https://tsx-aports.example.org/v3.24/common https://tsx-aports.example.org/v3.24/fake " "the repository category comes from the board file"
grep -q xx60 "$FX/etc/apk/repositories" && bad "xx60 in the repositories" || ok "no xx60 in the repositories"
grep -qx 'PROXY="on"' "$FX/run/tsx/bt.conf" && ok "an empty BT_PROXY follows TSX_BT_PROXY_DEFAULT of the board" || bad "bt.conf: $(cat "$FX/run/tsx/bt.conf")"
grep -qx 'MAC=""' "$FX/run/tsx/bt.conf" && ok "BT_MAC is left out when the board cannot set it" || bad "bt.conf: $(cat "$FX/run/tsx/bt.conf")"
case "$out" in *"BT_MAC=02:00:00:00:00:01 is set, but this board takes the Bluetooth address from the controller"*) ok "BT_MAC: a warning says why";; *) bad "BT_MAC warning: $out";; esac
head -n 1 "$CFG" | grep -q 'fake panel configuration' && ok "the panel.conf header names the family" || bad "panel.conf header: $(head -n 1 "$CFG")"
# the xx60 board keeps BT_MAC
out=$(PATH="$BB:$PATH" TSX_BOARD_CONF=$BOARD60 TSX_CONF="$CFG" TSX_RUN="$FX/run60" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$O/usr/local/sbin/tsx-config" apply 2>&1)
grep -qx 'MAC="02:00:00:00:00:01"' "$FX/run60/tsx/bt.conf" && grep -qx 'PROXY="off"' "$FX/run60/tsx/bt.conf" && ok "the xx60 board file: BT_MAC kept, proxy off" || bad "xx60 bt.conf: $(cat "$FX/run60/tsx/bt.conf")"

echo "== tsx-mqtt (dry run) =="
mkdir -p "$T/mq/run" "$T/mq/bin"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mq/mqtt.conf"
mkdir -p "$T/mq/asound/FakeCard"
# tsx-mqtt asks tsx-panelctl whether the sound card of the board is there
printf '#!/bin/sh\nexec sh "%s/usr/local/sbin/tsx-panelctl" "$@"\n' "$O" > "$T/mq/bin/tsx-panelctl"; chmod +x "$T/mq/bin/tsx-panelctl"
mq() { echo | PATH=$T/mq/bin:$PATH TSX_BOARD_CONF=$1 TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mq/mqtt.conf TSX_RUN_DIR=$T/mq/run TSX_ASOUND_DIR=$T/mq/asound sh "$O/usr/local/sbin/tsx-mqtt" 2>&1; }
out=$(mq "$BOARDX")
echo "$out" | grep -q '"mdl":"FAKE-100 (mainline Linux)"' && ok "the device model comes from the board file" || bad "mdl: $(echo "$out" | grep -m1 mdl)"
echo "$out" | grep -q 'number/tsx-kiosk/volume/config' && ok "the volume entity follows the sound card of the board (FakeCard)" || bad "no volume entity"
out=$(mq "$BOARD60")
echo "$out" | grep -q '"mdl":"xx60 (mainline Linux)"' && ok "the xx60 board file keeps the xx60 model name" || bad "mdl on xx60: $(echo "$out" | grep -m1 mdl)"
echo "$out" | grep -q 'number/tsx-kiosk/volume/config' && bad "the volume entity exists without the TSW1060 card" || ok "no volume entity without the card of the board"

echo "== tsx-autoupdate =="
BIN=$O/usr/local/sbin/tsx-autoupdate
TSX_BOARD_CONF=$BOARDX sh "$BIN" __needs_reboot "tsx-fake-kernel-lts"; eq $? 0 "the kernel package of the board needs a reboot"
TSX_BOARD_CONF=$BOARDX sh "$BIN" __needs_reboot "tsx-xx60-kernel-lts"; eq $? 1 "the kernel package of another family does not"
TSX_BOARD_CONF=$BOARD60 sh "$BIN" __needs_reboot "tsx-xx60-kernel-lts"; eq $? 0 "the xx60 board file: the xx60 kernel package needs a reboot"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS test-board-fake" || { echo "FAIL test-board-fake"; exit 1; }
