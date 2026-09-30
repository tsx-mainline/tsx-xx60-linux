#!/usr/bin/env bash
# Host-side test for tsx-emmc-restore, against a real unit-B eMMC
# capture (out/bundle-unitB and a sparse copy of the captured raw eMMC image).
# The test never touches a panel, an ssh host or a serial port.
# It runs on the workstation only. The loop-device and mount paths run in a
# privileged Alpine container (same pattern as installer/tests/test-factory.sh).
# The test needs the eMMC and boot0 captures of a real unit (CAPTURES_DIR).
# They are proprietary, one set per unit, and not part of this repo.
# The test skips if they are not present.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FACTORY=$(cd "$HERE/.." && pwd)
INSTALLER=$(cd "$FACTORY/.." && pwd)
SRC=$FACTORY/tsx-emmc-restore
BUNDLE=$FACTORY/out/bundle-unitB
MANIFEST=$BUNDLE/emmc.manifest
RESULTS_DIR=$HERE/results
RESULTS=$RESULTS_DIR/test-emmc-restore.txt
mkdir -p "$RESULTS_DIR"

CAPTURES=${CAPTURES_DIR:-}
RAW=${TMPDIR:-/var/tmp}/tsx-emmc-restore-test/emmc.raw
BOOT0=$CAPTURES/tsw-1060-unitB/emmc/unitB-mmcblk1boot0-20260926-2114.img
TSXBOOT=$INSTALLER/emmc/out/tsxboot-emmc.img

if [ -z "$CAPTURES" ] || [ ! -f "$BOOT0" ] || [ ! -f "$RAW" ]; then
	echo "SKIPPED: needs a real unit's eMMC + boot0 captures (set CAPTURES_DIR and RAW). Not present here"
	exit 0
fi

T=${TMPDIR:-/var/tmp}/tsx-emmc-restore-test
MiB=1048576

cleanup() { rm -rf "$T"; }
trap cleanup EXIT

N=0; F=0
ok()   { N=$((N+1)); echo "  ok: $*"; }
fail() { F=$((F+1)); echo "  FAIL: $*"; }

sha_range() { # file off_mib len_mib
	dd if="$1" bs=$MiB skip="$2" count="$3" status=none | sha256sum | cut -d' ' -f1
}
sha_file() { sha256sum < "$1" | cut -d' ' -f1; }

# ---- sanity on the fixed inputs --------------------------------------------
manifest_check() {
	[ -f "$MANIFEST" ] || { fail "no emmc.manifest at $MANIFEST"; return 1; }
	local got; got=$(sha_file "$RAW")
	[ "$got" = "c1bdb0af89117b0f15ae317a973d18641b6815662c619167e94ab03283e79c7a" ] \
		&& ok "emmc.raw sha256 matches the recorded capture" \
		|| fail "emmc.raw sha256 = $got, expected c1bdb0af89..."
	got=$(sha_file "$BOOT0")
	[ "$got" = "ec95744e7877a743534be47663ad3979d7b629dd85571a4c27772dff57a32d9a" ] \
		&& ok "boot0 capture sha256 matches" \
		|| fail "boot0 sha256 = $got, expected ec95744e78..."
}

# ---- build a "post-eMMC-migration state" image on top of the stock capture ------------
# $1 = target file or block device to write into
build_emmc_boot_state() {
	local dev=$1
	dd if=/dev/zero of="$dev" bs=$MiB seek=684 count=32  conv=notrunc status=none   # recovery -> 0
	dd if=/dev/zero of="$dev" bs=$MiB seek=108 count=512 conv=notrunc status=none   # cache -> 0
	dd if=/dev/zero of="$dev" bs=$MiB seek=764 count=32  conv=notrunc status=none   # boot region -> 0
	dd if="$TSXBOOT" of="$dev" bs=$MiB seek=764 conv=notrunc status=none            # ... then mainline boot.img
	if ! mkfs.ext4 -F -q -L tsxroot-emmc -E offset=$((804 * MiB)) "$dev" $((2916 * 1024)) 2>"$T/mke2fs.err"; then
		echo "  (mke2fs -E offset failed on $dev, falling back to a separate image + dd)" >&2
		cat "$T/mke2fs.err" >&2
		truncate -s $((2916 * MiB)) "$T/fallback-fs.img"
		mkfs.ext4 -F -q -L tsxroot-emmc "$T/fallback-fs.img"
		dd if="$T/fallback-fs.img" of="$dev" bs=$MiB seek=804 conv=notrunc status=none
		rm -f "$T/fallback-fs.img"
	fi
}

main() {
echo "== test-emmc-restore: $(date -Is)"
echo "== SUT: $SRC"
echo "== bundle: $BUNDLE"
echo "== base image: $RAW"

manifest_check

rm -rf "$T"; mkdir -p "$T"

echo "-- building test images in $T (this copies ~8GB, may take a minute) --"
cp --sparse=always "$RAW" "$T/emmc.img"
cp "$BOOT0" "$T/boot0.img"
cp "$TSXBOOT" "$T/tsxboot-emmc.img"

# a boot0 with one byte flipped (byte offset 1000)
cp "$T/boot0.img" "$T/boot0-bad.img"
orig=$(dd if="$T/boot0-bad.img" bs=1 skip=1000 count=1 status=none | od -An -tu1 | tr -d ' ')
newb=$(( (orig + 1) % 256 ))
printf "$(printf '\\%03o' "$newb")" | dd of="$T/boot0-bad.img" bs=1 seek=1000 count=1 conv=notrunc status=none

# a bundle copy with a corrupted system.img (small files + one changed byte in system.img)
mkdir -p "$T/bundle-bad"
cp "$BUNDLE/emmc.manifest" "$BUNDLE/tsx-emmc-restore" "$BUNDLE/tsx-factory-restore" \
   "$BUNDLE/boot.img" "$BUNDLE/logo.img" "$BUNDLE/recovery.img.gz" \
   "$BUNDLE/cache.img.gz" "$BUNDLE/data.img.gz" "$T/bundle-bad/"
chmod +x "$T/bundle-bad/tsx-emmc-restore" "$T/bundle-bad/tsx-factory-restore"
cp "$BUNDLE/system.img" "$T/bundle-bad/system.img"
orig=$(dd if="$T/bundle-bad/system.img" bs=1 skip=12345 count=1 status=none | od -An -tu1 | tr -d ' ')
newb=$(( (orig + 1) % 256 ))
printf "$(printf '\\%03o' "$newb")" | dd of="$T/bundle-bad/system.img" bs=1 seek=12345 count=1 conv=notrunc status=none

# before-state hashes: bootloader (0..4MiB) and reserved (36..100MiB) must never move
BEFORE_BOOTLOADER=$(sha_range "$T/emmc.img" 0 4)
BEFORE_RESERVED=$(sha_range "$T/emmc.img" 36 64)
BEFORE_BOOT0=$(sha_file "$T/boot0.img")

echo "-- simulating the post-eMMC-migration state on T/emmc.img --"
build_emmc_boot_state "$T/emmc.img"

DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	DOCKER_OK=1
fi

# read the region list from the manifest once (name off len src want)
mapfile -t REGIONS < <(grep '^region ' "$MANIFEST" | awk '{print $2, $3, $4, $5, $6}')

if [ "$DOCKER_OK" = 1 ]; then
	echo "-- running tests 1-5 in a privileged alpine:3.24 container --"
	cat > "$T/dockertest.sh" <<'DOCKEREOF'
#!/bin/sh
set -u
apk add --no-cache e2fsprogs dosfstools sfdisk blkid losetup util-linux-misc util-linux >/w/log-apk.txt 2>&1 \
	|| { echo APK_FAIL > /w/log-apk-status.txt; exit 90; }
echo APK_OK > /w/log-apk-status.txt
RESTORE=/b/tsx-emmc-restore

env TSX_EMMC=/w/emmc.img TSX_BOOT0=/w/boot0.img \
	sh "$RESTORE" check /b >/w/log-t1.txt 2>&1
echo "T1_EXIT=$?" >> /w/log-t1.txt

env TSX_EMMC=/w/emmc.img TSX_BOOT0=/w/boot0-bad.img \
	sh "$RESTORE" check /b >/w/log-t2.txt 2>&1
echo "T2_EXIT=$?" >> /w/log-t2.txt

env TSX_EMMC=/w/emmc.img TSX_BOOT0=/w/boot0.img \
	sh "$RESTORE" check /w/bundle-bad >/w/log-t3.txt 2>&1
echo "T3_EXIT=$?" >> /w/log-t3.txt

env TSX_EMMC=/w/emmc.img TSX_BOOT0=/w/boot0.img \
	sh "$RESTORE" run /b --yes >/w/log-t4.txt 2>&1
echo "T4_EXIT=$?" >> /w/log-t4.txt

env TSX_EMMC=/w/emmc.img TSX_BOOT0=/w/boot0.img \
	sh "$RESTORE" run /b --yes >/w/log-t5.txt 2>&1
echo "T5_EXIT=$?" >> /w/log-t5.txt

MiB=1048576
LOOP=$(losetup -f --show /w/emmc-loop.img)
trap 'losetup -d "$LOOP" 2>/dev/null' EXIT
echo "LOOP=$LOOP" > /w/log-t6a.txt
dd if=/dev/zero of="$LOOP" bs=1M seek=684 count=32  conv=notrunc status=none
dd if=/dev/zero of="$LOOP" bs=1M seek=108 count=512 conv=notrunc status=none
dd if=/dev/zero of="$LOOP" bs=1M seek=764 count=32  conv=notrunc status=none
dd if=/w/tsxboot-emmc.img of="$LOOP" bs=1M seek=764 conv=notrunc status=none
if ! mkfs.ext4 -F -q -L tsxroot-emmc -E offset=$((804 * MiB)) "$LOOP" $((2916 * 1024)) >>/w/log-t6a.txt 2>&1; then
	echo "(mke2fs -E offset failed on $LOOP, falling back)" >>/w/log-t6a.txt
	truncate -s $((2916 * MiB)) /w/fallback-fs.img
	mkfs.ext4 -F -q -L tsxroot-emmc /w/fallback-fs.img >>/w/log-t6a.txt 2>&1
	dd if=/w/fallback-fs.img of="$LOOP" bs=1M seek=804 conv=notrunc status=none
	rm -f /w/fallback-fs.img
fi
env TSX_EMMC="$LOOP" TSX_BOOT0=/w/boot0.img \
	sh "$RESTORE" run /b --yes >>/w/log-t6a.txt 2>&1
echo "T6A_EXIT=$?" >>/w/log-t6a.txt
losetup -d "$LOOP"

mkdir -p /mnt/x
mount -o ro,noload,loop,offset=$((804 * MiB)) /w/emmc-loop.img /mnt/x >/w/log-t6b.txt 2>&1
MOUNTED_DEV=$(findmnt -n -o SOURCE /mnt/x)
echo "MOUNTED_DEV=$MOUNTED_DEV" >>/w/log-t6b.txt
env TSX_EMMC="$MOUNTED_DEV" TSX_BOOT0=/w/boot0.img TSX_EMMC_SECTORS=7634944 \
	sh "$RESTORE" check /b >>/w/log-t6b.txt 2>&1
echo "T6B_EXIT=$?" >>/w/log-t6b.txt
umount /mnt/x >>/w/log-t6b.txt 2>&1

echo ALL_DONE
DOCKEREOF
	chmod +x "$T/dockertest.sh"

	# fresh factory-state source for the loop-device test, built inside the
	# container onto the loop device itself (kept as pristine stock copy here)
	cp --sparse=always "$RAW" "$T/emmc-loop.img"

	. "$(dirname "$0")/../../../ci/loopcheck.sh"; loop_mark "$T/loops0"
	timeout 900 docker run --rm --privileged --platform linux/amd64 \
		-v "$T":/w -v "$BUNDLE":/b:ro \
		alpine:3.24 sh /w/dockertest.sh
	DOCKER_RC=$?
	leak=$(loop_new "$T/loops0"); [ -z "$leak" ] && ok "no loop device left attached" || fail "loop devices left attached: $leak"
	[ "$DOCKER_RC" = 0 ] && ok "docker test harness ran to completion (ALL_DONE)" \
		|| fail "docker test harness exited $DOCKER_RC (see $T/log-*.txt, cleaned up on exit -- rerun to inspect)"
else
	echo "-- docker unavailable or unusable: running tests 1-5 without a container --"
	if command -v busybox >/dev/null 2>&1; then
		SH="busybox sh"; echo "-- using host busybox sh --"
	else
		SH="sh"; echo "-- using plain host sh (no busybox found) --"
	fi
	env TSX_EMMC="$T/emmc.img" TSX_BOOT0="$T/boot0.img" \
		$SH "$SRC" check "$BUNDLE" >"$T/log-t1.txt" 2>&1; echo "T1_EXIT=$?" >>"$T/log-t1.txt"
	env TSX_EMMC="$T/emmc.img" TSX_BOOT0="$T/boot0-bad.img" \
		$SH "$SRC" check "$BUNDLE" >"$T/log-t2.txt" 2>&1; echo "T2_EXIT=$?" >>"$T/log-t2.txt"
	env TSX_EMMC="$T/emmc.img" TSX_BOOT0="$T/boot0.img" \
		$SH "$SRC" check "$T/bundle-bad" >"$T/log-t3.txt" 2>&1; echo "T3_EXIT=$?" >>"$T/log-t3.txt"
	env TSX_EMMC="$T/emmc.img" TSX_BOOT0="$T/boot0.img" \
		$SH "$SRC" run "$BUNDLE" --yes >"$T/log-t4.txt" 2>&1; echo "T4_EXIT=$?" >>"$T/log-t4.txt"
	env TSX_EMMC="$T/emmc.img" TSX_BOOT0="$T/boot0.img" \
		$SH "$SRC" run "$BUNDLE" --yes >"$T/log-t5.txt" 2>&1; echo "T5_EXIT=$?" >>"$T/log-t5.txt"
	echo "SKIPPED: test 6 (loop device + mount refusal) needs docker --privileged. docker not usable here"
fi

# ---- evaluate test 1 --------------------------------------------------------
if [ -f "$T/log-t1.txt" ]; then
	grep -q '^T1_EXIT=0$' "$T/log-t1.txt" && ok "test1: check exits 0 on a clean kernel-state image" \
		|| fail "test1: check did not exit 0 ($(grep T1_EXIT "$T/log-t1.txt"))"
	grep -q 'check OK' "$T/log-t1.txt" && ok "test1: printed 'check OK'" || fail "test1: no 'check OK' in output"
	grep -q 'misc: already as wanted' "$T/log-t1.txt" && ok "test1: misc already as wanted" || fail "test1: misc not reported as wanted"
	grep -q 'logo: already as wanted' "$T/log-t1.txt" && ok "test1: logo already as wanted" || fail "test1: logo not reported as wanted"
	for r in recovery cache data system boot; do
		grep -qE "$r: differs" "$T/log-t1.txt" && ok "test1: $r reported as differs" || fail "test1: $r not reported as differs"
	done
else
	fail "test1: no log captured"
fi

# ---- evaluate test 2 (bad boot0) --------------------------------------------
if [ -f "$T/log-t2.txt" ]; then
	grep -q '^T2_EXIT=0$' "$T/log-t2.txt" && fail "test2: check should have failed on a corrupted boot0 but exited 0" \
		|| ok "test2: check exits non-zero on a corrupted boot0"
	grep -q 'boot0 sha256 differs' "$T/log-t2.txt" && ok "test2: error message is 'boot0 sha256 differs'" \
		|| fail "test2: expected 'boot0 sha256 differs' in output"
else
	fail "test2: no log captured"
fi

# ---- evaluate test 3 (bad bundle) -------------------------------------------
if [ -f "$T/log-t3.txt" ]; then
	grep -q '^T3_EXIT=0$' "$T/log-t3.txt" && fail "test3: check should have failed on a corrupted bundle but exited 0" \
		|| ok "test3: check exits non-zero on a corrupted bundle"
	grep -q 'do not match emmc.manifest' "$T/log-t3.txt" && ok "test3: error message mentions 'do not match emmc.manifest'" \
		|| fail "test3: expected 'do not match emmc.manifest' in output"
else
	fail "test3: no log captured"
fi

# ---- evaluate test 4 (first run --yes) + full region verification ---------
if [ -f "$T/log-t4.txt" ]; then
	grep -q '^T4_EXIT=0$' "$T/log-t4.txt" && ok "test4: run --yes exits 0" || fail "test4: run --yes did not exit 0"
	grep -q 'DONE' "$T/log-t4.txt" && ok "test4: printed DONE" || fail "test4: no DONE in output"
else
	fail "test4: no log captured"
fi

if [ "$DOCKER_OK" = 1 ] || [ -f "$T/emmc.img" ]; then
	for line in "${REGIONS[@]}"; do
		read -r name off len src want <<<"$line"
		got=$(sha_range "$T/emmc.img" "$off" "$len")
		[ "$got" = "$want" ] && ok "test4: region $name sha256 matches manifest after restore" \
			|| fail "test4: region $name sha256 = $got, manifest wants $want"
	done
	AFTER_BOOTLOADER=$(sha_range "$T/emmc.img" 0 4)
	AFTER_RESERVED=$(sha_range "$T/emmc.img" 36 64)
	AFTER_BOOT0=$(sha_file "$T/boot0.img")
	[ "$AFTER_BOOTLOADER" = "$BEFORE_BOOTLOADER" ] && ok "test4: bootloader area (0..4MiB) unchanged" \
		|| fail "test4: bootloader area changed! $BEFORE_BOOTLOADER -> $AFTER_BOOTLOADER"
	[ "$AFTER_RESERVED" = "$BEFORE_RESERVED" ] && ok "test4: reserved area (36..100MiB) unchanged" \
		|| fail "test4: reserved area changed! $BEFORE_RESERVED -> $AFTER_RESERVED"
	[ "$AFTER_BOOT0" = "$BEFORE_BOOT0" ] && ok "test4: boot0 file untouched by the restore" \
		|| fail "test4: boot0 file changed! $BEFORE_BOOT0 -> $AFTER_BOOT0"

	cmp -s <(dd if="$T/emmc.img" bs=1 skip=$((764 * MiB)) count=8644608 status=none) "$BUNDLE/boot.img" \
		&& ok "test4: boot region head bytes == bundle/boot.img" \
		|| fail "test4: boot region head bytes != bundle/boot.img"
	cmp -s <(dd if="$T/emmc.img" bs=1 skip=$((804 * MiB)) count=652414976 status=none) "$BUNDLE/system.img" \
		&& ok "test4: system region head bytes == bundle/system.img" \
		|| fail "test4: system region head bytes != bundle/system.img"

	WHOLE_SHA1=$(sha_file "$T/emmc.img")
	ok "test4: whole-image sha256 after restore = $WHOLE_SHA1"
else
	fail "test4: T/emmc.img missing, cannot verify regions"
fi

# ---- evaluate test 5 (second run --yes, everything already as wanted) -----
if [ -f "$T/log-t5.txt" ]; then
	grep -q '^T5_EXIT=0$' "$T/log-t5.txt" && ok "test5: second run --yes exits 0" || fail "test5: second run --yes did not exit 0"
	grep -q 'DONE' "$T/log-t5.txt" && ok "test5: second run printed DONE" || fail "test5: second run has no DONE"
	n_wanted=$(grep -c 'already as wanted, skipped' "$T/log-t5.txt" || true)
	[ "$n_wanted" = "${#REGIONS[@]}" ] && ok "test5: all ${#REGIONS[@]} regions already as wanted (idempotent)" \
		|| fail "test5: only $n_wanted/${#REGIONS[@]} regions reported already as wanted"
	if [ -f "$T/emmc.img" ]; then
		WHOLE_SHA2=$(sha_file "$T/emmc.img")
		[ "$WHOLE_SHA2" = "${WHOLE_SHA1:-}" ] && ok "test5: whole-image sha256 unchanged/deterministic after second run" \
			|| fail "test5: whole-image sha256 changed on a no-op run! $WHOLE_SHA1 -> $WHOLE_SHA2"
	fi
else
	fail "test5: no log captured"
fi

# ---- evaluate test 6 (loop device + mounted refusal), docker only ---------
if [ "$DOCKER_OK" = 1 ]; then
	if [ -f "$T/log-t6a.txt" ]; then
		grep -q '^T6A_EXIT=0$' "$T/log-t6a.txt" && ok "test6a: run --yes over a loop device exits 0" \
			|| fail "test6a: run --yes over a loop device did not exit 0"
		grep -q 'DONE' "$T/log-t6a.txt" && ok "test6a: loop-device run printed DONE" || fail "test6a: loop-device run has no DONE"
		if [ -f "$T/emmc-loop.img" ]; then
			for line in "${REGIONS[@]}"; do
				read -r name off len src want <<<"$line"
				got=$(sha_range "$T/emmc-loop.img" "$off" "$len")
				[ "$got" = "$want" ] && ok "test6a: (loop) region $name sha256 matches manifest" \
					|| fail "test6a: (loop) region $name sha256 = $got, manifest wants $want"
			done
		else
			fail "test6a: T/emmc-loop.img missing, cannot verify regions"
		fi
	else
		fail "test6a: no log captured"
	fi

	if [ -f "$T/log-t6b.txt" ]; then
		grep -q '^T6B_EXIT=0$' "$T/log-t6b.txt" && fail "test6b: check should refuse a mounted device but exited 0" \
			|| ok "test6b: check exits non-zero against a mounted loop device"
		grep -q 'is mounted' "$T/log-t6b.txt" && ok "test6b: error message mentions 'is mounted'" \
			|| fail "test6b: expected 'is mounted' in output"
	else
		fail "test6b: no log captured"
	fi
else
	echo "  (test6 skipped: docker unavailable)"
fi

echo "== $N ok, $F failed"
if [ "$F" = 0 ]; then echo "PASS test-emmc-restore"; return 0 2>/dev/null || exit 0; fi
echo "FAIL test-emmc-restore"
return 1 2>/dev/null || exit 1
}

main 2>&1 | tee "$RESULTS"
exit "${PIPESTATUS[0]}"
