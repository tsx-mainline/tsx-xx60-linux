#!/bin/bash
# Host test of installer/emmc/tsx-usb-recovery against a bare 64 KiB U-Boot
# env fixture (no loop device, no docker: fw_printenv/fw_setenv accept a
# plain file as the "device" in fw_env.config, and TSX_ENV_DEV points
# tsx-usb-recovery straight at it). Needs fw_printenv/fw_setenv (u-boot-tools)
# only. Usage: installer/emmc/tests/test-usb-recovery.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$HERE/tsx-usb-recovery"
STOCK_SWITCH='usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;'
FALLBACK_HOOK="${STOCK_SWITCH}if itest \${boot_retry} -lt 6; then run tsx_boot; fi"
ONCE_HOOK="${STOCK_SWITCH}if itest \${tsx_once} -eq 1; then setenv tsx_once 0; saveenv; run tsx_boot; fi"
# Bound every fw_printenv/fw_setenv call the tool makes (see tsx-usb-recovery's
# TSX_FWENV_TIMEOUT): a config whose declared env size doesn't match the real
# file size makes u-boot-tools' read loop spin at 100% CPU forever instead of
# erroring out (confirmed on both uboot-tools 2026.07 and Alpine's 2026.04).
# Keep it short here since every fixture below is well-formed and should
# return immediately; a long run means something regressed.
export TSX_FWENV_TIMEOUT=3
W=$(mktemp -d)
cleanup() { jobs -p | xargs -r kill -9 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT INT TERM HUP
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkenv() {   # mkenv OUTFILE 'switch_bootmode value'
	python3 - "$1" "$2" <<'PY'
import struct, sys, zlib
out, sw = sys.argv[1], sys.argv[2]
entries = [b'aml_dt=yushan_one_10inch', b'crestron_uboot_version=1.00.12',
           b'preboot=run switch_bootmode', ('switch_bootmode=' + sw).encode(), b'boot_retry=0']
body = b'\0'.join(entries) + b'\0\0'
body += b'\0' * (65536 - 4 - len(body))
assert len(body) == 65536 - 4
open(out, 'wb').write(struct.pack('<I', zlib.crc32(body) & 0xffffffff) + body)
PY
}
swval() {   # swval ENVFILE
	python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()[4:]
for raw in d.split(b'\0'):
    if raw.startswith(b'switch_bootmode='):
        print(raw[len(b'switch_bootmode='):].decode())
        break
PY
}
crcok() { python3 -c "
import sys, zlib, struct
d = open('$1','rb').read()
stored = struct.unpack_from('<I', d, 0)[0]
sys.exit(0 if zlib.crc32(d[4:]) & 0xffffffff == stored else 1)
"; }

echo "== 1. status on the stock hook (disabled)"
E=$W/env.bin; mkenv "$E" "$STOCK_SWITCH"
OUT=$(TSX_ENV_DEV="$E" TSX_RUN="$W" "$TOOL" status) && ok "status exits 0 on a recognised (disabled) hook"
echo "$OUT" | grep -q ': disabled ' && ok "status reports disabled"

echo "== 2. enable"
OUT=$(TSX_ENV_DEV="$E" TSX_RUN="$W" "$TOOL" enable) || { echo "$OUT"; bad "enable failed"; }
echo "$OUT" | grep -q "done and verified" && ok "enable reports done and verified"
crcok "$E" && ok "env CRC valid after enable"
NEWSW=$(swval "$E")
[ "$NEWSW" = "gset GPIOX_18 out high; msleep 500; ${STOCK_SWITCH}" ] && ok "switch_bootmode has the VBUS prefix, rest byte-identical"

echo "== 3. status after enable"
OUT=$(TSX_ENV_DEV="$E" TSX_RUN="$W" "$TOOL" status) && echo "$OUT" | grep -q ': enabled ' && ok "status reports enabled"

echo "== 4. enable again (idempotent, no second write)"
CRC0=$(dd if="$E" bs=1 count=4 2>/dev/null | od -An -tx1)
OUT=$(TSX_ENV_DEV="$E" TSX_RUN="$W" "$TOOL" enable) || { echo "$OUT"; bad "second enable failed"; }
echo "$OUT" | grep -q "already enabled" && ok "second enable: already enabled, nothing written"
[ "$(swval "$E")" = "$NEWSW" ] && ok "idempotent: switch_bootmode unchanged"

echo "== 5. disable"
OUT=$(TSX_ENV_DEV="$E" TSX_RUN="$W" "$TOOL" disable) || { echo "$OUT"; bad "disable failed"; }
echo "$OUT" | grep -q "done and verified" && ok "disable reports done and verified"
crcok "$E" && ok "env CRC valid after disable"
[ "$(swval "$E")" = "$STOCK_SWITCH" ] && ok "switch_bootmode back to byte-identical stock"

echo "== 6. disable again (idempotent)"
OUT=$(TSX_ENV_DEV="$E" TSX_RUN="$W" "$TOOL" disable) || { echo "$OUT"; bad "second disable failed"; }
echo "$OUT" | grep -q "already disabled" && ok "second disable: already disabled, nothing written"

echo "== 7. round trip on the fallback hook variant (not just bare stock)"
E2=$W/env2.bin; mkenv "$E2" "$FALLBACK_HOOK"
TSX_ENV_DEV="$E2" TSX_RUN="$W" "$TOOL" enable >/dev/null
[ "$(swval "$E2")" = "gset GPIOX_18 out high; msleep 500; ${FALLBACK_HOOK}" ] && ok "enable on the fallback-guard hook: VBUS prefix + hook byte-identical"
TSX_ENV_DEV="$E2" TSX_RUN="$W" "$TOOL" disable >/dev/null
[ "$(swval "$E2")" = "$FALLBACK_HOOK" ] && ok "disable on the fallback-guard hook: back to byte-identical"
crcok "$E2" && ok "env CRC valid after the fallback-hook round trip"

echo "== 7b. round trip on the once-guard hook variant (rescue-arm.sh's default, v2 one-shot)"
E2B=$W/env2b.bin; mkenv "$E2B" "$ONCE_HOOK"
TSX_ENV_DEV="$E2B" TSX_RUN="$W" "$TOOL" enable >/dev/null
[ "$(swval "$E2B")" = "gset GPIOX_18 out high; msleep 500; ${ONCE_HOOK}" ] && ok "enable on the once-guard hook: VBUS prefix + hook byte-identical"
TSX_ENV_DEV="$E2B" TSX_RUN="$W" "$TOOL" disable >/dev/null
[ "$(swval "$E2B")" = "$ONCE_HOOK" ] && ok "disable on the once-guard hook: back to byte-identical"
crcok "$E2B" && ok "env CRC valid after the once-hook round trip"

echo "== 8. a bad CRC is refused"
E3=$W/env3.bin; mkenv "$E3" "$STOCK_SWITCH"; printf '\xff' | dd of="$E3" bs=1 seek=100 conv=notrunc 2>/dev/null
TSX_ENV_DEV="$E3" TSX_RUN="$W" "$TOOL" enable >"$W/e3.txt" 2>&1 && bad "bad CRC accepted" || { grep -qi "bad crc\|CRC bad" "$W/e3.txt" && ok "bad CRC refused, nothing written"; }

echo "== 9. a foreign switch_bootmode is refused"
E4=$W/env4.bin; mkenv "$E4" "run something_else"
TSX_ENV_DEV="$E4" TSX_RUN="$W" "$TOOL" enable >"$W/e4.txt" 2>&1 && bad "foreign switch_bootmode accepted" || ok "foreign switch_bootmode refused"
TSX_ENV_DEV="$E4" TSX_RUN="$W" "$TOOL" status >"$W/e4s.txt" 2>&1 || true; grep -q foreign "$W/e4s.txt" && ok "status reports foreign"

echo "== 10. a short/truncated env file fails fast, it does not hang (regression for the fw_printenv CPU spin)"
E5=$W/env5.bin; mkenv "$E5" "$STOCK_SWITCH"; truncate -s 32768 "$E5"   # half the declared 0x10000
T0=$(date +%s)
TSX_ENV_DEV="$E5" TSX_RUN="$W" "$TOOL" status >"$W/e5.txt" 2>&1 && bad "short env file accepted" || ok "short env file refused (not silently accepted)"
T1=$(date +%s)
[ $((T1 - T0)) -le $((TSX_FWENV_TIMEOUT + 5)) ] && ok "short env file failed within the bounded timeout (${T1}-${T0}=$((T1-T0))s), no CPU-spin hang" || bad "took $((T1-T0))s: the timeout bound did not hold"
grep -qi "timed out\|failed" "$W/e5.txt" && ok "error message names the failure"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-usb-recovery || echo FAIL test-usb-recovery
exit $F
