#!/bin/bash
# Host test: provision/panel-provision.sh has no default password. It logs in with
# your ssh key, your ssh agent, or a password file (sshpass -f). It prints a
# preflight (panel, login method, HA URL) and tests the login before it writes
# anything. It needs no panel and no network (stub ssh and sshpass).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-provision.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
bash -n "$SRC" && busybox sh -n "$SRC" && ok "panel-provision.sh passes sh -n" || bad "syntax"
grep -q 'sshpass -p' "$SRC" && bad "sshpass -p (password on the command line) in the script" || ok "no password on a command line in the script"
grep -qw 'tsx$\|-p tsx' "$SRC" && bad "the tsx password is still in the script" || ok "no fixed password in the script"
mkdir -p "$W/bin" "$W/prov/secrets" "$W/home" "$W/.ssh-empty"
cp "$SRC" "$W/prov/panel-provision.sh"
for f in ha-token kiosk-token tsw1060.password; do echo secretvalue > "$W/prov/secrets/$f"; done
cat > "$W/bin/ssh" <<'STUB'
#!/bin/sh
echo "ssh $*" >> "$W_LOG"
exit "${STUB_SSH_RC:-0}"
STUB
cat > "$W/bin/sshpass" <<'STUB'
#!/bin/sh
echo "sshpass $*" >> "$W_LOG"
[ "$1" = -f ] && [ -s "$2" ] || exit 9
shift 2
exec ssh "$@"
STUB
cat > "$W/bin/ssh-add" <<'STUB'
#!/bin/sh
exit "${STUB_AGENT_RC:-1}"
STUB
chmod +x "$W/bin/"* "$W/prov/panel-provision.sh"
echo secret-root-pw > "$W/pw"; : > "$W/emptypw"; echo key > "$W/key"
export W_LOG=$W/log
run() { PATH="$W/bin:$PATH" HOME="$W/home" env -u SSH_AUTH_SOCK -u PANEL_IP -u HA_URL -u PANEL_PASSWORD_FILE "$@"; }
P=$W/prov/panel-provision.sh
BASE=(--panel 192.0.2.9 --ha-url https://ha.test --light light.t)

echo "== missing login: stops before any ssh =="
: > "$W_LOG"
OUT=$(run "$P" "${BASE[@]}" 2>&1); RC=$?
[ $RC = 2 ] && ok "exit code 2" || bad "exit code $RC"
echo "$OUT" | grep -q 'no login for root@192.0.2.9' && echo "$OUT" | grep -q -- '--password-file' && echo "$OUT" | grep -q -- '--key' && ok "the message says what to give" || bad "message: $OUT"
echo "$OUT" | grep -q 'changed nothing' && ok "the message says that nothing changed" || bad "no 'changed nothing'"
[ ! -s "$W_LOG" ] && ok "no ssh call" || bad "ssh called: $(cat "$W_LOG")"

echo "== required arguments =="
for miss in --panel --ha-url --light; do
	args=(); set -- "${BASE[@]}"
	while [ $# -gt 0 ]; do [ "$1" = "$miss" ] && { shift 2; continue; }; args+=("$1"); shift; done
	OUT=$(run "$P" "${args[@]}" --key "$W/key" 2>&1); RC=$?
	[ $RC = 2 ] && echo "$OUT" | grep -q "^ERROR: no " && ok "missing $miss: clear error, exit 2" || bad "missing $miss: rc $RC $OUT"
done
OUT=$(run "$P" "${BASE[@]}" --key "$W/key" --password-file "$W/pw" 2>&1); [ $? = 2 ] && ok "key and password file together: refused" || bad "both given: $OUT"
OUT=$(run "$P" "${BASE[@]}" --password-file "$W/emptypw" 2>&1); [ $? = 2 ] && ok "empty password file: refused" || bad "empty pw: $OUT"
OUT=$(run "$P" "${BASE[@]}" --key "$W/nokey" 2>&1); [ $? = 2 ] && ok "unreadable key: refused" || bad "no key file: $OUT"

echo "== key login =="
: > "$W_LOG"
OUT=$(run "$P" "${BASE[@]}" --key "$W/key" --check 2>&1); RC=$?
[ $RC = 0 ] && ok "--check exits 0" || bad "rc $RC: $OUT"
grep -q -- "-i $W/key" "$W_LOG" && grep -q 'BatchMode=yes' "$W_LOG" && ok "ssh -i KEY with BatchMode" || bad "ssh log: $(cat "$W_LOG")"
grep -q sshpass "$W_LOG" && bad "sshpass used with a key" || ok "no sshpass with a key"

echo "== agent login =="
: > "$W_LOG"
OUT=$(PATH="$W/bin:$PATH" HOME="$W/home" SSH_AUTH_SOCK=/x STUB_AGENT_RC=0 "$P" "${BASE[@]}" --check 2>&1); RC=$?
echo "$OUT" | grep -q 'login:       root, ssh agent' && [ $RC = 0 ] && ok "agent is used" || bad "agent: rc $RC $OUT"
grep -q -- ' -i ' "$W_LOG" && bad "-i with the agent" || ok "no -i with the agent"
: > "$W_LOG"; mkdir -p "$W/home/.ssh"; touch "$W/home/.ssh/id_ed25519"
OUT=$(run "$P" "${BASE[@]}" --check 2>&1); RC=$?
echo "$OUT" | grep -q 'default keys' && [ $RC = 0 ] && ok "default ~/.ssh key is used" || bad "default key: rc $RC $OUT"

echo "== password file =="
: > "$W_LOG"
OUT=$(run "$P" "${BASE[@]}" --password-file "$W/pw" --check 2>&1); RC=$?
[ $RC = 0 ] && ok "--check exits 0" || bad "rc $RC: $OUT"
grep -q "sshpass -f $W/pw ssh" "$W_LOG" && ok "sshpass -f FILE" || bad "log: $(cat "$W_LOG")"
grep -q secret-root-pw "$W_LOG" && bad "the password is in a command line" || ok "the password is not in any command line"
echo "$OUT" | grep -q secret-root-pw && bad "the password was printed" || ok "the password is not printed"
: > "$W_LOG"
run PANEL_PASSWORD_FILE="$W/pw" "$P" "${BASE[@]}" --check >/dev/null 2>&1
grep -q "sshpass -f $W/pw" "$W_LOG" && ok "PANEL_PASSWORD_FILE works" || bad "env file: $(cat "$W_LOG")"

echo "== preflight =="
OUT=$(run "$P" "${BASE[@]}" --key "$W/key" --broker mq.test --check 2>&1)
for want in 'panel:       192.0.2.9' "login:       root, ssh key $W/key" 'HA URL:      https://ha.test' 'dashboard:   https://ha.test/tsw-1060/home' 'light:       light.t' 'host mq.test' 'login test:  ok' 'nothing written'; do
	echo "$OUT" | grep -qF "$want" && ok "preflight shows: $want" || bad "preflight lacks '$want': $OUT"
done
: > "$W_LOG"
run "$P" "${BASE[@]}" --key "$W/key" --check >/dev/null 2>&1
[ "$(wc -l < "$W_LOG" | tr -d ' ')" = 1 ] && ok "--check makes one ssh call (the login test) and writes nothing" || bad "--check ssh calls: $(cat "$W_LOG")"

echo "== login fails: nothing is written =="
: > "$W_LOG"
OUT=$(STUB_SSH_RC=255 run "$P" "${BASE[@]}" --key "$W/key" --no-verify 2>&1); RC=$?
[ $RC = 1 ] && echo "$OUT" | grep -q 'cannot log in to root@192.0.2.9' && echo "$OUT" | grep -q 'changed nothing' && ok "clear error, exit 1" || bad "rc $RC $OUT"
[ "$(wc -l < "$W_LOG" | tr -d ' ')" = 1 ] && ok "only the login test ran" || bad "ssh calls: $(cat "$W_LOG")"

echo "== full run, no verify =="
: > "$W_LOG"
OUT=$(run "$P" "${BASE[@]}" --key "$W/key" --no-verify 2>&1); RC=$?
[ $RC = 0 ] && echo "$OUT" | grep -q 'done (no verification)' && ok "all six steps run" || bad "rc $RC $OUT"
grep -q 'HA_URL=https://ha.test' "$W_LOG" && grep -q 'KIOSK_URL' "$W_LOG" && grep -q '/etc/tsx/ha-token' "$W_LOG" && ok "ha-token, HA_URL and KIOSK_URL are written" || bad "writes: $(cat "$W_LOG")"
echo "$OUT" | grep -q secretvalue && bad "a secret was printed" || ok "no secret printed"
echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-panel-provision-login || echo FAIL test-panel-provision-login
exit $F
