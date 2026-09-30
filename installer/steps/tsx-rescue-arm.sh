#!/system/bin/bash
# xx60 mainline installer v2, step 1. It runs on the STOCK ANDROID root shell
# (ssh -tt admin@<panel>, root bash 3.2). It arms a ONE-SHOT boot into the
# mainline rescue system and reboots. The rescue does the whole eMMC and root
# install afterwards (installer/steps/tsx-rescue-install). See docs/install.md
# "Install: rescue-first (v2)" and docs/boot.md "The v2 env state machine".
# Unlike the old tsx-android-install.sh, this script writes NOTHING to p2 and
# does not touch the MBR. It leaves the Android partitions of the SD card
# alone until the rescue folds them. You can still undo a v2 install: power-
# cycle once more than the arm (see docs/recovery.md).
#
#   bash tsx-rescue-arm.sh preflight [options]   read only: checks + plan
#   bash tsx-rescue-arm.sh install   [options]   do it (asks for "INSTALL")
#   bash tsx-rescue-arm.sh status                what is armed now
#
# Options:
#   --rescue FILE       the mainline rescue image (output of installer/rescue*/*.sh:
#                        an Android v0 boot image with /etc/tsx/rescue-image set)
#   --guard once|fallback|nogolden   U-Boot hook variant. The default is once,
#                        the true one-shot, gated on tsx_once and not on
#                        boot_retry (see docs/boot.md "The v2 env state
#                        machine"). fallback and nogolden are the older
#                        persistent hook with boot_retry<6. They stay for
#                        testing and compatibility (see installer/android/tsx-lib.sh).
#   --no-defuse-golden   do not set DataRecoveryDone=1 (default: set it)
#   --no-reboot          do not reboot at the end
#   --yes                do not ask
#
# What it writes:
#   - p1:boot.img: first a backup, then a copy of the rescue. This is the
#     golden (factory recovery) slot of Crestron. From here on it is
#     permanently the rescue (see docs/recovery.md).
#   - p1:tsxboot.img: a copy of the same rescue image (the one-shot hook target)
#   - the U-Boot env, through the fw_setenv of Android. The script reads each
#     value back: tsx_boot, golden_boot_retry=0, DataRecoveryDone=1,
#     boot_retry=0, tsx_once=1 with --guard once (the default) or
#     boot_retry=3 with --guard fallback|nogolden (the legacy arm value, see
#     ARM_BOOT_RETRY below), and switch_bootmode last.
# It never writes p2, p5..p8 or the MBR. The rescue folds the card later, after
# it has verified the eMMC writes (docs/boot.md "The v2 env state machine").
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../android/tsx-lib.sh"
. "$HERE/../lib/tsx-rescue.sh"

log() { echo "tsx-rescue-arm: $*" >&2; [ -n "${LOG:-}" ] && echo "$(date '+%F %T' 2>/dev/null) $*" >> "$LOG"; return 0; }
die() { log "ERROR: $*"; echo "tsx-rescue-arm: nothing more was changed. Log: ${LOG:-none}" >&2; exit 1; }
warn() { log "WARNING: $*"; }

tsx_pick_bb || { echo "tsx-rescue-arm: no busybox found" >&2; exit 1; }
tsx_wrap_applets
tsx_pick_fwenv || { echo "tsx-rescue-arm: no fw_printenv/fw_setenv found" >&2; exit 1; }

CMD=${1:-}; [ $# -gt 0 ] && shift
RESCUE= GUARD=once DEFUSE=1 REBOOT=1 YES=0
while [ $# -gt 0 ]; do
	case "$1" in
	--rescue) RESCUE=$2; shift;;
	--guard) GUARD=$2; shift;;
	--defuse-golden) DEFUSE=1;;
	--no-defuse-golden) DEFUSE=0;;
	--no-reboot) REBOOT=0;;
	--yes) YES=1;;
	*) echo "unknown option $1" >&2; exit 2;;
	esac; shift
done
case "$CMD" in preflight|install|status) ;; *) sed -n '2,30p' "$0"; exit 2;; esac
case "$GUARD" in once) WANT_SWITCH=$TSX_SWITCH_ONCE;; fallback) WANT_SWITCH=$TSX_SWITCH_FALLBACK;; nogolden) WANT_SWITCH=$TSX_SWITCH_NOGOLDEN;; *) die "--guard once|fallback|nogolden";; esac
# --guard once (the default): the real one-shot is tsx_once, not boot_retry
# (see TSX_SWITCH_ONCE in installer/android/tsx-lib.sh and docs/boot.md "The
# v2 env state machine"). U-Boot clears tsx_once BEFORE it runs tsx_boot. So
# the shot is spent as soon as U-Boot reaches that line, whether or not the
# rescue ever checks in. This script only resets boot_retry to 0, so it starts
# clean. Android resets it on every boot of its own anyway.
#
# --guard fallback|nogolden (legacy, kept for testing and compatibility): these
# do not know about tsx_once. The persistent hook runs tsx_boot on every boot
# while boot_retry<6. ARM_BOOT_RETRY=3 is the old one-shot by exhaustion.
# checkBootRetry() increments boot_retry on every boot, so the NEXT boot lands
# at 4. That is below 6, so the hook runs. This gives the ONE rescue attempt
# that the arm grants. The U-Boot of Crestron treats a boot that finds
# boot_retry=4 in a special way. It saved 5 and reset the SoC, and the second
# pass saved 6 (seen on hardware 2026-09-27). So arming at 4 skipped the
# rescue and booted Android.
# From 4, a boot AFTER the rescue, where nothing has reset the counter, goes
# 4 -> 5 -> reset -> 6. Then the hook stops and stock Android boots. This is
# the safety net. It comes entirely from the existing boot_retry<6 guard and
# needs no new hook logic. --guard once does not use it, because tsx_once is
# its only gate.
ARM_BOOT_RETRY=3

W=${TSX_WORKDIR:-/dev/tsx-inst}
mkdir -p "$W" || die "cannot create $W"
LOG=$W/rescue-arm.log
MNT_P1=$W/p1 P1_MOUNTED_BY_US=0
cleanup() { [ "$P1_MOUNTED_BY_US" = 1 ] && umount "$MNT_P1" 2>/dev/null; return 0; }
trap cleanup EXIT

FAILS=0
chk() { if [ "$1" = ok ]; then log "  ok    $2"; else log "  FAIL  $2"; FAILS=$((FAILS+1)); fi; }

log "== xx60 rescue-arm v2 ($CMD) $(date 2>/dev/null)"
[ "$(id -u)" = 0 ] && chk ok "running as root" || chk fail "not root (id -u = $(id -u)). Use: ssh -tt admin@<panel>"
tsx_find_disk && chk ok "boot disk $WHOLE: $TSX_DISK_LAYOUT layout" || chk fail "no mmcblk device with the Crestron (or card-stage) partition layout"
[ $FAILS = 0 ] || die "basic checks failed"

why=$(tsx_env_sane) && chk ok "U-Boot env at $WHOLE+0x100000: CRC ok, yushan_one env" || chk fail "U-Boot env: $why"
MODEL=$(tsx_model) && chk ok "model: $MODEL" || chk fail "unknown model (lcdsize=$(tsx_env lcdsize 2>/dev/null) aml_dt=$(tsx_env aml_dt 2>/dev/null))"
UNIT=$(tsx_unit_id); log "  unit id: $UNIT"
HOOK=$(tsx_hook_state)
case "$HOOK" in stock|fallback|nogolden|once|plain) chk ok "switch_bootmode: $HOOK";; *) chk fail "switch_bootmode has unknown content: $(tsx_env switch_bootmode)";; esac
BR=$(tsx_env boot_retry 2>/dev/null); GBR=$(tsx_env golden_boot_retry 2>/dev/null)
log "  boot_retry=$BR golden_boot_retry=$GBR tsx_once=$(tsx_env tsx_once 2>/dev/null) DataRecoveryDone=$(tsx_env DataRecoveryDone 2>/dev/null) fwUpgrade=$(tsx_env fwUpgrade 2>/dev/null)"
[ "$(tsx_env fwUpgrade 2>/dev/null)" = 0 ] || chk fail "fwUpgrade is not 0: a Crestron firmware update is in progress"

M=$(tsx_mounts_of "$P1" | head -n 1)
if [ -n "$M" ]; then MNT_P1=$M; log "  p1 already mounted at $M"
else
	mkdir -p "$MNT_P1"
	if [ "$CMD" = install ]; then mount -t vfat -o rw,noatime "$P1" "$MNT_P1"; else mount -t vfat -o ro "$P1" "$MNT_P1"; fi \
		&& P1_MOUNTED_BY_US=1 || chk fail "cannot mount $P1 (vfat)"
fi
if [ -f "$MNT_P1/boot.img" ] && [ "$(dd if="$MNT_P1/boot.img" bs=8 count=1 2>/dev/null)" = "ANDROID!" ]; then
	GSHA=$(sha256sum < "$MNT_P1/boot.img" | cut -d' ' -f1); chk ok "p1: golden boot.img present (sha256 ${GSHA%${GSHA#????????????}}...)"
else chk fail "p1 has no golden boot.img with an Android header"; fi
P1FREE=$(df -Pk "$MNT_P1" 2>/dev/null | awk 'NR==2{print $4}')
log "  p1 files: $(ls "$MNT_P1" 2>/dev/null | tr '\n' ' ')(free ${P1FREE:-?} KiB)"

if [ "$CMD" != status ]; then
	[ -n "$RESCUE" ] && [ -f "$RESCUE" ] && [ "$(dd if="$RESCUE" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] && chk ok "rescue image: $RESCUE ($(tsx_size "$RESCUE") bytes)" \
		|| chk fail "no valid rescue image (--rescue FILE, an Android boot image)"
	if [ -n "$RESCUE" ] && [ -f "$RESCUE" ]; then
		RNEED=$(( $(tsx_size "$RESCUE") / 1024 * 2 + 512 ))   # room for boot.img and tsxboot.img side by side
		GOLD=0; [ -f "$MNT_P1/boot.img" ] && GOLD=$(( $(tsx_size "$MNT_P1/boot.img") / 1024 ))
		OLDT=0; [ -f "$MNT_P1/tsxboot.img" ] && OLDT=$(( $(tsx_size "$MNT_P1/tsxboot.img") / 1024 ))
		[ $(( ${P1FREE:-0} + GOLD + OLDT )) -gt $RNEED ] && chk ok "p1 has room for the rescue image (golden + tsxboot.img)" || chk fail "p1 too full for the rescue image (need ~$RNEED KiB)"
	fi
fi

log "== plan"
log "  1. back up: env block (64 KiB), first 2 MiB of $WHOLE -> /data/local/tsx-backup/"
log "  2. p1:boot.img -> backup, then <- rescue (golden slot, permanent). p1:tsxboot.img <- rescue (one-shot hook target). Remove tsxboot.off"
if [ "$GUARD" = once ]; then
	log "  3. env (Android fw_setenv, each read back): tsx_boot, golden_boot_retry=0$( [ $DEFUSE = 1 ] && echo ', DataRecoveryDone=1'), boot_retry=0, tsx_once=1 (arms ONE rescue boot), switch_bootmode = once hook (last)"
else
	log "  3. env (Android fw_setenv, each read back): tsx_boot, golden_boot_retry=0$( [ $DEFUSE = 1 ] && echo ', DataRecoveryDone=1'), boot_retry=$ARM_BOOT_RETRY (arms ONE rescue boot by exhaustion), switch_bootmode = $GUARD hook (last)"
fi
log "  4. $( [ $REBOOT = 1 ] && echo 'reboot (busybox reboot -f)' || echo 'no reboot (--no-reboot)')"

if [ "$CMD" = status ]; then
	log "== status: hook=$HOOK boot_retry=$BR golden_boot_retry=$GBR tsx_once=$(tsx_env tsx_once 2>/dev/null) p1:tsxboot.img=$( [ -f "$MNT_P1/tsxboot.img" ] && echo yes || echo no ) tsxboot.off=$( [ -f "$MNT_P1/tsxboot.off" ] && echo yes || echo no )"
	exit 0
fi
[ $FAILS = 0 ] || die "$FAILS check(s) failed. Nothing written"
if [ "$CMD" = preflight ]; then log "== preflight OK (nothing written). Run again with 'install' to do it."; exit 0; fi

if [ $YES != 1 ]; then
	printf 'Type INSTALL to arm the rescue boot on this %s (%s): ' "$MODEL" "$UNIT" >&2
	read -r ans; [ "$ans" = INSTALL ] || die "not confirmed"
fi

# 1. backups
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
BK=/data/local/tsx-backup/$UNIT-$TS
mkdir -p "$BK" || die "cannot create $BK"
dd if="$WHOLE" bs=65536 skip=16 count=1 of="$BK/env-0x100000.bin" 2>/dev/null || die "env backup failed"
[ "$(tsx_size "$BK/env-0x100000.bin")" = $TSX_ENV_SIZE ] || die "env backup has the wrong size"
dd if="$WHOLE" bs=1048576 count=2 of="$BK/disk-head-2M.bin" 2>/dev/null || die "disk head backup failed"
if [ -f "$MNT_P1/boot.img" ] && [ "$GSHA" != "$(sha256sum < "$RESCUE" | cut -d' ' -f1)" ]; then
	cp "$MNT_P1/boot.img" "$BK/golden-boot.img" && [ "$(sha256sum < "$BK/golden-boot.img" | cut -d' ' -f1)" = "$GSHA" ] || die "golden boot.img backup failed"
fi
tsx_fw_bound "$FWP" > "$BK/fw_printenv.txt" 2>&1
(cd "$BK" && sha256sum env-0x100000.bin disk-head-2M.bin fw_printenv.txt $( [ -f golden-boot.img ] && echo golden-boot.img) > SHA256SUMS)
log "backups in $BK"

# 2. p1: golden slot + one-shot target, both <- rescue
RSHA=$(sha256sum < "$RESCUE" | cut -d' ' -f1)
if [ "$(sha256sum 2>/dev/null < "$MNT_P1/boot.img" | cut -d' ' -f1)" != "$RSHA" ]; then
	rm -f "$MNT_P1/boot.new"
	if [ "$(df -Pk "$MNT_P1" | awk 'NR==2{print $4}')" -le $(( $(tsx_size "$RESCUE") / 1024 + 64 )) ]; then rm -f "$MNT_P1/boot.img"; sync; fi
	cp "$RESCUE" "$MNT_P1/boot.new" && sync
	[ "$(sha256sum < "$MNT_P1/boot.new" | cut -d' ' -f1)" = "$RSHA" ] || { rm -f "$MNT_P1/boot.new"; die "rescue copy to p1:boot.img corrupt (golden backup: $BK/golden-boot.img)"; }
	mv "$MNT_P1/boot.new" "$MNT_P1/boot.img" && sync
	log "p1:boot.img = rescue ($RSHA). Crestron's golden image backed up to $BK/golden-boot.img"
else
	log "p1:boot.img is already this rescue image ($RSHA)"
fi
if [ "$(sha256sum 2>/dev/null < "$MNT_P1/tsxboot.img" | cut -d' ' -f1)" != "$RSHA" ]; then
	rm -f "$MNT_P1/tsxboot.new"
	FREE=$(df -Pk "$MNT_P1" | awk 'NR==2{print $4}')
	NEED=$(( $(tsx_size "$RESCUE") / 1024 + 256 ))
	if [ "$FREE" -le "$NEED" ] && [ -f "$MNT_P1/tsxboot.img" ]; then rm -f "$MNT_P1/tsxboot.img"; sync; fi
	cp "$RESCUE" "$MNT_P1/tsxboot.new" && sync
	[ "$(sha256sum < "$MNT_P1/tsxboot.new" | cut -d' ' -f1)" = "$RSHA" ] || { rm -f "$MNT_P1/tsxboot.new"; die "rescue copy to p1:tsxboot.img corrupt"; }
	mv "$MNT_P1/tsxboot.new" "$MNT_P1/tsxboot.img" && sync
	log "p1:tsxboot.img = rescue ($RSHA), one-shot hook target"
else
	log "p1:tsxboot.img is already this rescue image ($RSHA)"
fi
rm -f "$MNT_P1/tsxboot.off"; sync

# 3. Write the env through the own fw_setenv of Android, one variable per call.
# Read each value back. This is the writer that tsx-android-install.sh uses, and
# it is proven on hardware. The fw_setenv and fw_printenv of Android take no
# -c, -l or -s. So this script cannot use tsx_env_apply (installer/lib/
# tsx-rescue.sh, for the fw_setenv of the rescue).
# The hook (switch_bootmode) goes LAST. A power loss between two writes then
# leaves either the stock or previous hook (Android boots, and nothing has read
# tsx_once yet) or the complete one-shot arm. With --guard once, tsx_once=1
# arms the rescue boot. The script only resets boot_retry to 0. Android resets
# it to 0 on every boot of its own anyway, so this is a clean starting point and
# not a special value. With --guard fallback or nogolden (legacy),
# boot_retry=$ARM_BOOT_RETRY is still the arm.
setv() {
	tsx_fw_bound "$FWS" "$1" "$2" >> "$LOG" 2>&1 || die "fw_setenv $1 failed or timed out (env backup: $BK/env-0x100000.bin)"
	[ "$(tsx_env "$1")" = "$2" ] || die "readback of $1 differs after fw_setenv (env backup: $BK/env-0x100000.bin)"
	log "env $1 set"
}
[ "$(tsx_env tsx_boot 2>/dev/null)" = "$TSX_BOOT_CMD" ] || setv tsx_boot "$TSX_BOOT_CMD"
[ "$(tsx_env golden_boot_retry 2>/dev/null)" = 0 ] || setv golden_boot_retry 0
[ $DEFUSE = 1 ] && [ "$(tsx_env DataRecoveryDone 2>/dev/null)" != 1 ] && setv DataRecoveryDone 1
if [ "$GUARD" = once ]; then
	[ "$(tsx_env boot_retry 2>/dev/null)" = 0 ] || setv boot_retry 0
	setv tsx_once 1
else
	setv boot_retry $ARM_BOOT_RETRY
fi
[ "$(tsx_env switch_bootmode)" = "$WANT_SWITCH" ] || setv switch_bootmode "$WANT_SWITCH"
tsx_fw_bound "$FWP" > "$BK/fw_printenv-after.txt" 2>&1
tsx_env_sane >/dev/null || die "env not sane after the writes: restore $BK/env-0x100000.bin (dd it back to $WHOLE+0x100000)"

sync
if [ "$P1_MOUNTED_BY_US" = 1 ]; then umount "$MNT_P1" && P1_MOUNTED_BY_US=0; fi
if [ "$GUARD" = once ]; then
	log "DONE. Next boot: U-Boot -> tsx_once=1 clears itself (setenv 0, then saveenv) -> p1:tsxboot.img -> the mainline rescue, exactly once. If it never checks in and the unit reboots again, tsx_once is already 0 and stock Android boots automatically (no boot_retry involved)."
else
	log "DONE. Next boot: U-Boot -> p1:tsxboot.img -> the mainline rescue (boot_retry $ARM_BOOT_RETRY -> 4, one attempt). If it never checks in and the unit reboots again, boot_retry -> 6 and stock Android boots automatically."
fi
if [ $REBOOT = 1 ]; then
	# Reboot in the background, immune to the hangup of the ssh session. Then
	# this script returns, and the host sees DONE before the reboot drops the
	# connection. tsx_reboot_detached runs in its own session and ignores HUP.
	# Each step goes to a trace on /data. The host reads it if the panel does
	# not go down.
	log "rebooting in 3 s"
	log "reboot trace: $BK/reboot.trace"
	sync
	tsx_reboot_detached "$BK/reboot.trace" 3
fi
exit 0
