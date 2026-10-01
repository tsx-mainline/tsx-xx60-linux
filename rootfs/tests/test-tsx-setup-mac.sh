#!/bin/bash
# Host test: the eth0-MAC selection in rootfs/overlay/etc/init.d/tsx-setup
# (docs/recovery.md "Random MAC in the rescue, and the fix"). The test runs the
# same script that the panel runs. It uses the TSX_MMCBLK0 and
# TSX_ETH0_MAC_FILE host-test hooks (the same idea as TSX_APPLY_PREFIX of
# tsx-config). A fake env image stands in for /dev/mmcblk0. The test needs no
# docker, no real block device and no root.
#
# The test also checks that every rescue path sets the same MAC. The logic
# lives in the base rcS of the initramfs. Before, a force-rescue on a TSS-10
# got a random MAC and a different DHCP address. The logic lived only in the
# rcS of the rescue image.
set -uo pipefail
# The board file (rootfs/overlay/usr/local/lib/tsx/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/lib/tsx/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/overlay/etc/init.d/tsx-setup"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-setup-mac: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

busybox sh -n "$SCRIPT" && ok "busybox sh -n" || bad "busybox sh -n"

# a fake "/dev/mmcblk0": just the env text at the same 1 MiB (64k*16) offset
# the real script dd's from, padded so the offset lands correctly.
mkenv() {  # mkenv FILE [ETHADDR-LINE]
	: > "$1"
	dd if=/dev/zero of="$1" bs=64k count=16 status=none
	{ [ -n "${2:-}" ] && printf '%s\n' "$2"; printf 'other=1\n'; } >> "$1"
}

# run_setup MMCBLK MACFILE: source tsx-setup under busybox sh and call ONLY
# select_eth0_mac. The openrc helpers are stubs. einfo prints to stdout as
# OpenRC does, so a message that leaks into the answer of select_eth0_mac
# fails the test. The test never calls start(): start() also touches zram
# swap and the real /sys cpufreq governor, and it must not run on a shared
# test host. run_setup prints "MAC=<value>" and leaves MACFILE as the
# function left it.
run_setup() {
	local mmcblk=$1 macf=$2
	TSX_MMCBLK0="$mmcblk" TSX_ETH0_MAC_FILE="$macf" busybox sh -c '
		einfo() { echo " * $*"; }   # like OpenRC: einfo writes to STDOUT
		. "'"$SCRIPT"'"
		echo "MAC=$(select_eth0_mac)"
	' 2>/dev/null
}

echo "== no env, no persisted file: a fresh random MAC is generated and saved =="
NOENV="$W/no-mmcblk0"; MF1="$W/eth0.mac.1"
OUT=$(run_setup "$NOENV" "$MF1")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
echo "$GOT" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && ok "a MAC was generated ($GOT)" || bad "no valid MAC generated: $OUT"
[ "$(cat "$MF1" 2>/dev/null)" = "$GOT" ] && ok "it was persisted to the mac file" || bad "mac file not written/mismatched"

echo "== valid env, no persisted file: the env's ethaddr wins and is persisted =="
ENV1="$W/mmcblk0.1"; mkenv "$ENV1" "ethaddr=00:11:22:33:44:55"
MF2="$W/eth0.mac.2"
OUT=$(run_setup "$ENV1" "$MF2")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "00:11:22:33:44:55" ] && ok "the env's ethaddr is used" || bad "env ethaddr not used: got $GOT"
[ "$(cat "$MF2" 2>/dev/null)" = "00:11:22:33:44:55" ] && ok "the mac file was seeded from the env" || bad "mac file not seeded from env"

echo "== valid env + a STALE persisted MAC: the env wins and the file is resynced (the actual bug) =="
MF3="$W/eth0.mac.3"; echo "02:aa:bb:cc:dd:ee" > "$MF3"   # e.g. persisted before ethaddr was ever readable
OUT=$(run_setup "$ENV1" "$MF3")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "00:11:22:33:44:55" ] && ok "a stale persisted MAC no longer wins over a valid env ethaddr" \
	|| bad "stale persisted MAC was used instead of the env: got $GOT"
[ "$(cat "$MF3")" = "00:11:22:33:44:55" ] && ok "the stale mac file was resynced to the env" || bad "mac file still stale: $(cat "$MF3")"
# The rescue system (rcS) always computes this MAC from the same env,
# unconditionally. So a kiosk boot and a rescue boot of the same unit now
# always agree. Before, they agreed only until the file went stale.

echo "== env present but unreadable/malformed (no ethaddr line): the persisted MAC is kept, nothing regenerated =="
BADENV="$W/mmcblk0.bad"; mkenv "$BADENV"
MF4="$W/eth0.mac.4"; echo "02:11:22:33:44:55" > "$MF4"
OUT=$(run_setup "$BADENV" "$MF4")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "02:11:22:33:44:55" ] && ok "an existing persisted MAC survives a boot with no env ethaddr" || bad "persisted MAC lost: got $GOT"
[ "$(cat "$MF4")" = "02:11:22:33:44:55" ] && ok "the mac file is untouched" || bad "mac file rewritten unnecessarily"

echo "== malformed ethaddr in the env is rejected like a missing one =="
BADMAC="$W/mmcblk0.badmac"; mkenv "$BADMAC" "ethaddr=not-a-mac"
MF5="$W/eth0.mac.5"; echo "02:66:77:88:99:aa" > "$MF5"
OUT=$(run_setup "$BADMAC" "$MF5")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "02:66:77:88:99:aa" ] && ok "a malformed env ethaddr falls back to the persisted MAC" || bad "malformed ethaddr accepted: got $GOT"

RCS="$HERE/initramfs/overlay/etc/init.d/rcS"
grep -q 'ethaddr' "$RCS" && grep -q 'ip link set dev eth0 address' "$RCS" \
	&& ok "the initramfs's base rcS (every rescue path) sets eth0's MAC from the env" || bad "base rcS does not set the MAC"
[ ! -e "$HERE/../installer/rescue/overlay/etc/init.d/rcS" ] && ok "the rescue image does not override the base rcS" || bad "installer/rescue overrides rcS again"
grep -q "BASE's rcS does not set the eth0 MAC" "$HERE/../installer/rescue/mkrescue.sh" && ok "mkrescue.sh refuses a base image without it" || bad "mkrescue.sh has no rcS check"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS test-tsx-setup-mac" || { echo "FAIL test-tsx-setup-mac"; exit 1; }
