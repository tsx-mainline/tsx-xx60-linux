#!/bin/bash
# Host test for tsx-panelctl (rootfs/overlay/usr/local/sbin/tsx-panelctl):
# the FIFO's writer is the "kiosk" user, which also runs Chromium
# unsandboxed, so every line must be validated as hostile input, not just
# parsed. Checks that the documented, exact command forms run the expected
# fake CLI with the expected arguments, and that malformed/hostile lines
# (a glob, a leading-dash "option", wrong arg count, an out-of-range number,
# an overlong numeric string, a bare shell metacharacter) are rejected --
# logged, never executed -- without killing the daemon.
set -uo pipefail
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

# TSX_REBOOT_BIN as an absolute path, not PATH alone: busybox ash's "reboot"
# is one of its own built-in applets and short-circuits a bare name before
# PATH is ever searched, so a $T/bin/reboot fixture on PATH would silently
# never run (harmless on the panel, where busybox's own reboot IS what we
# want -- but it defeats overriding it for this test).
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
echo 12 > "$T/run/brightness"
send "brightness-offset -3"

for want in \
	'tsx-ledbar set 10 20 30' 'tsx-ledbar off' \
	'tsx-keypad led 128' 'tsx-keypad led off' \
	'tsx-blank on' 'tsx-blank off' 'tsx-als auto on' \
	'tsx-config set KIOSK_URL https://ha.example.org/lovelace/0' 'tsx-config apply' \
	'amixer -q -c TSW1060 sset Master 42%' 'reboot' 'tsx-autoupdate now' \
	'tsx-keypad page reload' 'tsx-config set BLANK_TIMEOUT 600'
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

[ ! -s "$T/cmds.log" ] && ok "no fake CLI was ever run for any hostile line" || { bad "a hostile line reached a CLI"; cat "$T/cmds.log"; }
rejected=$(grep -c 'rejected:' "$T/panelctl.log")
[ "$rejected" -ge 18 ] && ok "all 18 hostile lines were logged as rejected ($rejected)" || bad "expected >=18 rejections, got $rejected"
kill -0 "$PID" 2>/dev/null && ok "daemon is still alive after the hostile batch" || bad "daemon died"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-panelctl || echo FAIL test-panelctl
exit $F
