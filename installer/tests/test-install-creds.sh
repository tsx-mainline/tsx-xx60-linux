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

echo "== 1. tsx_creds_opt: options, files, the environment"
printf 'filepw1\r\nsecond line\n' > "$W/pw1"; printf 'filepw2' > "$W/pw2"; : > "$W/empty"
OUT=$(TSX_ADMIN_PW=envpw bash -c '. "$1"; tsx_creds_opt --admin-password-file "$2" && echo "$TSX_ADMIN_PW|$TSX_CREDS_SHIFT"' _ "$HERE/lib/tsx-creds.sh" "$W/pw1")
[ "$OUT" = "filepw1|2" ] && ok "the file wins over TSX_ADMIN_PW, first line, no CR" || bad "file: '$OUT'"
OUT=$(bash -c '. "$1"; tsx_creds_opt --mainline-password-file "$2"; bash -c "echo \$TSX_MAINLINE_PW"' _ "$HERE/lib/tsx-creds.sh" "$W/pw2")
[ "$OUT" = filepw2 ] && ok "a file with no newline, and the value is exported to child scripts" || bad "export: '$OUT'"
OUT=$(TSX_ADMIN_USER=envuser bash -c '. "$1"; tsx_creds_opt --admin-user optuser; echo "$TSX_ADMIN_USER"' _ "$HERE/lib/tsx-creds.sh")
[ "$OUT" = optuser ] && ok "--admin-user wins over TSX_ADMIN_USER" || bad "user: '$OUT'"
for c in "--admin-password-file $W/nofile:cannot read" "--admin-password-file $W/empty:empty" "--rescue-password-file:needs a value"; do
	set -- ${c%%:*}
	OUT=$(bash -c '. "$1"; shift; tsx_creds_opt "$@"; echo went-on' _ "$HERE/lib/tsx-creds.sh" "$@" 2>&1); rc=$?
	[ $rc = 2 ] && case "$OUT" in *"${c#*:}"*) true;; *) false;; esac && ok "$1 ${2:-}: exit 2 ($OUT)" || bad "$c: rc $rc '$OUT'"
done
bash -c '. "$1"; tsx_creds_opt --kernel lts' _ "$HERE/lib/tsx-creds.sh"; [ $? = 1 ] && ok "another option: return 1" || bad "other option"

echo "== 2. tsx_creds_need_admin: no default, no prompt without a terminal"
OUT=$(bash -c '. "$1"; tsx_creds_need_admin 1; echo "rc=$?"' _ "$HERE/lib/tsx-creds.sh" </dev/null 2>&1)
case "$OUT" in *"--admin-user USER"*"rc=2") ok "no user: names --admin-user, rc 2";; *) bad "no user: $OUT";; esac
OUT=$(TSX_ADMIN_USER=u bash -c '. "$1"; tsx_creds_need_admin 1; echo "rc=$?"' _ "$HERE/lib/tsx-creds.sh" </dev/null 2>&1)
case "$OUT" in *"--admin-password-file FILE"*"rc=2") ok "no password: names --admin-password-file, rc 2";; *) bad "no password: $OUT";; esac
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
[ $rc != 0 ] && case "$OUT" in *"--admin-password-file FILE"*) true;; *) false;; esac && nocalls && ok "a real run (--yes) with a user and no password: stops, no contact" || bad "no password: rc $rc $OUT $(calls)"
reset; OUT=$(drv --yes --results "$W/r2b.txt" --admin-password-file "$W/nofile"); rc=$?
[ $rc = 2 ] && nocalls && ok "an unreadable password file: exit 2 before anything" || bad "nofile: rc $rc $OUT"
OUT=$(TSX_ADMIN_USER=envadmin TSX_ADMIN_PW=envpw77 drv --dry-run --results "$W/r3.txt"); rc=$?
[ $rc = 0 ] && case "$OUT" in *"Crestron admin login: user envadmin"*) true;; *) false;; esac && ok "the environment alone works (automation)" || bad "env: rc $rc $OUT"
OUT=$(TSX_ADMIN_USER=envadmin TSX_ADMIN_PW=envpw77 drv --dry-run --results "$W/r4.txt" --admin-user optadmin --admin-password-file "$W/pw2"); rc=$?
[ $rc = 0 ] && case "$OUT" in *"user optadmin"*) true;; *) false;; esac && ok "--admin-user wins over TSX_ADMIN_USER" || bad "option wins: rc $rc $OUT"
grep -q -e envpw77 -e filepw2 "$W/r3.txt" "$W/r4.txt" && bad "a password is in the results file" || ok "no password in the results files"
OUT=$(KIND=mainline drv --dry-run --yes --results "$W/r5.txt"); rc=$?
case "$OUT" in *"admin login"*) bad "a reinstall asks for the Crestron login";; *) ok "a reinstall (mainline) needs no Crestron login";; esac
OUT=$("$DRIVER" --help 2>&1)
case "$OUT" in *"option wins over its environment variable"*"--admin-password-file FILE"*"--rescue-password-file FILE"*"process list"*) ok "--help shows the rule, the options and the warning";; *) bad "--help: $OUT";; esac
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
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/rootsh" --admin-user u --admin-password-file "$W/pw2" 192.0.2.10 id 2>&1)
grep -q '^sshpass -e ssh .* u@192.0.2.10 rootsh' "$W/calls" && ok "rootsh: the options give the login, sshpass -e" || bad "rootsh options: $(calls)"
reset; OUT=$(PATH="$W/bin:$PATH" "$HERE/steps/tsx-ensure-root" 192.0.2.10 --uart no --results "$W/er.txt" </dev/null 2>&1); rc=$?
[ $rc = 2 ] && nocalls && ok "tsx-ensure-root: exit 2, no contact" || bad "ensure-root: rc $rc $OUT $(calls)"
OUT=$("$HERE/tsx-restore-factory" --help 2>&1)
case "$OUT" in *"--admin-password-file FILE"*"--rescue-password-file FILE"*) ok "tsx-restore-factory --help shows the login options";; *) bad "restore --help";; esac

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-creds || echo FAIL test-install-creds
exit $F
