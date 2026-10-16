#!/bin/bash
# Host test: the logins of the installer (installer/lib/tsx-creds.sh). Each
# login comes from a command line option or from its environment variable.
# The option wins. Nothing has a built-in default. A missing login stops the
# script with an error that names the option, before any ssh, sshpass or curl
# call. The test needs no panel and no network: stubs of ssh, sshpass and
# curl record each call.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
DRIVER=$HERE/tsx-install-mainline
W=$(mktemp -d); trap 'rm -rf "$W" "${TSX_CONFIG_STAGE:-}"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
unset TSX_ADMIN_USER TSX_ADMIN_PW TSX_MAINLINE_PW TSX_RESCUE_PW SSHPASS
. "$HERE/lib/tsx-creds.sh"

mkdir -p "$W/bin"
for t in ssh sshpass curl scp; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$t" "$W" > "$W/bin/$t"; chmod +x "$W/bin/$t"
done
calls() { cat "$W/calls" 2>/dev/null; }
nocalls() { [ ! -s "$W/calls" ]; }
reset() { rm -f "$W/calls"; }

echo "== 1. tsx_creds_opt: options and the environment"
OUT=$(TSX_ADMIN_PW=envpw bash -c '. "$1"; tsx_creds_opt --admin-password optpw && echo "$TSX_ADMIN_PW|$TSX_CREDS_SHIFT"' _ "$HERE/lib/tsx-creds.sh")
[ "$OUT" = "optpw|2" ] && ok "--admin-password wins over TSX_ADMIN_PW" || bad "option: '$OUT'"
OUT=$(bash -c '. "$1"; tsx_creds_opt --mainline-password mpw; bash -c "echo \$TSX_MAINLINE_PW"' _ "$HERE/lib/tsx-creds.sh")
[ "$OUT" = mpw ] && ok "the value is exported to child scripts" || bad "export: '$OUT'"
OUT=$(TSX_ADMIN_USER=envuser bash -c '. "$1"; tsx_creds_opt --admin-user optuser; echo "$TSX_ADMIN_USER"' _ "$HERE/lib/tsx-creds.sh")
[ "$OUT" = optuser ] && ok "--admin-user wins over TSX_ADMIN_USER" || bad "user: '$OUT'"
for o in --admin-password-file --mainline-password-file --rescue-password-file; do
	OUT=$(bash -c '. "$1"; tsx_creds_opt "$2" /x; echo went-on' _ "$HERE/lib/tsx-creds.sh" "$o" 2>&1); rc=$?
	[ $rc = 2 ] && case "$OUT" in *"is gone"*"--install-config"*) true;; *) false;; esac && ok "$o is gone: exit 2, names --install-config" || bad "$o: rc $rc $OUT"
done
OUT=$(bash -c '. "$1"; tsx_creds_opt --rescue-password; echo went-on' _ "$HERE/lib/tsx-creds.sh" 2>&1); rc=$?
[ $rc = 2 ] && case "$OUT" in *"needs a value"*) true;; *) false;; esac && ok "an option with no value: exit 2" || bad "no value: rc $rc $OUT"
bash -c '. "$1"; tsx_creds_opt --kernel lts' _ "$HERE/lib/tsx-creds.sh"; [ $? = 1 ] && ok "another option: return 1" || bad "other option"

echo "== 1b. the install config file: the parser"
icload() { bash -c '. "$1"; tsx_install_config_load "$2" && for k in $3; do v=IC_$k; printf "%s=[%s]\n" "$k" "${!v}"; done' _ "$HERE/lib/tsx-creds.sh" "$@" 2>&1; }
{
	printf '# a comment\n\n   # an indented comment\n'
	printf 'PANEL = 192.0.2.10\n'
	printf 'ADMIN_USER="tsx admin"\r\n'
	printf "ADMIN_PASSWORD='p=#\$(touch %s/pwned) x\"y'\n" "$W"
	printf 'MAINLINE_PASSWORD="a=b c"\n'
	printf 'KERNEL=  lts  \n'
	printf 'UART=\n'
} > "$W/ic1.conf"; chmod 600 "$W/ic1.conf"
OUT=$(icload "$W/ic1.conf" "PANEL ADMIN_USER ADMIN_PASSWORD MAINLINE_PASSWORD KERNEL UART STAGE"); rc=$?
EXP="PANEL=[192.0.2.10]
ADMIN_USER=[tsx admin]
ADMIN_PASSWORD=[p=#\$(touch $W/pwned) x\"y]
MAINLINE_PASSWORD=[a=b c]
KERNEL=[lts]
UART=[]
STAGE=[]"
[ $rc = 0 ] && [ "$OUT" = "$EXP" ] && ok "quotes, spaces, '=', '#', a CR, an empty value and a missing key" || bad "parser: rc $rc
$OUT"
[ ! -e "$W/pwned" ] && ok "no shell expansion: the \$(...) in a value never runs" || bad "the file ran as shell code"
printf 'PANEL=x\nPANNEL=y\n' > "$W/ic2.conf"; OUT=$(icload "$W/ic2.conf" PANEL); rc=$?
[ $rc = 2 ] && case "$OUT" in *"line 2: unknown key PANNEL"*) true;; *) false;; esac && ok "an unknown key: exit 2 with the line" || bad "unknown: rc $rc $OUT"
printf 'PANEL=x\nPANEL=y\n' > "$W/ic3.conf"; OUT=$(icload "$W/ic3.conf" PANEL); rc=$?
[ $rc = 2 ] && case "$OUT" in *"two times"*) true;; *) false;; esac && ok "a key two times: exit 2" || bad "dup: rc $rc $OUT"
printf 'export PANEL=x\n' > "$W/ic4.conf"; OUT=$(icload "$W/ic4.conf" PANEL); rc=$?
[ $rc = 2 ] && ok "a line that is not KEY=VALUE: exit 2" || bad "bad line: rc $rc $OUT"
printf 'ADMIN_PASSWORD="x"\n' > "$W/ic5.conf"; chmod 644 "$W/ic5.conf"; OUT=$(icload "$W/ic5.conf" ADMIN_PASSWORD); rc=$?
[ $rc = 2 ] && case "$OUT" in *"holds a password"*"chmod 600"*) true;; *) false;; esac && ok "a password in a file with mode 644: refused, names chmod 600" || bad "mode: rc $rc $OUT"
printf 'PANEL=x\n' > "$W/ic6.conf"; chmod 644 "$W/ic6.conf"; OUT=$(icload "$W/ic6.conf" PANEL); rc=$?
[ $rc = 0 ] && ok "mode 644 with no password: accepted" || bad "no pw mode: rc $rc $OUT"
OUT=$(bash -c '. "$1"; tsx_install_config_write "$2" PANEL=192.0.2.10 ADMIN_PASSWORD="q\"=# \$x" EMPTY= && stat -c %a "$2" && tsx_install_config_load "$2" && echo "[$IC_ADMIN_PASSWORD]"' _ "$HERE/lib/tsx-creds.sh" "$W/ic7.conf" 2>&1)
[ "$OUT" = "600
[q\"=# \$x]" ] && ! grep -q EMPTY "$W/ic7.conf" && ok "write then load: mode 600, the password comes back the same, an empty value is left out" || bad "write: $OUT"

echo "== 2. tsx_creds_need_admin: no default, no prompt without a terminal"
OUT=$(bash -c '. "$1"; tsx_creds_need_admin 1; echo "rc=$?"' _ "$HERE/lib/tsx-creds.sh" </dev/null 2>&1)
case "$OUT" in *"--admin-user USER"*"rc=2") ok "no user: names --admin-user, rc 2";; *) bad "no user: $OUT";; esac
OUT=$(TSX_ADMIN_USER=u bash -c '. "$1"; tsx_creds_need_admin 1; echo "rc=$?"' _ "$HERE/lib/tsx-creds.sh" </dev/null 2>&1)
case "$OUT" in *"ADMIN_PASSWORD in the install config file"*"--admin-password PW"*"rc=2") ok "no password: names ADMIN_PASSWORD and --admin-password, rc 2";; *) bad "no password: $OUT";; esac
OUT=$(TSX_ADMIN_USER='a b' TSX_ADMIN_PW=p bash -c '. "$1"; tsx_creds_need_admin 0; echo "rc=$?"' _ "$HERE/lib/tsx-creds.sh" 2>&1)
case "$OUT" in *"rc=2") ok "a user name with a space is refused";; *) bad "user check: $OUT";; esac
SCRIPTS=$(find "$HERE/tsx-install-mainline" "$HERE/tsx-restore-factory" "$HERE/steps" "$HERE/lib" -type f ! -name '*.md')
# shellcheck disable=SC2086
if grep -nE '(ADMIN_USER|ADMIN_PW|_PW):-[^}$]' $SCRIPTS; then bad "a default for a login is still there"; else ok "no default for a login in the scripts"; fi
# shellcheck disable=SC2086
if grep -nE 'sshpass -p' $SCRIPTS; then bad "a password on an sshpass command line"; else ok "no sshpass -p: the passwords go in SSHPASS"; fi

echo "== 3. tsx-install-mainline: the stop before any contact"
mkdir -p "$W/p/lts"
echo r > "$W/p/rescue.img"; echo root > "$W/p/lts/root.img"; echo boot > "$W/p/lts/boot.img"
printf 'format=tsx-rescue-install-1\nkernel_flavor=lts\nroot_bytes=5\nroot_sha256=%s\nboot_sha256=%s\n' \
	"$(sha256sum < "$W/p/lts/root.img" | cut -d' ' -f1)" "$(sha256sum < "$W/p/lts/boot.img" | cut -d' ' -f1)" > "$W/p/lts/manifest"
(cd "$W/p/lts" && sha256sum root.img boot.img > SHA256SUMS)
drv() { PATH="$W/bin:$PATH" TSX_PANEL_KIND=${KIND:-android} "$DRIVER" 192.0.2.10 --payload "$W/p" --kernel lts "$@" </dev/null 2>&1; }
reset; OUT=$(drv --dry-run --results "$W/r1.txt"); rc=$?
[ $rc != 0 ] && case "$OUT" in *"--admin-user USER"*"Nothing was changed"*) true;; *) false;; esac && ok "stock Android, no login: stops, names --admin-user" || bad "no login: rc $rc $OUT"
nocalls && ok "no ssh, sshpass or curl call before the stop" || bad "calls: $(calls)"
reset; OUT=$(drv --yes --results "$W/r2.txt" --admin-user optadmin); rc=$?
[ $rc != 0 ] && case "$OUT" in *"ADMIN_PASSWORD in the install config file"*) true;; *) false;; esac && nocalls && ok "a real run (--yes) with a user and no password: stops, no contact" || bad "no password: rc $rc $OUT $(calls)"
reset; OUT=$(drv --yes --results "$W/r2b.txt" --install-config "$W/nofile"); rc=$?
[ $rc = 2 ] && nocalls && ok "an unreadable install config file: exit 2 before anything" || bad "nofile: rc $rc $OUT"
reset; OUT=$(drv --yes --results "$W/r2c.txt" --install-config "$W/ic5.conf"); rc=$?
[ $rc = 2 ] && nocalls && case "$OUT" in *"chmod 600"*) true;; *) false;; esac && ok "the installer refuses a readable install config with a password" || bad "mode: rc $rc $OUT"
OUT=$(TSX_ADMIN_USER=envadmin TSX_ADMIN_PW=envpw77 drv --dry-run --results "$W/r3.txt"); rc=$?
[ $rc = 0 ] && case "$OUT" in *"Crestron admin login: user envadmin"*) true;; *) false;; esac && ok "the environment alone works (automation)" || bad "env: rc $rc $OUT"
printf 'ADMIN_USER=fileadmin\nADMIN_PASSWORD="filepw2"\nKERNEL=lts\n' > "$W/icp.conf"; chmod 600 "$W/icp.conf"
OUT=$(TSX_ADMIN_USER=envadmin TSX_ADMIN_PW=envpw77 drv --dry-run --results "$W/r4.txt" --admin-user optadmin --install-config "$W/icp.conf"); rc=$?
[ $rc = 0 ] && case "$OUT" in *"user optadmin"*) true;; *) false;; esac && ok "option > environment > file: --admin-user wins" || bad "option wins: rc $rc $OUT"
OUT=$(TSX_ADMIN_USER=envadmin drv --dry-run --results "$W/r4b.txt" --install-config "$W/icp.conf"); rc=$?
[ $rc = 0 ] && case "$OUT" in *"user envadmin"*) true;; *) false;; esac && ok "option > environment > file: TSX_ADMIN_USER wins over the file" || bad "env wins: rc $rc $OUT"
OUT=$(drv --dry-run --results "$W/r4c.txt" --install-config "$W/icp.conf"); rc=$?
[ $rc = 0 ] && case "$OUT" in *"user fileadmin"*) true;; *) false;; esac && ok "the install config file alone gives the login" || bad "file: rc $rc $OUT"
printf 'PANEL=192.0.2.44\nPAYLOAD="%s"\nKERNEL=lts\nADMIN_USER=a\nADMIN_PASSWORD=b\n' "$W/p" > "$W/icq.conf"; chmod 600 "$W/icq.conf"
OUT=$(PATH="$W/bin:$PATH" TSX_PANEL_KIND=android "$DRIVER" --install-config "$W/icq.conf" --dry-run --results "$W/r4d.txt" </dev/null 2>&1); rc=$?
[ $rc = 0 ] && case "$OUT" in *"PANEL=192.0.2.44 PAYLOAD=$W/p KERNEL=lts"*) true;; *) false;; esac && ok "PANEL, PAYLOAD and KERNEL from the file, no other argument" || bad "file run: rc $rc $OUT"
OUT=$(PATH="$W/bin:$PATH" TSX_PANEL_KIND=android "$DRIVER" --dry-run --results "$W/r4e.txt" </dev/null 2>&1); rc=$?
[ $rc = 2 ] && case "$OUT" in *"panel address is missing"*"PANEL in the install config file"*) true;; *) false;; esac && ok "no panel and no terminal: exit 2, names PANEL" || bad "no panel: rc $rc $OUT"
grep -q -e envpw77 -e filepw2 "$W"/r3.txt "$W"/r4*.txt && bad "a password is in the results file" || ok "no password in the results files"
OUT=$(KIND=mainline drv --dry-run --yes --results "$W/r5.txt"); rc=$?
case "$OUT" in *"admin login"*) bad "a reinstall asks for the Crestron login";; *) ok "a reinstall (mainline) needs no Crestron login";; esac
reset; OUT=$(KIND=rescue-locked drv --yes --results "$W/r6.txt"); rc=$?
[ $rc != 0 ] && nocalls && case "$OUT" in *"runs the rescue, and it takes none of the logins"*"RESCUE_PASSWORD"*) true;; *) false;; esac \
	&& ok "a rescue that asks for its one-time password: stops at once and names RESCUE_PASSWORD" || bad "rescue-locked: rc $rc $OUT $(calls)"
OUT=$("$DRIVER" --help 2>&1)
case "$OUT" in *"REQUIREMENT"*"rootsh method"*"--install-config FILE"*"option wins over its environment variable"*"--admin-password PW"*"process list"*"install config file (mode 600)"*) ok "--help shows the rule, the options, the file and the warning";; *) bad "--help: $OUT";; esac
OUT=$(drv --stage-wait soon --admin-user a --admin-password x 2>&1); rc=$?
[ $rc = 2 ] && ok "--stage-wait takes only seconds" || bad "stage-wait: rc $rc"

echo "== 4. the steps: the same stop"
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/crestron-admin" 192.0.2.10 </dev/null 2>&1); rc=$?
[ $rc = 2 ] && nocalls && case "$OUT" in *"--admin-user"*) true;; *) false;; esac && ok "crestron-admin: exit 2, no curl or ssh call" || bad "crestron-admin: rc $rc $OUT $(calls)"
printf '#!/bin/sh\necho "curl $*" >> "%s/calls"\necho '"'"'{"Device":{"Authentication":{"AuthenticationState":{"IsEnabled":false},"LocalUsers":[]}}}'"'"'\n' "$W" > "$W/bin/curl"
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/crestron-admin" --status 192.0.2.10 2>&1); rc=$?
[ $rc = 0 ] && [ "$OUT" = none ] && ok "crestron-admin --status needs no login" || bad "--status: rc $rc $OUT"
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/rootsh" 192.0.2.10 id 2>&1); rc=$?
[ $rc = 2 ] && nocalls && ok "rootsh: exit 2, no ssh call" || bad "rootsh: rc $rc $OUT $(calls)"
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/rootsh" --admin-user u --admin-password pw2 192.0.2.10 id 2>&1)
grep -q '^sshpass -e ssh .* u@192.0.2.10 rootsh' "$W/calls" && ok "rootsh: the options give the login, sshpass -e" || bad "rootsh options: $(calls)"
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/tsx-ensure-root" 192.0.2.10 --uart no --results "$W/er.txt" </dev/null 2>&1); rc=$?
[ $rc = 2 ] && nocalls && ok "tsx-ensure-root: exit 2, no contact" || bad "ensure-root: rc $rc $OUT $(calls)"
OUT=$("$HERE/tsx-restore-factory" --help 2>&1)
case "$OUT" in *"--install-config FILE"*"--admin-password PW"*"--rescue-password PW"*) ok "tsx-restore-factory --help shows the login options and --install-config";; *) bad "restore --help";; esac
OUT=$("$HERE/tsx-restore-factory" --install-config "$W/ic5.conf" 2>&1); rc=$?
[ $rc = 2 ] && case "$OUT" in *"chmod 600"*) true;; *) false;; esac && ok "tsx-restore-factory refuses a readable install config with a password" || bad "restore mode: rc $rc $OUT"
OUT=$(PATH="$W/bin:$PATH" "$HERE/tsx-restore-factory" --install-config "$W/icq.conf" --bundle "$W/nobundle" --dry-run --uart no --results "$W/rf.txt" 2>&1); rc=$?
case "$OUT" in *"PANEL=192.0.2.44"*) ok "tsx-restore-factory reads the same file and ignores the keys it does not use (PAYLOAD, KERNEL)";; *) bad "restore file: rc $rc $OUT";; esac

echo "== 5. on a terminal: the prompts, then the install config file (fake tty)"
cat > "$W/faketerm.py" <<'PY'
import os, pty, sys, time
argv = sys.argv[1:]
answers = [("Panel address", "192.0.2.55"), ("Kernel flavor", "lts"), ("Crestron admin user", "ttyadmin"),
           ("Crestron admin password:", 'p w"=#$x'), ("password again", 'p w"=#$x'), ("Save these answers", os.environ["SAVE_TO"])]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
buf, i, t0 = b"", 0, time.time()
while time.time() - t0 < 120:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
    if i < len(answers) and answers[i][0].encode() in buf.split(b"\n")[-1] + buf[-200:]:
        os.write(fd, (answers[i][1] + "\n").encode()); i += 1; buf = b""
_, st = os.waitpid(pid, 0)
print("ANSWERED=%d RC=%d" % (i, os.waitstatus_to_exitcode(st)))
PY
OUT=$(SAVE_TO="$W/saved.conf" TSX_TEST_STOP_AFTER_SAVE=1 PATH="$W/bin:$PATH" TSX_PANEL_KIND=android python3 "$W/faketerm.py" "$DRIVER" --payload "$W/p" --results "$W/r7.txt" 2>&1)
case "$OUT" in *"ANSWERED=6 RC=0"*) ok "the six prompts were answered and the run stopped after the save (test hook)";; *) bad "tty run: $(printf '%s' "$OUT" | tail -n 5)";; esac
[ "$(stat -c %a "$W/saved.conf" 2>/dev/null)" = 600 ] && ok "the saved file has mode 600" || bad "mode of the saved file: $(stat -c %a "$W/saved.conf" 2>&1)"
OUT=$(icload "$W/saved.conf" "PANEL KERNEL ADMIN_USER ADMIN_PASSWORD PAYLOAD"); rc=$?
[ $rc = 0 ] && [ "$OUT" = "PANEL=[192.0.2.55]
KERNEL=[lts]
ADMIN_USER=[ttyadmin]
ADMIN_PASSWORD=[p w\"=#\$x]
PAYLOAD=[$W/p]" ] && ok "the saved file loads back: panel, kernel, login and the payload path" || bad "saved: rc $rc $OUT"
reset; OUT=$(PATH="$W/bin:$PATH" TSX_PANEL_KIND=android "$DRIVER" --install-config "$W/saved.conf" --dry-run --results "$W/r8.txt" </dev/null 2>&1); rc=$?
[ $rc = 0 ] && case "$OUT" in *"PANEL=192.0.2.55"*"user ttyadmin"*) true;; *) false;; esac && nocalls && ok "the next run needs only --install-config" || bad "rerun: rc $rc $OUT"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-creds || echo FAIL test-install-creds
exit $F
