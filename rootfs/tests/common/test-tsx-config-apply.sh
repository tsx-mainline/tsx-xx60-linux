#!/bin/bash
# Host test: `tsx-config apply` of tsx-linux-common with the xx60 board files
# of this repository. The test covers what the xx60 board changes. The
# repository category is xx60. The Bluetooth proxy is off by default, and
# BT_MAC can set the Bluetooth address. The CAMERA key works. The presence keys
# do not, because the xx60 has no presence sensor. A TSW-760-NC has no
# microphone, no camera and no Bluetooth module. Its hw.conf comes from the
# real tsx-hw of the xx60. The test runs against a fixture directory that
# stands in for the root of the panel (TSX_APPLY_PREFIX, TSX_RUN,
# TSX_STATE_DIR, TSX_APPLY_ALLOW_NONROOT). It never touches the real
# /etc/shadow or /root/.ssh.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SCRIPT="$COMMON/base/usr/local/sbin/tsx-config"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED common/test-tsx-config-apply: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CFG="$W/panel.conf"
FX="$W/fixture"
mkdir -p "$FX/etc/tsx" "$FX/root" "$FX/var/lib/kiosk"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
set_() { TSX_CONF="$CFG" busybox sh "$SCRIPT" set "$@"; }
unset_() { TSX_CONF="$CFG" busybox sh "$SCRIPT" unset "$@"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply; }

echo "== apply with no panel.conf at all is a no-op (never fails) =="
env TSX_CONF="$W/nope/panel.conf" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply >/dev/null 2>&1
[ $? = 0 ] && ok "apply with no config exits 0" || bad "apply with no config failed"

echo "== a new panel.conf names the family =="
set_ PANEL_NAME TSS-10-ABCDEF >/dev/null
head -n 1 "$CFG" | grep -q '^# /data/tsx/panel.conf: xx60 panel configuration' && ok "the header of panel.conf says xx60" || bad "panel.conf header: $(head -n 1 "$CFG")"

echo "== a full panel.conf and apply =="
set_ KIOSK_URL "https://ha.example.org/lovelace/default_view" >/dev/null
set_ TZ_NAME "America/Denver" >/dev/null
set_ MQTT_HOST "192.0.2.5" >/dev/null
set_ MQTT_USER "tss10" >/dev/null
set_ MQTT_PASSWORD "hunter2" >/dev/null
set_ WAKE_WORD hey_jarvis >/dev/null
apply_ >/dev/null 2>&1
[ $? = 0 ] && ok "apply exits 0" || bad "apply failed"
[ "$(cat "$FX/run/tsx/panel-name" 2>/dev/null)" = TSS-10-ABCDEF ] && ok "panel-name written" || bad "panel-name missing/wrong"
grep -q '^NAME="TSS-10-ABCDEF"$' "$FX/run/tsx/voice.conf" 2>/dev/null && ok "voice.conf override has NAME" || bad "voice.conf override wrong (NAME)"
grep -q '^KIOSK_URL="https://ha.example.org/lovelace/default_view"$' "$FX/run/tsx/kiosk.conf" 2>/dev/null && ok "kiosk.conf override has KIOSK_URL" || bad "kiosk.conf override wrong"
grep -q '^BROKER="192.0.2.5"$' "$FX/run/tsx/mqtt.conf" 2>/dev/null && ok "mqtt.conf override has BROKER" || bad "mqtt.conf override wrong"

echo "== tsx-esphome, tsx-voice and tsx-bt follow their inputs =="
mkdir -p "$W/bin"
printf '#!/bin/sh\necho "rc-service $*" >> "%s/rc.log"\nexit 0\n' "$W" > "$W/bin/rc-service"; chmod +x "$W/bin/rc-service"
rm -f "$FX/run/tsx/.esphome-sig" "$W/rc.log"
applyp() { PATH="$W/bin:$PATH" apply_ >/dev/null 2>&1; }
restarts() { grep -c 'tsx-esphome restart' "$W/rc.log" 2>/dev/null || true; }
vrestarts() { grep -c 'tsx-voice restart' "$W/rc.log" 2>/dev/null || true; }
btl() { grep -c "tsx-bt $1" "$W/rc.log" 2>/dev/null || true; }
applyp; [ "$(restarts)" = 1 ] && ok "first apply (no signature yet) restarts tsx-esphome" || bad "first apply: $(restarts) restarts"
applyp; [ "$(restarts)" = 1 ] && ok "apply with nothing changed does not restart it" || bad "unchanged apply restarted it ($(restarts))"

echo "== APK_URL: this project's two repositories first in /etc/apk/repositories =="
# busybox applets for what apply runs, as on the panel (musl regex, no GNU extensions)
BB="$W/bb"; mkdir -p "$BB"
for a in sed grep cmp head cut mv chmod cat rm; do ln -sf "$(command -v busybox)" "$BB/$a"; done
applyb() { PATH="$BB:$PATH" apply_ >/dev/null 2>&1; }
REPOS="$FX/etc/apk/repositories"; mkdir -p "$FX/etc/apk" "$FX/etc/tsx"
ALP='https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community'
printf '%s\n' "$ALP" > "$REPOS"
applyb
[ "$(sed -n 2,3p "$REPOS")" = "https://tsx-aports.unexceptional.net/v3.24/common
https://tsx-aports.unexceptional.net/v3.24/xx60" ] && ok "no APK_URL, no build default: the public URL with common and xx60, listed first" || bad "default block wrong: $(cat "$REPOS")"
[ "$(tail -n 2 "$REPOS")" = "$ALP" ] && ok "Alpine lines kept, after ours" || bad "Alpine lines changed"
echo https://mirror.example.org/tsx/ > "$FX/etc/tsx/apk-url.default"
applyb
grep -qx 'https://mirror.example.org/tsx/v3.24/xx60' "$REPOS" && ok "build default (/etc/tsx/apk-url.default) used, trailing / dropped" || bad "build default not used: $(cat "$REPOS")"
set_ APK_URL http://192.0.2.7:8080 >/dev/null; applyb
[ "$(grep -c '/v3.24/common$' "$REPOS")/$(grep -c '/v3.24/xx60$' "$REPOS")/$(grep -c '^# tsx-aports ' "$REPOS")" = 1/1/1 ] && ok "one block, one common + one xx60 line" || bad "duplicate lines: $(cat "$REPOS")"
[ "$(sed -n 3p "$REPOS")" = http://192.0.2.7:8080/v3.24/xx60 ] && ok "APK_URL (a LAN mirror) replaces the block" || bad "APK_URL not applied: $(cat "$REPOS")"
set_ APK_URL off >/dev/null; applyb
grep -qE '/(common|xx60)$' "$REPOS" && bad "APK_URL=off still lists our repositories" || ok "APK_URL=off drops our repositories"
unset_ APK_URL >/dev/null; applyb

echo "== BT_PROXY / BT_ACTIVE / BT_MAC: /run/tsx/bt.conf, tsx-bt follows the key =="
applyp
grep -qx 'PROXY="off"' "$FX/run/tsx/bt.conf" 2>/dev/null && grep -qx 'MAC=""' "$FX/run/tsx/bt.conf" \
	&& grep -qx 'ACTIVE="off"' "$FX/run/tsx/bt.conf" \
	&& ok "bt.conf: PROXY off (the xx60 board default), ACTIVE off and an empty MAC by default" || bad "bt.conf default: $(cat "$FX/run/tsx/bt.conf" 2>/dev/null)"
[ "$(stat -c '%a' "$FX/run/tsx/bt.conf" 2>/dev/null)" = 644 ] && ok "bt.conf is world-readable (the voice satellite reads it)" || bad "bt.conf mode $(stat -c '%a' "$FX/run/tsx/bt.conf" 2>/dev/null)"
r0=$(restarts); v0=$(vrestarts); s0=$(btl restart)
set_ BT_PROXY on >/dev/null; applyp
grep -qx 'PROXY="on"' "$FX/run/tsx/bt.conf" && ok "BT_PROXY=on reaches bt.conf" || bad "bt.conf after BT_PROXY=on: $(cat "$FX/run/tsx/bt.conf")"
[ "$(btl restart)" = $((s0 + 1)) ] && ok "BT_PROXY=on restarts tsx-bt" || bad "BT_PROXY=on: $(btl restart) tsx-bt restarts (was $s0)"
[ "$(restarts)/$(vrestarts)" = "$((r0 + 1))/$((v0 + 1))" ] && ok "BT_PROXY=on restarts tsx-esphome and tsx-voice (new feature flags)" || bad "BT_PROXY=on: $(restarts)/$(vrestarts) restarts (was $r0/$v0)"
awk '/tsx-bt restart/{b=NR} /tsx-esphome restart/{e=NR} END{exit !(b && e && b < e)}' "$W/rc.log" \
	&& ok "tsx-bt restarts before tsx-esphome (bt.mac is ready)" || bad "restart order: $(tr '\n' ';' < "$W/rc.log")"
set_ BT_MAC 02:11:22:33:44:55 >/dev/null 2>"$W/btmac.err"; applyp
[ ! -s "$W/btmac.err" ] && ok "set BT_MAC gives no warning: the xx60 can set the Bluetooth address" || bad "set BT_MAC warns: $(cat "$W/btmac.err")"
grep -qx 'MAC="02:11:22:33:44:55"' "$FX/run/tsx/bt.conf" && ok "BT_MAC reaches bt.conf" || bad "bt.conf after BT_MAC: $(cat "$FX/run/tsx/bt.conf")"
[ "$(btl restart)" = $((s0 + 2)) ] && ok "a BT_MAC change restarts tsx-bt" || bad "BT_MAC change: $(btl restart) tsx-bt restarts"
applyp; [ "$(btl restart)" = $((s0 + 2)) ] && ok "an unchanged apply leaves tsx-bt alone" || bad "unchanged apply touched tsx-bt"
r0=$(restarts); v0=$(vrestarts); s0=$(btl restart)
set_ BT_ACTIVE on >/dev/null; applyp
grep -qx 'ACTIVE="on"' "$FX/run/tsx/bt.conf" && ok "BT_ACTIVE=on reaches bt.conf" || bad "bt.conf after BT_ACTIVE=on: $(cat "$FX/run/tsx/bt.conf")"
[ "$(restarts)/$(vrestarts)/$(btl restart)" = "$((r0 + 1))/$((v0 + 1))/$s0" ] \
	&& ok "BT_ACTIVE=on restarts tsx-esphome and tsx-voice (new feature flags), not tsx-bt" \
	|| bad "BT_ACTIVE=on: $(restarts)/$(vrestarts)/$(btl restart) restarts (was $r0/$v0/$s0)"
set_ BT_PROXY off >/dev/null; applyp
[ "$(btl stop)" -ge 1 ] && ok "BT_PROXY=off stops tsx-bt" || bad "BT_PROXY=off did not stop tsx-bt"
set_ BT_PROXY "" >/dev/null; applyp
grep -qx 'PROXY="off"' "$FX/run/tsx/bt.conf" && ok "an empty BT_PROXY is the board default: off on the xx60" || bad "empty BT_PROXY: $(cat "$FX/run/tsx/bt.conf")"
unset_ BT_PROXY >/dev/null; unset_ BT_ACTIVE >/dev/null; unset_ BT_MAC >/dev/null; applyp

echo "== CAMERA: /run/tsx/camera.conf, the ESPHome front ends follow the key =="
applyp
grep -qx 'CAMERA="off"' "$FX/run/tsx/camera.conf" 2>/dev/null && ok "camera.conf: CAMERA off by default" || bad "camera.conf default: $(cat "$FX/run/tsx/camera.conf" 2>/dev/null)"
[ "$(stat -c '%a' "$FX/run/tsx/camera.conf" 2>/dev/null)" = 644 ] && ok "camera.conf is world-readable (the voice satellite reads it)" || bad "camera.conf mode $(stat -c '%a' "$FX/run/tsx/camera.conf" 2>/dev/null)"
r0=$(restarts); v0=$(vrestarts)
set_ CAMERA on >/dev/null; applyp
grep -qx 'CAMERA="live"' "$FX/run/tsx/camera.conf" && ok "CAMERA=on (the old name of live) reaches camera.conf as live" || bad "camera.conf after CAMERA=on: $(cat "$FX/run/tsx/camera.conf")"
[ "$(restarts)/$(vrestarts)" = "$((r0 + 1))/$((v0 + 1))" ] && ok "CAMERA=on restarts tsx-esphome and tsx-voice (new entity list)" || bad "CAMERA=on: $(restarts)/$(vrestarts) restarts (was $r0/$v0)"
applyp; [ "$(restarts)/$(vrestarts)" = "$((r0 + 1))/$((v0 + 1))" ] && ok "an unchanged CAMERA restarts nothing" || bad "unchanged CAMERA: $(restarts)/$(vrestarts) restarts"
set_ CAMERA off >/dev/null; applyp
grep -qx 'CAMERA="off"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 2))/$((v0 + 2))" ] \
	&& ok "CAMERA=off: camera.conf off, both front ends restart" || bad "CAMERA=off: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
set_ CAMERA snapshot >/dev/null; applyp
grep -qx 'CAMERA="snapshot"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 3))/$((v0 + 3))" ] \
	&& ok "CAMERA=snapshot reaches camera.conf, both front ends restart" || bad "CAMERA=snapshot: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
set_ CAMERA live >/dev/null; applyp
grep -qx 'CAMERA="live"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 4))/$((v0 + 4))" ] \
	&& ok "CAMERA=live reaches camera.conf, both front ends restart" || bad "CAMERA=live: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
printf 'CAMERA="bogus"\n' >> "$CFG"; applyp
grep -qx 'CAMERA="off"' "$FX/run/tsx/camera.conf" && ok "an unknown CAMERA value in panel.conf is off" || bad "CAMERA=bogus: $(cat "$FX/run/tsx/camera.conf")"
set_ CAMERA off >/dev/null; applyp

echo "== the parts of the xx60 from the real tsx-hw =="
# tsx-hw of this repository writes hw.conf from the kernel command line. The
# TSW-760-NC (government=1) has no microphone, no camera and no Bluetooth
# module. Every xx60 lacks the presence sensor.
CFG3="$W/panel-hw.conf"; FX3="$W/fx-hw"; mkdir -p "$FX3/run/tsx" "$FX3/etc" "$W/proc"
printf '#!/bin/sh\necho "tsx-audio $*" >> "%s/audio.log"\nexit 0\n' "$W" > "$W/bin/tsx-audio"; chmod +x "$W/bin/tsx-audio"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"; chmod +x "$W/bin/logger"
hw_detect() {  # hw_detect CMDLINE: write hw.conf with the real tsx-hw
	echo "$1" > "$W/proc/cmdline"
	env PATH="$W/bin:$PATH" TSX_RUN_DIR="$FX3/run/tsx" TSX_PROC="$W/proc" busybox sh "$XX60_HW" detect >/dev/null
}
cfg3() { env PATH="$W/bin:$PATH" TSX_CONF="$CFG3" TSX_RUN="$FX3/run" TSX_STATE_DIR="$FX3/var/lib/tsx" TSX_APPLY_PREFIX="$FX3" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" "$@"; }
hw_detect "console=tty0 androidboot.government=1"
# The texts of tsx-config name the REASON line of hw.conf, as the tsx-hw of the xx60 writes it.
REASON='government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module'
grep -qxF "REASON=$REASON" "$FX3/run/tsx/hw.conf" \
	&& ok "tsx-hw of the xx60: hw.conf names the missing parts" || bad "hw.conf: $(cat "$FX3/run/tsx/hw.conf")"
for k in VOICE BT_PROXY BT_ACTIVE CAMERA; do
	out=$(cfg3 set "$k" on 2>&1); rc=$?
	[ $rc = 0 ] && [ "$(cfg3 get "$k")" = on ] && case "$out" in *"WARNING: $k=on is saved, but this panel has no "*"($REASON). apply leaves it out"*) true;; *) false;; esac \
		&& ok "set $k on: saved (a panel.conf from another panel loads), with a warning" || bad "set $k on: exit $rc, '$out'"
done
out=$(cfg3 set CAMERA snapshot 2>&1)
case "$out" in *"WARNING: CAMERA=snapshot is saved, but this panel has no camera ($REASON)"*) ok "set CAMERA snapshot: saved, with a warning";; *) bad "set CAMERA snapshot (government=1): '$out'";; esac
out=$(cfg3 set CAMERA off 2>&1); [ -z "$out" ] && ok "set CAMERA off: no warning" || bad "set CAMERA off warns: $out"
cfg3 set CAMERA on >/dev/null 2>&1
out=$(cfg3 set VOICE off 2>&1); [ -z "$out" ] && ok "set VOICE off: no warning" || bad "set VOICE off warns: $out"
cfg3 set VOICE on >/dev/null 2>&1
out=$(cfg3 show 2>&1 >/dev/null)
case "$out" in *"# WARNING: VOICE=on is set, but this panel has no microphone ($REASON)"*"# WARNING: BT_PROXY=on is set"*"# WARNING: BT_ACTIVE=on is set"*) ok "show: a warning for each of the three keys";; *) bad "show warnings: $out";; esac
rm -f "$W/audio.log" "$W/rc.log"
out=$(cfg3 apply 2>&1); rc=$?
[ $rc = 0 ] && grep -qx 'PROXY="off"' "$FX3/run/tsx/bt.conf" && grep -qx 'ACTIVE="off"' "$FX3/run/tsx/bt.conf" \
	&& ok "apply: bt.conf says PROXY and ACTIVE off" || bad "apply (government=1): exit $rc, bt.conf $(cat "$FX3/run/tsx/bt.conf" 2>/dev/null)"
grep -qx 'tsx-audio disable voice' "$W/audio.log" 2>/dev/null && ! grep -q 'enable voice' "$W/audio.log" \
	&& ok "apply: VOICE=on is treated as off (tsx-audio disable voice)" || bad "apply voice: $(cat "$W/audio.log" 2>/dev/null)"
case "$out" in *"WARNING: VOICE=on is set, but this panel has no microphone"*"WARNING: BT_PROXY=on is set"*) ok "apply: the log says why";; *) bad "apply log: $out";; esac
grep -q '|off|' "$FX3/run/tsx/.esphome-sig" && ok "apply: tsx-esphome sees VOICE off (it serves the entities)" || bad ".esphome-sig: $(cat "$FX3/run/tsx/.esphome-sig")"
grep -qx 'CAMERA="off"' "$FX3/run/tsx/camera.conf" && case "$out" in *"WARNING: CAMERA=on is set, but this panel has no camera"*) true;; *) false;; esac \
	&& ok "apply: CAMERA=on is treated as off, with a warning" || bad "apply camera: $(cat "$FX3/run/tsx/camera.conf" 2>/dev/null)"
rm -f "$W/rc.log"; cfg3 set BT_MAC 02:11:22:33:44:55 >/dev/null 2>&1; cfg3 apply >/dev/null 2>&1
grep -q 'tsx-bt restart' "$W/rc.log" 2>/dev/null && bad "a BT_MAC change restarted tsx-bt on a panel without the module" || ok "a BT_MAC change does not restart tsx-bt (the proxy stays off)"
cfg3 unset BT_MAC >/dev/null 2>&1

hw_detect "console=tty0 androidboot.government=0"
rm -f "$W/audio.log"
out=$(cfg3 set VOICE on 2>&1); [ -z "$out" ] && ok "government=0: set VOICE on gives no warning" || bad "government=0 set warns: $out"
out=$(cfg3 set CAMERA live 2>&1); [ -z "$out" ] && ok "government=0: set CAMERA live gives no warning" || bad "government=0 set CAMERA warns: $out"
cfg3 apply >/dev/null 2>&1
grep -qx 'PROXY="on"' "$FX3/run/tsx/bt.conf" && grep -qx 'ACTIVE="on"' "$FX3/run/tsx/bt.conf" && grep -qx 'tsx-audio enable voice' "$W/audio.log" \
	&& grep -qx 'CAMERA="live"' "$FX3/run/tsx/camera.conf" \
	&& ok "government=0: BT_PROXY, BT_ACTIVE, VOICE and CAMERA work" || bad "government=0: bt.conf $(cat "$FX3/run/tsx/bt.conf"), camera $(cat "$FX3/run/tsx/camera.conf"), audio $(cat "$W/audio.log" 2>/dev/null)"

echo "== the xx60 has no presence sensor =="
grep -qx 'PRESENCE=no' "$FX3/run/tsx/hw.conf" && ok "tsx-hw of the xx60 writes PRESENCE=no" || bad "hw.conf: $(cat "$FX3/run/tsx/hw.conf")"
hw_detect "console=tty0 androidboot.government=1"
grep -qx 'PRESENCE=no' "$FX3/run/tsx/hw.conf" && ok "tsx-hw of the xx60 writes PRESENCE=no also for government=1" || bad "hw.conf (government=1): $(cat "$FX3/run/tsx/hw.conf")"
hw_detect "console=tty0 androidboot.government=0"
rm -f "$FX3/run/tsx/sensors.conf"
out=$(cfg3 set PRESENCE_WAKE on 2>&1); rc=$?
[ $rc = 0 ] && [ "$(cfg3 get PRESENCE_WAKE)" = on ] && case "$out" in *"WARNING: PRESENCE_WAKE=on is saved, but this panel has no "*"apply leaves it out"*) true;; *) false;; esac \
	&& ok "set PRESENCE_WAKE on: saved, with a warning" || bad "set PRESENCE_WAKE on: exit $rc, '$out'"
cfg3 apply >/dev/null 2>&1
{ [ ! -e "$FX3/run/tsx/sensors.conf" ] || ! grep -q PRESENCE "$FX3/run/tsx/sensors.conf"; } && ok "apply: no presence key reaches sensors.conf" || bad "sensors.conf: $(cat "$FX3/run/tsx/sensors.conf")"
cfg3 unset PRESENCE_WAKE >/dev/null 2>&1

echo "== no hw.conf: a panel with all parts =="
rm -f "$FX3/run/tsx/hw.conf" "$W/audio.log"
out=$(cfg3 set BT_PROXY on 2>&1); [ -z "$out" ] && ok "no hw.conf: set BT_PROXY on gives no warning" || bad "no hw.conf set warns: $out"
cfg3 apply >/dev/null 2>&1
grep -qx 'PROXY="on"' "$FX3/run/tsx/bt.conf" && grep -qx 'tsx-audio enable voice' "$W/audio.log" \
	&& ok "no hw.conf: the keys work" || bad "no hw.conf: bt.conf $(cat "$FX3/run/tsx/bt.conf")"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS common/test-tsx-config-apply || echo FAIL common/test-tsx-config-apply
exit $F
