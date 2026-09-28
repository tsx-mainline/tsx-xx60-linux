#!/bin/bash
# Host test: installer/lib/tsx-arm-from-mainline.sh (arm one rescue boot from
# a running mainline kiosk; shared by tsx-install-mainline's reinstall path
# and tsx-restore-factory). No panel, no root: mount/umount/fw_printenv/
# fw_setenv/reboot are PATH shims working on a directory (the "p1") and a
# key=value file (the "env"). Syntax is checked with busybox sh -n (the
# panel's shell); the functional cases run it under bash --posix, because a
# busybox sh built with standalone applets runs its own mount/umount/reboot
# and ignores the PATH shims.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ARM="$HERE/lib/tsx-arm-from-mainline.sh"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-arm-from-mainline: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkdir -p "$W/bin"
cat > "$W/bin/mount" <<'EOF'
#!/bin/sh
exit 0
EOF
cp "$W/bin/mount" "$W/bin/umount"
cat > "$W/bin/fw_printenv" <<'EOF'
#!/bin/sh
# fw_printenv -c CFG -l DIR -n NAME
while [ $# -gt 1 ]; do case "$1" in -c|-l) shift 2;; -n) shift;; *) break;; esac; done
v=$(sed -n "s/^$1=//p" "$TSX_TEST_ENV" | tail -n 1)
[ -n "$v" ] || exit 1
echo "$v"
EOF
cat > "$W/bin/fw_setenv" <<'EOF'
#!/bin/sh
while [ $# -gt 2 ]; do case "$1" in -c|-l) shift 2;; *) break;; esac; done
grep -v "^$1=" "$TSX_TEST_ENV" > "$TSX_TEST_ENV.new"; echo "$1=$2" >> "$TSX_TEST_ENV.new"; mv "$TSX_TEST_ENV.new" "$TSX_TEST_ENV"
EOF
cat > "$W/bin/reboot" <<'EOF'
#!/bin/sh
touch "$TSX_TEST_ENV.rebooted"
EOF
chmod +x "$W/bin/"*

ONCE='gset GPIOX_18 out high; if itest ${tsx_once} -eq 1; then setenv tsx_once 0; saveenv; run tsx_boot; fi'
mkimg() { { printf 'ANDROID!'; head -c 4096 /dev/urandom; } > "$1"; }
setup() {  # $1 = switch_bootmode value
	rm -rf "$W/p1" "$W/run" "$W/env"*; mkdir -p "$W/p1" "$W/run"
	mkimg "$W/p1/boot.img"; mkimg "$W/p1/tsxboot.img"; : > "$W/p1/tsxboot.off"
	printf 'switch_bootmode=%s\ntsx_once=0\nboot_retry=0\n' "$1" > "$W/env"
}
run_arm() {
	PATH="$W/bin:$PATH" TSX_TEST_ENV="$W/env" TSX_MNT="$W/p1" TSX_RUN="$W/run" TSX_P1=/dev/null \
		bash --posix "$ARM" "$@" 2>&1
}
sha() { sha256sum < "$1" | cut -d' ' -f1; }

echo "== 0. busybox sh -n"
busybox sh -n "$ARM" && ok "syntax (busybox sh -n)" || bad "busybox sh -n failed"

echo "== 1. --rescue FILE, once guard, tsxboot.off present"
setup "$ONCE"; mkimg "$W/new.img"
OUT=$(run_arm --rescue "$W/new.img" --no-reboot); RC=$?
[ $RC = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ "$(sha "$W/p1/tsxboot.img")" = "$(sha "$W/new.img")" ] && ok "p1:tsxboot.img = the new rescue" || bad "tsxboot.img not replaced"
[ ! -e "$W/p1/tsxboot.off" ] && ok "tsxboot.off removed" || bad "tsxboot.off still there"
grep -qx 'tsx_once=1' "$W/env" && ok "tsx_once=1 armed" || bad "tsx_once not armed"
echo "$OUT" | grep -qx ARMED && ok "prints ARMED (--no-reboot)" || bad "no ARMED line: $OUT"
[ ! -e "$W/env.rebooted" ] && ok "no reboot with --no-reboot" || bad "rebooted despite --no-reboot"

echo "== 2. default source is the golden slot (p1:boot.img); reboot"
setup "$ONCE"
OUT=$(run_arm); RC=$?; sleep 3
[ $RC = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ "$(sha "$W/p1/tsxboot.img")" = "$(sha "$W/p1/boot.img")" ] && ok "p1:tsxboot.img = p1:boot.img" || bad "tsxboot.img is not the golden image"
echo "$OUT" | grep -qx REBOOTING && ok "prints REBOOTING" || bad "no REBOOTING line: $OUT"
[ -e "$W/env.rebooted" ] && ok "reboot called" || bad "reboot not called"

echo "== 3. the tsx_boot hook missing: refused, nothing written"
setup 'gset GPIOX_18 out high; run storeboot'; mkimg "$W/new.img"; BEFORE=$(sha "$W/p1/tsxboot.img")
OUT=$(run_arm --rescue "$W/new.img" --no-reboot); RC=$?
[ $RC = 1 ] && ok "exit 1" || bad "exit $RC"
echo "$OUT" | grep -q "hook (tsx_boot) is not installed" && ok "names the missing hook" || bad "message: $OUT"
[ "$(sha "$W/p1/tsxboot.img")" = "$BEFORE" ] && [ -e "$W/p1/tsxboot.off" ] && ok "p1 untouched" || bad "p1 changed"
grep -qx 'tsx_once=0' "$W/env" && ok "env untouched" || bad "env changed"

echo "== 4. the older boot_retry guard: no env write"
setup 'if itest ${boot_retry} -lt 6; then run tsx_boot; fi'; mkimg "$W/new.img"
OUT=$(run_arm --rescue "$W/new.img" --no-reboot); RC=$?
[ $RC = 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -qx 'tsx_once=0' "$W/env" && ok "tsx_once not written" || bad "tsx_once written"
echo "$OUT" | grep -q "hook: boot_retry=0" && ok "reports boot_retry" || bad "message: $OUT"

echo "== 5. a file that is not an Android boot image is refused"
setup "$ONCE"; echo junk > "$W/junk.img"
OUT=$(run_arm --rescue "$W/junk.img" --no-reboot); RC=$?
[ $RC = 1 ] && echo "$OUT" | grep -q "not an Android boot image" && ok "refused" || bad "exit $RC: $OUT"
grep -qx 'tsx_once=0' "$W/env" && ok "env untouched" || bad "env changed"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-arm-from-mainline || echo FAIL test-arm-from-mainline
exit $F
