#!/bin/bash
# Host test of rootfs/overlay/usr/local/sbin/tsx-boot-ok (boot_retry
# reset + keep DataRecoveryDone=1). Runs the script as the panel
# runs it: armv7 Alpine 3.24 (qemu-user binfmt), busybox sh, u-boot-tools
# 2026.04 (= the rootfs package), on a loop block device that holds a REAL env
# block at 0x100000:
#   unit B  captures/tsw-1060-unitB/backup/... (the bench panel, hook installed,
#           snapshot with boot_retry=1, DataRecoveryDone=0)
#   unit A  captures/tsw-1060/backup/tsw1060-mmcblk0p3-env.img (stock env)
# fw_setenv is wrapped to count env writes. ~1 min. Usage: tests/test-boot-ok.sh
set -euo pipefail
INSTALLER_DIR=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS_DIR=$(cd "$INSTALLER_DIR/../rootfs" && pwd)
CAPTURES=${CAPTURES_DIR:-}
BFILE=$CAPTURES/tsw-1060-unitB/backup/tsw1060B-mmcblk0-20260926.img
AFILE=$CAPTURES/tsw-1060/backup/tsw1060-mmcblk0p3-env.img
if [ -z "$CAPTURES" ] || [ ! -f "$BFILE" ] || [ ! -f "$AFILE" ]; then
	echo "SKIPPED: needs real unit env captures (CAPTURES_DIR); not present here"
	exit 0
fi
W=${TMPDIR:-/tmp}/tsx-bootok-test; rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
dd if="$BFILE" of="$W/envB.bin" bs=65536 skip=16 count=1 status=none
dd if="$AFILE" of="$W/envA.bin" bs=65536 count=1 status=none
cp "$ROOTFS_DIR/overlay/usr/local/sbin/tsx-boot-ok" "$ROOTFS_DIR/overlay/etc/tsx/uboot-env.conf" "$W/"

docker run --rm --privileged --platform linux/arm/v7 -v "$W:/w" alpine:3.24 sh -euc '
apk add -q --no-cache u-boot-tools losetup >/dev/null
echo "== $(uname -m), $(apk info -e -v u-boot-tools), /bin/sh = $(readlink -f /bin/sh)"
for i in $(seq 0 63); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
truncate -s 2M /w/disk.img
L=$(losetup -f --show /w/disk.img); trap "losetup -d $L" EXIT
FP="fw_printenv -c /w/fw.cfg"; echo "$L 0x100000 0x10000" > /w/fw.cfg
# counting wrapper in front of the real fw_setenv
mkdir -p /wrap; printf "#!/bin/sh\necho \"\$*\" >> /w/setenv.calls\nexec /usr/bin/fw_setenv \"\$@\"\n" > /wrap/fw_setenv; chmod 755 /wrap/fw_setenv
mkdir -p /run/t
sed "s|^ENV_DISK=.*|ENV_DISK=$L|" /w/uboot-env.conf > /w/conf.yes
BOK="env PATH=/wrap:$PATH TSX_ENV_CONF=/w/conf.yes TSX_RUN=/run/t sh /w/tsx-boot-ok"
ok() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }
load() { dd if=$1 of=$L bs=65536 seek=16 conv=notrunc 2>/dev/null; : > /w/setenv.calls; }
blk() { dd if=$L bs=65536 skip=16 count=1 2>/dev/null | sha256sum | cut -d" " -f1; }
calls() { wc -l < /w/setenv.calls | tr -d " "; }
v() { $FP -n $1 2>/dev/null; }
others() { $FP | grep -v -e "^boot_retry=" -e "^golden_boot_retry=" -e "^DataRecoveryDone=" | sort; }

echo "== 1. unit B env (hook installed, boot_retry=1, DataRecoveryDone=0): one verified write"
load /w/envB.bin; O0=$(others); H0=$(blk)
[ "$(v boot_retry)" = 1 ] && [ "$(v DataRecoveryDone)" = 0 ] && ok "start state boot_retry=1 DataRecoveryDone=0 golden_boot_retry=$(v golden_boot_retry)"
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "tsx-boot-ok"; }; sed "s/^/    /" /tmp/o
grep -q "verified" /tmp/o && ok "reports the readback verification"
[ "$(v boot_retry)" = 0 ] && [ "$(v DataRecoveryDone)" = 1 ] && [ "$(v golden_boot_retry)" = 0 ] && ok "now boot_retry=0 DataRecoveryDone=1 golden_boot_retry=0"
[ "$(calls)" = 1 ] && grep -q -- "-s /run/t/tsx-boot-ok.setenv" /w/setenv.calls && ok "exactly one fw_setenv call (--script batch = one env write)"
[ "$(others)" = "$O0" ] && ok "all other $(echo "$O0" | wc -l) variables unchanged (tsx_boot, switch_bootmode, ethaddr, ...)"
$FP >/dev/null 2>&1 && ! $FP 2>&1 | grep -qi "bad crc" && ok "env CRC valid afterwards (fw_printenv)"
[ ! -e /run/t/tsx-boot-ok.setenv ] && ok "script file removed"

echo "== 2. second run: idempotent, no write"
H1=$(blk); : > /w/setenv.calls
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "second run"; }; sed "s/^/    /" /tmp/o
[ "$(calls)" = 0 ] && [ "$(blk)" = "$H1" ] && ok "no fw_setenv call, env block byte-identical"

echo "== 3. after an Android boot (logBootComplete: DataRecoveryDone=0), boot_retry already 0"
fw_setenv -c /w/fw.cfg DataRecoveryDone 0; : > /w/setenv.calls; BR=$(v boot_retry)
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "drd only"; }; sed "s/^/    /" /tmp/o
[ "$(calls)" = 1 ] && [ "$(v DataRecoveryDone)" = 1 ] && [ "$(v boot_retry)" = 0 ] && ok "one write, only DataRecoveryDone set back to 1"

echo "== 4. boot_retry=4, DataRecoveryDone already 1: only boot_retry"
fw_setenv -c /w/fw.cfg boot_retry 4; : > /w/setenv.calls
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "br only"; }; sed "s/^/    /" /tmp/o
[ "$(calls)" = 1 ] && [ "$(v boot_retry)" = 0 ] && grep -q "verified: boot_retry=0 (was" /tmp/o && ok "one write, boot_retry=0, DataRecoveryDone not rewritten"

echo "== 5. golden_boot_retry=3 + boot_retry=7 + DataRecoveryDone=0: all three in one write"
fw_setenv -c /w/fw.cfg golden_boot_retry 3; fw_setenv -c /w/fw.cfg boot_retry 7; fw_setenv -c /w/fw.cfg DataRecoveryDone 0; : > /w/setenv.calls; O0=$(others)
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "three"; }; sed "s/^/    /" /tmp/o
[ "$(calls)" = 1 ] && [ "$(v boot_retry)$(v golden_boot_retry)$(v DataRecoveryDone)" = 001 ] && [ "$(others)" = "$O0" ] && ok "one write, 0/0/1, others unchanged"

echo "== 6. DEFUSE_GOLDEN=no: DataRecoveryDone left alone"
fw_setenv -c /w/fw.cfg DataRecoveryDone 0; fw_setenv -c /w/fw.cfg boot_retry 2; : > /w/setenv.calls
sed "s/^DEFUSE_GOLDEN=.*/DEFUSE_GOLDEN=no/" /w/conf.yes > /w/conf.no
env PATH=/wrap:$PATH TSX_ENV_CONF=/w/conf.no TSX_RUN=/run/t sh /w/tsx-boot-ok > /tmp/o 2>&1 || { cat /tmp/o; fail "defuse no"; }
[ "$(v DataRecoveryDone)" = 0 ] && [ "$(v boot_retry)" = 0 ] && ok "boot_retry reset, DataRecoveryDone stays 0"
grep -v "^DEFUSE_GOLDEN=" /w/conf.yes > /w/conf.old; fw_setenv -c /w/fw.cfg boot_retry 2
env PATH=/wrap:$PATH TSX_ENV_CONF=/w/conf.old TSX_RUN=/run/t sh /w/tsx-boot-ok > /tmp/o 2>&1 || { cat /tmp/o; fail "old conf"; }
[ "$(v DataRecoveryDone)" = 1 ] && ok "a uboot-env.conf without DEFUSE_GOLDEN (older rootfs) means yes"

echo "== 7. --status / --dry-run write nothing"
fw_setenv -c /w/fw.cfg boot_retry 5; fw_setenv -c /w/fw.cfg DataRecoveryDone 0; H=$(blk); : > /w/setenv.calls
$BOK --status > /tmp/o 2>&1; sed "s/^/    /" /tmp/o
[ "$(sed -n "s/^boot_retry=\([0-9]*\).*/\1/p" /tmp/o)" = 5 ] && grep -q "DataRecoveryDone=0" /tmp/o && ok "--status: boot_retry=5 parsed the way rootfs/uboot/cycle.sh does, DataRecoveryDone shown"
$BOK --dry-run > /tmp/o 2>&1; sed "s/^/    /" /tmp/o
grep -q "would set: boot_retry=0,DataRecoveryDone=1" /tmp/o && [ "$(calls)" = 0 ] && [ "$(blk)" = "$H" ] && ok "--dry-run: plan printed, env block unchanged"

echo "== 8. refusals leave the env untouched"
sed "s/^ENV_VERIFIED=.*/ENV_VERIFIED=no/" /w/conf.yes > /w/conf.nv
env PATH=/wrap:$PATH TSX_ENV_CONF=/w/conf.nv TSX_RUN=/run/t sh /w/tsx-boot-ok > /tmp/o 2>&1 && fail "ran without ENV_VERIFIED"
grep -q "not verified" /tmp/o && [ "$(calls)" = 0 ] && [ "$(blk)" = "$H" ] && ok "ENV_VERIFIED=no: refused, nothing written"
printf X | dd of=$L bs=1 seek=$((0x100000 + 200)) conv=notrunc 2>/dev/null; HB=$(blk)
$BOK > /tmp/o 2>&1 && fail "wrote over a bad CRC"
grep -qi "crc bad" /tmp/o && [ "$(calls)" = 0 ] && [ "$(blk)" = "$HB" ] && ok "bad CRC: refused, block unchanged (fw_setenv would have written a default env)"
load /w/envB.bin; fw_setenv -c /w/fw.cfg aml_dt m8m2_n200_1G; : > /w/setenv.calls; H=$(blk)
$BOK > /tmp/o 2>&1 && fail "wrote a foreign env"
grep -q "does not look like" /tmp/o && [ "$(calls)" = 0 ] && [ "$(blk)" = "$H" ] && ok "env of another board: refused, nothing written"

echo "== 9. readback catches a bad write"
load /w/envB.bin
printf "#!/bin/sh\necho \"\$*\" >> /w/setenv.calls\n/usr/bin/fw_setenv \"\$@\" && /usr/bin/fw_setenv -c /w/fw.cfg bootdelay 9\n" > /wrap/fw_setenv
$BOK > /tmp/o 2>&1 && fail "accepted a write that changed another variable"
grep -q "variables other than" /tmp/o && ok "a write that also changed another variable is reported (exit 1)"
printf "#!/bin/sh\necho \"\$*\" >> /w/setenv.calls\nexit 0\n" > /wrap/fw_setenv; load /w/envB.bin
$BOK > /tmp/o 2>&1 && fail "accepted a write that did nothing"
grep -q "readback: boot_retry" /tmp/o && ok "a write that did not land is reported (exit 1)"

echo "== 10. unit A stock env (no hook, DataRecoveryDone=0, boot_retry=0)"
printf "#!/bin/sh\necho \"\$*\" >> /w/setenv.calls\nexec /usr/bin/fw_setenv \"\$@\"\n" > /wrap/fw_setenv
load /w/envA.bin; O0=$(others)
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "unit A"; }; sed "s/^/    /" /tmp/o
[ "$(calls)" = 1 ] && [ "$(v DataRecoveryDone)" = 1 ] && [ "$(v boot_retry)" = 0 ] && [ "$(others)" = "$O0" ] && ok "one write: DataRecoveryDone=1 only"
fw_setenv -c /w/fw.cfg DataRecoveryDone; : > /w/setenv.calls
$BOK > /tmp/o 2>&1 || { cat /tmp/o; fail "absent"; }
[ "$(v DataRecoveryDone)" = 1 ] && [ "$(calls)" = 1 ] && ok "DataRecoveryDone missing from the env: added (golden treats missing as != 1)"
echo "PASS test-boot-ok"
' | tee "$W/out.txt"
N=$(grep -c "  ok: " "$W/out.txt" || true); echo "ok checks: $N (expected 22)"
[ "$N" = 22 ] && grep -q "^PASS" "$W/out.txt" || { echo "FAIL: a check was skipped or failed"; exit 1; }
