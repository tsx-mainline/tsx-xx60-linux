#!/bin/bash
# Host test for the on-panel setup page (PLAN.md section 16 item 3,
# docs/rootfs.md "Setup page"): tsx-kiosk-url (which URL the kiosk should
# load), tsx-config's `validate`/`setup` subcommands, tsx-setup-helper (the
# one root process privileged writes go through), and tsx-setupd itself --
# all real scripts, run as real processes against fixture files and fake
# helper binaries (never the panel, never docker, never root: tsx-setupd and
# tsx-setup-helper both run as this test's own uid, with
# TSX_APPLY_ALLOW_NONROOT standing in for the root check tsx-config apply/
# setup would otherwise require).
#
# Covers: the trigger (unconfigured -> setup page), form validation (through
# the exact same tsx-config regex table, including a shell-metacharacter
# payload that must round-trip literally and never execute), the LAN pairing
# code (not needed on localhost, required and rate-limited from a simulated
# LAN client), tsx-setupd listening on loopback ONLY once configured (not
# just refusing at the HTTP layer -- a simulated LAN connection must fail to
# even connect), tsx-setup-helper rejecting anything outside its fixed
# command set (never running the fake tsx-config/chpasswd for a bad line),
# the setup-open window being monotonic (immune to a broken/wrong `date`,
# since none of this ever calls it), a save landing in a temp panel.conf,
# and that no secret ever appears in a JSON response or in either daemon's
# own log.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SBIN="$HERE/overlay/usr/local/sbin"
BIN="$HERE/overlay/usr/local/bin"
SETUPD="$SBIN/tsx-setupd"
HELPER="$SBIN/tsx-setup-helper"
TSXCONFIG="$SBIN/tsx-config"
KIOSKURL="$BIN/tsx-kiosk-url"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-setup: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-setup: no python3 on this host"; exit 0; }

T=$(mktemp -d)
SETUPD_PID= HELPER_PID=
cleanup() {
	[ -n "$SETUPD_PID" ] && kill "$SETUPD_PID" 2>/dev/null
	[ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null
	[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

# ---- 0. syntax ----------------------------------------------------------
echo "== syntax =="
busybox sh -n "$TSXCONFIG" && ok "busybox sh -n tsx-config" || bad "busybox sh -n tsx-config"
busybox sh -n "$KIOSKURL" && ok "busybox sh -n tsx-kiosk-url" || bad "busybox sh -n tsx-kiosk-url"
busybox sh -n "$HERE/overlay/usr/local/bin/kiosk-session" && ok "busybox sh -n kiosk-session" || bad "busybox sh -n kiosk-session"
busybox sh -n "$HELPER" && ok "busybox sh -n tsx-setup-helper" || bad "busybox sh -n tsx-setup-helper"
busybox sh -n "$HERE/overlay/etc/init.d/tsx-setupd" && ok "busybox sh -n init.d/tsx-setupd" || bad "busybox sh -n init.d/tsx-setupd"
busybox sh -n "$HERE/overlay/etc/init.d/tsx-setup-helper" && ok "busybox sh -n init.d/tsx-setup-helper" || bad "busybox sh -n init.d/tsx-setup-helper"
busybox sh -n "$SBIN/tsx-panelctl" && ok "busybox sh -n tsx-panelctl" || bad "busybox sh -n tsx-panelctl"
python3 -m py_compile "$SETUPD" && ok "python3 -m py_compile tsx-setupd" || bad "py_compile tsx-setupd"
find "$HERE" -name __pycache__ -exec rm -rf {} + 2>/dev/null

echo "== tsx-setupd runs as an unprivileged user, not root =="
grep -q '^command_user="tsx-setup:tsx-setup"$' "$HERE/overlay/etc/init.d/tsx-setupd" \
	&& ok "init.d/tsx-setupd sets command_user to tsx-setup, not root" \
	|| bad "init.d/tsx-setupd does not run as the unprivileged tsx-setup user"
grep -q 'adduser -D -H -s /sbin/nologin.*tsx-setup' "$HERE/mkrootfs.sh" \
	&& ok "mkrootfs.sh creates the tsx-setup system user" \
	|| bad "mkrootfs.sh does not create a tsx-setup user"

# ---- fixtures -------------------------------------------------------------
mkdir -p "$T/run" "$T/bin" "$T/zoneinfo/America"
CONF="$T/panel.conf"
cat > "$T/bin/tsx-config" <<EOF
#!/bin/sh
exec busybox sh "$TSXCONFIG" "\$@"
EOF
chmod +x "$T/bin/tsx-config"
cat > "$T/bin/chpasswd" <<'EOF'
#!/bin/sh
# stands in for the real chpasswd: logs what it was given on stdin (so the
# test can check the password travels there, never as a shell argument),
# then rewrites the fixture shadow file the same way the real tool would --
# so tsx-setup-helper's own follow-up read of it is realistic.
echo "chpasswd $*" >> "$FAKE_CMD_LOG"
cat > "$FAKE_CHPASSWD_LOG"
printf 'root:$6$faketestfixturesalt$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN.:19000:0:99999:7:::\n' > "$TSX_SHADOW_FILE"
exit 0
EOF
chmod +x "$T/bin/chpasswd"
cat > "$T/bin/rc-service" <<EOF
#!/bin/sh
echo "rc-service \$*" >> "$T/rc-service.log"
case "\$2" in status) exit 1;; *) exit 0;; esac
EOF
chmod +x "$T/bin/rc-service"
# a deliberately broken/wrong `date`, early on PATH: tsx-config setup and
# tsx-kiosk-url must not be affected AT ALL (they read /proc/uptime, never
# date +%s -- docs/rootfs.md "Setup page") -- this is what proves the setup
# window is monotonic, not wall-clock, without needing to actually step the
# system clock (which a host test cannot safely do). tsx-setup-helper's own
# log() DOES call date (cosmetic timestamps only); it must keep working
# (not crash), just with a silly-looking log line.
cat > "$T/bin/date" <<'EOF'
#!/bin/sh
echo "2099-01-01 00:00:00 (FAKE_BROKEN_DATE: not real wall-clock time)"
EOF
chmod +x "$T/bin/date"
touch "$T/zoneinfo/UTC" "$T/zoneinfo/America/New_York" "$T/zoneinfo/America/Denver"
cat > "$T/shadow" <<'EOF'
root:$oldhash$oldoldoldoldoldoldoldoldoldoldold:19000:0:99999:7:::
EOF
cat > "$T/setup.conf" <<EOF
TSX_SETUP_PORT=0
TSX_SETUP_LAN=on
TSX_SETUP_WINDOW=6
EOF

get_free_port() { python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('0.0.0.0', 0))
print(s.getsockname()[1])
s.close()
"; }
PORT=$(get_free_port)
sed -i "s/TSX_SETUP_PORT=0/TSX_SETUP_PORT=$PORT/" "$T/setup.conf"

# --source connects FROM that local address instead of whatever the OS
# would otherwise pick, so the server sees a non-loopback peer even though
# both ends are this same test host (a real second LAN host is not
# available in CI). A short connect timeout: once tsx-setupd is bound
# loopback-only, a LAN attempt must fail fast (connection refused), not
# hang.
cat > "$T/client.py" <<'PYEOF'
import argparse, http.client, sys
p = argparse.ArgumentParser()
p.add_argument("method"); p.add_argument("path")
p.add_argument("--port", type=int, required=True)
p.add_argument("--source", default=None)
p.add_argument("--cookie", default=None)
p.add_argument("--data", default=None)
a = p.parse_args()
kwargs = {"timeout": 3}
if a.source:
	kwargs["source_address"] = (a.source, 0)
conn = http.client.HTTPConnection(a.source or "127.0.0.1", a.port, **kwargs)
headers = {}
body = None
if a.data is not None:
	body = a.data.encode()
	headers["Content-Type"] = "application/json"
if a.cookie:
	headers["Cookie"] = "tsxsetup=" + a.cookie
try:
	conn.request(a.method, a.path, body=body, headers=headers)
	resp = conn.getresponse()
	raw = resp.read()
	status = resp.status
	setcookie = resp.getheader("Set-Cookie") or ""
except Exception as e:
	print(0); print(""); print('{"_client_error": "%s"}' % str(e).replace('"', "'"))
	sys.exit(0)
token = ""
if setcookie.startswith("tsxsetup="):
	token = setcookie.split(";")[0][len("tsxsetup="):]
print(status)
print(token)
sys.stdout.write(raw.decode(errors="replace"))
PYEOF

call() {
	# ServerManager (tsx-setupd) can be mid-rebind (closing one listening
	# socket, opening another -- e.g. right after a save flips
	# lan_allowed()) for a few milliseconds; a request that lands in that
	# exact window gets a connection reset/refused, not a real answer.
	# Retry a couple of times before treating it as this test's own
	# failure -- a real client (the kiosk, a browser tab) would do the
	# same rather than give up on the very first reset.
	local out status tries=0
	while :; do
		out=$(python3 "$T/client.py" "$@" --port "$PORT")
		status=$(printf '%s\n' "$out" | sed -n '1p')
		[ "$status" != 0 ] && break
		tries=$((tries + 1))
		[ "$tries" -ge 3 ] && break
		sleep 0.2
	done
	printf '%s\n' "$out"
}
status_of() { printf '%s\n' "$1" | sed -n '1p'; }
cookie_of() { printf '%s\n' "$1" | sed -n '2p'; }
body_of() { printf '%s\n' "$1" | sed -n '3,$p'; }
jget() {  # jget PATH <<< "$body"  (dotted path into the JSON object; a
	# numeric segment indexes a list, e.g. tz_list.0)
	python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d
for k in '$1'.split('.'):
	if isinstance(v, dict):
		v = v.get(k)
	elif isinstance(v, list) and k.lstrip('-').isdigit() and -len(v) <= int(k) < len(v):
		v = v[int(k)]
	else:
		v = None
print('' if v is None else v)
"
}

# find a local, non-loopback source address to stand in for a LAN client
# (there is no real second host in CI): connecting a UDP socket never sends
# a packet, it only asks the kernel to pick the route/source address.
LANIP=$(python3 -c "
import socket
try:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.connect(('192.0.2.1', 80))
	print(s.getsockname()[0])
except Exception:
	print('')
" 2>/dev/null)
[ -n "$LANIP" ] && [ "$LANIP" != 127.0.0.1 ] || LANIP=

# ---- start tsx-setup-helper (the root side) + tsx-setupd (unprivileged) --
# tsx-config itself reads TSX_RUN (a base dir; it appends /tsx internally);
# tsx-setup-helper/tsx-setupd/tsx-kiosk-url read TSX_RUN_DIR (the tsx dir
# itself, like tsx-panelctl's TSX_RUN_DIR) -- both must resolve to the same
# physical directory.
RUNBASE="$T/run"; RUNDIR="$T/run/tsx"
FAKE_CHPASSWD_LOG="$T/chpasswd-stdin.log"
FAKE_CMD_LOG="$T/fake-cmd.log"
export FAKE_CHPASSWD_LOG FAKE_CMD_LOG

PATH="$T/bin:$PATH" TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_CONF="$CONF" \
TSX_RUN="$RUNBASE" TSX_RUN_DIR="$RUNDIR" TSX_APPLY_ALLOW_NONROOT=1 \
TSX_APPLY_PREFIX="$T/prefix" TSX_STATE_DIR="$T/state" \
TSX_CHPASSWD_BIN="$T/bin/chpasswd" TSX_SHADOW_FILE="$T/shadow" TSX_RCSERVICE_BIN="$T/bin/rc-service" \
	busybox sh "$HELPER" > "$T/helper.log" 2>&1 &
HELPER_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$T/helper.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/helper.log" 2>/dev/null || { echo "FAIL: tsx-setup-helper did not start"; cat "$T/helper.log"; exit 1; }

TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_RUN_DIR="$RUNDIR" TSX_ZONEINFO_DIR="$T/zoneinfo" \
TSX_SETUP_CONF="$T/setup.conf" TSX_SETUP_NO_ZEROCONF=1 \
	python3 "$SETUPD" > "$T/setupd.log" 2>&1 &
SETUPD_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$T/setupd.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/setupd.log" 2>/dev/null || { echo "FAIL: tsx-setupd did not start"; cat "$T/setupd.log"; exit 1; }

# ---- 1. unconfigured: loopback sees the page, a fresh pairing code, no secret fields set
echo "== unconfigured, loopback =="
out=$(call GET /setup/api/state); body=$(body_of "$out")
[ "$(status_of "$out")" = 200 ] && ok "GET state 200" || bad "GET state: $(status_of "$out")"
[ "$(jget need_pairing <<<"$body")" = False ] && ok "loopback needs no pairing" || bad "loopback need_pairing: $body"
[ "$(jget configured <<<"$body")" = False ] && ok "reports unconfigured" || bad "configured should be false: $body"
CODE=$(jget pairing_code <<<"$body")
printf '%s' "$CODE" | grep -Eq '^[0-9]{6}$' && ok "pairing code is 6 digits ($CODE)" || bad "bad pairing code: '$CODE'"
[ "$(jget fields.HA_TOKEN__set <<<"$body")" != True ] && ok "no HA_TOKEN set yet" || bad "HA_TOKEN__set should be unset"
[ "$(jget tz_list.0 <<<"$body")" != "" ] && ok "tz_list is non-empty" || bad "tz_list empty"

out=$(call GET /setup); [ "$(status_of "$out")" = 200 ] && ok "GET /setup 200 on loopback" || bad "GET /setup: $(status_of "$out")"

echo "== unconfigured: tsx-setupd listens on 0.0.0.0 (LAN allowed) =="
ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" \
	&& ok "bound to 0.0.0.0 while unconfigured" \
	|| bad "not bound to 0.0.0.0 while unconfigured: $(ss -ltn 2>/dev/null | grep ":$PORT" || echo none)"

# ---- 2. LAN policy while unconfigured: reachable, but needs the code, and never sees it
if [ -n "$LANIP" ]; then
	echo "== unconfigured, simulated LAN ($LANIP) =="
	out=$(call GET /setup --source "$LANIP"); [ "$(status_of "$out")" = 200 ] && ok "LAN GET /setup reachable while unconfigured" || bad "LAN /setup: $(status_of "$out")"
	out=$(call GET /setup/api/state --source "$LANIP"); body=$(body_of "$out")
	[ "$(jget need_pairing <<<"$body")" = True ] && ok "LAN client is asked to pair" || bad "LAN need_pairing: $body"
	[ "$(jget pairing_code <<<"$body")" = "" ] && ok "LAN state never carries the pairing code" || bad "LAN state leaked the code: $body"

	echo "== pairing =="
	out=$(call POST /setup/api/pair --source "$LANIP" --data '{"code":"000000"}')
	if [ "$CODE" = 000000 ]; then bad "test code collided with the real one, rerun"; else
		[ "$(status_of "$out")" = 403 ] && ok "wrong pairing code rejected" || bad "wrong code: $(status_of "$out")"
	fi
	out=$(call POST /setup/api/pair --source "$LANIP" --data "{\"code\":\"$CODE\"}")
	[ "$(status_of "$out")" = 200 ] && ok "correct pairing code accepted" || bad "pair failed: $out"
	TOKEN=$(cookie_of "$out")
	[ -n "$TOKEN" ] && ok "pairing issued a session token" || bad "no session token issued"
	out=$(call GET /setup/api/state --source "$LANIP" --cookie "$TOKEN"); body=$(body_of "$out")
	[ "$(jget need_pairing <<<"$body")" = False ] && ok "paired LAN session no longer needs pairing" || bad "still need_pairing after pairing: $body"
	[ "$(jget pairing_code <<<"$body")" = "" ] && ok "paired LAN session still never sees the code" || bad "paired LAN state leaked the code: $body"

	echo "== pairing rate limit =="
	f=0
	for i in $(seq 1 12); do
		out=$(call POST /setup/api/pair --source "$LANIP" --data '{"code":"999999"}')
		[ "$(status_of "$out")" = 429 ] && f=1 && break
	done
	[ "$f" = 1 ] && ok "repeated wrong codes eventually get rate-limited (429)" || bad "no rate limit seen after 12 wrong attempts"
else
	echo "SKIPPED: no non-loopback local address available to simulate a LAN client"
fi

# ---- 3. tsx-setup-helper: strict allowlist, nothing outside it ever runs
echo "== tsx-setup-helper rejects anything outside its command set =="
: > "$FAKE_CMD_LOG"
helper_send() { printf '%s\n' "$1" > "$RUNDIR/setup-helper"; timeout 3 head -1 "$RUNDIR/setup-helper.resp"; }
r=$(helper_send "frobnicate --evil"); echo "$r" | grep -q '^err' && ok "unknown command rejected: $r" || bad "unknown command not rejected: $r"
r=$(helper_send "unset BAD KEY"); echo "$r" | grep -q '^err' && ok "unset with a spaced key rejected: $r" || bad "bad unset accepted: $r"
r=$(helper_send "; rm -rf /"); echo "$r" | grep -q '^err' && ok "a shell-metacharacter command name rejected: $r" || bad "metacharacter command accepted: $r"
r=$(helper_send "rootpw short"); echo "$r" | grep -q '^err' && ok "a too-short root password rejected: $r" || bad "short root password accepted: $r"
[ ! -s "$FAKE_CMD_LOG" ] && ok "none of the rejected lines ever ran the fake chpasswd" || { bad "a rejected line reached a real command"; cat "$FAKE_CMD_LOG"; }
grep -q '^ok' <(helper_send "show") && ok "the allowed 'show' command still works after the rejected batch" || bad "helper stopped answering after rejections"

# ---- 4. form validation: bad URL, bad TZ, overlong field, shell metacharacters
echo "== form validation =="
out=$(call POST /setup/api/submit --data '{}'); body=$(body_of "$out")
[ "$(status_of "$out")" = 400 ] && ok "empty submit rejected (400)" || bad "empty submit: $(status_of "$out")"
[ "$(jget errors.KIOSK_URL <<<"$body")" != "" ] && ok "missing KIOSK_URL flagged" || bad "no KIOSK_URL error: $body"
[ "$(jget errors.HA_LOGIN_METHOD <<<"$body")" != "" ] && ok "missing HA_LOGIN_METHOD flagged" || bad "no HA_LOGIN_METHOD error: $body"

out=$(call POST /setup/api/submit --data '{"KIOSK_URL":"not a url","HA_LOGIN_METHOD":"form"}')
[ "$(status_of "$out")" = 400 ] && ok "bad URL rejected" || bad "bad URL accepted: $out"

LONG=$(python3 -c "print('a'*70)")
out=$(call POST /setup/api/submit --data "{\"KIOSK_URL\":\"https://ha.example.org\",\"HA_LOGIN_METHOD\":\"form\",\"PANEL_NAME\":\"$LONG\"}")
body=$(body_of "$out")
[ "$(jget errors.PANEL_NAME <<<"$body")" != "" ] && ok "overlong PANEL_NAME rejected" || bad "overlong PANEL_NAME accepted: $out"

out=$(call POST /setup/api/submit --data '{"KIOSK_URL":"https://ha.example.org","HA_LOGIN_METHOD":"form","TZ_NAME":"Not A Zone!"}')
body=$(body_of "$out")
[ "$(jget errors.TZ_NAME <<<"$body")" != "" ] && ok "malformed TZ_NAME rejected" || bad "malformed TZ_NAME accepted: $out"

out=$(call POST /setup/api/submit --data '{"KIOSK_URL":"https://ha.example.org","HA_LOGIN_METHOD":"form","ORIENTATION":"sideways"}')
body=$(body_of "$out")
[ "$(jget errors.ORIENTATION <<<"$body")" != "" ] && ok "unknown ORIENTATION rejected" || bad "ORIENTATION sideways accepted: $out"

# shell metacharacters: MQTT_PASSWORD has no character restriction in
# tsx-config's own val_ok, so this must be accepted -- and, critically,
# stored and passed through literally, never executed (subprocess argv
# lists and the helper's own argv-shaped FIFO protocol only, never a shell
# string built from form input).
rm -f "$T/PWNED"
PAYLOAD='$(touch '"$T"'/PWNED); `touch '"$T"'/PWNED2`; ;rm -rf /'
printf '%s' "$PAYLOAD" > "$T/payload.txt"
JSONBODY=$(python3 -c "
import json
print(json.dumps({'KIOSK_URL':'https://ha.example.org','HA_LOGIN_METHOD':'form','MQTT_HOST':'mq.example','MQTT_PASSWORD': open('$T/payload.txt').read()}))
")
out=$(call POST /setup/api/submit --data "$JSONBODY")
[ "$(status_of "$out")" = 200 ] && ok "a value with shell metacharacters is accepted (MQTT_PASSWORD has no charset restriction)" || bad "metacharacter payload rejected unexpectedly: $out"
[ ! -e "$T/PWNED" ] && [ ! -e "$T/PWNED2" ] && ok "the metacharacter payload was never executed by a shell" || bad "the payload WAS executed -- a shell was built from form input"
STORED=$(TSX_CONF="$CONF" busybox sh "$TSXCONFIG" get MQTT_PASSWORD)
[ "$STORED" = "$PAYLOAD" ] && ok "the payload round-trips byte-for-byte through panel.conf" || bad "stored value differs: got [$STORED]"
grep -qF 'PWNED' "$T/setupd.log" && bad "the payload leaked into tsx-setupd's own log" || ok "the payload is not in tsx-setupd's log"
grep -qF 'PWNED' "$T/helper.log" && bad "the payload leaked into tsx-setup-helper's own log" || ok "the payload is not in tsx-setup-helper's log"

# ---- 5. a real submit: writes land in panel.conf, secrets never echoed back
echo "== full submit (token login + root password + ssh key) =="
TOKEN_VAL="abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH"
SSHKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVoZHRlc3RrZXl0ZXN0a2V5dGVzdGtleXRlc3Rr test@laptop"
ROOTPW="a-fairly-long-test-password-123"
SUBMIT=$(python3 -c "
import json
print(json.dumps({
	'KIOSK_URL': 'https://ha.example.org/lovelace/0',
	'HA_LOGIN_METHOD': 'token', 'HA_TOKEN': '$TOKEN_VAL',
	'PANEL_NAME': 'test-panel-1', 'TZ_NAME': 'America/Denver', 'VOICE': 'on', 'WAKE_WORD': 'okay_nabu',
	'ORIENTATION': 'portrait',
	'ROOT_PASSWORD': '$ROOTPW', 'SSH_AUTHORIZED_KEY': '$SSHKEY'
}))
")
out=$(call POST /setup/api/submit --data "$SUBMIT")
[ "$(status_of "$out")" = 200 ] && ok "full submit accepted" || { bad "full submit failed: $out"; }
grep -q '^KIOSK_URL="https://ha.example.org/lovelace/0"$' "$CONF" && ok "KIOSK_URL landed in the temp panel.conf" || bad "KIOSK_URL missing from $CONF"
grep -q '^PANEL_NAME="test-panel-1"$' "$CONF" && ok "PANEL_NAME landed in panel.conf" || bad "PANEL_NAME missing"
grep -q '^ORIENTATION="portrait"$' "$CONF" && ok "ORIENTATION landed in panel.conf" || bad "ORIENTATION missing"
[ "$(cat "$T/prefix/etc/tsx/orientation" 2>/dev/null)" = portrait ] && ok "apply left /etc/tsx/orientation (portrait) in the prefix" || bad "no orientation file after apply"
grep -q '^HA_TOKEN=' "$CONF" && ok "HA_TOKEN was written" || bad "HA_TOKEN missing"
[ -s "$FAKE_CHPASSWD_LOG" ] && grep -qF "root:$ROOTPW" "$FAKE_CHPASSWD_LOG" && ok "chpasswd received the new root password over stdin" || bad "chpasswd did not get the password"
grep -q '^ROOT_PASSWORD_HASH=' "$CONF" && ok "the resulting hash was mirrored into panel.conf (ROOT_PASSWORD_HASH)" || bad "ROOT_PASSWORD_HASH missing from panel.conf"
grep -qF "$ROOTPW" "$CONF" && bad "the plaintext root password ended up in panel.conf" || ok "panel.conf holds the hash, not the plaintext password"
grep -qF "$ROOTPW" "$T/setupd.log" && bad "the root password leaked into tsx-setupd's log" || ok "the root password is not in tsx-setupd's log"
grep -qF "$ROOTPW" "$T/helper.log" && bad "the root password leaked into tsx-setup-helper's log" || ok "the root password is not in tsx-setup-helper's log"
grep -qF "$TOKEN_VAL" "$T/setupd.log" && bad "the HA token leaked into tsx-setupd's log" || ok "the HA token is not in tsx-setupd's log"
grep -qF "$TOKEN_VAL" "$T/helper.log" && bad "the HA token leaked into tsx-setup-helper's log" || ok "the HA token is not in tsx-setup-helper's log"

echo "== state after submit never echoes secrets, but reports them set =="
out=$(call GET /setup/api/state); body=$(body_of "$out")
printf '%s' "$body" | grep -qF "$TOKEN_VAL" && bad "state response echoed the HA token back" || ok "state response never echoes HA_TOKEN"
[ "$(jget fields.HA_TOKEN <<<"$body")" = "" ] && ok "HA_TOKEN value itself is null/empty in the response" || bad "HA_TOKEN value leaked: $body"
[ "$(jget fields.HA_TOKEN__set <<<"$body")" = True ] && ok "HA_TOKEN__set is reported true" || bad "HA_TOKEN__set missing: $body"
[ "$(jget fields.SSH_AUTHORIZED_KEY__set <<<"$body")" = True ] && ok "SSH_AUTHORIZED_KEY__set is reported true" || bad "SSH_AUTHORIZED_KEY__set missing: $body"
[ "$(jget configured <<<"$body")" = True ] && ok "panel now reports configured" || bad "still reports unconfigured: $body"

# rc-service kiosk restart must have been attempted after a successful save
grep -q 'rc-service kiosk status' "$T/rc-service.log" 2>/dev/null && ok "kiosk restart was attempted after saving" || bad "kiosk was never poked after saving"

# ---- 6. disabled once configured: not just a 403, no listening LAN socket at all
echo "== configured + no setup-open flag: not even reachable over the network =="
rm -f "$RUNDIR/setup-open"
# is_configured() is cached for a few seconds (tsx-setupd) and the bind is
# reconciled on a poll of its own: give both a moment.
ok_bind=0
for _ in $(seq 1 20); do
	ss -ltn 2>/dev/null | grep -q "127\.0\.0\.1:$PORT" && { ok_bind=1; break; }
	sleep 0.5
done
[ "$ok_bind" = 1 ] && ok "rebound to loopback-only once configured" || bad "still listening on more than loopback once configured: $(ss -ltn 2>/dev/null | grep ":$PORT" || echo none)"
! ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" && ok "no longer bound to 0.0.0.0" || bad "still bound to 0.0.0.0 once configured"
out=$(call GET /setup/api/state); [ "$(status_of "$out")" = 200 ] && ok "loopback still reachable once configured" || bad "loopback blocked once configured"
if [ -n "$LANIP" ]; then
	out=$(call GET /setup --source "$LANIP")
	[ "$(status_of "$out")" = 0 ] && ok "a simulated LAN client cannot even connect once configured (no listening socket there)" \
		|| bad "LAN connection unexpectedly succeeded once configured: status $(status_of "$out")"
fi

# ---- 7. tsx-config setup re-opens it for one window, then it expires ---
# (fake broken `date` is on PATH for all of this: proves the window uses
# /proc/uptime, not wall-clock time -- docs/rootfs.md "Setup page")
echo "== tsx-config setup (monotonic window; PATH has a deliberately broken date) =="
BEFORE_UPTIME=$(awk '{print int($1)}' /proc/uptime)
PATH="$T/bin:$PATH" TSX_CONF="$CONF" TSX_RUN="$RUNBASE" TSX_APPLY_ALLOW_NONROOT=1 \
	busybox sh "$TSXCONFIG" setup >/dev/null 2>&1
[ -s "$RUNDIR/setup-open" ] && ok "tsx-config setup wrote /run/tsx/setup-open" || bad "setup-open flag missing"
FLAG_VAL=$(cat "$RUNDIR/setup-open")
printf '%s' "$FLAG_VAL" | grep -Eq '^[0-9]+$' && [ "$FLAG_VAL" -ge "$BEFORE_UPTIME" ] \
	&& ok "the flag holds a real /proc/uptime value ($FLAG_VAL), not something derived from the broken date" \
	|| bad "setup-open does not look like /proc/uptime: '$FLAG_VAL' (uptime was ~$BEFORE_UPTIME)"
for _ in $(seq 1 20); do
	ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" && break
	sleep 0.2
done
RESOLVED=$(PATH="$T/bin:$PATH" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$RUNDIR" busybox sh "$KIOSKURL" "https://ha.example.org/lovelace/0")
[ "$RESOLVED" = "http://127.0.0.1:$PORT/setup" ] && ok "tsx-kiosk-url shows the setup page again after tsx-config setup" || bad "tsx-kiosk-url did not reopen setup: $RESOLVED"
if [ -n "$LANIP" ]; then
	out=$(call GET /setup --source "$LANIP")
	[ "$(status_of "$out")" = 200 ] && ok "LAN reachable again during the reopened window" || bad "LAN still refused during the reopened window: $(status_of "$out")"
fi
sleep 7
RESOLVED2=$(PATH="$T/bin:$PATH" TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$RUNDIR" busybox sh "$KIOSKURL" "https://ha.example.org/lovelace/0")
[ "$RESOLVED2" = "https://ha.example.org/lovelace/0" ] && ok "the reopened window expires (tsx-kiosk-url), unaffected by the broken date the whole time" || bad "window did not expire: $RESOLVED2"
for _ in $(seq 1 20); do
	ss -ltn 2>/dev/null | grep -q "127\.0\.0\.1:$PORT" && ! ss -ltn 2>/dev/null | grep -q "0\.0\.0\.0:$PORT" && break
	sleep 0.5
done
if [ -n "$LANIP" ]; then
	out=$(call GET /setup --source "$LANIP")
	[ "$(status_of "$out")" = 0 ] && ok "LAN cannot connect again once the reopened window expired" || bad "LAN still reachable after the window expired: $(status_of "$out")"
fi

# ---- 8. unconfigured trigger, from tsx-kiosk-url's own point of view ----
echo "== tsx-kiosk-url: unconfigured always shows setup =="
R=$(TSX_SETUP_CONF="$T/setup.conf" TSX_RUN_DIR="$RUNDIR" busybox sh "$KIOSKURL" "")
[ "$R" = "http://127.0.0.1:$PORT/setup" ] && ok "empty KIOSK_URL -> setup page" || bad "empty KIOSK_URL did not trigger setup: $R"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo PASS test-setup || echo FAIL test-setup
exit "$F"
