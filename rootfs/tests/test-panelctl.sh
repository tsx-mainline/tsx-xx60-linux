#!/bin/bash
# Host test for tsx-panelctl (rootfs/overlay/usr/local/sbin/tsx-panelctl).
# The "kiosk" user writes to the FIFO and also runs Chromium unsandboxed. So
# tsx-panelctl must validate every line as hostile input and not only parse it.
# The test checks two things. The documented, exact command forms must run the
# expected fake CLI with the expected arguments. Malformed or hostile lines
# must be rejected, logged and never executed, and must not kill the daemon.
# Such lines are a glob, a leading-dash "option", a wrong argument count, an
# out-of-range number, an overlong numeric string and a bare shell metacharacter.
set -uo pipefail
# The board file (rootfs/overlay/usr/local/lib/tsx/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/lib/tsx/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../overlay/usr/local/sbin/tsx-panelctl"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-panelctl: no busybox on this host"; exit 0; }
T=$(mktemp -d); PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/bin"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

for b in tsx-ledbar tsx-keypad tsx-blank tsx-als tsx-config tsx-autoupdate; do
	cat > "$T/bin/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "$T/cmds.log"
EOF
	chmod +x "$T/bin/$b"
done
cat > "$T/bin/amixer" <<EOF
#!/bin/sh
echo "amixer \$*" >> "$T/cmds.log"
EOF
chmod +x "$T/bin/amixer"
cat > "$T/bin/reboot" <<EOF
#!/bin/sh
# tsx-panelctl's reboot branch never passes an argument -- keep this exact
# so the "ran: reboot" check below is a real assertion, not a trailing-space
# false negative.
echo "reboot" >> "$T/cmds.log"
EOF
chmod +x "$T/bin/reboot"

# TSX_REBOOT_BIN is an absolute path and not a name in PATH. The "reboot" of
# busybox ash is a built-in applet. It catches a bare name before the shell
# searches PATH. So a $T/bin/reboot fixture on PATH would silently never run.
# This is harmless on the panel, where the reboot of busybox is what we want,
# but it defeats the override in this test.
PATH="$T/bin:$PATH" TSX_RUN_DIR="$T/run" TSX_REBOOT_BIN="$T/bin/reboot" \
	busybox sh "$SCRIPT" > "$T/panelctl.log" 2>&1 &
PID=$!
for _ in $(seq 1 20); do grep -q "listening on" "$T/panelctl.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/panelctl.log" || { echo "FAIL: tsx-panelctl did not start"; cat "$T/panelctl.log"; exit 1; }

send() { echo "$1" > "$T/run/panelctl"; sleep 0.15; }

echo "== valid commands run the expected CLI =="
send "ledbar set 10 20 30"
send "ledbar off"
send "keypad led 128"
send "keypad led off"
send "blank on"
send "blank off"
send "als auto on"
send "brightness 17"
send "volume 42"
send "config-url https://ha.example.org/lovelace/0"
send "reboot"
send "update-install"
send "reload-page"
send "blank-timeout 600"
send "verbose-boot on"
send "verbose-boot off"
send "setup"
echo 12 > "$T/run/brightness"
send "brightness-offset -3"

for want in \
	'tsx-ledbar set 10 20 30' 'tsx-ledbar off' \
	'tsx-keypad led 128' 'tsx-keypad led off' \
	'tsx-blank on' 'tsx-blank off' 'tsx-als auto on' \
	'tsx-config set KIOSK_URL https://ha.example.org/lovelace/0' 'tsx-config apply' \
	'amixer -q -c TSW1060 sset Master 42%' 'reboot' 'tsx-autoupdate now' \
	'tsx-keypad page reload' 'tsx-config set BLANK_TIMEOUT 600' 'tsx-config setup' \
	'tsx-config set BOOT_VERBOSE 1' 'tsx-config set BOOT_VERBOSE 0'
do
	grep -qxF "$want" "$T/cmds.log" 2>/dev/null && ok "ran: $want" || bad "missing: $want"
done
[ "$(cat "$T/run/brightness-offset" 2>/dev/null)" = -3 ] && ok "brightness-offset file has -3" || bad "brightness-offset wrong: '$(cat "$T/run/brightness-offset" 2>/dev/null)'"
[ ! -e "$T/run/brightness" ] && ok "brightness-offset removed the absolute override" || bad "override left next to the offset"
send "brightness-offset 0"
[ ! -e "$T/run/brightness-offset" ] && ok "brightness-offset 0 removes the file" || bad "offset 0 left a file"
send "brightness 17"
[ "$(cat "$T/run/brightness" 2>/dev/null)" = 17 ] && ok "brightness override file has 17" || bad "brightness override wrong"

echo "== hostile/malformed input is rejected, not run =="
: > "$T/cmds.log"
send "ledbar set 10 20 *"
send "ledbar set -x 20 30"
send "keypad led 999"
send "blank -rf"
send "ledbar set 10 20 30 extra"
send "reboot now"
send "; rm -rf /"
send "config-url ftp://evil.example"
send "brightness $(printf '9%.0s' $(seq 1 40))"
send "volume 999"
send "update-install now"
send "brightness-offset 32"
send "brightness-offset --3"
send "brightness-offset +3"
send "brightness-offset 3-"
send "blank-timeout 86401"
send "blank-timeout -5"
send "reload-page now"
send "setup now"
send "verbose-boot maybe"
send "verbose-boot on extra"

[ ! -s "$T/cmds.log" ] && ok "no fake CLI was ever run for any hostile line" || { bad "a hostile line reached a CLI"; cat "$T/cmds.log"; }
rejected=$(grep -c 'rejected:' "$T/panelctl.log")
[ "$rejected" -ge 21 ] && ok "all 21 hostile lines were logged as rejected ($rejected)" || bad "expected >=21 rejections, got $rejected"
kill -0 "$PID" 2>/dev/null && ok "daemon is still alive after the hostile batch" || bad "daemon died"

echo "== orientation: the four names, nothing else =="
: > "$T/cmds.log"
send "orientation portrait-flipped"
grep -qxF 'tsx-config set ORIENTATION portrait-flipped' "$T/cmds.log" && grep -qxF 'tsx-config apply' "$T/cmds.log" \
	&& ok "orientation portrait-flipped -> tsx-config set ORIENTATION + apply" || bad "orientation: $(cat "$T/cmds.log" 2>/dev/null)"
: > "$T/cmds.log"; r0=$(grep -c 'rejected:' "$T/panelctl.log")
send "orientation sideways"
send "orientation portrait extra"
send "orientation"
send "orientation -portrait"
send "orientation landscape*"
[ ! -s "$T/cmds.log" ] && [ "$(grep -c 'rejected:' "$T/panelctl.log")" = $((r0 + 5)) ] \
	&& ok "5 bad orientation lines rejected, nothing run" || bad "bad orientation lines: $(cat "$T/cmds.log" 2>/dev/null)"

echo "== the seam: commands for the Home Assistant layer (ledbar on, keypad led auto, backlight) =="
: > "$T/cmds.log"
mkdir -p "$T/bl/dev0"; echo 0 > "$T/bl/dev0/brightness"; echo "on 17" > "$T/idled.state"
restart_with_hw() {
	kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
	PATH="$T/bin:$PATH" TSX_RUN_DIR="$T/run" TSX_REBOOT_BIN="$T/bin/reboot" TSX_IDLED_STATE="$T/idled.state" \
		TSX_BACKLIGHT_DIR="$T/bl" TSX_BUTTONS_CONF="$T/buttons.conf" TSX_ALS_CONF="$T/als.conf" TSX_ASOUND_DIR="$T/asound" \
		busybox sh "$SCRIPT" > "$T/panelctl.log" 2>&1 &
	PID=$!
	for _ in $(seq 1 20); do grep -q "listening on" "$T/panelctl.log" 2>/dev/null && break; sleep 0.1; done
}
restart_with_hw
send "ledbar on"; send "keypad led auto"; send "backlight 9"
grep -qxF 'tsx-ledbar on' "$T/cmds.log" && ok "ledbar on -> tsx-ledbar on" || bad "ledbar on: $(cat "$T/cmds.log")"
grep -qxF 'tsx-keypad led auto' "$T/cmds.log" && ok "keypad led auto -> tsx-keypad led auto" || bad "keypad led auto missing"
[ "$(cat "$T/run/brightness" 2>/dev/null)" = 9 ] && ok "backlight 9 writes the override file" || bad "backlight: override file wrong"
[ "$(cat "$T/bl/dev0/brightness")" = 9 ] && ok "backlight 9 writes the backlight device while the screen is lit" || bad "backlight device not written"
echo "blank" > "$T/idled.state"; send "backlight 12"
[ "$(cat "$T/run/brightness")" = 12 ] && [ "$(cat "$T/bl/dev0/brightness")" = 9 ] && ok "backlight with the screen blanked: override only, device untouched" || bad "backlight while blanked wrong"
r0=$(grep -c 'rejected:' "$T/panelctl.log"); : > "$T/cmds.log"
send "backlight 0"; send "backlight 32"; send "backlight 5 extra"; send "backlight *"; send "ledbar on now"; send "keypad led auto 5"
[ ! -s "$T/cmds.log" ] && [ "$(grep -c 'rejected:' "$T/panelctl.log")" = $((r0 + 6)) ] && ok "6 bad lines for the new commands rejected" || bad "bad lines for the new commands: $(cat "$T/cmds.log")"

echo "== the seam: tsx-panelctl send, get, has, events =="
PCTL="env PATH=$T/bin:$PATH TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled.state TSX_BUTTONS_CONF=$T/buttons.conf TSX_ALS_CONF=$T/als.conf TSX_ASOUND_DIR=$T/asound busybox sh $SCRIPT"
: > "$T/cmds.log"
$PCTL send ledbar set 4 5 6 && sleep 0.2 && grep -qxF 'tsx-ledbar set 4 5 6' "$T/cmds.log" && ok "send writes the command, the daemon runs it" || bad "send did not reach the daemon"
$PCTL send 2>/dev/null && bad "send with no command succeeded" || ok "send with no command fails"
$PCTL send "ledbar $(printf 'x\001y')" 2>/dev/null && bad "send accepted a control character" || ok "send refuses control characters"
$PCTL send "$(printf 'a%.0s' $(seq 1 250))" 2>/dev/null && bad "send accepted a 250 character line" || ok "send refuses a long line"
# the FIFO exists, nothing reads it: send gives up
mkdir -p "$T/run2"; mkfifo "$T/run2/panelctl"
t0=$(date +%s); env TSX_RUN_DIR="$T/run2" busybox sh "$SCRIPT" send blank on 2>/dev/null && bad "send with no reader succeeded" || ok "send with no daemon fails"
[ $(( $(date +%s) - t0 )) -le 6 ] && ok "send gives up after a few seconds, it does not hang" || bad "send waited too long"
env TSX_RUN_DIR="$T/run3" busybox sh "$SCRIPT" send blank on 2>/dev/null && bad "send with no FIFO succeeded" || ok "send with no FIFO fails at once"
mkdir -p "$T/asound/TSW1060"
mkdir -p "$T/bin2"; printf '#!/bin/sh\necho "Simple mixer control Master,0"\necho "  Front Left: Playback 40 [63%%] [on]"\n' > "$T/bin2/amixer"; chmod +x "$T/bin2/amixer"
[ "$(env PATH="$T/bin2:$PATH" TSX_RUN_DIR="$T/run" TSX_ASOUND_DIR="$T/asound" busybox sh "$SCRIPT" get volume)" = 63 ] && ok "get volume: the percent of the Master control" || bad "get volume wrong"
rm -rf "$T/asound/TSW1060"
env PATH="$T/bin2:$PATH" TSX_RUN_DIR="$T/run" TSX_ASOUND_DIR="$T/asound" busybox sh "$SCRIPT" get volume >/dev/null 2>&1 && bad "get volume without a sound card succeeded" || ok "get volume without a sound card: nothing, exit 1"
printf 'want 10 20 30\n' > "$T/run/ledbar.state"; printf 'led 128 day\nlast home short 12:00:01\n' > "$T/run/buttons.state"; printf 'raw 12.50\nreport 12.5\nauto on\n' > "$T/run/als.state"
echo "on 17" > "$T/idled.state"
for kv in "ledbar=10 20 30" "keypad-led=128 day" "last-key=home short 12:00:01" "lux=12.5" "als-auto=on" "screen=on 17"; do
	k=${kv%%=*}; w=${kv#*=}; got=$($PCTL get "$k" 2>/dev/null)
	[ "$got" = "$w" ] && ok "get $k: $w" || bad "get $k: got '$got', want '$w'"
done
$PCTL get nothing >/dev/null 2>&1; [ $? = 2 ] && ok "get of an unknown name: exit 2" || bad "get of an unknown name"
rm -f "$T/run/als.state"; $PCTL get lux >/dev/null 2>&1 && bad "get lux with no sensor succeeded" || ok "get lux with no sensor: nothing, exit 1"
printf 'raw 12.50\nreport 12.5\nauto on\n' > "$T/run/als.state"
printf '#!/bin/sh\n' > "$T/als.conf"; : > "$T/buttons.conf"; : > "$T/bin/tsx-ledbar"; chmod +x "$T/bin/tsx-ledbar"; mkdir -p "$T/asound/TSW1060"
for h in ledbar keypad als sound; do $PCTL has $h && ok "has $h: yes" || bad "has $h: no"; done
rm -f "$T/als.conf" "$T/buttons.conf" "$T/run/als.state"; rm -rf "$T/asound/TSW1060"; rm -f "$T/bin/tsx-ledbar"
for h in ledbar keypad als sound; do $PCTL has $h && bad "has $h: yes without the hardware" || ok "has $h: no without the hardware"; done
for h in ledbar keypad als sound; do $PCTL has $h >/dev/null 2>&1; [ $? = 1 ] && ok "has $h: exit 1 without the hardware" || bad "has $h: exit is not 1"; done
$PCTL has toaster >/dev/null 2>&1; [ $? = 2 ] && ok "has of an unknown name: exit 2" || bad "has of an unknown name"
# events: the present values first, then a line for each change
printf 'want 10 20 30\n' > "$T/run/ledbar.state"; printf 'led 128 day\nlast home short 12:00:01\n' > "$T/run/buttons.state"
echo "on 17" > "$T/idled.state"; printf 'raw 12.50\nreport 12.5\nauto on\n' > "$T/run/als.state"
( sleep 0.7; printf 'led 128 day\nlast power long 12:00:09\n' > "$T/run/buttons.state"; sleep 0.5; echo blank > "$T/idled.state" ) &
EV=$(env TSX_EVENTS_POLL=0.2 TSX_EVENTS_MAX=8 TSX_RUN_DIR="$T/run" TSX_IDLED_STATE="$T/idled.state" timeout 10 busybox sh "$SCRIPT" events)
echo "$EV" | head -n 4 | grep -qx 'lux 12.5' && echo "$EV" | grep -qx 'als-auto on' && echo "$EV" | grep -qx 'screen on 17' && echo "$EV" | grep -qx 'ledbar 10 20 30' && echo "$EV" | grep -qx 'keypad-led 128 day' \
	&& ok "events: the present values come first" || bad "events start: $EV"
echo "$EV" | grep -q 'button home' && bad "events: the old key press came out as an event" || ok "events: the key press of before the start is not an event"
echo "$EV" | grep -qx 'button power long' && ok "events: a new key press is 'button NAME TYPE'" || bad "events: no button event: $EV"
echo "$EV" | grep -qx 'screen blank' && ok "events: a screen change is an event" || bad "events: no screen event: $EV"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-panelctl || echo FAIL test-panelctl
exit $F
