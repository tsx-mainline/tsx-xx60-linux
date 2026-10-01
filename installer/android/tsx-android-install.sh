#!/system/bin/bash
# xx60 mainline installer. It runs on the STOCK ANDROID root shell
# (ssh -tt admin@<panel>, root bash 3.2). It needs no UART and no U-Boot
# prompt. One root-shell command does the whole conversion, with no second
# stage:
#   - p2 (the golden /system, unused by the running Android) gets the kiosk
#     rootfs (rootfs-p2.ext4.gz on the stick)
#   - p1:boot.img (the Crestron golden) gets the mainline rescue
#   - p1:tsxboot.img gets the kiosk image
#   - the U-Boot env gets the hook
#   - LAST, one MBR byte changes (entry 4 type 0x05 -> 0x83). p5..p8 (Android
#     sdcard, data, cache, logs) disappear. p4 becomes one 2.8 GiB partition.
#     The first mainline boot formats it as ext4 tsxdata (/data), because
#     p1:tsxlayout.cfg orders it.
# The Android on the card is gone afterwards. factory/puf-tool.sh and
# tsx-factory-restore bring it back from the .puf.
# This "card stage" is temporary. tsx-card-to-emmc (steps/legacy/tsx-card-to-emmc)
# then migrates boot and root onto the eMMC, which is the normal end state of
# the panel. tsx-install-mainline does not use this script. Only the USB
# install method does. Calling it directly is an expert and debug step.
#
#   bash tsx-android-install.sh preflight [options]   read only: checks + plan
#   bash tsx-android-install.sh install   [options]   do it (asks for "INSTALL")
#   bash tsx-android-install.sh status                what is installed now
#
# Options:
#   --stick DIR        stick root (default: search /mnt/media_rw/udisk*, /storage/udisk*,
#                      and the directory this script was started from)
#   --p2-written       p2 ALREADY holds the kiosk rootfs image, written from outside
#                      (e.g. a direct write to /dev/block/mmcblk0p2 by another tool).
#                      The stick directory then needs no rootfs-p2.ext4.gz (348 MiB, it fits
#                      no card partition). It needs only ROOTFS_P2_SHA256 and ROOTFS_P2_BYTES in
#                      tsx-install.conf. preflight hashes p2 (about a minute) and refuses
#                      a mismatch. Install writes nothing to p2.
#   --bootimg FILE     boot image to put on p1 (default: tsxboot-<model>.img on the stick)
#   --guard fallback|nogolden   U-Boot hook variant (default fallback, the one
#                      proven on the TSW-1060. Nogolden is untested)
#   --no-defuse-golden do not set DataRecoveryDone=1. Default: set it. Then the golden
#                      image does not format p5 or wipe /data if it ever runs.
#                      The tsx-boot-ok of mainline keeps it at 1 after each boot.
#   --no-sdcard-backup do not tar the Android sdcard (p5) contents to the stick
#   --no-reboot        do not reboot at the end
#   --yes              do not ask
#
# What it writes: p2 (kiosk rootfs, unless --p2-written), the Crestron golden
# p1:boot.img (backups first, then the mainline rescue), p1:tsxboot.img (the
# kiosk image), p1:tsxlayout.cfg (orders the first mainline boot to format p4
# as tsxdata), three or four U-Boot env variables through the own fw_setenv of
# Android, and LAST the MBR byte that swaps p5..p8 for p4. Every earlier state
# still boots: Android, or mainline from p2. Backups go to the stick and to
# /data/local/tsx-backup. It never writes the eMMC, U-Boot (the U-Boot copy of
# the card in the first MiB included) or p3.
# The older single-stage and second-stage alternatives to this flow are gone.
# This is the only supported path now.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tsx-lib.sh"

log() { echo "tsx-install: $*" >&2; [ -n "${LOG:-}" ] && echo "$(date '+%F %T' 2>/dev/null) $*" >> "$LOG"; return 0; }
die() { log "ERROR: $*"; echo "tsx-install: nothing more was changed. Log: ${LOG:-none}" >&2; exit 1; }
warn() { log "WARNING: $*"; }

tsx_pick_bb || { echo "tsx-install: no busybox found" >&2; exit 1; }
tsx_wrap_applets

CMD=${1:-}; [ $# -gt 0 ] && shift
STICK= BOOTIMG= P2WRITTEN=0 GUARD=fallback DEFUSE=1 SDBACKUP=1 REBOOT=1 YES=0
while [ $# -gt 0 ]; do
	case "$1" in
	--stick) STICK=$2; shift;;
	--bootimg) BOOTIMG=$2; shift;;
	--direct-p5) echo "--direct-p5 was removed: this is now the only install path" >&2; exit 2;;
	--guard) GUARD=$2; shift;;
	--defuse-golden) DEFUSE=1;;
	--no-defuse-golden) DEFUSE=0;;
	--p2-written) P2WRITTEN=1;;
	--no-sdcard-backup) SDBACKUP=0;;
	--no-reboot) REBOOT=0;;
	--yes) YES=1;;
	*) echo "unknown option $1" >&2; exit 2;;
	esac; shift
done
case "$CMD" in preflight|install|status) ;; *) sed -n '2,54p' "$0"; exit 2;; esac
case "$GUARD" in fallback) WANT_SWITCH=$TSX_SWITCH_FALLBACK;; nogolden) WANT_SWITCH=$TSX_SWITCH_NOGOLDEN;; *) die "--guard fallback|nogolden";; esac

W=${TSX_WORKDIR:-/dev/tsx-inst}          # /dev is a tmpfs on Android (RAM, gone after a reboot)
mkdir -p "$W" || die "cannot create $W"
LOG=$W/install.log
MNT_P1=$W/p1 P1_MOUNTED_BY_US=0
cleanup() { [ "$P1_MOUNTED_BY_US" = 1 ] && umount "$MNT_P1" 2>/dev/null; return 0; }
trap cleanup EXIT

# ------------------------------------------------------------------ checks
FAILS=0
chk() { if [ "$1" = ok ]; then log "  ok    $2"; else log "  FAIL  $2"; FAILS=$((FAILS+1)); fi; }

log "== xx60 installer ($CMD) $(date 2>/dev/null)"
[ "$(id -u)" = 0 ] && chk ok "running as root" || chk fail "not root (id -u = $(id -u)). Use: ssh -tt admin@<panel>"
log "  busybox: $BB"
tsx_pick_fwenv && chk ok "fw_printenv/fw_setenv: $FWP" || chk fail "no fw_printenv/fw_setenv"
BBLIST=$("$BB" --list 2>/dev/null)
if [ -n "$BBLIST" ]; then
	for a in $TSX_APPLETS sort fuser blkid tar reboot; do echo "$BBLIST" | "$BB" grep -qx "$a" || chk fail "busybox has no applet $a"; done
else log "  (busybox --list not supported: applets not checked)"; fi

if tsx_find_disk; then chk ok "boot disk $WHOLE: $TSX_DISK_LAYOUT layout ($( [ "$TSX_DISK_LAYOUT" = stock ] && echo 'Crestron MBR, p1..p8' || echo 'card stage: p1..p4, p4 = tsxdata'))"
else chk fail "no mmcblk device with the exact Crestron (or card-stage) partition layout: wrong unit or repartitioned"; fi
[ $FAILS = 0 ] || die "basic checks failed"

why=$(tsx_env_sane) && chk ok "U-Boot env at $WHOLE+0x100000: CRC ok, yushan_one env" || chk fail "U-Boot env: $why"
MODEL=$(tsx_model) && chk ok "model: $MODEL (lcdsize=$(tsx_env lcdsize), $(tsx_env product_name | cut -c1-24))" \
	|| chk fail "unknown model: lcdsize=$(tsx_env lcdsize 2>/dev/null) aml_dt=$(tsx_env aml_dt 2>/dev/null) product_name=$(tsx_env product_name 2>/dev/null)"
UNIT=$(tsx_unit_id); log "  unit id: $UNIT"
HOOK=$(tsx_hook_state)
case "$HOOK" in
stock|fallback|nogolden|plain) chk ok "switch_bootmode: $HOOK";;
*) chk fail "switch_bootmode has unknown content (not stock, not our hook): $(tsx_env switch_bootmode)";;
esac
TB=$(tsx_env tsx_boot 2>/dev/null) || TB=
if [ -n "$TB" ] && [ "$TB" != "$TSX_BOOT_CMD" ]; then chk fail "tsx_boot exists with different content: $TB"; fi
BR=$(tsx_env boot_retry 2>/dev/null); GBR=$(tsx_env golden_boot_retry 2>/dev/null)
log "  boot_retry=$BR golden_boot_retry=$GBR DataRecoveryDone=$(tsx_env DataRecoveryDone 2>/dev/null) fwUpgrade=$(tsx_env fwUpgrade 2>/dev/null)"
[ "$(tsx_env fwUpgrade 2>/dev/null)" = 0 ] || chk fail "fwUpgrade is not 0: a Crestron firmware update is in progress"

# p1 (FAT, golden boot.img). Android does not mount it, so this script mounts it.
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

# p5
p5_label() { [ -b "$P5" ] && "$BB" blkid "$P5" 2>/dev/null | sed -n 's/.* LABEL="\([^"]*\)".*/\1/p'; }
log "  p5 label: $(p5_label)"
P5M=$(tsx_mounts_of "$P5" | tr '\n' ' ')
log "  p5 ($P5) mounted at: ${P5M:-nothing}"

# stick
[ -n "$STICK" ] || STICK=$(tsx_find_stick "$HERE/.." "$HERE/../..") || STICK=
if [ -n "$STICK" ]; then
	CONF=$STICK/tsx-install/tsx-install.conf
	chk ok "stick: $STICK ($(tsx_conf VERSION "$CONF"))"
else
	chk fail "no stick with tsx-install/tsx-install.conf found (--stick DIR)"
fi

if [ -n "$STICK" ] && [ -n "${MODEL:-}" ] && [ "$CMD" != status ]; then
	[ -n "$BOOTIMG" ] || BOOTIMG=$STICK/$(tsx_conf "BOOTIMG_$MODEL" "$CONF")
	log "  verifying the stick payload (sha256 of every file in tsx-install/SHA256SUMS; ~20 s per 300 MB)"
	SUMS=$STICK/tsx-install/SHA256SUMS
	P2REL=$(tsx_conf ROOTFS_P2 "$CONF")
	if [ $P2WRITTEN = 1 ] && [ -n "$P2REL" ] && [ ! -f "$STICK/$P2REL" ]; then
		# By design, the rootfs archive is not on the stick. The script checks p2 itself below.
		grep -v "  $P2REL\$" "$SUMS" > "$W/sums.in"; SUMS=$W/sums.in
		log "  --p2-written: $P2REL is not on the stick (expected). p2 is hashed instead"
	fi
	if (cd "$STICK" && sha256sum -c "$SUMS" > "$W/sums.txt" 2>&1); then chk ok "stick payload: all sha256 match$( [ "$SUMS" != "$STICK/tsx-install/SHA256SUMS" ] && echo ' (rootfs archive excluded)')"
	else chk fail "stick payload corrupt: $(grep -v ': OK$' "$W/sums.txt" | head -n 3 | tr '\n' ' ')"; fi
	[ -f "$BOOTIMG" ] || chk fail "no boot image for $MODEL on the stick (BOOTIMG_$MODEL in tsx-install.conf)"
	grep -q "^ENV_VERIFIED=yes" "$STICK/tsx-install/rootfs.info" 2>/dev/null \
		|| warn "rootfs.info does not say ENV_VERIFIED=yes: tsx-boot-ok may not reset boot_retry (see stick README)"
fi
if [ "$CMD" != status ]; then
	P2IMG=${STICK:+$STICK/$(tsx_conf ROOTFS_P2 "$CONF")}; P2SHA=${STICK:+$(tsx_conf ROOTFS_P2_SHA256 "$CONF")}; P2BYTES=${STICK:+$(tsx_conf ROOTFS_P2_BYTES "$CONF")}
	RESC=${STICK:+$STICK/$(tsx_conf "RESCUE_${MODEL:-x}" "$CONF")}
	P2GOT=
	if [ $P2WRITTEN = 1 ]; then
		if [ -n "$P2SHA" ] && [ -n "$P2BYTES" ] && [ "$P2BYTES" -le $((1638400 * 512)) ] && [ $((P2BYTES % 1048576)) = 0 ]; then
			log "  --p2-written: hashing the first $P2BYTES bytes of $P2 from the card (about a minute)"
			sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
			P2GOT=$(dd if="$P2" bs=1048576 count=$((P2BYTES / 1048576)) 2>/dev/null | sha256sum | cut -d' ' -f1)
			[ "$P2GOT" = "$P2SHA" ] && chk ok "p2 already holds the kiosk rootfs ($P2BYTES bytes, sha256 matches tsx-install.conf)" \
				|| chk fail "--p2-written, but p2 does not hold the rootfs image (sha256 $P2GOT != $P2SHA)"
		else chk fail "--p2-written needs ROOTFS_P2_SHA256 and ROOTFS_P2_BYTES (whole MiB, at most 800 MiB) in tsx-install.conf"; fi
	elif [ -n "$P2IMG" ] && [ -f "$P2IMG" ] && [ -n "$P2SHA" ] && [ -n "$P2BYTES" ]; then
		[ "$P2BYTES" -le $((1638400 * 512)) ] && [ $((P2BYTES % 1048576)) = 0 ] && chk ok "kiosk rootfs for p2 on the stick ($P2BYTES bytes)" \
			|| chk fail "ROOTFS_P2_BYTES=$P2BYTES does not fit p2 (800 MiB, whole MiB)"
	else chk fail "no rootfs-p2 image on the stick (mkpayload --rootfs-p2. ROOTFS_P2, ROOTFS_P2_SHA256, ROOTFS_P2_BYTES. Or --p2-written)"; fi
	[ -n "$RESC" ] && [ -f "$RESC" ] && [ "$(dd if="$RESC" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] && chk ok "rescue image for the golden slot: $RESC" \
		|| chk fail "no rescue image for ${MODEL:-?} on the stick (mkpayload --rescue-tsw1060)"
	[ -z "$(tsx_mounts_of "$P2")" ] && chk ok "p2 is not mounted (Android uses it only in the golden image)" || chk fail "p2 is mounted"
	MBR4=$(od -An -tx1 -j $TSX_MBR_P4_TYPE_OFFSET -N 1 "$WHOLE" 2>/dev/null | tr -d ' ')
	case "$MBR4" in 05|83) chk ok "MBR entry 4 type 0x$MBR4";; *) chk fail "MBR entry 4 type is 0x$MBR4, expected 05 (Crestron) or 83 (card stage)";; esac
	if [ -f "$RESC" ] && [ -n "${BOOTIMG:-}" ] && [ -f "$BOOTIMG" ]; then
		GOLD=0; [ -f "$MNT_P1/boot.img" ] && GOLD=$(( $(tsx_size "$MNT_P1/boot.img") / 1024 ))
		OLDT=0; [ -f "$MNT_P1/tsxboot.img" ] && OLDT=$(( $(tsx_size "$MNT_P1/tsxboot.img") / 1024 ))
		P1NEED=$(( $(tsx_size "$RESC") / 1024 + $(tsx_size "$BOOTIMG") / 1024 + 512 ))
		[ $(( ${P1FREE:-0} + GOLD + OLDT )) -gt $P1NEED ] && chk ok "p1 has room for kiosk + rescue image" || chk fail "p1 too full for kiosk + rescue ($P1NEED KiB needed)"
	fi
fi
if [ -n "$BOOTIMG" ]; then
	[ -f "$BOOTIMG" ] && [ "$(dd if="$BOOTIMG" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] && chk ok "boot image $BOOTIMG ($(tsx_size "$BOOTIMG") bytes)" \
		|| chk fail "boot image $BOOTIMG missing or not an Android boot image"
	NEED=$(( $(tsx_size "$BOOTIMG" 2>/dev/null || echo 0) / 1024 + 256 ))
	OLD=0; [ -f "$MNT_P1/tsxboot.img" ] && OLD=$(( $(tsx_size "$MNT_P1/tsxboot.img") / 1024 ))
	[ $(( ${P1FREE:-0} + OLD )) -gt $NEED ] && chk ok "p1 has room for the boot image" || chk fail "p1 too full: ${P1FREE:-?} KiB free, need $NEED KiB"
else
	chk fail "no boot image (give --bootimg FILE or a stick)"
fi


log "== plan"
log "  1. back up: env block (64 KiB), first 2 MiB of $WHOLE (MBR + U-Boot copy + env), first MiB of p5,"
log "     fw_printenv text${STICK:+, Android sdcard files (tar)} -> ${STICK:+stick tsx-install/backup/$UNIT-*/ and }/data/local/tsx-backup/"
log "  2. p1: tsxboot.img <- $(basename "${BOOTIMG:-?}") (golden boot.img untouched), tsxenv.bak, remove tsxboot.off"
log "  3. p2 $( [ $P2WRITTEN = 1 ] && echo 'already written (verified, left as is)' || echo "<- $(basename "${P2IMG:-?}") (verified)"), Crestron golden p1:boot.img -> backups, p1:boot.img <- rescue,"
log "     p1:tsxlayout.cfg (first mainline boot formats p4 as tsxdata), then after the env: MBR byte 498 0x05 -> 0x83"
log "  4. env (fw_setenv): tsx_boot, switch_bootmode = $GUARD hook, boot_retry=0, golden_boot_retry=0$( [ $DEFUSE = 1 ] && echo ', DataRecoveryDone=1')"
log "  5. $( [ $REBOOT = 1 ] && echo 'reboot (busybox reboot -f)' || echo 'no reboot (--no-reboot)')"

if [ "$CMD" = status ]; then
	log "== status: hook=$HOOK tsx_boot=$( [ -n "$TB" ] && echo set || echo unset ) p1:tsxboot.img=$( [ -f "$MNT_P1/tsxboot.img" ] && echo yes || echo no ) tsxboot.off=$( [ -f "$MNT_P1/tsxboot.off" ] && echo yes || echo no ) p5=$("$BB" blkid "$P5" 2>/dev/null)"
	exit 0
fi
[ $FAILS = 0 ] || die "$FAILS check(s) failed. Nothing written"
if [ "$CMD" = preflight ]; then log "== preflight OK (nothing written). Run again with 'install' to do it."; exit 0; fi

# ------------------------------------------------------------------ install
if [ $YES != 1 ]; then
	printf 'Type INSTALL to write p1 + the U-Boot env of this %s (%s): ' "$MODEL" "$UNIT" >&2
	read -r ans; [ "$ans" = INSTALL ] || die "not confirmed"
fi

# 1. Backups. Everything below is read-only until step 2.
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
BK=/data/local/tsx-backup/$UNIT-$TS
mkdir -p "$BK" || die "cannot create $BK"
dd if="$WHOLE" bs=65536 skip=16 count=1 of="$BK/env-0x100000.bin" 2>/dev/null || die "env backup failed"
[ "$(tsx_size "$BK/env-0x100000.bin")" = $TSX_ENV_SIZE ] || die "env backup has the wrong size"
dd if="$WHOLE" bs=1048576 count=2 of="$BK/disk-head-2M.bin" 2>/dev/null || die "disk head backup failed"
if [ -b "$P5" ]; then dd if="$P5" bs=1048576 count=1 of="$BK/p5-head-1M.bin" 2>/dev/null || die "p5 head backup failed"
else : > "$BK/p5-head-1M.bin"; fi
if [ -f "$MNT_P1/boot.img" ] && [ "$GSHA" != "$(sha256sum < "$RESC" | cut -d' ' -f1)" ]; then
	cp "$MNT_P1/boot.img" "$BK/golden-boot.img" && [ "$(sha256sum < "$BK/golden-boot.img" | cut -d' ' -f1)" = "$GSHA" ] || die "golden boot.img backup failed"
fi
tsx_fw_bound "$FWP" > "$BK/fw_printenv.txt" 2>&1
for p in 1 2 3 4 5 6 7 8; do [ -e /sys/block/$DISK/${DISK}p$p ] && echo "p$p $(cat /sys/block/$DISK/${DISK}p$p/start) $(cat /sys/block/$DISK/${DISK}p$p/size)"; done > "$BK/partitions.txt"
echo "golden_boot_img_sha256=$GSHA" >> "$BK/partitions.txt"
(cd "$BK" && sha256sum env-0x100000.bin disk-head-2M.bin p5-head-1M.bin fw_printenv.txt $( [ -f golden-boot.img ] && echo golden-boot.img) > SHA256SUMS)
log "backups in $BK"
if [ -n "$STICK" ]; then
	SBK=$STICK/tsx-install/backup/$UNIT-$TS
	mkdir -p "$SBK" && cp "$BK"/* "$SBK/" && (cd "$SBK" && sha256sum -c SHA256SUMS >/dev/null 2>&1) \
		&& log "backups copied to the stick: $SBK" || die "cannot write the backups to the stick (read-only? full?)"
	if [ $SDBACKUP = 1 ] && [ "$(p5_label)" = sdcard ]; then
		SDM=$(tsx_mounts_of "$P5" | head -n 1)
		if [ -n "$SDM" ]; then
			log "archiving the Android sdcard ($SDM) to the stick (Crestron ROMDISK, project files)"
			"$BB" tar czf "$SBK/android-sdcard.tar.gz" -C "$SDM" . 2>>"$LOG" || warn "sdcard archive incomplete (see log)"
		fi
	fi
fi

# 2. p1 (FAT): boot image and a copy of the env backup. The script never opens the golden boot.img for writing.
cp "$BK/env-0x100000.bin" "$MNT_P1/tsxenv.bak" && sync
BSHA=$(sha256sum < "$BOOTIMG" | cut -d' ' -f1)
if [ -f "$MNT_P1/tsxboot.img" ] && [ "$(sha256sum < "$MNT_P1/tsxboot.img" | cut -d' ' -f1)" = "$BSHA" ]; then
	log "p1:tsxboot.img is already this image ($BSHA)"
else
	FREE=$(df -Pk "$MNT_P1" | awk 'NR==2{print $4}')
	if [ "$FREE" -le "$NEED" ] && [ -f "$MNT_P1/tsxboot.img" ]; then
		log "not enough room for a side-by-side copy: removing the old p1:tsxboot.img first"
		rm -f "$MNT_P1/tsxboot.img"; sync
	fi
	cp "$BOOTIMG" "$MNT_P1/tsxboot.new" && sync
	[ "$(sha256sum < "$MNT_P1/tsxboot.new" | cut -d' ' -f1)" = "$BSHA" ] || { rm -f "$MNT_P1/tsxboot.new"; die "copy to p1 corrupt"; }
	mv "$MNT_P1/tsxboot.new" "$MNT_P1/tsxboot.img" && sync
	log "p1:tsxboot.img written ($BSHA)"
fi
[ "$(sha256sum < "$MNT_P1/boot.img" | cut -d' ' -f1)" = "$GSHA" ] || warn "golden boot.img changed?!"

# 3. p2 gets the kiosk rootfs, the golden slot gets the rescue, and p1 gets the order for the first mainline boot.
if [ $P2WRITTEN = 1 ]; then
	[ "$P2GOT" = "$P2SHA" ] || die "p2 does not hold the rootfs image ($P2GOT != $P2SHA)"
	GOT=$P2GOT
	log "p2 already holds the kiosk rootfs (hashed from the card during the checks: $GOT). Nothing written to p2"
else
	log "writing the kiosk rootfs to p2 ($P2BYTES bytes, about a minute)"
	gunzip -c "$P2IMG" | dd of="$P2" bs=1048576 2>"$W/dd.txt" || die "write to p2 failed: $(cat "$W/dd.txt") (Android still boots: p2 is only the golden /system)"
	sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	GOT=$(dd if="$P2" bs=1048576 count=$((P2BYTES / 1048576)) 2>/dev/null | sha256sum | cut -d' ' -f1)
	[ "$GOT" = "$P2SHA" ] || die "p2 readback $GOT != $P2SHA (nothing else changed yet. Android still boots)"
	log "p2 written and verified ($GOT)"
fi
RSHA=$(sha256sum < "$RESC" | cut -d' ' -f1)
if [ "$(sha256sum < "$MNT_P1/boot.img" 2>/dev/null | cut -d' ' -f1)" != "$RSHA" ]; then
	rm -f "$MNT_P1/boot.new"
	if [ "$(df -Pk "$MNT_P1" | awk 'NR==2{print $4}')" -le $(( $(tsx_size "$RESC") / 1024 + 64 )) ]; then rm -f "$MNT_P1/boot.img"; sync; fi
	cp "$RESC" "$MNT_P1/boot.new" && sync
	[ "$(sha256sum < "$MNT_P1/boot.new" | cut -d' ' -f1)" = "$RSHA" ] || die "rescue copy to p1 corrupt (golden backup: $BK/golden-boot.img)"
	mv "$MNT_P1/boot.new" "$MNT_P1/boot.img" && sync
	log "p1:boot.img = mainline rescue ($RSHA). Crestron's golden image: $BK/golden-boot.img${STICK:+ and the stick}"
fi
MKUUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
[ -n "$MKUUID" ] || die "cannot generate MKDATA_UUID (/proc/sys/kernel/random/uuid unreadable)"
{ echo "# tsx-android-install.sh $TS: the first mainline boot formats p4 (tsxdata)"; echo "MKDATA=p4"; echo "MKDATA_UUID=$MKUUID"; echo "RESCUE_SHA256=$RSHA"; echo "ROOTFS_P2_SHA256=$P2SHA"; } > "$MNT_P1/tsxlayout.cfg" && sync || die "cannot write p1:tsxlayout.cfg"
rm -f "$MNT_P1/tsxinst.cfg"
rm -f "$MNT_P1/tsxboot.off"; sync

# 4. Write the U-Boot env through the own fw_setenv of Android. The scripts of Crestron use the same writer on every boot.
setv() {
	tsx_fw_bound "$FWS" "$1" "$2" >> "$LOG" 2>&1 || die "fw_setenv $1 failed or timed out (env backup: $BK/env-0x100000.bin, p1:tsxenv.bak)"
	[ "$(tsx_env "$1")" = "$2" ] || die "readback of $1 differs after fw_setenv (restore the env backup with tsx-android-uninstall.sh --restore-env)"
	log "env $1 set"
}
[ "$(tsx_env tsx_boot 2>/dev/null)" = "$TSX_BOOT_CMD" ] || setv tsx_boot "$TSX_BOOT_CMD"
[ "$(tsx_env switch_bootmode)" = "$WANT_SWITCH" ] || setv switch_bootmode "$WANT_SWITCH"
setv boot_retry 0
setv golden_boot_retry 0
[ $DEFUSE = 1 ] && [ "$(tsx_env DataRecoveryDone 2>/dev/null)" != 1 ] && setv DataRecoveryDone 1
tsx_fw_bound "$FWP" > "$BK/fw_printenv-after.txt" 2>&1
tsx_env_sane >/dev/null || die "env not sane after the writes: restore $BK/env-0x100000.bin (tsx-android-uninstall.sh --restore-env)"
log "U-Boot env hook installed ($GUARD)"

# 5. The MBR byte, LAST. Every earlier state still boots: Android, or mainline from p2.
if [ "$(od -An -tx1 -j $TSX_MBR_P4_TYPE_OFFSET -N 1 "$WHOLE" | tr -d ' ')" != 83 ]; then
	printf '\203' | dd of="$WHOLE" bs=1 seek=$TSX_MBR_P4_TYPE_OFFSET count=1 conv=notrunc 2>>"$LOG" || die "MBR write failed"
	sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	[ "$(od -An -tx1 -j $TSX_MBR_P4_TYPE_OFFSET -N 1 "$WHOLE" | tr -d ' ')" = 83 ] || die "MBR readback: entry 4 type is not 0x83 (restore: disk-head-2M.bin in $BK)"
	log "MBR: entry 4 = 0x83. The running Android keeps its old partition view until the reboot."
fi

[ -n "$STICK" ] && { mkdir -p "$STICK/tsx-install/log"; cp "$LOG" "$STICK/tsx-install/log/$UNIT-$TS-android.log"; }
sync
if [ "$P1_MOUNTED_BY_US" = 1 ]; then umount "$MNT_P1" && P1_MOUNTED_BY_US=0; fi
log "DONE. Next boot: U-Boot -> p1:tsxboot.img -> kiosk from p2. The initramfs formats p4 as tsxdata once. The stick can go."
if [ $REBOOT = 1 ]; then
	log "rebooting in 5 s (Android's own reboot script hangs once p5 is not the Android sdcard)"
	sync; sleep 5
	"$BB" reboot -f
	sleep 5; echo 1 > /proc/sys/kernel/sysrq 2>/dev/null; echo b > /proc/sysrq-trigger
fi
exit 0
