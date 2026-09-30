#!/bin/bash
# Host test for mk-tsxroot-emmc.sh. The test builds a small synthetic rootfs
# tarball (one modules tree, an etc/fstab, etc/kiosk.conf). It checks these
# points:
#  - the image is COMPACT: well under the given --bytes partition size and
#    not truncated to it
#  - the image is fsck-clean and has the right label, fstab and KIOSK_URL edits
#  - the manifest fragment carries root_bytes (the size of the image) and
#    root_partition_min_bytes (the --bytes value)
# The test needs docker. The script always uses docker, to build for armv7 as
# a real run does. The test skips if docker is unavailable or unusable here,
# the same convention as installer/factory/tests/test-emmc-restore.sh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EMMC=$(cd "$HERE/.." && pwd)
SUT=$EMMC/mk-tsxroot-emmc.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok()   { N=$((N+1)); echo "  ok: $*"; }
fail() { F=$((F+1)); echo "  FAIL: $*"; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
	echo "SKIPPED: docker unavailable or unusable here (mk-tsxroot-emmc.sh always builds in a container)"
	exit 0
fi

echo "== building a synthetic rootfs tarball (one modules tree, ~600 MiB content)"
mkdir -p "$W/fr/lib/modules/6.1.0-test/kernel" "$W/fr/lib/modules/6.1.0-other/kernel" "$W/fr/etc/tsx"
echo module > "$W/fr/lib/modules/6.1.0-test/kernel/mod.ko"
echo module > "$W/fr/lib/modules/6.1.0-other/kernel/mod.ko"
dd if=/dev/urandom of="$W/fr/lib/modules/6.1.0-test/kernel/pad.bin" bs=1M count=600 status=none
printf 'LABEL=tsxroot   /   ext4   rw,noatime   0   1\n' > "$W/fr/etc/fstab"
printf 'KIOSK_URL=""\n' > "$W/fr/etc/kiosk.conf"
tar -C "$W/fr" -czf "$W/rootfs.tar.gz" .

BYTES=$((2932 * 1048576))   # ~p8's real size (docs/boot.md eMMC region table)
echo "== running mk-tsxroot-emmc.sh (--bytes $BYTES, the p8 floor)"
OUT="$W/root.img"
if ! "$SUT" --rootfs-tar "$W/rootfs.tar.gz" --modules-ver 6.1.0-test --bytes "$BYTES" --out "$OUT" --flavor stable --url https://ha.example.org/ > "$W/build.log" 2>&1; then
	fail "mk-tsxroot-emmc.sh exited non-zero"; cat "$W/build.log"
else
	ok "mk-tsxroot-emmc.sh exited 0"
fi

echo "== --list-versions"
LIST=$("$SUT" --list-versions "$W/rootfs.tar.gz")
[ "$LIST" = "$(printf '6.1.0-other\n6.1.0-test')" ] && ok "--list-versions lists both module trees" || fail "--list-versions: got [$LIST]"

[ -f "$OUT" ] || { fail "no output image at $OUT"; echo "== $N ok, $F failed"; echo FAIL test-mk-tsxroot-emmc; exit 1; }

SIZE=$(stat -c %s "$OUT")
echo "== image is $SIZE bytes ($((SIZE / 1048576)) MiB), partition floor $((BYTES / 1048576)) MiB"
[ "$SIZE" -lt "$BYTES" ] && ok "compact image is smaller than the partition (not truncated to it)" \
	|| fail "image is $SIZE bytes, not smaller than --bytes=$BYTES: compaction did not happen"
[ "$SIZE" -lt $((900 * 1048576)) ] && ok "compact image is well under 900 MiB for ~600 MiB of content" \
	|| fail "image is $((SIZE / 1048576)) MiB, expected well under 900 MiB for ~600 MiB of content"
[ $((SIZE % 1048576)) = 0 ] && ok "image size is a whole MiB (pr_dd/readback need this)" \
	|| fail "image size $SIZE is not a whole MiB multiple"

e2fsck -fn "$OUT" >"$W/fsck.log" 2>&1 && ok "e2fsck -fn clean" || { fail "e2fsck -fn reported problems"; cat "$W/fsck.log"; }
LABEL=$(dumpe2fs -h "$OUT" 2>/dev/null | sed -n 's/^Filesystem volume name:\s*//p')
[ "$LABEL" = tsxroot-emmc ] && ok "LABEL=tsxroot-emmc" || fail "label is '$LABEL', expected tsxroot-emmc"
FEAT=$(dumpe2fs -h "$OUT" 2>/dev/null | sed -n 's/^Filesystem features:\s*//p')
case " $FEAT " in *" metadata_csum_seed "*) fail "metadata_csum_seed is set (vendor 3.10-incompatible feature leaked in)";; *) ok "no metadata_csum_seed";; esac
case " $FEAT " in *" orphan_file "*) fail "orphan_file is set";; *) ok "no orphan_file";; esac

FSTAB=$(debugfs -R "cat /etc/fstab" "$OUT" 2>/dev/null)
echo "$FSTAB" | grep -q '^LABEL=tsxroot-emmc' && ok "fstab: LABEL=tsxroot-emmc" || fail "fstab missing LABEL=tsxroot-emmc: $FSTAB"
echo "$FSTAB" | grep -q '/media/bootfat' && ok "fstab: /media/bootfat added" || fail "fstab missing /media/bootfat"
echo "$FSTAB" | grep -q 'LABEL=tsxdata' && ok "fstab: LABEL=tsxdata added" || fail "fstab missing LABEL=tsxdata"
KIOSK=$(debugfs -R "cat /etc/kiosk.conf" "$OUT" 2>/dev/null)
echo "$KIOSK" | grep -q '^KIOSK_URL="https://ha.example.org/"$' && ok "KIOSK_URL set from --url" || fail "KIOSK_URL not set: $KIOSK"
MODLIST=$(debugfs -R "ls -l /lib/modules" "$OUT" 2>/dev/null | awk 'NF>=8{print $NF}' | grep -v '^\.\.\?$')
echo "$MODLIST" | grep -q '6.1.0-test' && ok "kept the requested module tree" || fail "6.1.0-test module tree missing"
echo "$MODLIST" | grep -q '6.1.0-other' && ok "kept the other flavor's module tree (flavor switch)" || fail "the other flavor's module tree was dropped"

echo "== manifest-fragment"
FRAG="$OUT.manifest-fragment"
if [ -f "$FRAG" ]; then
	ok "manifest-fragment exists"
	grep -q "^format=tsx-rescue-install-1$" "$FRAG" && ok "format=tsx-rescue-install-1" || fail "bad/missing format line"
	grep -q "^kernel_flavor=stable$" "$FRAG" && ok "kernel_flavor=stable" || fail "bad/missing kernel_flavor"
	FRAG_BYTES=$(sed -n 's/^root_bytes=//p' "$FRAG")
	[ "$FRAG_BYTES" = "$SIZE" ] && ok "manifest root_bytes matches the image's own size ($SIZE)" \
		|| fail "manifest root_bytes=$FRAG_BYTES, image is $SIZE bytes"
	FRAG_MINPART=$(sed -n 's/^root_partition_min_bytes=//p' "$FRAG")
	[ "$FRAG_MINPART" = "$BYTES" ] && ok "manifest root_partition_min_bytes matches --bytes ($BYTES)" \
		|| fail "manifest root_partition_min_bytes=$FRAG_MINPART, expected $BYTES"
	FRAG_SHA=$(sed -n 's/^root_sha256=//p' "$FRAG")
	[ "$FRAG_SHA" = "$(sha256sum < "$OUT" | cut -d' ' -f1)" ] && ok "manifest root_sha256 matches the image" \
		|| fail "manifest root_sha256 does not match the image"
else
	fail "no manifest-fragment at $FRAG"
fi
[ -f "$OUT.sha256" ] && ok "$OUT.sha256 exists" || fail "$OUT.sha256 missing"

echo "== --bytes too small for the content is refused"
"$SUT" --rootfs-tar "$W/rootfs.tar.gz" --modules-ver 6.1.0-test --bytes 1048576 --out "$W/toosmall.img" --flavor stable \
	> "$W/toosmall.log" 2>&1 && fail "a too-small --bytes was accepted" || ok "a too-small --bytes is refused"
grep -q "exceeds the partition size" "$W/toosmall.log" && ok "error names the partition-size problem" || fail "error message unclear: $(cat "$W/toosmall.log")"
[ -f "$W/toosmall.img" ] && fail "toosmall.img was left behind after a refused build" || ok "no output image left behind after a refused build"

echo "== $N ok, $F failed"
[ "$F" = 0 ] && echo PASS test-mk-tsxroot-emmc || echo FAIL test-mk-tsxroot-emmc
exit "$F"
