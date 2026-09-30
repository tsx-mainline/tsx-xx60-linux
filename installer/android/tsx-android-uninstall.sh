#!/system/bin/bash
# xx60: undo stage 1 from the STOCK ANDROID root shell (no UART).
#
#   bash tsx-android-uninstall.sh [--dry-run]           revert the U-Boot hook to the stock
#                                                        switch_bootmode, delete tsx_boot, remove
#                                                        p1:tsxboot.img / tsxinst.cfg / tsxboot.off
#   bash tsx-android-uninstall.sh --disable             only create p1:tsxboot.off (the hook then
#                                                        boots Android. Remove the file to re-enable)
#   bash tsx-android-uninstall.sh --restore-env FILE    write a 64 KiB env backup taken by the
#                                                        installer (env-0x100000.bin or p1:tsxenv.bak)
#                                                        back to mmcblk0 at 0x100000
#   --yes   do not ask
#
# p5 is left as it is. If it holds the mainline rootfs, stock Android mounts it
# as its "sdcard" and adds its folders. To give Android an empty sdcard again,
# run rootfs/uninstall.sh --p5-mkfs in the mainline rescue system BEFORE this
# script (touch /etc/tsx/force-rescue; reboot), or restore the stick's
# backup/<unit>-<time>/android-sdcard.tar.gz there. Golden boot.img, p2, p6-p8,
# the eMMC and U-Boot are never touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tsx-lib.sh"
log() { echo "tsx-uninstall: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
tsx_pick_bb || die "no busybox"
tsx_wrap_applets
MODE=revert DRY=0 YES=0 ENVFILE=
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY=1;;
	--disable) MODE=disable;;
	--restore-env) MODE=restore-env; ENVFILE=$2; shift;;
	--yes) YES=1;;
	*) sed -n '2,21p' "$0"; exit 2;;
	esac; shift
done
[ "$(id -u)" = 0 ] || die "not root"
tsx_pick_fwenv || die "no fw_printenv/fw_setenv"
tsx_find_disk || die "no disk with the Crestron layout"
W=${TSX_WORKDIR:-/dev/tsx-inst}; mkdir -p "$W/p1"
M=$(tsx_mounts_of "$P1" | head -n 1); OWN=0
if [ -z "$M" ]; then M=$W/p1; mount -t vfat -o rw,noatime "$P1" "$M" || die "mount $P1"; OWN=1; fi
trap '[ $OWN = 1 ] && umount "$M" 2>/dev/null' EXIT
[ -f "$M/boot.img" ] || log "WARNING: no golden boot.img on p1"
ask() { [ $YES = 1 ] || [ $DRY = 1 ] && return 0; printf '%s Type YES: ' "$1" >&2; read -r a; [ "$a" = YES ] || die "not confirmed"; }
run() { log "$*"; [ $DRY = 1 ] || "$@"; }

case $MODE in
disable)
	ask "Create p1:tsxboot.off (next boots go to stock Android)?"
	run touch "$M/tsxboot.off"; run sync
	log "done: U-Boot prints 'tsx: mainline disabled' and boots Android. Undo: rm p1:tsxboot.off";;
restore-env)
	[ -f "$ENVFILE" ] || die "no file $ENVFILE"
	[ "$(tsx_size "$ENVFILE")" = $TSX_ENV_SIZE ] || die "$ENVFILE is not 64 KiB"
	# the image must look like this board's env (the CRC is checked by fw_printenv afterwards)
	tr '\000' '\n' < "$ENVFILE" | grep -q '^aml_dt=yushan_one' || die "$ENVFILE has no aml_dt=yushan_one*"
	tr '\000' '\n' < "$ENVFILE" | grep -q '^crestron_uboot_version=' || die "$ENVFILE has no crestron_uboot_version"
	S=$(dirname "$ENVFILE")/SHA256SUMS
	if [ -f "$S" ]; then
		(cd "$(dirname "$ENVFILE")" && grep " $(basename "$ENVFILE")\$" SHA256SUMS | sha256sum -c >/dev/null 2>&1) || die "$ENVFILE does not match its SHA256SUMS"
	fi
	dd if="$WHOLE" bs=65536 skip=16 count=1 of="$W/env-before-restore.bin" 2>/dev/null
	ask "Write $ENVFILE to $WHOLE at 0x100000 (old block saved to $W/env-before-restore.bin)?"
	run dd if="$ENVFILE" of="$WHOLE" bs=65536 seek=16 count=1 conv=notrunc,fsync
	[ $DRY = 1 ] || { tsx_env_sane >&2 || die "env not sane after the restore: CRC? write $W/env-before-restore.bin back the same way"; }
	log "env restored. switch_bootmode is now: $(tsx_hook_state)";;
revert)
	st=$(tsx_hook_state)
	log "hook state: $st. tsx_boot: $(tsx_env tsx_boot >/dev/null 2>&1 && echo set || echo unset)"
	ask "Revert the U-Boot hook and remove p1:tsxboot.img?"
	if [ "$st" != stock ]; then
		case "$st" in fallback|nogolden|plain) ;; *) die "switch_bootmode has unknown content. Not touching it";; esac
		run tsx_fw_bound "$FWS" switch_bootmode "$TSX_STOCK_SWITCH"
		[ $DRY = 1 ] || [ "$(tsx_env switch_bootmode)" = "$TSX_STOCK_SWITCH" ] || die "switch_bootmode readback differs"
	fi
	tsx_env tsx_boot >/dev/null 2>&1 && run tsx_fw_bound "$FWS" tsx_boot
	run tsx_fw_bound "$FWS" boot_retry 0
	run rm -f "$M/tsxboot.img" "$M/tsxboot.new" "$M/tsxboot.off" "$M/tsxinst.cfg" "$M/tsxinst.done" "$M/tsxinst.failed"
	run sync
	log "done: U-Boot runs stock Android again. p1:tsxenv.bak and /data/local/tsx-backup are kept.";;
esac
