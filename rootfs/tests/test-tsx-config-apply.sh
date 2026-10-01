#!/bin/bash
# Host test: `tsx-config apply` (docs/rootfs.md "Panel configuration")
# against a fixture directory standing in for the panel's root, via
# TSX_APPLY_PREFIX/TSX_RUN/TSX_STATE_DIR/TSX_APPLY_ALLOW_NONROOT. No docker,
# no real /etc/shadow or /root/.ssh is ever touched.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/overlay/usr/local/sbin/tsx-config"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-config-apply: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CFG="$W/panel.conf"
FX="$W/fixture"
mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
set_() { TSX_CONF="$CFG" busybox sh "$SCRIPT" set "$@"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply; }

echo "== apply with no panel.conf at all is a no-op (never fails) =="
env TSX_CONF="$W/nope/panel.conf" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply >/dev/null 2>&1
[ $? = 0 ] && ok "apply with no config exits 0" || bad "apply with no config failed"
[ ! -e "$FX/run/tsx/kiosk.conf" ] && ok "no /run/tsx/kiosk.conf written" || bad "kiosk.conf written with nothing to apply"

echo "== apply requires root unless TSX_APPLY_ALLOW_NONROOT=1 =="
set_ PANEL_NAME TSS-10-ABCDEF >/dev/null
env TSX_CONF="$CFG" TSX_RUN="$FX/run" busybox sh "$SCRIPT" apply >/dev/null 2>&1 && bad "apply ran without root and without the test override" || ok "apply refuses non-root without the override"

echo "== build a full panel.conf and apply it =="
set_ KIOSK_URL "https://ha.example.org/lovelace/default_view" >/dev/null
set_ TZ_NAME "America/Denver" >/dev/null
set_ MQTT_HOST "192.0.2.5" >/dev/null
set_ MQTT_PORT "1883" >/dev/null
set_ MQTT_USER "tss10" >/dev/null
set_ MQTT_PASSWORD "hunter2" >/dev/null
set_ HA_LOGIN_METHOD token >/dev/null
set_ HA_TOKEN "abcdefghijklmnopqrstuvwxyz0123456789ABCDEF" >/dev/null
set_ ROOT_PASSWORD_HASH '$6$abcdefgh$somehashvalueherelongenough' >/dev/null
set_ SSH_AUTHORIZED_KEY "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host" >/dev/null
set_ WAKE_WORD hey_jarvis >/dev/null
apply_ >/dev/null 2>&1
[ $? = 0 ] && ok "apply exits 0" || bad "apply failed"

[ "$(cat "$FX/run/tsx/panel-name" 2>/dev/null)" = TSS-10-ABCDEF ] && ok "panel-name written" || bad "panel-name missing/wrong"
grep -q '^SENDSPIN_NAME="TSS-10-ABCDEF"$' "$FX/run/tsx/sendspin.conf" 2>/dev/null && ok "sendspin.conf override has SENDSPIN_NAME" || bad "sendspin.conf override wrong"
grep -q '^NAME="TSS-10-ABCDEF"$' "$FX/run/tsx/voice.conf" 2>/dev/null && ok "voice.conf override has NAME" || bad "voice.conf override wrong (NAME)"
grep -q '^WAKE_WORD="hey_jarvis"$' "$FX/run/tsx/voice.conf" 2>/dev/null && ok "voice.conf override has WAKE_WORD" || bad "voice.conf override wrong (WAKE_WORD)"
grep -q '^KIOSK_URL="https://ha.example.org/lovelace/default_view"$' "$FX/run/tsx/kiosk.conf" 2>/dev/null && ok "kiosk.conf override has KIOSK_URL" || bad "kiosk.conf override wrong"
grep -q '^TZ_NAME="America/Denver"$' "$FX/run/tsx/kiosk.conf" 2>/dev/null && ok "kiosk.conf override has TZ_NAME" || bad "kiosk.conf override missing TZ_NAME"
[ "$(stat -c '%a' "$FX/run/tsx/kiosk.conf" 2>/dev/null)" = 644 ] && ok "kiosk.conf override is mode 644 (kiosk-session reads it as the kiosk user)" || bad "kiosk.conf override not readable by the kiosk user"
grep -q '^BROKER="192.0.2.5"$' "$FX/run/tsx/mqtt.conf" 2>/dev/null && ok "mqtt.conf override has BROKER" || bad "mqtt.conf override wrong"
grep -q '^TRANSPORT="esphome"$' "$FX/run/tsx/esphome.conf" 2>/dev/null && ok "esphome.conf override defaults to TRANSPORT=esphome" || bad "esphome.conf override missing/wrong default"
[ "$(stat -c '%a' "$FX/run/tsx/esphome.conf" 2>/dev/null)" = 644 ] && ok "esphome.conf override is world-readable (no secret)" || bad "esphome.conf override should be 644"
[ "$(stat -c '%a' "$FX/run/tsx/mqtt.conf" 2>/dev/null)" = 600 ] && ok "mqtt.conf override is mode 600 (carries MQTT_PASSWORD)" || bad "mqtt.conf override not mode 600"

echo "== the generated overrides are valid, safely sourceable shell =="
busybox sh -c '. "'"$FX"'/run/tsx/mqtt.conf"; [ "$PASSWORD" = "hunter2" ]' && ok "mqtt.conf sources back to the original password" || bad "mqtt.conf did not source back correctly"

echo "== HA token staged for the kiosk, root shadow hash updated, ssh key added =="
[ "$(cat "$FX/var/lib/kiosk/pending-token" 2>/dev/null)" = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEF" ] && ok "pending-token staged" || bad "pending-token missing/wrong"
grep -q '^root:\$6\$abcdefgh\$somehashvalueherelongenough:' "$FX/etc/shadow" && ok "root shadow hash updated" || bad "root shadow hash not updated"
grep -qxF "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host" "$FX/root/.ssh/authorized_keys" && ok "ssh key present" || bad "ssh key missing"
[ "$(stat -c '%a' "$FX/root/.ssh/authorized_keys" 2>/dev/null)" = 600 ] && ok "authorized_keys mode 600" || bad "authorized_keys mode wrong"

echo "== re-apply is idempotent: no duplicate key line, shadow untouched again =="
SHADOW_BEFORE=$(cat "$FX/etc/shadow")
apply_ >/dev/null 2>&1
[ "$(cat "$FX/etc/shadow")" = "$SHADOW_BEFORE" ] && ok "shadow unchanged on re-apply" || bad "shadow changed on a no-op re-apply"
[ "$(wc -l < "$FX/root/.ssh/authorized_keys")" = 1 ] && ok "authorized_keys still has exactly one line" || bad "authorized_keys grew a duplicate"

echo "== a manually-added extra ssh key survives apply (panel.conf never removes a key) =="
echo "ssh-ed25519 AAAAOTHERKEY someone@elsewhere" >> "$FX/root/.ssh/authorized_keys"
apply_ >/dev/null 2>&1
[ "$(wc -l < "$FX/root/.ssh/authorized_keys")" = 2 ] && ok "both keys present after another apply" || bad "an existing key was lost"

echo "== tsx-esphome is restarted only when its inputs change =="
mkdir -p "$W/bin"
printf '#!/bin/sh\necho "rc-service $*" >> "%s/rc.log"\nexit 0\n' "$W" > "$W/bin/rc-service"; chmod +x "$W/bin/rc-service"
rm -f "$FX/run/tsx/.esphome-sig" "$W/rc.log"
applyp() { PATH="$W/bin:$PATH" apply_ >/dev/null 2>&1; }
restarts() { grep -c 'tsx-esphome restart' "$W/rc.log" 2>/dev/null || true; }
applyp; [ "$(restarts)" = 1 ] && ok "first apply (no signature yet) restarts tsx-esphome" || bad "first apply: $(restarts) restarts"
applyp; [ "$(restarts)" = 1 ] && ok "apply with nothing changed does not restart it" || bad "unchanged apply restarted it ($(restarts))"
set_ KIOSK_URL "https://ha.example.org/other" >/dev/null; applyp
[ "$(restarts)" = 1 ] && ok "a KIOSK_URL change does not restart it" || bad "KIOSK_URL change restarted it ($(restarts))"
set_ HA_ALLOW_FROM 192.0.2.9 >/dev/null; applyp
[ "$(restarts)" = 2 ] && ok "an HA_ALLOW_FROM change restarts it" || bad "HA_ALLOW_FROM change: $(restarts) restarts"
set_ PANEL_NAME TSS-10-OTHER >/dev/null; applyp
[ "$(restarts)" = 3 ] && ok "a PANEL_NAME change restarts it" || bad "PANEL_NAME change: $(restarts) restarts"

vrestarts() { grep -c 'tsx-voice restart' "$W/rc.log" 2>/dev/null || true; }
[ "$(vrestarts)" = 1 ] && ok "the PANEL_NAME change restarts a running tsx-voice too (device name)" || bad "PANEL_NAME change: $(vrestarts) tsx-voice restarts"

echo "== HA_API_KEY: key file for both ESPHome servers, restarts on change =="
KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
set_ HA_API_KEY "$KEY" >/dev/null; applyp
[ "$(cat "$FX/run/tsx/esphome.key" 2>/dev/null)" = "$KEY" ] && ok "esphome.key holds the key" || bad "esphome.key missing/wrong"
[ "$(stat -c '%a' "$FX/run/tsx/esphome.key" 2>/dev/null)" = 640 ] && ok "esphome.key is mode 640 (group kiosk: the voice satellite)" || bad "esphome.key mode $(stat -c '%a' "$FX/run/tsx/esphome.key" 2>/dev/null), want 640"
grep -qF -- "$KEY" "$FX/run/tsx/esphome.conf" "$FX/run/tsx/.esphome-sig" "$FX/run/tsx/.voice-sig" 2>/dev/null && bad "the key leaked into a world-readable file" || ok "the key is in no world-readable file"
[ "$(restarts)" = 4 ] && ok "a new HA_API_KEY restarts tsx-esphome" || bad "HA_API_KEY: $(restarts) tsx-esphome restarts"
[ "$(vrestarts)" = 2 ] && ok "a new HA_API_KEY restarts tsx-voice" || bad "HA_API_KEY: $(vrestarts) tsx-voice restarts"
breloads() { grep -c 'tsx-buttons reload' "$W/rc.log" 2>/dev/null || true; }
b0=$(breloads)
set_ KIOSK_URL "https://ha.example.org/third" >/dev/null; applyp
[ "$(restarts)/$(vrestarts)" = 4/2 ] && ok "a KIOSK_URL change restarts neither" || bad "KIOSK_URL change: $(restarts)/$(vrestarts) restarts"
[ "$(breloads)" = $((b0 + 1)) ] && ok "a KIOSK_URL change reloads tsx-buttons (front-key home URL)" || bad "KIOSK_URL change: $(breloads) tsx-buttons reloads (was $b0)"
applyp; [ "$(breloads)" = $((b0 + 1)) ] && ok "an unchanged apply does not reload tsx-buttons" || bad "unchanged apply reloaded tsx-buttons ($(breloads))"
OUT=$(TSX_CONF="$CFG" busybox sh "$SCRIPT" show 2>&1)
case "$OUT" in *"$KEY"*) bad "show prints HA_API_KEY";; *"HA_API_KEY=********"*) ok "show masks HA_API_KEY";; *) bad "show does not list HA_API_KEY";; esac
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset HA_API_KEY >/dev/null; applyp
[ ! -e "$FX/run/tsx/esphome.key" ] && ok "unsetting HA_API_KEY removes esphome.key (plaintext again)" || bad "esphome.key left behind"
[ "$(restarts)/$(vrestarts)" = 5/3 ] && ok "removing the key restarts both" || bad "key removal: $(restarts)/$(vrestarts) restarts"

echo "== apply warns while the API is open (no HA_API_KEY, no HA_ALLOW_FROM) =="
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset HA_ALLOW_FROM >/dev/null 2>&1 || true
OUT=$(apply_ 2>&1)   # not piped into grep -q: pipefail would see the SIGPIPE
case "$OUT" in *"WARNING: the ESPHome API (port 6053) is open"*) ok "apply prints the open-API warning";; *) bad "apply does not warn about an open API";; esac
set_ HA_ALLOW_FROM 192.0.2.9 >/dev/null
OUT=$(apply_ 2>&1)
case "$OUT" in *"WARNING"*) bad "apply warns with HA_ALLOW_FROM set";; *) ok "no warning once HA_ALLOW_FROM is set";; esac
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset HA_ALLOW_FROM >/dev/null 2>&1 || true
set_ HA_API_KEY "$KEY" >/dev/null
OUT=$(apply_ 2>&1)
case "$OUT" in *"WARNING"*) bad "apply warns with HA_API_KEY set";; *) ok "no warning with HA_API_KEY set (HA_ALLOW_FROM optional)";; esac

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
https://tsx-aports.unexceptional.net/v3.24/xx60" ] && ok "no APK_URL, no build default: the public URL, listed first" || bad "default block wrong: $(cat "$REPOS")"
[ "$(tail -n 2 "$REPOS")" = "$ALP" ] && ok "Alpine lines kept, after ours" || bad "Alpine lines changed"
echo https://mirror.example.org/tsx/ > "$FX/etc/tsx/apk-url.default"
applyb
grep -qx 'https://mirror.example.org/tsx/v3.24/xx60' "$REPOS" && ok "build default (/etc/tsx/apk-url.default) used, trailing / dropped" || bad "build default not used: $(cat "$REPOS")"
set_ APK_URL http://192.0.2.7:8080 >/dev/null; applyb
[ "$(grep -c '/v3.24/common$' "$REPOS")/$(grep -c '/v3.24/xx60$' "$REPOS")/$(grep -c '^# tsx-aports ' "$REPOS")" = 1/1/1 ] && ok "one block, one common + one xx60 line" || bad "duplicate lines: $(cat "$REPOS")"
[ "$(sed -n 2p "$REPOS")" = http://192.0.2.7:8080/v3.24/common ] && ok "APK_URL (a LAN mirror) replaces the block" || bad "APK_URL not applied: $(cat "$REPOS")"
echo /media/usb/alpine/v3.24/testing >> "$REPOS"
cp "$REPOS" "$W/repos.before"; applyb
cmp -s "$REPOS" "$W/repos.before" && ok "re-apply leaves the file (and a user's own line) alone" || bad "re-apply changed the file"
set_ APK_URL off >/dev/null; applyb
grep -qE '/(common|xx60)$' "$REPOS" && bad "APK_URL=off still lists our repositories" || ok "APK_URL=off drops our repositories"
[ "$(grep -c alpinelinux.org "$REPOS")" = 2 ] && ok "APK_URL=off keeps Alpine" || bad "APK_URL=off lost Alpine lines"
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset APK_URL >/dev/null; applyb
[ "$(sed -n 2p "$REPOS")" = https://mirror.example.org/tsx/v3.24/common ] && ok "unset APK_URL: back to the build default" || bad "unset: $(cat "$REPOS")"
for v in ftp://x.example.org 'https://a b' 'http://' relative/path; do
	set_ APK_URL "$v" >/dev/null 2>&1 && bad "APK_URL '$v' accepted" || ok "APK_URL '$v' rejected"
done
set_ APK_URL /media/usb/tsx-aports >/dev/null 2>&1 && ok "APK_URL local directory accepted" || bad "APK_URL local directory rejected"

echo "== BLANK_TIMEOUT: /run/tsx/blank-timeout for tsx-idled =="
[ ! -e "$FX/run/tsx/blank-timeout" ] && ok "unset: no blank-timeout file" || bad "blank-timeout written while unset"
set_ BLANK_TIMEOUT 600 >/dev/null; applyb
[ "$(cat "$FX/run/tsx/blank-timeout" 2>/dev/null)" = 600 ] && ok "BLANK_TIMEOUT 600 -> blank-timeout 600" || bad "blank-timeout: '$(cat "$FX/run/tsx/blank-timeout" 2>/dev/null)'"
[ "$(stat -c %a "$FX/run/tsx/blank-timeout")" = 644 ] && ok "blank-timeout is world-readable (644)" || bad "blank-timeout mode $(stat -c %a "$FX/run/tsx/blank-timeout")"
touch -d '2000-01-01' "$FX/run/tsx/blank-timeout"; applyb
[ "$(stat -c %Y "$FX/run/tsx/blank-timeout")" = "$(date -d 2000-01-01 +%s)" ] && ok "unchanged value: file not rewritten (no tsx-idled wakeup)" || bad "unchanged value rewrote the file"
set_ BLANK_TIMEOUT 0 >/dev/null; applyb
[ "$(cat "$FX/run/tsx/blank-timeout" 2>/dev/null)" = 0 ] && ok "BLANK_TIMEOUT 0 (never) written" || bad "BLANK_TIMEOUT 0 not written"
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset BLANK_TIMEOUT >/dev/null; applyb
[ ! -e "$FX/run/tsx/blank-timeout" ] && ok "unset again: file removed (kiosk.conf's BLANK_TIMEOUT)" || bad "blank-timeout left after unset"
for v in -1 86401 10s 1e3 ''; do
	set_ BLANK_TIMEOUT "$v" >/dev/null 2>&1 && bad "BLANK_TIMEOUT '$v' accepted" || ok "BLANK_TIMEOUT '$v' rejected"
done
set_ BLANK_TIMEOUT 86400 >/dev/null 2>&1 && ok "BLANK_TIMEOUT 86400 (a day) accepted" || bad "BLANK_TIMEOUT 86400 rejected"

echo "== BOOT_VERBOSE: /etc/tsx/boot-verbose on the root fs for the initramfs =="
[ ! -e "$FX/etc/tsx/boot-verbose" ] && ok "unset: no boot-verbose flag" || bad "boot-verbose flag while unset"
set_ BOOT_VERBOSE 1 >/dev/null; applyb
[ -e "$FX/etc/tsx/boot-verbose" ] && ok "BOOT_VERBOSE=1 -> flag file" || bad "BOOT_VERBOSE=1: no flag file"
set_ BOOT_VERBOSE 0 >/dev/null; applyb
[ ! -e "$FX/etc/tsx/boot-verbose" ] && ok "BOOT_VERBOSE=0 -> flag removed" || bad "BOOT_VERBOSE=0 left the flag"
set_ BOOT_VERBOSE 1 >/dev/null; applyb
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset BOOT_VERBOSE >/dev/null; applyb
[ ! -e "$FX/etc/tsx/boot-verbose" ] && ok "unset again: flag removed" || bad "flag left after unset"
for v in 2 yes on ''; do
	set_ BOOT_VERBOSE "$v" >/dev/null 2>&1 && bad "BOOT_VERBOSE '$v' accepted" || ok "BOOT_VERBOSE '$v' rejected"
done

echo "== ORIENTATION: /etc/tsx/orientation on the root fs, the kiosk turned on a change =="
printf '#!/bin/sh\necho "tsx-orientation $* $(cat "$TSX_ORIENTATION_FILE" 2>/dev/null)" >> "%s/orient.log"\n' "$W" > "$W/bin/tsx-orientation"
chmod +x "$W/bin/tsx-orientation"; : > "$W/orient.log"
applyo() { PATH="$W/bin:$BB:$PATH" apply_ >/dev/null 2>&1; }
lives() { grep -c '^tsx-orientation apply' "$W/orient.log" 2>/dev/null || true; }
applyo
[ ! -e "$FX/etc/tsx/orientation" ] && [ "$(lives)" = 0 ] && ok "unset: no orientation file, kiosk not touched" || bad "unset: file or live apply ($(lives))"
set_ ORIENTATION portrait >/dev/null; applyo
[ "$(cat "$FX/etc/tsx/orientation" 2>/dev/null)" = portrait ] && ok "portrait -> /etc/tsx/orientation = portrait" || bad "orientation file: '$(cat "$FX/etc/tsx/orientation" 2>/dev/null)'"
[ "$(stat -c %a "$FX/etc/tsx/orientation")" = 644 ] && ok "orientation file is world-readable (kiosk, tsx-buttons, the ESPHome plugin)" || bad "orientation file mode $(stat -c %a "$FX/etc/tsx/orientation")"
[ "$(lives)" = 1 ] && grep -q '^tsx-orientation apply portrait$' "$W/orient.log" && ok "the change turned the running kiosk (tsx-orientation apply, file already written)" || bad "live apply: $(cat "$W/orient.log" 2>/dev/null)"
touch -d '2000-01-01' "$FX/etc/tsx/orientation"; applyo
[ "$(stat -c %Y "$FX/etc/tsx/orientation")" = "$(date -d 2000-01-01 +%s)" ] && [ "$(lives)" = 1 ] && ok "unchanged: file not rewritten, kiosk not touched again" || bad "unchanged value rewrote the file or re-applied ($(lives))"
set_ ORIENTATION portrait-flipped >/dev/null; applyo
[ "$(cat "$FX/etc/tsx/orientation")" = portrait-flipped ] && [ "$(lives)" = 2 ] && ok "portrait-flipped: file + live apply" || bad "portrait-flipped: $(lives)"
set_ ORIENTATION landscape >/dev/null; applyo
[ ! -e "$FX/etc/tsx/orientation" ] && [ "$(lives)" = 3 ] && ok "landscape (the default): file removed, kiosk turned back" || bad "landscape: file left or no live apply ($(lives))"
set_ ORIENTATION landscape-flipped >/dev/null; applyo
TSX_CONF="$CFG" busybox sh "$SCRIPT" unset ORIENTATION >/dev/null; applyo
[ ! -e "$FX/etc/tsx/orientation" ] && [ "$(lives)" = 5 ] && ok "unset again: file removed, kiosk turned back" || bad "unset: $(lives)"
echo "== BT_PROXY / BT_ACTIVE / BT_MAC: /run/tsx/bt.conf, tsx-bt follows the key =="
btl() { grep -c "tsx-bt $1" "$W/rc.log" 2>/dev/null || true; }
applyp
grep -qx 'PROXY="off"' "$FX/run/tsx/bt.conf" 2>/dev/null && grep -qx 'MAC=""' "$FX/run/tsx/bt.conf" \
	&& grep -qx 'ACTIVE="off"' "$FX/run/tsx/bt.conf" \
	&& ok "bt.conf: PROXY and ACTIVE off and an empty MAC by default" || bad "bt.conf default: $(cat "$FX/run/tsx/bt.conf" 2>/dev/null)"
[ "$(stat -c '%a' "$FX/run/tsx/bt.conf" 2>/dev/null)" = 644 ] && ok "bt.conf is world-readable (the voice satellite reads it)" || bad "bt.conf mode $(stat -c '%a' "$FX/run/tsx/bt.conf" 2>/dev/null)"
r0=$(restarts); v0=$(vrestarts); s0=$(btl restart)
set_ BT_PROXY on >/dev/null; applyp
grep -qx 'PROXY="on"' "$FX/run/tsx/bt.conf" && ok "BT_PROXY=on reaches bt.conf" || bad "bt.conf after BT_PROXY=on: $(cat "$FX/run/tsx/bt.conf")"
[ "$(btl restart)" = $((s0 + 1)) ] && ok "BT_PROXY=on restarts tsx-bt" || bad "BT_PROXY=on: $(btl restart) tsx-bt restarts (was $s0)"
[ "$(restarts)/$(vrestarts)" = "$((r0 + 1))/$((v0 + 1))" ] && ok "BT_PROXY=on restarts tsx-esphome and tsx-voice (new feature flags)" || bad "BT_PROXY=on: $(restarts)/$(vrestarts) restarts (was $r0/$v0)"
awk '/tsx-bt restart/{b=NR} /tsx-esphome restart/{e=NR} END{exit !(b && e && b < e)}' "$W/rc.log" \
	&& ok "tsx-bt restarts before tsx-esphome (bt.mac is ready)" || bad "restart order: $(tr '\n' ';' < "$W/rc.log")"
set_ BT_MAC 02:11:22:33:44:55 >/dev/null; applyp
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
s1=$(btl restart); TSX_BT_PROXY_DEFAULT=on applyp
grep -qx 'PROXY="on"' "$FX/run/tsx/bt.conf" && [ "$(btl restart)" = $((s1 + 1)) ] \
	&& ok "an empty BT_PROXY follows the default of the board file (TSX_BT_PROXY_DEFAULT=on): bt.conf on, tsx-bt restarts" \
	|| bad "empty BT_PROXY, board default on: $(cat "$FX/run/tsx/bt.conf"), $(btl restart) restarts (was $s1)"
set_ BT_PROXY off >/dev/null; TSX_BT_PROXY_DEFAULT=on applyp
grep -qx 'PROXY="off"' "$FX/run/tsx/bt.conf" && ok "BT_PROXY=off wins over a board default of on" || bad "BT_PROXY=off, board default on: $(cat "$FX/run/tsx/bt.conf")"
echo "== AUTO_BRIGHTNESS and ALS_SCALE: /run/tsx/als.panel for tsx-als =="
rm -f "$FX/run/tsx/als.panel"; applyp
[ ! -e "$FX/run/tsx/als.panel" ] && ok "als.panel: not written while neither key is set" || bad "als.panel written by default: $(cat "$FX/run/tsx/als.panel")"
set_ AUTO_BRIGHTNESS off >/dev/null; set_ ALS_SCALE 2.5 >/dev/null; applyp
grep -qx 'ALS_AUTO="0"' "$FX/run/tsx/als.panel" && grep -qx 'ALS_SCALE="2.5"' "$FX/run/tsx/als.panel" \
	&& ok "AUTO_BRIGHTNESS=off, ALS_SCALE=2.5 reach als.panel (ALS_AUTO=0)" || bad "als.panel: $(cat "$FX/run/tsx/als.panel" 2>/dev/null)"
[ "$(stat -c '%a' "$FX/run/tsx/als.panel")" = 644 ] && ok "als.panel mode 644" || bad "als.panel mode"
busybox sh -c '. "'"$FX"'/run/tsx/als.panel"; [ "$ALS_AUTO" = 0 ] && [ "$ALS_SCALE" = 2.5 ]' && ok "als.panel sources back" || bad "als.panel does not source"
set_ AUTO_BRIGHTNESS on >/dev/null; applyp
grep -qx 'ALS_AUTO="1"' "$FX/run/tsx/als.panel" && ok "AUTO_BRIGHTNESS=on -> ALS_AUTO=1" || bad "als.panel on: $(cat "$FX/run/tsx/als.panel")"
for k in AUTO_BRIGHTNESS ALS_SCALE; do TSX_CONF="$CFG" busybox sh "$SCRIPT" unset $k >/dev/null; done; applyp
[ ! -e "$FX/run/tsx/als.panel" ] && ok "both keys unset: als.panel removed" || bad "als.panel left behind"

echo "== a panel without a microphone or a Bluetooth module (hw.conf, government=1) =="
CFG3="$W/panel-gov.conf"; FX3="$W/fx-gov"; mkdir -p "$FX3/run/tsx" "$FX3/etc"
printf '#!/bin/sh\necho "tsx-audio $*" >> "%s/audio.log"\nexit 0\n' "$W" > "$W/bin/tsx-audio"; chmod +x "$W/bin/tsx-audio"
gov_conf() {  # gov_conf 0|1: the hw.conf that tsx-hw writes for that flag
	if [ "$1" = 1 ]; then printf 'GOVERNMENT=1\nMIC=no\nBT=no\nCAMERA=no\nREASON=government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module\n'
	else printf 'GOVERNMENT=0\nMIC=yes\nBT=yes\nCAMERA=yes\nREASON=\n'; fi > "$FX3/run/tsx/hw.conf"
}
cfg3() { env PATH="$W/bin:$PATH" TSX_CONF="$CFG3" TSX_RUN="$FX3/run" TSX_STATE_DIR="$FX3/var/lib/tsx" TSX_APPLY_PREFIX="$FX3" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" "$@"; }
gov_conf 1
for k in VOICE BT_PROXY BT_ACTIVE; do
	out=$(cfg3 set "$k" on 2>&1); rc=$?
	[ $rc = 0 ] && [ "$(cfg3 get "$k")" = on ] && case "$out" in *"WARNING: $k=on is saved, but this panel has no "*"(government=1). apply treats it as off"*) true;; *) false;; esac \
		&& ok "set $k on: saved (a panel.conf from another panel loads), with a warning" || bad "set $k on: exit $rc, '$out'"
done
out=$(cfg3 set VOICE off 2>&1); [ -z "$out" ] && ok "set VOICE off: no warning" || bad "set VOICE off warns: $out"
cfg3 set VOICE on >/dev/null 2>&1
out=$(cfg3 show 2>&1 >/dev/null)
case "$out" in *"# WARNING: VOICE=on is set, but this panel has no microphone (government=1)"*"# WARNING: BT_PROXY=on is set"*"# WARNING: BT_ACTIVE=on is set"*) ok "show: a warning for each of the three keys";; *) bad "show warnings: $out";; esac
rm -f "$W/audio.log" "$W/rc.log"
out=$(cfg3 apply 2>&1); rc=$?
[ $rc = 0 ] && grep -qx 'PROXY="off"' "$FX3/run/tsx/bt.conf" && grep -qx 'ACTIVE="off"' "$FX3/run/tsx/bt.conf" \
	&& ok "apply: bt.conf says PROXY and ACTIVE off" || bad "apply (government=1): exit $rc, bt.conf $(cat "$FX3/run/tsx/bt.conf" 2>/dev/null)"
grep -qx 'tsx-audio disable voice' "$W/audio.log" 2>/dev/null && ! grep -q 'enable voice' "$W/audio.log" \
	&& ok "apply: VOICE=on is treated as off (tsx-audio disable voice)" || bad "apply voice: $(cat "$W/audio.log" 2>/dev/null)"
case "$out" in *"WARNING: VOICE=on is set, but this panel has no microphone"*"WARNING: BT_PROXY=on is set"*) ok "apply: the log says why";; *) bad "apply log: $out";; esac
grep -q '|off|' "$FX3/run/tsx/.esphome-sig" && ok "apply: tsx-esphome sees VOICE off (it serves the entities)" || bad ".esphome-sig: $(cat "$FX3/run/tsx/.esphome-sig")"
# a panel with ALS=no in hw.conf: AUTO_BRIGHTNESS=on is saved with a warning, apply treats it as off
printf 'ALS=no\n' >> "$FX3/run/tsx/hw.conf"
out=$(cfg3 set AUTO_BRIGHTNESS on 2>&1); rc=$?
[ $rc = 0 ] && case "$out" in *"WARNING: AUTO_BRIGHTNESS=on is saved, but this panel has no ambient light sensor"*) true;; *) false;; esac \
	&& ok "ALS=no: set AUTO_BRIGHTNESS on is saved, with a warning" || bad "ALS=no set: exit $rc, '$out'"
cfg3 apply >/dev/null 2>&1
[ ! -e "$FX3/run/tsx/als.panel" ] && ok "ALS=no: apply writes no ALS_AUTO" || bad "ALS=no: $(cat "$FX3/run/tsx/als.panel")"
cfg3 unset AUTO_BRIGHTNESS >/dev/null 2>&1; gov_conf 1
grep -q 'tsx-bt' "$W/rc.log" 2>/dev/null && bad "the first apply touched tsx-bt" || ok "the first apply does not touch tsx-bt"
cfg3 apply >/dev/null 2>&1
grep -q 'tsx-bt' "$W/rc.log" 2>/dev/null && bad "an unchanged apply touched tsx-bt" || ok "an unchanged apply does not touch tsx-bt"
cfg3 set BT_MAC 02:11:22:33:44:55 >/dev/null 2>&1; cfg3 apply >/dev/null 2>&1
grep -q 'tsx-bt restart' "$W/rc.log" 2>/dev/null && bad "a BT_MAC change restarted tsx-bt on a panel without the module" || ok "a BT_MAC change does not restart tsx-bt (the proxy stays off)"
gov_conf 0; rm -f "$W/audio.log" "$FX3/run/tsx/.bt-sig"
out=$(cfg3 set VOICE on 2>&1); [ -z "$out" ] && ok "government=0: set VOICE on gives no warning" || bad "government=0 set warns: $out"
cfg3 apply >/dev/null 2>&1
grep -qx 'PROXY="on"' "$FX3/run/tsx/bt.conf" && grep -qx 'ACTIVE="on"' "$FX3/run/tsx/bt.conf" && grep -qx 'tsx-audio enable voice' "$W/audio.log" \
	&& ok "government=0: BT_PROXY, BT_ACTIVE and VOICE work as before" || bad "government=0: bt.conf $(cat "$FX3/run/tsx/bt.conf"), audio $(cat "$W/audio.log" 2>/dev/null)"
rm -f "$FX3/run/tsx/hw.conf" "$W/audio.log"; cfg3 apply >/dev/null 2>&1
grep -qx 'PROXY="on"' "$FX3/run/tsx/bt.conf" && grep -qx 'tsx-audio enable voice' "$W/audio.log" \
	&& ok "no hw.conf: a panel with all parts" || bad "no hw.conf: bt.conf $(cat "$FX3/run/tsx/bt.conf")"
rm -f "$W/bin/tsx-audio" "$W/audio.log"

echo "== unconfigured panel (no KIOSK_URL, no TZ_NAME): apply runs to the end =="
CFG2="$W/panel-unconf.conf"; FX2="$W/fx-unconf"; mkdir -p "$FX2/run" "$FX2/etc"
printf '# header only\nKERNEL_FLAVOR="stable"\n' > "$CFG2"
rm -f "$W/rc.log"
out=$(PATH="$W/bin:$PATH" env TSX_CONF="$CFG2" TSX_RUN="$FX2/run" TSX_STATE_DIR="$FX2/var/lib/tsx" TSX_APPLY_PREFIX="$FX2" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply 2>&1); rc=$?
[ "$rc" = 0 ] && ok "apply exits 0 with no kiosk override" || bad "apply exit $rc with no kiosk override (set -e)"
case "$out" in *"apply done"*) ok "apply reached its end (apply done)";; *) bad "apply stopped early: $(printf '%s' "$out" | tail -1)";; esac
[ -e "$FX2/run/tsx/.kiosk-sig" ] && ok "the kiosk signature exists after the first apply" || bad "no .kiosk-sig after the first apply"
TSX_CONF="$CFG2" busybox sh "$SCRIPT" set KIOSK_URL https://ha.example.org >/dev/null
PATH="$W/bin:$PATH" env TSX_CONF="$CFG2" TSX_RUN="$FX2/run" TSX_STATE_DIR="$FX2/var/lib/tsx" TSX_APPLY_PREFIX="$FX2" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" apply >/dev/null 2>&1
grep -q 'tsx-buttons reload' "$W/rc.log" 2>/dev/null && ok "the first KIOSK_URL (setup page save) reloads tsx-buttons" || bad "first KIOSK_URL did not reload tsx-buttons"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-tsx-config-apply || echo FAIL test-tsx-config-apply
exit $F
