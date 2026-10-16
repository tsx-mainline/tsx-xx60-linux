#!/bin/bash
# Host test: installer/steps/legacy/tsx-card-to-emmc has no fixed password. It uses
# your SSH key, or the root password of --mainline-password (or
# TSX_MAINLINE_PW, the option wins), and it stops before it
# changes anything when it has no login. It needs no panel, no compiler and
# no network (stub ssh and sshpass).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
S=$HERE/steps/legacy/tsx-card-to-emmc
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
bash -n "$S" && ok "tsx-card-to-emmc passes bash -n" || bad "bash -n"
grep -q 'sshpass -p tsx' "$S" && bad "a fixed password is still in tsx-card-to-emmc" || ok "no fixed password in tsx-card-to-emmc"
mkdir -p "$W/bin"; echo img > "$W/img"
cat > "$W/bin/ssh" <<'STUB'
#!/bin/sh
echo "ssh $*" >> "$W_LOG"
exit "${STUB_SSH_RC:-1}"
STUB
cat > "$W/bin/sshpass" <<'STUB'
#!/bin/sh
echo "sshpass $* SSHPASS=${SSHPASS:-}" >> "$W_LOG"
exit "${STUB_SSH_RC:-1}"
STUB
chmod +x "$W/bin/ssh" "$W/bin/sshpass"
export W_LOG=$W/log
echo "== no login: the script stops =="
: > "$W_LOG"
OUT=$(PATH="$W/bin:$PATH" "$S" 192.0.2.9 --img "$W/img" --results "$W/r1.txt" 2>&1); RC=$?
[ $RC != 0 ] && ok "no login: exit code is not 0" || bad "no login: the script went on"
echo "$OUT" | grep -q "no fixed password" && echo "$OUT" | grep -q -- "--mainline-password PW" && ok "the message says what to give" || bad "message: $OUT"
echo "$OUT" | grep -q "changed nothing" && ok "the message says that nothing changed" || bad "no 'changed nothing'"
[ "$(wc -l < "$W_LOG" | tr -d ' ')" = 1 ] && grep -q 'BatchMode=yes' "$W_LOG" && ok "one ssh try with the key, no password prompt" || bad "ssh log: $(cat "$W_LOG")"
grep -q sshpass "$W_LOG" && bad "sshpass used with no password" || ok "no sshpass without TSX_MAINLINE_PW"
echo "== TSX_MAINLINE_PW: sshpass -e =="
: > "$W_LOG"
OUT=$(PATH="$W/bin:$PATH" TSX_MAINLINE_PW=testpw12 "$S" 192.0.2.9 --img "$W/img" --results "$W/r2.txt" 2>&1)
grep -q 'sshpass -e ssh' "$W_LOG" && grep -q 'SSHPASS=testpw12' "$W_LOG" && ok "the password goes in the environment" || bad "password call: $(cat "$W_LOG")"
grep -q -- '-p testpw12' "$W_LOG" && bad "the password is on the command line" || ok "the password is not on the command line"
echo "== --mainline-password: the option wins over TSX_MAINLINE_PW =="
: > "$W_LOG"
OUT=$(PATH="$W/bin:$PATH" TSX_MAINLINE_PW=envpw56 "$S" 192.0.2.9 --mainline-password optpw34 --img "$W/img" --results "$W/r4.txt" 2>&1)
grep -q 'SSHPASS=optpw34' "$W_LOG" && ! grep -q envpw56 "$W_LOG" && ok "the password of the option is used, not the environment" || bad "option over env: $(cat "$W_LOG")"
OUT=$(PATH="$W/bin:$PATH" "$S" 192.0.2.9 --mainline-password-file "$W/nofile" --img "$W/img" --results "$W/r5.txt" 2>&1); RC=$?
[ $RC = 2 ] && echo "$OUT" | grep -q "is gone" && ok "the old -file option: exit 2" || bad "old option: rc $RC $OUT"
echo "== dry run needs no login =="
: > "$W_LOG"
PATH="$W/bin:$PATH" "$S" 192.0.2.9 --img "$W/img" --dry-run --results "$W/r3.txt" >/dev/null 2>&1
grep -q 'no login to' "$W/r3.txt" && bad "dry run stopped for no login" || ok "dry run does not stop for the login"
echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-card-to-emmc-login || echo FAIL test-card-to-emmc-login
exit $F
