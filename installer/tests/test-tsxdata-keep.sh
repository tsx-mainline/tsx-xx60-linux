#!/bin/bash
# Host test: the "keep /data on a reinstall" decision of
# installer/steps/tsx-rescue-install --keep-data (docs/install.md
# "Reinstalling or updating a mainline panel"). No docker, no root, no loop
# device: installer/lib/tsx-rescue.sh's tsx_tsxdata_keepable runs under
# busybox sh (the rescue's shell) against small file-backed ext4 images, and
# tsx_conf_set_flavor against a panel.conf copy.
#   1. a clean ext4 LABEL=tsxdata            -> 0 (keep)
#   2. ext4 with another label, or no fs     -> 1 (format)
#   3. a tsxdata ext4 with an inconsistency  -> 2 (repair, then ask again);
#      after e2fsck -fp it is 0 again
#   4. tsx_conf_set_flavor replaces or appends KERNEL_FLAVOR, keeps the rest
#   5. tsx_rootinfo_set_flavor replaces or appends kernel_flavor= in a fresh
#      root's etc/tsx/emmc-root.info (tsx-rescue-install step 3)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HERE/lib/tsx-rescue.sh"
for t in busybox mkfs.ext4 e2fsck blkid debugfs; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED test-tsxdata-keep: no $t on this host"; exit 0; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
keepable() {   # IMG -> "rc reason" (run in busybox sh, like the rescue)
	busybox sh -c '. "$1"; r=$(tsx_tsxdata_keepable "$2"); echo "$? $r"' sh "$LIB" "$1"
}
mkimg() {      # IMG LABEL
	truncate -s 16M "$1"
	mkfs.ext4 -F -q -L "$2" "$1" >/dev/null 2>&1
}

echo "== 1. a clean tsxdata ext4 is kept"
mkimg "$W/good.img" tsxdata
debugfs -w -R "mkdir tsx" "$W/good.img" >/dev/null 2>&1
OUT=$(keepable "$W/good.img")
[ "${OUT%% *}" = 0 ] && ok "rc 0 ($OUT)" || bad "clean tsxdata not keepable: $OUT"

echo "== 2. anything that is not a tsxdata ext4 is formatted"
mkimg "$W/other.img" somethingelse
OUT=$(keepable "$W/other.img")
[ "${OUT%% *}" = 1 ] && ok "other label: rc 1 ($OUT)" || bad "other label: $OUT"
truncate -s 16M "$W/blank.img"
OUT=$(keepable "$W/blank.img")
[ "${OUT%% *}" = 1 ] && ok "no file system: rc 1 ($OUT)" || bad "no file system: $OUT"
truncate -s 16M "$W/ext2.img"; mkfs.ext2 -F -q -L tsxdata "$W/ext2.img" >/dev/null 2>&1
OUT=$(keepable "$W/ext2.img")
[ "${OUT%% *}" = 1 ] && ok "ext2 LABEL=tsxdata: rc 1 ($OUT)" || bad "ext2 tsxdata: $OUT"

echo "== 3. a damaged tsxdata ext4 asks for a repair first"
mkimg "$W/bad.img" tsxdata
debugfs -w -R "set_inode_field <2> links_count 9" "$W/bad.img" >/dev/null 2>&1
OUT=$(keepable "$W/bad.img")
[ "${OUT%% *}" = 2 ] && ok "rc 2 ($OUT)" || bad "damaged tsxdata: $OUT"
e2fsck -fp "$W/bad.img" >/dev/null 2>&1
OUT=$(keepable "$W/bad.img")
[ "${OUT%% *}" = 0 ] && ok "after e2fsck -fp: rc 0" || bad "still not keepable after e2fsck -fp: $OUT"

echo "== 4. tsx_conf_set_flavor"
printf '# c\nKIOSK_URL="https://ha.example.org"\nKERNEL_FLAVOR="lts"\nVOICE="off"\n' > "$W/a.conf"
busybox sh -c '. "$1"; tsx_conf_set_flavor "$2" stable' sh "$LIB" "$W/a.conf"
[ "$(grep -c '^KERNEL_FLAVOR="stable"$' "$W/a.conf")" = 1 ] && ok "KERNEL_FLAVOR replaced" || bad "replace: $(cat "$W/a.conf")"
grep -q '^KIOSK_URL="https://ha.example.org"$' "$W/a.conf" && grep -q '^VOICE="off"$' "$W/a.conf" && grep -q '^# c$' "$W/a.conf" \
	&& ok "other lines unchanged" || bad "other lines changed: $(cat "$W/a.conf")"
printf 'VOICE="off"\n' > "$W/b.conf"
busybox sh -c '. "$1"; tsx_conf_set_flavor "$2" lts' sh "$LIB" "$W/b.conf"
[ "$(tail -n 1 "$W/b.conf")" = 'KERNEL_FLAVOR="lts"' ] && ok "KERNEL_FLAVOR appended" || bad "append: $(cat "$W/b.conf")"
cp "$W/b.conf" "$W/c.conf"
busybox sh -c '. "$1"; tsx_conf_set_flavor "$2" beta' sh "$LIB" "$W/c.conf"
cmp -s "$W/b.conf" "$W/c.conf" && ok "an unknown flavor changes nothing" || bad "unknown flavor changed the file"

echo "== 5. tsx_rootinfo_set_flavor"
mkdir -p "$W/root5/etc/tsx"
printf 'root=emmc\nkernel_flavor=lts\nkernel_modules_ver=x\n' > "$W/root5/etc/tsx/emmc-root.info"
busybox sh -c '. "$1"; tsx_rootinfo_set_flavor "$2" stable' sh "$LIB" "$W/root5/etc/tsx/emmc-root.info"
[ "$(grep -c '^kernel_flavor=stable$' "$W/root5/etc/tsx/emmc-root.info")" = 1 ] && ok "kernel_flavor replaced" || bad "replace: $(cat "$W/root5/etc/tsx/emmc-root.info")"
grep -q '^root=emmc$' "$W/root5/etc/tsx/emmc-root.info" && grep -q '^kernel_modules_ver=x$' "$W/root5/etc/tsx/emmc-root.info" \
	&& ok "other lines unchanged" || bad "other lines changed: $(cat "$W/root5/etc/tsx/emmc-root.info")"
# no kernel_flavor= line yet (e.g. migrate-to-emmc.sh's own emmc-root.info, or
# a root image built before this field existed): appended, not left missing
mkdir -p "$W/root6/etc/tsx"
printf 'root=emmc\n' > "$W/root6/etc/tsx/emmc-root.info"
busybox sh -c '. "$1"; tsx_rootinfo_set_flavor "$2" lts' sh "$LIB" "$W/root6/etc/tsx/emmc-root.info"
[ "$(tail -n 1 "$W/root6/etc/tsx/emmc-root.info")" = 'kernel_flavor=lts' ] && ok "kernel_flavor appended" || bad "append: $(cat "$W/root6/etc/tsx/emmc-root.info")"
# no etc/tsx/ directory at all yet: created
rm -rf "$W/root7"
busybox sh -c '. "$1"; tsx_rootinfo_set_flavor "$2" stable' sh "$LIB" "$W/root7/etc/tsx/emmc-root.info"
[ "$(cat "$W/root7/etc/tsx/emmc-root.info" 2>/dev/null)" = 'kernel_flavor=stable' ] && ok "etc/tsx/ created, file written" || bad "missing dir: $(cat "$W/root7/etc/tsx/emmc-root.info" 2>/dev/null)"
# an unknown flavor changes nothing (same contract as tsx_conf_set_flavor)
cp "$W/root6/etc/tsx/emmc-root.info" "$W/root6.before"
busybox sh -c '. "$1"; tsx_rootinfo_set_flavor "$2" beta' sh "$LIB" "$W/root6/etc/tsx/emmc-root.info"
cmp -s "$W/root6.before" "$W/root6/etc/tsx/emmc-root.info" && ok "an unknown flavor changes nothing" || bad "unknown flavor changed the file"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-tsxdata-keep || echo FAIL test-tsxdata-keep
exit $F
