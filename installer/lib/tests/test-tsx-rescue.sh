#!/bin/bash
# Host test of installer/lib/tsx-rescue.sh's writers (tsx_env_apply,
# tsx_mbr_fold, tsx_mkfs_tsxdata) against plain-file fixtures -- same style as
# installer/emmc/tests/test-usb-recovery.sh (no loop device, no docker. Env
# fixtures are bare 64 KiB blocks fw_printenv/fw_setenv accept as a file).
# Needs fw_printenv/fw_setenv (u-boot-tools), mke2fs/e2fsck/blkid (e2fsprogs).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tsx-rescue.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkenv() {   # mkenv OUTFILE 'boot_retry value' 'golden_boot_retry value' 'DataRecoveryDone value'
	python3 - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys, zlib
out, br, gbr, drd = sys.argv[1:5]
entries = [b'aml_dt=yushan_one_10inch', b'crestron_uboot_version=1.00.12',
           b'preboot=run switch_bootmode', ('boot_retry=' + br).encode(),
           ('golden_boot_retry=' + gbr).encode(), ('DataRecoveryDone=' + drd).encode(),
           b'switch_bootmode=usb start 0;something', b'ethaddr=00:11:22:33:44:55']
body = b'\0'.join(entries) + b'\0\0'
body += b'\0' * (65536 - 4 - len(body))
open(out, 'wb').write(struct.pack('<I', zlib.crc32(body) & 0xffffffff) + body)
PY
}
getv() { python3 -c "
import sys
d = open('$1','rb').read()[4:]
for raw in d.split(b'\0'):
    if raw.startswith(b'$2='):
        print(raw[len(b'$2='):].decode()); break
"; }
crcok() { python3 -c "
import sys, zlib, struct
d = open('$1','rb').read()
stored = struct.unpack_from('<I', d, 0)[0]
sys.exit(0 if zlib.crc32(d[4:]) & 0xffffffff == stored else 1)
"; }

echo "== 1. tsx_env_apply: fresh write of boot_retry/golden_boot_retry/DataRecoveryDone"
E=$W/env.bin; mkenv "$E" 5 3 0
echo "$E 0x0 0x10000" > "$W/cfg"
OUT=$(TSX_RUN="$W" tsx_env_apply "$W/cfg" "boot_retry 0
golden_boot_retry 0
DataRecoveryDone 1" 2>&1) && ok "tsx_env_apply exits 0" || bad "tsx_env_apply failed: $OUT"
echo "$OUT" | grep -q "updated and verified" && ok "reports updated and verified"
crcok "$E" && ok "env CRC valid after the write"
[ "$(getv "$E" boot_retry)" = 0 ] && [ "$(getv "$E" golden_boot_retry)" = 0 ] && [ "$(getv "$E" DataRecoveryDone)" = 1 ] && ok "all three values applied"
[ "$(getv "$E" ethaddr)" = "00:11:22:33:44:55" ] && ok "unrelated variable (ethaddr) untouched"

echo "== 2. tsx_env_apply: already correct (no write)"
CRC0=$(dd if="$E" bs=1 count=4 2>/dev/null | od -An -tx1)
OUT=$(TSX_RUN="$W" tsx_env_apply "$W/cfg" "boot_retry 0
golden_boot_retry 0
DataRecoveryDone 1" 2>&1) && ok "second apply exits 0"
echo "$OUT" | grep -q "already matches" && ok "reports nothing to do"

echo "== 3. tsx_env_apply: arm value (boot_retry=4), one write"
E2=$W/env2.bin; mkenv "$E2" 0 0 0
echo "$E2 0x0 0x10000" > "$W/cfg2"
TSX_RUN="$W" tsx_env_apply "$W/cfg2" "boot_retry 4" >/dev/null 2>&1 && ok "arm write (boot_retry=4) applied"
[ "$(getv "$E2" boot_retry)" = 4 ] && ok "boot_retry is 4 (one rescue boot armed)"
[ "$(getv "$E2" DataRecoveryDone)" = 0 ] && ok "other variables (DataRecoveryDone) untouched by the arm write"

echo "== 4. tsx_env_apply: refuses a bad CRC"
E3=$W/env3.bin; mkenv "$E3" 0 0 0; printf '\xff' | dd of="$E3" bs=1 seek=100 conv=notrunc 2>/dev/null
echo "$E3 0x0 0x10000" > "$W/cfg3"
OUT=$(TSX_RUN="$W" tsx_env_apply "$W/cfg3" "boot_retry 1" 2>&1) && bad "bad CRC accepted" || ok "bad CRC refused"
echo "$OUT" | grep -qi "bad crc" && ok "error mentions bad CRC"

echo "== 4b. tsx_env_apply: a short/truncated env file fails fast, it does not hang (regression for the fw_printenv CPU spin, docs/boot.md 'fw_printenv can hang')"
E3B=$W/env3b.bin; mkenv "$E3B" 0 0 0; truncate -s 32768 "$E3B"   # half the declared 0x10000
echo "$E3B 0x0 0x10000" > "$W/cfg3b"
T0=$(date +%s)
OUT=$(TSX_RUN="$W" TSX_FWENV_TIMEOUT=3 tsx_env_apply "$W/cfg3b" "boot_retry 1" 2>&1) && bad "short env file accepted" || ok "short env file refused (not silently accepted)"
T1=$(date +%s)
[ $((T1 - T0)) -le 8 ] && ok "short env file failed within the bounded timeout ($((T1-T0))s), no CPU-spin hang" || bad "took $((T1-T0))s: the timeout bound did not hold"
echo "$OUT" | grep -qi "timed out\|failed" && ok "error message names the failure"

echo "== 5. tsx_mbr_fold: 0x05 -> 0x83, readback verified"
D=$W/disk.bin; python3 -c "open('$D','wb').write(b'\0'*512)"
printf '\5' | dd of="$D" bs=1 seek=498 conv=notrunc 2>/dev/null
OUT=$(tsx_mbr_fold "$D" 498 2>&1) && ok "tsx_mbr_fold exits 0"
[ "$(od -An -tx1 -j 498 -N 1 "$D" | tr -d ' ')" = 83 ] && ok "byte 498 is now 0x83"

echo "== 6. tsx_mbr_fold: idempotent at 0x83"
OUT=$(tsx_mbr_fold "$D" 498 2>&1) && echo "$OUT" | grep -q "already 0x83" && ok "second fold: already 0x83, no-op"

echo "== 7. tsx_mbr_fold: refuses an unexpected byte"
D2=$W/disk2.bin; python3 -c "open('$D2','wb').write(b'\0'*512)"
printf '\x07' | dd of="$D2" bs=1 seek=498 conv=notrunc 2>/dev/null
OUT=$(tsx_mbr_fold "$D2" 498 2>&1) && bad "unexpected byte (0x07) accepted" || ok "unexpected byte (0x07) refused: $OUT"

echo "== 8. tsx_mkfs_tsxdata: label + UUID"
IMG=$W/p4.img; python3 -c "open('$IMG','wb').write(b'\0'*67108864)"   # 64 MiB, enough for a tiny ext4
UUID=12345678-1234-1234-1234-123456789abc
tsx_mkfs_tsxdata "$IMG" "$UUID" >/dev/null 2>&1 && ok "tsx_mkfs_tsxdata exits 0"
e2fsck -fn "$IMG" >/dev/null 2>&1 && ok "e2fsck -fn clean"
[ "$(blkid -o value -s LABEL "$IMG" 2>/dev/null)" = tsxdata ] && ok "LABEL=tsxdata"
[ "$(blkid -o value -s UUID "$IMG" 2>/dev/null)" = "$UUID" ] && ok "UUID matches (stale-label trap check, docs/recovery.md)"

echo "== 9. tsx_env_apply: the once-arm write (boot_retry=0, tsx_once=1 together)"
E4=$W/env4.bin; mkenv "$E4" 9 0 0
echo "$E4 0x0 0x10000" > "$W/cfg4"
OUT=$(TSX_RUN="$W" tsx_env_apply "$W/cfg4" "boot_retry 0
tsx_once 1" 2>&1) && ok "once-arm write applied" || bad "once-arm write failed: $OUT"
[ "$(getv "$E4" boot_retry)" = 0 ] && [ "$(getv "$E4" tsx_once)" = 1 ] && ok "boot_retry=0, tsx_once=1 both applied"
[ "$(getv "$E4" ethaddr)" = "00:11:22:33:44:55" ] && ok "unrelated variable untouched by the once-arm write"

echo "== 10. tsx_env_apply: clearing tsx_once alone (what U-Boot's own hook does) touches nothing else"
OUT=$(TSX_RUN="$W" tsx_env_apply "$W/cfg4" "tsx_once 0" 2>&1) && ok "tsx_once clear applied"
[ "$(getv "$E4" tsx_once)" = 0 ] && ok "tsx_once is 0 after the clear"
[ "$(getv "$E4" boot_retry)" = 0 ] && ok "boot_retry (0) untouched by the tsx_once-only clear"

echo "== 11. TSX_SWITCH_ONCE (installer/android/tsx-lib.sh) matches tsx-env.py GUARDS['once'] byte-for-byte"
# Two independent copies of the hook text exist (the Android-side arm script
# sources tsx-lib.sh. tsx-env.py builds card images and does the factory
# unhook) -- this is the drift check for both.
LIBDIR=$(cd "$HERE/../android" && pwd)
. "$LIBDIR/tsx-lib.sh"
PYONCE=$(python3 -c "
import importlib.util as u
spec = u.spec_from_file_location('tsxenv', '$HERE/../sdcard/tsx-env.py')
m = u.module_from_spec(spec); spec.loader.exec_module(m)
print(m.GUARDS['once'])
")
[ "$TSX_SWITCH_ONCE" = "$PYONCE" ] && ok "TSX_SWITCH_ONCE (bash) == GUARDS['once'] (python)" \
	|| bad "hook text mismatch: bash='$TSX_SWITCH_ONCE' python='$PYONCE'"
case "$TSX_SWITCH_ONCE" in
*'if itest ${tsx_once} -eq 1; then setenv tsx_once 0; saveenv; run tsx_boot; fi')
	ok "tsx_once is cleared (setenv 0, then saveenv) BEFORE run tsx_boot, in that order";;
*) bad "TSX_SWITCH_ONCE does not clear tsx_once before running tsx_boot: $TSX_SWITCH_ONCE";;
esac
[ "$TSX_BOOT_CMD" = 'mmcinfo; if fatexist mmc 0 tsxboot.off; then echo tsx: mainline disabled; else if fatexist mmc 0 tsxboot.img; then echo tsx: booting tsxboot.img; fatload mmc 0 ${loadaddr} tsxboot.img; bootm; fi; fi' ] \
	&& ok "TSX_BOOT_CMD (the fatload/bootm hook target) is unchanged by the once guard"

echo "== 12. once-guard semantics: armed / not armed / after fallback"
# This host has no U-Boot hush interpreter. So the test does not parse or run
# the hush text. It models the documented semantics of TSX_SWITCH_ONCE and
# TSX_BOOT_CMD (checked byte for byte above) as a small state machine.
# Three scenarios:
sim_once() {   # sim_once TSX_ONCE_IN TSXBOOT_OFF_PRESENT TSXBOOT_IMG_PRESENT -> "BOOTS_RESCUE|no_rescue TSX_ONCE_OUT"
	local once_in=${1:-} off=${2:-} img=${3:-}
	local once_out=$once_in result=no_rescue
	if [ "$once_in" = 1 ]; then
		once_out=0   # setenv tsx_once 0; saveenv -- happens before run tsx_boot, unconditionally
		if [ "$off" = 1 ]; then result=no_rescue   # tsx: mainline disabled
		elif [ "$img" = 1 ]; then result=boots_rescue
		else result=no_rescue
		fi
	fi
	echo "$result $once_out"
}
R=$(sim_once 1 0 1); [ "$R" = "boots_rescue 0" ] && ok "armed (tsx_once=1, tsxboot.img present): boots the rescue once, and clears tsx_once" || bad "armed case: got '$R'"
R=$(sim_once 0 0 1); [ "$R" = "no_rescue 0" ] && ok "not armed (tsx_once=0, tsxboot.img still present): hook does nothing, stock bootcmd runs" || bad "not-armed case: got '$R'"
R=$(sim_once "" 0 1); [ "$R" = "no_rescue " ] && ok "not armed (tsx_once unset): hook does nothing" || bad "unset case: got '$R'"
# After a fallback, the rescue never checked in on its one shot and tsx_once is
# already 0 from that boot. The unit is power-cycled again. tsxboot.img and
# the golden slot still hold the rescue image.
R=$(sim_once 0 0 1); [ "$R" = "no_rescue 0" ] && ok "after fallback (tsx_once already spent): stays on stock Android even though tsxboot.img is still there" || bad "after-fallback case: got '$R'"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-tsx-rescue || echo FAIL test-tsx-rescue
exit $F
