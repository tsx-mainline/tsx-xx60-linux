#!/bin/sh
# Host test for the root login (docs/rootfs.md "Root login"). It needs no panel,
# no compiler and no container.
#   - the image build writes no password hash, unless TSX_DEV_ROOT_HASH is set
#   - first boot: tsx-config apply puts ROOT_PASSWORD_HASH and the SSH key in
#     place, and a password that a person sets later survives the next boot
#   - no password (key only): the root field stays locked, never empty,
#     tsx-rootpw, and the banner that says which case applies (password set,
#     key only, nothing at all)
#   - the console login never asks for a new password (no empty-password state)
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
mk_shadow() { mkdir -p "$T/img/etc"; printf 'root::0:::::\nbin:!::0:::::\n' > "$T/img/etc/shadow"; }
mk_shadow
out=$(R="$T/img" TSX_DEV_ROOT_HASH= sh "$T/block.sh" 2>&1)
eq "$(root_field "$T/img/etc/shadow")" "*" "default build: the root field of /etc/shadow is locked (*), not empty"
eq "$(sed -n 1p "$T/img/etc/shadow")" "root:*:0:::::" "default build: the other fields of the line stay"
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
reset_fx() { rm -rf "$FX/var/lib/tsx" "$FX/root/.ssh"; printf 'root:*:19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$CONFIG" apply >/dev/null 2>&1; }
set_() { TSX_CONF="$CFG" busybox sh "$CONFIG" set "$@" >/dev/null; }
unset_() { TSX_CONF="$CFG" busybox sh "$CONFIG" unset "$@" >/dev/null; }
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host'
reset_fx; : > "$CFG"
apply_
eq "$(root_field "$FX/etc/shadow")" "*" "no ROOT_PASSWORD_HASH: the field stays locked"
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
printf 'root:*:19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; rm -rf "$FX/root/.ssh"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "reinstall: the hash is applied again to the locked field"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "reinstall: the key is applied again" || bad "reinstall: no key"
# a locked field (a build of another kind)
printf 'root:*::0:::::\n' > "$FX/etc/shadow"; apply_
eq "$(root_field "$FX/etc/shadow")" "$HASH2" "a locked field gets the hash too"
# key only: the password stays locked, the key is in place
unset_ ROOT_PASSWORD_HASH; reset_fx; apply_
eq "$(root_field "$FX/etc/shadow")" "*" "key only: the root password stays locked"
grep -qxF "$KEY" "$FX/root/.ssh/authorized_keys" 2>/dev/null && ok "key only: ssh gets the key" || bad "key only: no key"
# an empty field (a broken image) is locked, never left open
printf 'root::19000:0:99999:7:::\nbin:!:19000:0:99999:7:::\n' > "$FX/etc/shadow"; apply_
eq "$(root_field "$FX/etc/shadow")" "*" "an empty root field is locked at the first boot"
eq "$(sed -n '2p' "$FX/etc/shadow")" "bin:!:19000:0:99999:7:::" "the lock leaves the other accounts alone"
unset_ SSH_AUTHORIZED_KEY

echo "== no password: tsx-rootpw =="
SH=$T/shadow AK=$T/authorized_keys
rp() { env TSX_SHADOW_FILE="$SH" TSX_AUTH_KEYS_FILE="$AK" busybox sh "$RPW" "$@"; }
printf 'root::19000:0:::::\n' > "$SH";             eq "$(rp state)" "empty" "empty field: state empty (an error state)"
printf 'root:!:19000:0:::::\n' > "$SH";            eq "$(rp state)" "locked" "field !: state locked"
printf 'root:*::0:::::\n' > "$SH";                 eq "$(rp state)" "locked" "field *: state locked"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH";   eq "$(rp state)" "set" "a hash: state set"
printf 'bin:!:19000:0:::::\n' > "$SH";             eq "$(rp state)" "locked" "no root line: not a usable password"
eq "$(env TSX_SHADOW_FILE="$T/none" busybox sh "$RPW" state)" "" "a shadow file that cannot be read: no answer (not root)"
rp login >/dev/null 2>&1 && bad "tsx-rootpw still has a login mode" || ok "tsx-rootpw has no login mode (no forced password change)"
grep -q 'passwd root\|PASSWD' "$RPW" && bad "tsx-rootpw still calls passwd" || ok "tsx-rootpw never runs passwd"
echo "$KEY" > "$AK"
printf 'root:*::0:::::\n' > "$SH"
rp note | grep -q 'no password is set' && rp note | grep -q 'over SSH with your key' && ok "note (key only): says no password, log in over SSH with the key" || bad "note (key only) wrong"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; rp note | grep -q 'password is set' && ok "note (password set)" || bad "note (set) wrong"
: > "$AK"; printf 'root:*::0:::::\n' > "$SH"
rp note | grep -q 'Nobody can log in' && ok "note (locked, no key): says nobody can log in" || bad "note (no key) wrong"
printf 'root::19000:0:::::\n' > "$SH"; rp note | grep -q 'WARNING' && ok "note (empty field): warns" || bad "note (empty) wrong"

echo "== /etc/profile.d/tsx.sh: the console login never forces a password =="
grep -q 'tsx-rootpw login' "$PROF" && bad "tsx.sh still forces a password change" || ok "tsx.sh has no forced password change"
grep -q '/dev/tty' "$PROF" && bad "tsx.sh still checks the console terminal" || ok "tsx.sh does not look at the terminal"

echo "== ssh takes the key until a password is set =="
grep -q '^PermitEmptyPasswords no$' "$SSHD" && ok "sshd: PermitEmptyPasswords no" || bad "sshd: no PermitEmptyPasswords no"
grep -q '^PermitRootLogin yes$' "$SSHD" && grep -q '^PubkeyAuthentication yes$' "$SSHD" && ok "sshd: root may log in with a key or a password" || bad "sshd policy changed"

echo "== the banner says which case applies =="
mkdir -p "$T/run"; echo TSS-10 > "$T/run/model"
ban() { env TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP=192.0.2.10 TSX_NO_RESPAWN=1 TSX_ROOTPW_BIN="$RPW" TSX_SHADOW_FILE="$SH" TSX_AUTH_KEYS_FILE="$AK" sh "$BAN"; }
printf 'root:*::0:::::\n' > "$SH"; echo "$KEY" > "$AK"; ban
for f in issue motd; do
	grep -q 'no password is set' "$T/$f" && grep -q 'over SSH with your key' "$T/$f" && grep -q 'run passwd' "$T/$f" && ok "$f (key only): says the console login opens after passwd over SSH" || bad "$f (key only) wrong"
done
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; ban
for f in issue motd; do grep -q 'password is set' "$T/$f" && ok "$f (password set): says so" || bad "$f (set) wrong"; done
printf 'root:*::0:::::\n' > "$SH"; : > "$AK"; ban
grep -q 'Nobody can log in' "$T/issue" && ok "issue (no password, no key): says nobody can log in" || bad "issue (nothing) wrong"

echo "== the banner follows passwd while the panel runs (tsx-banner check) =="
cban() { env TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP=192.0.2.10 TSX_NO_RESPAWN=1 TSX_ROOTPW_BIN="$RPW" TSX_SHADOW_FILE="$SH" TSX_AUTH_KEYS_FILE="$AK" sh "$BAN" check; }
printf 'root:*::0:::::\n' > "$SH"; echo "$KEY" > "$AK"; ban
touch -d '2026-01-01 00:00:00' "$SH"; ban
grep -q 'no password is set' "$T/issue" || bad "setup of the check test failed"
cp "$T/issue" "$T/issue.1"; cban
cmp -s "$T/issue" "$T/issue.1" && ok "check: no change in the files, no rewrite" || bad "check rewrote the banner with no change"
printf 'root:%s:19000:0:::::\n' "$HASH" > "$SH"; touch -d '2026-02-01 00:00:00' "$SH"; cban
for f in issue motd; do grep -q 'password is set' "$T/$f" && ! grep -q 'login on this screen is off' "$T/$f" && ok "check: $f says the password is set after passwd" || bad "check: $f stays stale after passwd"; done
printf 'root:*::0:::::\n' > "$SH"; touch -d '2026-03-01 00:00:00' "$SH"; cban
grep -q 'no password is set' "$T/issue" && ok "check: the password removed, the banner follows" || bad "check: banner stays at password set"
grep -q 'tsx-banner watch' "$HERE/profiles/console/overlay/etc/local.d/tsx-banner.start" && ok "the boot hook starts the watch" || bad "boot hook does not start the watch"
busybox sh -n "$BAN" && ok "tsx-banner passes busybox sh -n" || bad "tsx-banner: busybox sh -n"

echo "$N passed, $F failed"
[ "$F" = 0 ]
