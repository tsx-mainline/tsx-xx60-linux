#!/bin/sh
# Host test for the wiring of the image build (rootfs/mkrootfs.sh,
# rootfs/build-rootfs.sh). It needs no compiler, no container and no panel.
#   - the build needs TSX_APK_LOCAL and stops before it starts a container
#   - the image has no root password, unless TSX_DEV_ROOT_HASH is set
#   - the image ships the swclock file and makes the tsx-setup user
#   - the check of the kernel packages runs, and the ES2 patch of the browser
#     package is verified
#   - /init reads the orientation from the mounted root
# The tools of tsx-linux-common are in tests/common.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK=$HERE/mkrootfs.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
HASH='$6$abcdefgh$somehashvalueherelongenough'
root_field() { awk -F: '$1 == "root" { print $2 }' "$1"; }

echo "== the build needs the apk tree =="
for cmd in rootfs initramfs all; do
	out=$(env -u TSX_APK_LOCAL bash "$HERE/build-rootfs.sh" $cmd 2>&1); rc=$?
	[ $rc != 0 ] && echo "$out" | grep -q 'TSX_APK_LOCAL is required' && ok "build-rootfs.sh $cmd: stops without TSX_APK_LOCAL" || bad "build-rootfs.sh $cmd (rc $rc): $out"
done
out=$(TSX_APK_LOCAL="$T/none" bash "$HERE/build-rootfs.sh" rootfs 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q 'has no v3.24/' && ok "build-rootfs.sh: stops when the folder has no apk tree" || bad "no apk tree (rc $rc): $out"
grep -q '^\[ -n "\${TSX_APK_LOCAL:-}" \] || { echo "TSX_APK_LOCAL is required' "$MK" && ok "mkrootfs.sh stops without TSX_APK_LOCAL" || bad "mkrootfs.sh does not need TSX_APK_LOCAL"
for w in TSX_FROM_PACKAGES CHROMIUM_ES2_PATCH "gcc " build-base; do
	grep -q "$w" "$MK" && bad "the old build is still in mkrootfs.sh: $w" || ok "no $w in mkrootfs.sh"
done
grep -q CHROMIUM_ES2_PATCH "$HERE/build-rootfs.sh" && bad "the old build is still in build-rootfs.sh: CHROMIUM_ES2_PATCH" || ok "no CHROMIUM_ES2_PATCH in build-rootfs.sh"
# a release build stages the modules of its own kernel, and the image takes a tree that no package has
grep -q 'KVER' "$MK" && grep -q 'KVER' "$HERE/build-rootfs.sh" && ok "the build keeps the staged module trees (KVER)" || bad "KVER is gone"
# the initramfs takes its files only from the packages of packages.pin
for f in "$HERE/build-rootfs.sh" "$HERE/initramfs/mkinitramfs-switchroot.sh" "$HERE/../installer/initramfs/build-initramfs.sh"; do
	grep -q TSX_FROM_PACKAGES "$f" && bad "the old switch is still in ${f#"$HERE/"}: TSX_FROM_PACKAGES" || ok "no TSX_FROM_PACKAGES in ${f#"$HERE/"}"
done
for w in "gcc " build-base mksplash.sh '../overlay/usr/local'; do
	grep -q "$w" "$HERE/initramfs/mkinitramfs-switchroot.sh" && bad "the source build is still in mkinitramfs-switchroot.sh: $w" || ok "no $w in mkinitramfs-switchroot.sh"
done
grep -q 'check-boot-images.py' "$MK" && ok "mkrootfs.sh runs the check of the kernel packages" || bad "mkrootfs.sh does not run the check"
grep -q 'patch-chromium.py" --check' "$MK" && ok "mkrootfs.sh verifies the ES2 patch of tsx-xx60-chromium" || bad "mkrootfs.sh does not verify the ES2 patch"

echo "== no fixed root password =="
grep -q 'mkpasswd -m sha-512 -s' "$MK" && bad "mkrootfs.sh makes a hash of a fixed password" || ok "mkrootfs.sh makes no hash of a fixed password"
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
grep -q TSX_DEV_ROOT_HASH "$HERE/build-rootfs.sh" && ok "build-rootfs.sh passes TSX_DEV_ROOT_HASH to the container" || bad "build-rootfs.sh does not pass TSX_DEV_ROOT_HASH"
grep -q TSX_DEV_ROOT_HASH "$HERE/../tools/build/remote-build.sh" && ok "remote-build.sh passes TSX_DEV_ROOT_HASH" || bad "remote-build.sh does not pass TSX_DEV_ROOT_HASH"

echo "== files and users of the image =="
grep -q 'touch $R/var/lib/misc/openrc-shutdowntime' "$MK" && ok "image ships the swclock file (boot clock floor = build time)" || bad "no swclock floor in mkrootfs.sh"
grep -q 'adduser -D -H -s /sbin/nologin.*tsx-setup' "$MK" && ok "mkrootfs.sh creates the tsx-setup system user" || bad "mkrootfs.sh does not create a tsx-setup user"
for s in tsx-setup-helper tsx-setupd; do
	sh "$HERE/profile.sh" has kiosk svc "$s" && ok "the kiosk and ha profiles enable $s in the default runlevel" || bad "the kiosk profile does not enable $s in the default runlevel (no setup page on the panel)"
done

echo "== initramfs =="
grep -q 'tsx-orientation -f /newroot/etc/tsx/orientation info' "$HERE/initramfs/overlay/init" && ok "/init reads the orientation from the mounted root" || bad "/init does not read the orientation"

echo "$N passed, $F failed"
[ "$F" = 0 ]
