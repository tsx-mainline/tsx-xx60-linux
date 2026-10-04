#!/bin/bash
# Host test: the eth0-MAC selection in base/etc/init.d/tsx-setup of
# tsx-linux-common with the xx60 board file of this repository. The xx60 keeps
# the MAC in the U-Boot env at 1 MiB of the eMMC. The board file reads it as
# text (tsx_board_mac_early). The test runs the same script that the panel
# runs. It uses the TSX_MMCBLK0 and TSX_ETH0_MAC_FILE host-test hooks. A fake
# env image stands in for /dev/mmcblk0. The test needs no docker, no real block
# device and no root.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SCRIPT="$COMMON/base/etc/init.d/tsx-setup"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED common/test-tsx-setup-mac: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

busybox sh -n "$SCRIPT" && ok "busybox sh -n" || bad "busybox sh -n"

# a fake "/dev/mmcblk0": just the env text at the same 1 MiB (64k*16) offset
# the board file reads, padded so the offset lands correctly.
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

echo "== the xx60 board file names the MAC source =="
src=$(busybox sh -c ". '$TSX_BOARD_CONF'; echo \"\$TSX_MAC_SOURCE \$TSX_MAC_DEV\"")
[ "$src" = "uboot /dev/mmcblk0" ] && ok "the MAC source is uboot on /dev/mmcblk0" || bad "MAC source: $src"
src=$(busybox sh -c ". '$TSX_BOARD_CONF'; echo \"\$TSX_BT_MAC_SETTABLE\"")
[ "$src" = yes ] && ok "the board can set the Bluetooth address" || bad "TSX_BT_MAC_SETTABLE: $src"

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

echo "== the env is read at 1 MiB, not at another offset =="
ENVX="$W/mmcblk0.x"; { dd if=/dev/zero bs=64k count=15 2>/dev/null; printf 'ethaddr=00:aa:bb:cc:dd:ee\0'; } > "$ENVX"
MFX="$W/eth0.mac.x"
OUT=$(run_setup "$ENVX" "$MFX")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" != "00:aa:bb:cc:dd:ee" ] && ok "an ethaddr before 1 MiB is not read" || bad "an ethaddr before 1 MiB was read"
ENVY="$W/mmcblk0.y"; { dd if=/dev/zero bs=64k count=16 2>/dev/null; printf 'ethaddr=00:aa:bb:cc:dd:ef\0other=1\0'; } > "$ENVY"
OUT=$(run_setup "$ENVY" "$W/eth0.mac.y")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "00:aa:bb:cc:dd:ef" ] && ok "an ethaddr at 1 MiB with NUL separators is read" || bad "env with NUL separators: got $GOT"

echo "== valid env + a STALE persisted MAC: the env wins and the file is resynced =="
MF3="$W/eth0.mac.3"; echo "02:aa:bb:cc:dd:ee" > "$MF3"   # e.g. persisted before ethaddr was ever readable
OUT=$(run_setup "$ENV1" "$MF3")
GOT=$(echo "$OUT" | sed -n 's/^MAC=//p')
[ "$GOT" = "00:11:22:33:44:55" ] && ok "a stale persisted MAC does not win over a valid env ethaddr" \
	|| bad "stale persisted MAC was used instead of the env: got $GOT"
[ "$(cat "$MF3")" = "00:11:22:33:44:55" ] && ok "the stale mac file was resynced to the env" || bad "mac file still stale: $(cat "$MF3")"

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

echo "== the rescue system sets the same MAC =="
# The rcS of the initramfs (every rescue path) reads the same env with the same
# board function. So a unit has one MAC and one DHCP address in the kiosk and in the rescue.
RCS=$XX60/rootfs/initramfs/overlay/etc/init.d/rcS
grep -qF '. /usr/local/lib/tsx/board.sh' "$RCS" && grep -qF 'mac=$(tsx_board_mac_early)' "$RCS" && grep -qF 'ip link set dev eth0 address' "$RCS" \
	&& ok "rcS sets the MAC of eth0 with tsx_board_mac_early of the board file" || bad "rcS does not set the MAC from the board file"
rescue_mac=$(TSX_MMCBLK0="$ENV1" busybox sh -c ". '$TSX_BOARD_CONF'; tsx_board_mac_early")
[ "$rescue_mac" = "00:11:22:33:44:55" ] && ok "the rescue reads the same MAC as the kiosk" || bad "rescue MAC: $rescue_mac"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS common/test-tsx-setup-mac" || { echo "FAIL common/test-tsx-setup-mac"; exit 1; }
