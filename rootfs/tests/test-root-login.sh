#!/bin/sh
# Host test for the root login (docs/rootfs.md "Root login"). It needs no panel,
# no compiler and no container.
#   - the image build writes no password hash, unless TSX_DEV_ROOT_HASH is set
#   - first boot: tsx-config apply puts ROOT_PASSWORD_HASH and the SSH key in
#     place, and a password that a person sets later survives the next boot
#   - no password (expired state): tsx-rootpw, the console login that forces a
#     new password, ssh that takes keys only, and the banner that says which
#     case applies
# The installer prompt (with and without a password) is in
# installer/tests/test-install-mainline-config.sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=$HERE/overlay/usr/local/sbin/tsx-config
RPW=$HERE/overlay/usr/local/bin/tsx-rootpw
PROF=$HERE/overlay/etc/profile.d/tsx.sh
BAN=$HERE/profiles/console/overlay/usr/local/sbin/tsx-banner
ART=$HERE/profiles/console/overlay/etc/tsx/banner.art
SSHD=$HERE/overlay/etc/ssh/sshd_config.d/tsx.conf
MK=$HERE/mkrootfs.sh
export TSX_BOARD_CONF=$HERE/overlay/usr/local/lib/tsx/board.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
HASH='$6$abcdefgh$somehashvalueherelongenough'
HASH2='$6$ijklmnop$anotherhashvalueherelongenough'
root_field() { awk -F: '$1 == "root" { print $2 }' "$1"; }

echo "== syntax =="
for f in "$RPW" "$PROF" "$MK" "$BAN"; do busybox sh -n "$f" && ok "${f##*/} passes busybox sh -n" || bad "${f##*/}: busybox sh -n"; done

echo "== the image build: no fixed password =="
grep -q 'mkpasswd -m sha-512 -s' "$MK" && bad "mkrootfs.sh still makes a hash of a fixed password" || ok "mkrootfs.sh makes no hash of a fixed password"
# run the password block of mkrootfs.sh on a made-up shadow file
sed -n '/^if \[ -n "\${TSX_DEV_ROOT_HASH:-}" \]; then$/,/^echo "root password: /p' "$MK" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok "found the password block of mkrootfs.sh" || bad "no password block in mkrootfs.sh"
mk_shadow() { mkdir -p "$T/img/etc"; printf 'root:*::0:::::\nbin:!::0:::::\n' > "$T/img/etc/shadow"; }
mk_shadow
out=$(R="$T/img" TSX_DEV_ROOT_HASH= sh "$T/block.sh" 2>&1)
eq "$(root_field "$T/img/etc/shadow")" "" "default build: the root field of /etc/shadow is empty"
eq "$(sed -n 1p "$T/img/etc/shadow")" "root:::0:::::" "default build: the other fields of the line stay"
case "$out" in *none*) ok "the build log says that there is no root password";; *) bad "build log: $out";; esac
mk_shadow
out=$(R="$T/img" TSX_DEV_ROOT_HASH="$HASH" sh "$T/block.sh" 2>&1)
eq "$(root_field "$T/img/etc/shadow")" "$HASH" "TSX_DEV_ROOT_HASH goes into /etc/shadow"
case "$out" in *"test build"*) ok "the build log marks it as a test build";; *) bad "build log: $out";; esac
mk_shadow
R="$T/img" TSX_DEV_ROOT_HASH='plain' sh "$T/block.sh" >/dev/null 2>&1 && bad "a value that is not a crypt hash is accepted" || ok "TSX_DEV_ROOT_HASH must be a sha-512 crypt hash"
for f in build-rootfs.sh; do grep -q TSX_DEV_ROOT_HASH "$HERE/$f" && ok "$f passes TSX_DEV_ROOT_HASH to the container" || bad "$f does not pass TSX_DEV_ROOT_HASH"; done
grep -q TSX_DEV_ROOT_HASH "$HERE/../tools/build/remote-build.sh" && ok "remote-build.sh passes TSX_DEV_ROOT_HASH" || bad "remote-build.sh does not pass TSX_DEV_ROOT_HASH"

echo "== first boot: tsx-config apply =="
CFG=$T/panel.conf; FX=$T/fx; mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk"
reset_fx() { rm -rf "$FX/var/lib/tsx" "$FX/root/.ssh"; printf 'root::19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$CONFIG" apply >/dev/null 2>&1; }
set_() { TSX_CONF="$CFG" busybox sh "$CONFIG" set "$@" >/dev/null; }
unset_() { TSX_CONF="$CFG" busybox sh "$CONFIG" unset "$@" >/dev/null; }
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host'
reset_fx; : > "$CFG"
apply_
eq "$(root_field "$FX/etc/shadow")" "" "no ROOT_PASSWORD_HASH: the field stays empty (the expired state)"
[ ! -e "$FX/root/.ssh/authorized_keys" ] && ok "no key in panel.conf: no authorized_keys" || bad "authorized_keys without a key"
set_ ROOT_PASSWORD_HASH "$HASH"; set_ SSH_AUTHORIZED_KEY "$KEY"
apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH" "first boot: the hash from panel.conf is in /etc/shadow"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "first boot: the SSH key is in authorized_keys" || bad "first boot: no SSH key"
eq "$(sed -n '2p' "$FX/etc/shadow")" "bin:!:19000:0:99999:7:::" "the other accounts are not touched"
grep -q 'abcdefgh\|somehash' "$FX/var/lib/tsx/.root-hash-applied" 2>/dev/null && bad "the state file holds the hash" || ok "the state file holds a checksum, not the hash"
# a person sets a new password on the console: the next boot keeps it
sed -i "s|^root:[^:]*:|root:\$6\$localset\$typedonconsolevaluehere:|" "$FX/etc/shadow"
cur=$(root_field "$FX/etc/shadow"); apply_
eq "$(root_field "$FX/etc/shadow")" "$cur" "a password set on the console survives the next boot"
# a new hash in panel.conf (setup page, installer) is applied once
set_ ROOT_PASSWORD_HASH "$HASH2"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "a changed ROOT_PASSWORD_HASH is applied"
# a reinstall: the same panel.conf on /data, a new image with an empty field
printf 'root::19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; rm -rf "$FX/root/.ssh"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "reinstall: the hash is applied again to the empty field"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "reinstall: the key is applied again" || bad "reinstall: no key"
# a locked field (a build of another kind)
printf 'root:*::0:::::\n' > "$FX/etc/shadow"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "a locked field gets the hash too"
unset_ ROOT_PASSWORD_HASH; unset_ SSH_AUTHORIZED_KEY

echo "== no password: tsx-rootpw =="
SH=$T/shadow
rp() { env TSX_SHADOW_FILE="$SH" TSX_PASSWD_BIN="${PASSWD_BIN:-$T/passwd-ok}" busybox sh "$RPW" "$@"; }
printf 'root::19000:0:::::\n' > "$SH";             eq "$(rp state)" "none" "empty field: state none"
printf 'root:!:19000:0:::::\n' > "$SH";            eq "$(rp state)" "locked" "field !: state locked"
printf 'root:*::0:::::\n' > "$SH";                 eq "$(rp state)" "locked" "field *: state locked"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH";   eq "$(rp state)" "set" "a hash: state set"
printf 'bin:!:19000:0:::::\n' > "$SH";             eq "$(rp state)" "locked" "no root line: not a usable password"
eq "$(env TSX_SHADOW_FILE="$T/none" busybox sh "$RPW" state)" "" "a shadow file that cannot be read: no answer (not root)"
printf 'root::19000:0:::::\n' > "$SH"
rp note | grep -q 'no password yet' && rp note | grep -q 'keys only' && ok "note (none): says no password yet and keys only" || bad "note (none) wrong"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; rp note | grep -q 'password is set' && ok "note (set)" || bad "note (set) wrong"
printf 'root:!:19000:0:::::\n' > "$SH"; rp note | grep -q 'password login is off' && ok "note (locked)" || bad "note (locked) wrong"
# login: a fake passwd that writes a hash into the shadow file, one that does nothing
printf '#!/bin/sh\nsed -i "s|^root:[^:]*:|root:\\$6\\$new\\$typedvaluevaluevalue:|" "%s"\nexit 0\n' "$SH" > "$T/passwd-ok"
printf '#!/bin/sh\necho x >> "%s/tries"\nexit 1\n' "$T" > "$T/passwd-fail"
chmod 755 "$T/passwd-ok" "$T/passwd-fail"
printf 'root::19000:0:::::\n' > "$SH"
rp login >/dev/null 2>&1 && ok "login with no password: passwd runs and the login goes on" || bad "login failed although passwd set a password"
eq "$(rp state)" "set" "after the login, a password is set"
rp login >/dev/null 2>&1 && ok "login with a password: nothing to ask" || bad "login asked although a password is set"
printf 'root::19000:0:::::\n' > "$SH"; rm -f "$T/tries"
PASSWD_BIN=$T/passwd-fail rp login >/dev/null 2>&1 && bad "login went on with no password set" || ok "login with no password after 3 failed tries: the login ends"
eq "$(wc -l < "$T/tries" | tr -d ' ')" "3" "passwd was tried 3 times"
out=$(PASSWD_BIN=$T/passwd-fail rp login 2>&1); case "$out" in *"Choose one now"*) ok "login tells the person what to do";; *) bad "login text: $out";; esac

echo "== /etc/profile.d/tsx.sh: the console login that forces a new password =="
# a copy that calls the fake tsx-rootpw, with fake id and tty
mkdir -p "$T/fb"
# (a busybox ash may run id and tty as built-in applets, so the copy reads
# the user and the terminal from variables instead)
sed "s|/usr/local/bin/tsx-rootpw|$T/fb/tsx-rootpw|g; s|/etc/tsx/profile|$T/profile|g; s|/etc/tsx/build-id|$T/build-id|g; s|\$(id -u)|\$FAKE_UID|g; s|\$(tty 2>/dev/null)|\$FAKE_TTY|g" "$PROF" > "$T/profile.d.sh"
grep -q 'FAKE_UID' "$T/profile.d.sh" && grep -q 'FAKE_TTY' "$T/profile.d.sh" && ok "the test copy of tsx.sh reads the fake user and terminal" || bad "the copy of tsx.sh was not prepared"
cat > "$T/fb/tsx-rootpw" <<'FAKE'
#!/bin/sh
case "$1" in
note) echo "NOTE-LINE";;
login) echo login >> "$LOGFILE"; exit "${LOGIN_RC:-0}";;
esac
FAKE
chmod 755 "$T/fb/tsx-rootpw"
# the file only acts in an interactive shell: run it with -i
prof_i() { printf '%s\n' "$1" > "$T/profile"; rm -f "$T/log"
	env PATH="$T/fb:$PATH" LOGFILE="$T/log" FAKE_TTY="$2" FAKE_UID="$3" LOGIN_RC="$4" busybox sh -i -c ". $T/profile.d.sh; echo REACHED" 2>&1 < /dev/null; }
out=$(prof_i kiosk /dev/tty1 0 0); [ -s "$T/log" ] && ok "root on a text console with no password: the login asks for one" || bad "no forced login on a console: $out"
case "$out" in *REACHED*) ok "after a password is set the shell starts";; *) bad "shell did not start: $out";; esac
out=$(prof_i kiosk /dev/ttyAML0 0 0); [ -s "$T/log" ] && ok "the serial console is forced too" || bad "no forced login on the serial console"
out=$(prof_i kiosk /dev/tty1 0 1); case "$out" in *REACHED*) bad "the login went on after a failed password change";; *) ok "a failed password change ends the login";; esac
out=$(prof_i kiosk /dev/pts/0 0 0); [ ! -s "$T/log" ] && ok "a login over ssh is not forced" || bad "ssh login forced"
case "$out" in *NOTE-LINE*) ok "ssh login: the note says which case applies (kiosk profile)";; *) bad "no note over ssh: $out";; esac
out=$(prof_i console /dev/pts/0 0 0); case "$out" in *NOTE-LINE*) bad "console profile: the note is shown twice (banner and profile)";; *) ok "console profile: the banner has the note, the shell does not repeat it";; esac
out=$(prof_i kiosk /dev/tty1 1000 0); [ ! -s "$T/log" ] && ok "a user other than root is not asked" || bad "non-root user asked for the root password"

echo "== ssh takes keys only until a password is set =="
grep -q '^PermitEmptyPasswords no$' "$SSHD" && ok "sshd: PermitEmptyPasswords no" || bad "sshd: no PermitEmptyPasswords no"
grep -q '^PermitRootLogin yes$' "$SSHD" && grep -q '^PubkeyAuthentication yes$' "$SSHD" && ok "sshd: root may log in with a key or a password" || bad "sshd policy changed"

echo "== the banner says which case applies =="
mkdir -p "$T/run"; echo TSS-10 > "$T/run/model"
ban() { env TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP=192.0.2.10 TSX_NO_RESPAWN=1 TSX_ROOTPW_BIN="$RPW" TSX_SHADOW_FILE="$SH" sh "$BAN"; }
printf 'root::19000:0:::::\n' > "$SH"; ban
for f in issue motd; do
	grep -q 'no password yet' "$T/$f" && grep -q 'keys only' "$T/$f" && ok "$f (no password): says so and says keys only" || bad "$f (no password) wrong"
done
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; ban
for f in issue motd; do grep -q 'password is set' "$T/$f" && ok "$f (password set): says so" || bad "$f (set) wrong"; done
printf 'root:!:19000:0:::::\n' > "$SH"; ban
grep -q 'password login is off' "$T/issue" && ok "issue (locked): says so" || bad "issue (locked) wrong"

echo "$N passed, $F failed"
[ "$F" = 0 ]
