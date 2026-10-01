#!/bin/sh
# Host test for the rescue login (rootfs/initramfs/overlay/usr/sbin/tsx-rescue-login).
# It needs no panel, no compiler and no container.
#   - /data readable with a hash and a key: the rescue takes both
#   - a key only: the password stays locked, ssh takes the key
#   - /data unreadable, no panel.conf, or neither value: a one-time password
#     that only the screen file holds. dropbear (the shadow field) refuses "tsx"
#   - the one-time password never reaches stdout, stderr or any other file
#   - a test build with a baked hash keeps it
#   - nothing in the rescue sources has the fixed password any more
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
RL=$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-rescue-login
RS=$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-rescue-status
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
HASH='$6$abcdefgh$somehashvalueherelongenough'
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host'
field() { awk -F: '$1 == "root" { print $2 }' "$T/shadow"; }

echo "== syntax =="
busybox sh -n "$RL" && ok "tsx-rescue-login passes busybox sh -n" || bad "tsx-rescue-login: busybox sh -n"

# fake tools: chpasswd stores "FAKE_<password>" as the field (the password is
# visible to the test only), findfs/mount/umount serve a fixture as /data
mkdir -p "$T/bin" "$T/fx/tsx"
cat > "$T/chpasswd" <<'FAKE'
#!/bin/sh
read -r line; user=${line%%:*}; pw=${line#*:}
awk -F: -v h="FAKE_$pw" 'BEGIN { OFS = ":" } { if ($1 == "root") $2 = h; print }' "$SHADOW_FILE" > "$SHADOW_FILE.n" && cat "$SHADOW_FILE.n" > "$SHADOW_FILE"
FAKE
cat > "$T/bin/findfs" <<'FAKE'
#!/bin/sh
[ -e "$FAKE_NODATA" ] && exit 1
echo /dev/fakedata
FAKE
cat > "$T/bin/mount" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE_MOUNTLOG"
[ -e "$FAKE_BADMOUNT" ] && exit 1
for last; do :; done; cp -r "$FAKE_DATA"/. "$last"/
FAKE
cat > "$T/bin/umount" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE_MOUNTLOG"
for last; do :; done; rm -rf "$last"/*
FAKE
chmod 755 "$T/chpasswd" "$T/bin/findfs" "$T/bin/mount" "$T/bin/umount"
export SHADOW_FILE=$T/shadow FAKE_NODATA=$T/nodata FAKE_BADMOUNT=$T/badmount FAKE_DATA=$T/fx FAKE_MOUNTLOG=$T/mountlog

reset() {   # reset [ROOTFIELD]
	rm -rf "$T/run" "$T/root" "$T/nodata" "$T/badmount" "$T/out" "$T/fx/tsx/panel.conf"
	mkdir -p "$T/run" "$T/root"; : > "$T/mountlog"
	printf 'root:%s:19000:0:::::\nbin:!:19000:0:::::\n' "${1:-*}" > "$T/shadow"
}
rl() {   # run the script on the fixtures. Any extra env goes in front.
	env PATH="$T/bin:$PATH" TSX_RESCUE_SHADOW="$T/shadow" TSX_RESCUE_ROOT="$T/root" TSX_RESCUE_RUN="$T/run" \
	    TSX_RESCUE_WAIT=0 TSX_RESCUE_CHPASSWD="$T/chpasswd" TSX_RESCUE_FINDFS="$T/bin/findfs" TSX_RESCUE_MOUNT="$T/bin/mount" TSX_RESCUE_UMOUNT="$T/bin/umount" "$@" busybox sh "$RL" > "$T/out" 2>&1
}
mode() { cat "$T/run/tsx-rescue-login" 2>/dev/null; }
conf() { printf '%s\n' "$@" > "$T/fx/tsx/panel.conf"; }

echo "== /data readable with a hash and a key =="
reset; conf 'KIOSK_URL=https://ha.example.org/' "ROOT_PASSWORD_HASH=$HASH" "SSH_AUTHORIZED_KEY=$KEY"
rl
eq "$(mode)" "panel" "the case is panel"
eq "$(field)" "$HASH" "the panel's hash is the password of root"
grep -qxF "$KEY" "$T/root/.ssh/authorized_keys" && ok "the panel's key is in authorized_keys" || bad "no key in authorized_keys"
[ ! -e "$T/run/tsx-rescue-otp" ] && ok "no one-time password when the panel's login is used" || bad "an OTP was made"
grep -q 'ro,noload' "$T/mountlog" && ok "/data is mounted read only (noload)" || bad "/data mount options: $(cat "$T/mountlog")"
grep -q '^-t ext4' "$T/mountlog" && grep -q '^/dev/fakedata\|fakedata' "$T/mountlog" && ok "it mounts the LABEL=tsxdata device" || bad "wrong device: $(cat "$T/mountlog")"
[ "$(wc -l < "$T/mountlog" | tr -d ' ')" = 2 ] && ok "/data is unmounted again" || bad "mount log: $(cat "$T/mountlog")"
[ "$(stat -c %a "$T/root/.ssh/authorized_keys")" = 600 ] && ok "authorized_keys is mode 600" || bad "authorized_keys mode"
eq "$(sed -n 2p "$T/shadow")" "bin:!:19000:0:::::" "the other accounts are not touched"

echo "== quoted values =="
reset; conf "ROOT_PASSWORD_HASH=\"$HASH\"" "SSH_AUTHORIZED_KEY='$KEY'"
rl; eq "$(field)" "$HASH" "a quoted hash works"; grep -qxF "$KEY" "$T/root/.ssh/authorized_keys" && ok "a quoted key works" || bad "quoted key"

echo "== a key only =="
reset; conf "SSH_AUTHORIZED_KEY=$KEY"
rl
eq "$(mode)" "panel" "key only: the case is panel"
eq "$(field)" "*" "key only: the password stays locked"
grep -qxF "$KEY" "$T/root/.ssh/authorized_keys" && ok "key only: ssh takes the key" || bad "key only: no key"
[ ! -e "$T/run/tsx-rescue-otp" ] && ok "key only: no one-time password" || bad "key only: an OTP was made"

echo "== a hash only =="
reset; conf "ROOT_PASSWORD_HASH=$HASH"
rl; eq "$(mode)" "panel" "hash only: the case is panel"; eq "$(field)" "$HASH" "hash only: the hash is applied"
[ ! -e "$T/root/.ssh/authorized_keys" ] && ok "hash only: no authorized_keys" || bad "hash only: authorized_keys exists"

echo "== no usable login on /data: a one-time password =="
check_otp() {   # check_otp LABEL
	eq "$(mode)" "onetime" "$1: the case is onetime"
	otp=$(cat "$T/run/tsx-rescue-otp" 2>/dev/null)
	[ "${#otp}" = 10 ] && ok "$1: the one-time password has 10 characters" || bad "$1: OTP '$otp'"
	case "$otp" in *[!abcdefghjkmnpqrstuvwxyz23456789]*|'') bad "$1: OTP has odd characters";; *) ok "$1: OTP uses only clear characters";; esac
	[ "$(stat -c %a "$T/run/tsx-rescue-otp")" = 600 ] && ok "$1: the OTP file is mode 600" || bad "$1: OTP file mode"
	eq "$(field)" "FAKE_$otp" "$1: the shadow field holds the OTP only"
	[ "$(field)" != "FAKE_tsx" ] && ok "$1: the password tsx is refused" || bad "$1: tsx is accepted"
	[ ! -e "$T/root/.ssh/authorized_keys" ] && ok "$1: no key is accepted" || bad "$1: authorized_keys exists"
	if grep -q "$otp" "$T/out"; then bad "$1: the OTP is in the output of the script"; else ok "$1: the OTP is not in the output of the script"; fi
	n=$(grep -rl "$otp" "$T" 2>/dev/null | grep -v "^$T/run/tsx-rescue-otp$\|^$T/shadow" | wc -l | tr -d ' ')
	[ "$n" = 0 ] && ok "$1: no other file holds the OTP" || bad "$1: $n other file(s) hold the OTP"
}
reset; touch "$T/nodata"; rl; check_otp "no tsxdata device"
first=$(cat "$T/run/tsx-rescue-otp")
reset; touch "$T/badmount"; conf "ROOT_PASSWORD_HASH=$HASH"; rl; check_otp "mount fails"
reset; rm -f "$T/fx/tsx/panel.conf"; rl; check_otp "no panel.conf"
reset; conf 'KIOSK_URL=https://ha.example.org/'; rl; check_otp "panel.conf with neither value"
reset; conf 'ROOT_PASSWORD_HASH=plain' 'SSH_AUTHORIZED_KEY=not a key'; rl; check_otp "bad values in panel.conf"
reset; touch "$T/nodata"; rl; second=$(cat "$T/run/tsx-rescue-otp")
[ "$first" != "$second" ] && ok "each run makes a new password" || bad "the OTP repeats"
reset; touch "$T/nodata"; rl TSX_RESCUE_CHPASSWD=/bin/false
eq "$(mode)" "none" "chpasswd fails: the case is none"
eq "$(field)" "*" "chpasswd fails: the field stays locked"
[ ! -e "$T/run/tsx-rescue-otp" ] && ok "chpasswd fails: no OTP is shown" || bad "an OTP was shown for no password"

echo "== a test build with a baked hash =="
reset "$HASH"; touch "$T/nodata"; rl
eq "$(mode)" "build" "baked hash: the case is build"
eq "$(field)" "$HASH" "baked hash: kept"
[ ! -e "$T/run/tsx-rescue-otp" ] && ok "baked hash: no OTP" || bad "baked hash: an OTP"

echo "== wiring: no fixed password anywhere in the rescue =="
RCS=$HERE/rootfs/initramfs/overlay/etc/init.d/rcS
MK=$HERE/rootfs/initramfs/mkinitramfs-switchroot.sh
grep -q "tsx-rescue-login" "$RCS" && ok "rcS runs tsx-rescue-login" || bad "rcS does not run tsx-rescue-login"
awk '/tsx-rescue-login/ { l = NR } /^dropbear/ { d = NR } END { exit !(l && d && l < d) }' "$RCS" && ok "the login is chosen before dropbear starts" || bad "dropbear starts before the login is chosen"
grep -q "password 'tsx'\|echo tsx |" "$RCS" "$MK" && bad "a fixed rescue password is still in rcS or the build" || ok "no fixed rescue password in rcS or the build"
grep -rn "(password tsx)\|(password: tsx)\|root/tsx" "$HERE/rootfs/initramfs" "$HERE/installer/initramfs" "$HERE/installer/rescue" "$HERE/installer/rescue-v2" >/dev/null 2>&1 && bad "the rescue sources still name the password tsx" || ok "the rescue sources do not name the password tsx"
grep -q 'TSX_DEV_RESCUE_HASH' "$MK" && ok "the test-build override is TSX_DEV_RESCUE_HASH" || bad "no TSX_DEV_RESCUE_HASH"
grep -q 'TSX_DEV_RESCUE_HASH' "$HERE/rootfs/build-rootfs.sh" && ok "build-rootfs.sh passes TSX_DEV_RESCUE_HASH" || bad "build-rootfs.sh does not pass it"
# the OTP file is written by tsx-rescue-login and read by the screen, nothing else
others=$(grep -rln "tsx-rescue-otp" "$HERE/rootfs" "$HERE/installer" --include='*' 2>/dev/null | grep -v '/tests/' | sort | tr '\n' ' ')
case "$others" in "$RL $RS "*|"$RS $RL "*) ok "only tsx-rescue-login and tsx-rescue-status use the OTP file";; *) bad "files that name the OTP file: $others";; esac
grep -n 'tsx-rescue-otp' "$RS" | grep -q 'kmsg' && bad "the screen sends the OTP to the kernel log" || ok "the screen never writes the OTP to the kernel log"

echo "$N passed, $F failed"
[ "$F" = 0 ]
