#!/bin/bash
# Host test of installer/lib/tsx-rescue.sh's writers (tsx_env_apply,
# tsx_mbr_fold, tsx_mkfs_tsxdata) against plain-file fixtures -- same style as
# installer/emmc/tests/test-usb-recovery.sh (no loop device, no docker; env
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

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-tsx-rescue || echo FAIL test-tsx-rescue
exit $F
