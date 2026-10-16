#!/bin/bash
# Host test: the network-only root step on stock Android
# (installer/steps/tsx-ensure-root --uart no with installer/steps/crestron-admin
# and installer/steps/rootsh). Stubs replace curl (the web UI of the panel)
# and sshpass (the Crestron sshd: the console, and the rootsh command when the
# panel has it). No panel, no network.
#   1. a panel as Crestron ships it (no rootsh command): the step creates the
#      account, the console login works, rootsh gives no root. The step stops
#      after two polls with an error that names the cause. Before, it waited
#      720 s and said "crestron-admin did not confirm console login yet".
#   2. a panel with the rootsh command: the account, root, Android settled.
#   3. an account with another password: one failed login, then a stop.
#   4. the panel refuses the account: one request, the answer on the screen,
#      a stop.
#   5. the request body is JSON for any password, and the password is on no
#      command line.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
S=$HERE/steps/tsx-ensure-root
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
export W
unset TSX_MAINLINE_PW SSHPASS

mkdir -p "$W/bin"
cat > "$W/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$W/calls"
case " $* " in
*" --data-binary @- "*)
	cat > "$W/post.json"; echo post >> "$W/posts"
	if [ "${REFUSE:-0}" = 1 ]; then echo '{"StatusId":1,"ErrorMessage":"The password does not meet the rules"}'
	else touch "$W/account"; echo '{"StatusId":0,"ErrorMessage":"Authentication enabled successfully"}'; fi;;
*Device/Authentication*)
	if [ -e "$W/account" ]; then echo '{"Device":{"Authentication":{"AuthenticationState":{"IsEnabled":true},"LocalUsers":[{"Name":"x"}]}}}'
	else echo '{"Device":{"Authentication":{"AuthenticationState":{"IsEnabled":false},"LocalUsers":[]}}}'; fi;;
esac
exit 0
EOF
cat > "$W/bin/sshpass" <<'EOF'
#!/bin/bash
# sshpass -e ssh -tt [options] USER@HOST [rootsh]
echo "sshpass $*" >> "$W/calls"
[ "${SSHPASS:-}" = "$GOODPW" ] || { cat > /dev/null; echo "Permission denied, please try again."; exit 5; }
case " $* " in
*" rootsh "*)
	if [ "${PATCHED:-0}" = 1 ]; then
		IFS= read -r line; cat > /dev/null
		case "$line" in
		*"BEGIN; id;"*) r="uid=0(root) gid=0(root)";;
		*fw_printenv*) r="fwUpgrade=0";;
		*"ls /mnt"*) r="ls: /mnt/sdcard/ROMDISK/romdisk/user/system/image: No such file or directory";;
		*getprop*|*"grep -c"*) r=1;;
		*) r=;;
		esac
		printf '%s\r\n\r\n__RS_BEGIN__\r\n%s\r\n\r\n__RS_END=0__\r\n' "$line" "$r"
	else
		# the stock sshShell.sh: the console reads the lines as console commands
		cat > /dev/null; printf 'TSS-10>Bad or Incomplete Command\r\n'
	fi;;
*)	cat > /dev/null; printf 'TSS-10>ver\r\nTSS-10 Cntrl Eng [v3.002.1061 (Sep 01 2026), #00000000]\r\n';;
esac
exit 0
EOF
printf '#!/bin/sh\necho "ssh $*" >> "$W/calls"\nexit 1\n' > "$W/bin/ssh"
chmod +x "$W/bin/curl" "$W/bin/sshpass" "$W/bin/ssh"
printf 'good"pw\\x\n' > "$W/pw"   # a quote and a backslash
GOOD='good"pw\x'

run() {   # run NAME [ENV...]: tsx-ensure-root --uart no against the stubs
	local name=$1; shift
	rm -f "$W/calls" "$W/posts" "$W/post.json"
	OUT=$(env PATH="$W/bin:$PATH" TSX_ROOT_POLL_S=1 TSX_ADMIN_POLL_S=0 GOODPW="$GOOD" "$@" \
		timeout 300 "$S" 192.0.2.10 --uart no --ws-ip 192.0.2.1 --results "$W/$name.txt" \
		--admin-user tsxadmin --admin-password-file "$W/pw" </dev/null 2>&1); RC=$?
}
count() { grep -c -- "$1" "$W/calls" 2>/dev/null || true; }

echo "== 1. a panel as Crestron ships it: no rootsh command"
rm -f "$W/account"; t0=$SECONDS
run stock
[ $RC != 0 ] && case "$OUT" in *"accepts the login of tsxadmin, but"*"gives no root shell"*"REQUIRES this method"*'Root over the Crestron sshd'*"--uart yes --sshshell FILE"*) true;; *) false;; esac \
	&& ok "it stops and names the requirement, the docs section and the UART way" || bad "rc $RC: $OUT"
[ $((SECONDS - t0)) -lt 60 ] && ok "it stops after two polls ($((SECONDS - t0)) s), not after the 720 s timeout" || bad "took $((SECONDS - t0)) s"
case "$OUT" in *"crestron-admin: answer: {\"StatusId\":0"*"crestron-admin: ok: console login tsxadmin works"*) ok "the lines of crestron-admin show on the screen";; *) bad "crestron-admin lines missing: $OUT";; esac
[ "$(count ' rootsh')" = 2 ] && ok "two rootsh tries" || bad "rootsh tries: $(count ' rootsh')"
[ "$(cat "$W/posts" 2>/dev/null | wc -l)" = 1 ] && ok "one account request" || bad "posts: $(cat "$W/posts" 2>/dev/null)"

echo "== 2. a panel with the rootsh command (restored by tsx-restore-factory)"
rm -f "$W/account"
run patched PATCHED=1
[ $RC = 0 ] && case "$OUT" in *"ok: Android settled (network-only)"*"== done: rootsh already answers uid=0"*) true;; *) false;; esac \
	&& ok "account, root, Android settled: rc 0" || bad "rc $RC: $OUT"
[ "$(cat "$W/posts" 2>/dev/null | wc -l)" = 1 ] && [ "$(count 'tsxadmin@192.0.2.10$')" = 1 ] && ok "one account request, one console login" || bad "calls: $(cat "$W/calls")"

echo "== 3. an account that exists with another password"
touch "$W/account"
run wrongpw GOODPW=other
[ $RC != 0 ] && case "$OUT" in *"refused the password of tsxadmin"*"refused the login of tsxadmin"*) true;; *) false;; esac \
	&& ok "it stops at the refused login" || bad "rc $RC: $OUT"
[ "$(count '^sshpass')" = 1 ] && ok "exactly one failed login (the sshd blocks a host after 3)" || bad "logins: $(count '^sshpass')"

echo "== 4. the panel refuses the account"
rm -f "$W/account"
run refuse REFUSE=1
[ $RC != 0 ] && case "$OUT" in *"answer: {\"StatusId\":1,\"ErrorMessage\":\"The password does not meet the rules\"}"*"refused to create the Crestron account"*) true;; *) false;; esac \
	&& ok "the answer of the panel shows, then a stop" || bad "rc $RC: $OUT"
[ "$(cat "$W/posts" 2>/dev/null | wc -l)" = 1 ] && [ "$(count '^sshpass')" = 0 ] && ok "one request, no login" || bad "calls: $(cat "$W/calls")"

echo "== 5. the request: JSON, no password on a command line"
rm -f "$W/account"
run json PATCHED=1
python3 -c 'import json, sys; a = json.load(open(sys.argv[1]))["Device"]["Authentication"]["AuthenticationState"]; sys.exit(0 if a == {"AdminUsername": "tsxadmin", "AdminPassword": sys.argv[2], "IsEnabled": True} else 1)' "$W/post.json" "$GOOD" \
	&& ok "the body is valid JSON with the exact password (quote and backslash)" || bad "body: $(cat "$W/post.json")"
grep -qF 'pw\x' "$W/calls" && bad "the password is on a command line: $(grep -F 'pw\x' "$W/calls")" || ok "no command line holds the password"
grep -qF 'pw\x' "$W"/*.txt && bad "the password is in a results file" || ok "no results file holds the password"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-ensure-root-net || echo FAIL test-ensure-root-net
exit $F
