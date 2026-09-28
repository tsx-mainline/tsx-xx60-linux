#!/bin/sh
# tsx-arm-from-mainline.sh: arm ONE boot into the mainline rescue from a
# RUNNING mainline system (the kiosk, any layout that keeps the U-Boot env on
# the card at 1 MiB). Panel side, POSIX sh (busybox ash). Shared by the two
# host drivers that must reach the rescue from the kiosk:
#   - installer/tsx-restore-factory  (step 2: the golden rescue, p1:boot.img)
#   - installer/tsx-install-mainline (reinstall/update: the payload's rescue.img)
# Both push it over ssh (stdin -> a file under /run) and run it; nothing here
# is installed on the panel. The Android path (steps/tsx-rescue-arm.sh) is a
# different script: Android's fw_setenv and busybox differ.
#
#   sh tsx-arm-from-mainline.sh [--rescue FILE] [--no-reboot]
#     --rescue FILE   the rescue image to boot (an Android v0 boot image);
#                     default: p1:boot.img, the golden slot (already the rescue
#                     on a panel installed by tsx-install-mainline)
#     --no-reboot     arm only; do not reboot
#
# What it writes (docs/boot.md "The v2 env state machine"): p1:tsxboot.img
# <- FILE (copy verified by sha256; replaced in place when p1 has no room for
# a side copy), removes p1:tsxboot.off (the hook's off switch, set by
# tsx-rescue-install), and, with the v2 `once` guard, tsx_once=1 (one
# verified single-variable env write; U-Boot clears it before it boots the
# rescue, so this arms exactly one rescue boot). With the older boot_retry
# guard nothing in the env is written. It never touches U-Boot, the MBR, the
# eMMC or p1:boot.img. It checks the hook (tsx_boot in switch_bootmode)
# BEFORE writing anything: without it the reboot would not reach the rescue.
# Output lines are parsed by the drivers: "REBOOTING" (or "ARMED" with
# --no-reboot) on success; exit 1 with a reason otherwise.
# Test hooks: TSX_P1 (vfat p1 device), TSX_ENV_CFG_LINE (fw_env.config line),
# TSX_MNT (mount point), TSX_RUN (dir for the env config file).
set -u
SRC= REBOOT=1
while [ $# -gt 0 ]; do case "$1" in
	--rescue) SRC=$2; shift;; --no-reboot) REBOOT=0;;
	*) echo "tsx-arm-from-mainline: unknown option $1"; exit 2;;
esac; shift; done
P1=${TSX_P1:-/dev/mmcblk0p1}
MNT=${TSX_MNT:-/mnt/p1}
RUN=${TSX_RUN:-/run}
CFG=$RUN/tsx-arm-env.cfg
MOUNTED=0
fail() { [ "$MOUNTED" = 1 ] && umount "$MNT" 2>/dev/null; echo "$*"; exit 1; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

# 1. the env and the hook, read only
echo "${TSX_ENV_CFG_LINE:-/dev/mmcblk0 0x100000 0x10000}" > "$CFG" || fail "cannot write $CFG"
sw=$(fw_printenv -c "$CFG" -l "$RUN" -n switch_bootmode 2>/dev/null) || fail "cannot read the U-Boot env"
case "$sw" in *tsx_boot*) ;; *) fail "the U-Boot hook (tsx_boot) is not installed: the reboot would not reach the rescue";; esac
case "$sw" in *tsx_once*) GUARD=once;; *) GUARD=boot_retry;; esac

# 2. p1:tsxboot.img <- the rescue
mkdir -p "$MNT"
mount -t vfat "$P1" "$MNT" || fail "cannot mount $P1 (vfat) at $MNT"
MOUNTED=1
[ -n "$SRC" ] || SRC=$MNT/boot.img
[ -f "$SRC" ] || fail "no rescue image at $SRC"
[ "$(dd if="$SRC" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || fail "$SRC is not an Android boot image"
g=$(sha "$SRC")
t=; [ -f "$MNT/tsxboot.img" ] && t=$(sha "$MNT/tsxboot.img")
if [ "$t" = "$g" ]; then
	echo "p1:tsxboot.img is already the rescue (no copy needed)"
else
	free=$(df -k "$MNT" | awk 'NR==2{print $4}')
	need=$(( $(stat -c %s "$SRC") / 1024 + 256 ))
	if [ "$free" -gt "$need" ]; then
		cp "$SRC" "$MNT/tsxboot.new"; sync
		[ "$(sha "$MNT/tsxboot.new")" = "$g" ] || { rm -f "$MNT/tsxboot.new"; fail "copy corrupt"; }
		mv "$MNT/tsxboot.new" "$MNT/tsxboot.img"
	else
		tsz=0; [ -f "$MNT/tsxboot.img" ] && tsz=$(stat -c %s "$MNT/tsxboot.img")
		[ $(( free + tsz / 1024 )) -gt "$need" ] || fail "no room on p1: free ${free}K (+ tsxboot.img) need ${need}K"
		echo "p1: no room for a side copy (free ${free}K): replacing tsxboot.img in place"
		rm -f "$MNT/tsxboot.img"; sync
		cp "$SRC" "$MNT/tsxboot.img"; sync
		[ "$(sha "$MNT/tsxboot.img")" = "$g" ] || { rm -f "$MNT/tsxboot.img"; fail "copy corrupt"; }
	fi
fi
if [ -f "$MNT/tsxboot.off" ]; then rm -f "$MNT/tsxboot.off"; echo "p1:tsxboot.off removed (hook re-enabled)"; fi
sync

# 3. arm: tsx_once=1 with the once guard (the boot_retry guard needs nothing)
if [ "$GUARD" = once ]; then
	fw_setenv -c "$CFG" -l "$RUN" tsx_once 1 || fail "fw_setenv tsx_once 1 failed"
	[ "$(fw_printenv -c "$CFG" -l "$RUN" -n tsx_once 2>/dev/null)" = 1 ] || fail "tsx_once=1 did not take"
	echo "tsx_once=1 armed (one rescue boot)"
else
	echo "hook: boot_retry=$(fw_printenv -c "$CFG" -l "$RUN" -n boot_retry 2>/dev/null) (runs tsx_boot while < 6)"
fi
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
echo "p1:tsxboot.img = rescue $g"
ls -l "$MNT"
umount "$MNT"; MOUNTED=0
if [ "$REBOOT" = 1 ]; then
	echo REBOOTING
	# detached from the ssh session (stdin/out/err), so the host sees the
	# output above and the session closes before the reboot drops it
	(sleep 2; reboot) </dev/null >/dev/null 2>&1 &
else
	echo ARMED
fi
exit 0
