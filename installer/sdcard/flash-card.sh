#!/bin/bash
# Write a xx60 card image (from mkcard.sh) to the panel's SD card in a Linux
# PC's card reader. No UART, no root shell on the panel.
#
#   sudo sdcard/flash-card.sh --image card-tsw1060.img[.gz|.xz|.zst] --device /dev/sdX [options]
#   sudo sdcard/flash-card.sh --restore BACKUP.img --device /dev/sdX
#
#   --mode auto|update|full   (default auto: update if the card holds the Crestron layout
#                              and a valid xx60 env, else full)
#       update  keep everything of the unit's card except: p1 gets tsxboot.img (golden
#               boot.img stays), p5 = the image's rootfs, env = the card's OWN env + hook.
#               p2, p6 (/data), p7, p8, MBR, U-Boot copy: untouched.
#       full    write the whole image (a new/blank/foreign card). If the card already has
#               the Crestron MBR, its first MiB (MBR + U-Boot copy) is kept. The env is the
#               card's own + hook if it has one, else --unit-env FILE, else refused unless
#               --generic-env (the image's env: no MAC in the env).
#   --unit-env FILE   64 KiB env block of this unit (a flash-card/installer backup, p1:tsxenv.bak)
#   --keep-data       full mode: do not write p6/p7/p8 (keep the card's Crestron data)
#   --guard fallback|nogolden   hook variant (default fallback)
#   --no-defuse-golden  do not set DataRecoveryDone=1 (default: set it, so the
#                     Crestron golden image does not format p5/p7 and empty /data)
#   --backup-dir DIR  where the full card backup goes (default ./tsx-card-backups); REQUIRED
#                     step, the flash does not start without a verified backup
#   (card size: at least the original Phison MP995, 3,980,394,496 bytes = 7774208 sectors;
#    a larger card is accepted, the layout is unchanged and the rest stays unused;
#    a smaller card is always refused)
#   --force-device    accept a block device that is not removable/USB/MMC
#   --dry-run         read, back up, plan and print; write nothing
#   --yes             do not ask
# A regular file as --device is accepted (tests). Needs: python3, mtools, GNU dd, sha256sum.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ENVPY="python3 $HERE/tsx-env.py"
CARD_BYTES=3980394496
P1_OFF=$((81920*512)) P1_LEN=$((81920*512)) P5_OFF=$((1847297*512)) P5_LEN=$((3055616*512)) P2_OFF=$((206849*512)) P2_LEN=$((1638400*512))
P6_OFF=$((4904961*512)) ENV_OFF=$((0x100000)) ENV_LEN=$((0x10000)) MIB=1048576
IMAGE= DEV= MODE=auto UNITENV= KEEPDATA=0 GUARD=fallback DEFUSE=--defuse-golden BKDIR=./tsx-card-backups LARGER=0 FORCEDEV=0 DRY=0 YES=0 RESTORE= GENERIC=0
while [ $# -gt 0 ]; do
	case "$1" in
	--image) IMAGE=$2; shift;; --device) DEV=$2; shift;; --mode) MODE=$2; shift;;
	--unit-env) UNITENV=$2; shift;; --keep-data) KEEPDATA=1;; --guard) GUARD=$2; shift;;
	--defuse-golden) DEFUSE=--defuse-golden;; --no-defuse-golden) DEFUSE=--no-defuse-golden;; --backup-dir) BKDIR=$2; shift;;
	--allow-larger) ;; --force-device) FORCEDEV=1;; --dry-run) DRY=1;; --yes) YES=1;;
	--restore) RESTORE=$2; shift;; --generic-env) GENERIC=1;;
	*) sed -n '2,30p' "$0"; exit 2;;
	esac; shift
done
die() { echo "flash-card: ERROR: $*" >&2; exit 1; }
say() { echo "flash-card: $*" >&2; [ -n "${LOG:-}" ] && echo "$(date +%T) $*" >> "$LOG"; return 0; }
[ -n "$DEV" ] && { [ -n "$IMAGE" ] || [ -n "$RESTORE" ]; } || { sed -n '2,30p' "$0"; exit 2; }
for t in python3 dd sha256sum mcopy mdel; do command -v $t >/dev/null || die "needs $t (mtools for mcopy)"; done

# ---------------------------------------------------------------- the target
if [ -b "$DEV" ]; then
	[ "$(id -u)" = 0 ] || die "run as root for a block device"
	D=$(basename "$(readlink -f "$DEV")")
	grep -q "^/dev/$D" /proc/mounts && die "$DEV (or a partition of it) is mounted: unmount it first (desktop auto-mount!)"
	rm=$(cat /sys/block/$D/removable 2>/dev/null || echo 0)
	tran=$(lsblk -dno TRAN "/dev/$D" 2>/dev/null || true)
	case "$rm:$tran:$D" in 1:*|*:usb:*|*:*:mmcblk*) ;; *) [ $FORCEDEV = 1 ] || die "$DEV is not removable/USB/MMC (removable=$rm tran=$tran): is this really the card reader? (--force-device)";; esac
	SIZE=$(blockdev --getsize64 "$DEV")
elif [ -f "$DEV" ]; then SIZE=$(stat -c %s "$DEV")
else die "$DEV is neither a block device nor a file"; fi
if [ "$SIZE" != $CARD_BYTES ]; then
	[ "$SIZE" -lt $CARD_BYTES ] && die "card is $SIZE bytes, smaller than the xx60 card ($CARD_BYTES): refused"
	say "NOTE: card is larger than the original Phison MP995 ($SIZE > $CARD_BYTES bytes, 7774208 sectors): the Crestron layout uses the first $CARD_BYTES, the rest stays unused"
fi
mkdir -p "$BKDIR"; TS=$(date +%Y%m%d-%H%M%S); LOG=$BKDIR/flash-$TS.log; : > "$LOG"
say "target $DEV ($SIZE bytes)"
rd() { dd if="$1" bs=4M iflag=skip_bytes,count_bytes skip=$2 count=$3 status=none; }   # rd SRC OFF LEN
wr() {   # wr SRCFILE SRCOFF LEN DSTOFF   (write to $DEV, sync)
	dd if="$1" of="$DEV" bs=4M iflag=skip_bytes,count_bytes oflag=seek_bytes skip=$2 count=$3 seek=$4 conv=notrunc,fsync status=none
}
sum() { rd "$1" $2 $3 | sha256sum | cut -d' ' -f1; }

# ---------------------------------------------------------------- restore
if [ -n "$RESTORE" ]; then
	[ "$(stat -c %s "$RESTORE")" = $CARD_BYTES ] || die "$RESTORE is not a full card backup"
	if [ -f "$RESTORE.sha256" ]; then
		[ "$(sha256sum < "$RESTORE" | cut -d' ' -f1)" = "$(cut -d' ' -f1 < "$RESTORE.sha256")" ] || die "$RESTORE does not match its .sha256"
	fi
	[ $YES = 1 ] || { read -r -p "Write $RESTORE over ALL of $DEV? Type RESTORE: " a; [ "$a" = RESTORE ] || die "not confirmed"; }
	[ $DRY = 1 ] && { say "dry run: nothing written"; exit 0; }
	wr "$RESTORE" 0 $CARD_BYTES 0
	[ "$(sum "$DEV" 0 $CARD_BYTES)" = "$(sha256sum < "$RESTORE" | cut -d' ' -f1)" ] || die "readback differs"
	say "card restored from $RESTORE and verified"; exit 0
fi

# ---------------------------------------------------------------- the image
W=$(mktemp -d "$BKDIR/.flash.XXXX"); trap 'rm -rf "$W"' EXIT
case "$IMAGE" in
*.gz) say "decompressing $IMAGE"; gzip -dc "$IMAGE" | dd of="$W/image.img" bs=4M conv=sparse status=none; IMG=$W/image.img;;
*.xz) say "decompressing $IMAGE"; xz -dc "$IMAGE" | dd of="$W/image.img" bs=4M conv=sparse status=none; IMG=$W/image.img;;
*.zst) say "decompressing $IMAGE"; zstd -dc "$IMAGE" | dd of="$W/image.img" bs=4M conv=sparse status=none; IMG=$W/image.img;;
*) IMG=$IMAGE;;
esac
[ "$(stat -c %s "$IMG")" = $CARD_BYTES ] || die "image is not $CARD_BYTES bytes"
MAN=${IMAGE%.gz}; MAN=${MAN%.xz}; MAN=${MAN%.zst}; MAN=${MAN%.img}.manifest
if [ -f "$MAN" ]; then
	while read -r _ name off len sha; do
		[ "$(sum "$IMG" $off $len)" = "$sha" ] || die "image region $name does not match $MAN: corrupt download?"
	done < <(grep '^region ' "$MAN")
	say "image regions match $(basename "$MAN")"
else say "WARNING: no manifest next to the image: not verified"; fi
$ENVPY check "$IMG" >> "$LOG" || die "the image's env is not valid (see $LOG)"
# p5 must stay mountable by the stock Android kernel 3.10 (Android shares p5 as its
# /sdcard after a fallback): no metadata_csum_seed (INCOMPAT 0x2000), no orphan_file
# (COMPAT 0x1000, RO_COMPAT 0x10000). mkcard.sh makes sure of that; checked again here.
python3 - "$IMG" $P5_OFF <<'PY' || die "the image's p5 has ext4 features the stock Android kernel 3.10 cannot mount: rebuild it with mkcard.sh"
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(int(sys.argv[2]) + 1024); d = f.read(1024)
assert struct.unpack_from('<H', d, 0x38)[0] == 0xEF53, 'p5 is not ext2/3/4'
compat, incompat, ro = struct.unpack_from('<III', d, 0x5C)
INC_OK = 0x2 | 0x4 | 0x10 | 0x40 | 0x80 | 0x200 | 0x100 | 0x8000   # 3.10 EXT4_FEATURE_INCOMPAT_SUPP
RO_OK = 0x1 | 0x2 | 0x10 | 0x20 | 0x40 | 0x4 | 0x8 | 0x200 | 0x100   # no 0x400 metadata_csum: hardware pass B3, 3.10 'error loading journal'
assert incompat & ~INC_OK == 0 and ro & ~RO_OK == 0 and not compat & 0x1000, (hex(compat), hex(incompat), hex(ro))
PY
export MTOOLS_SKIP_CHECK=1
rd "$IMG" $P1_OFF $P1_LEN > "$W/img-p1.fat"
mcopy -n -i "$W/img-p1.fat" ::tsxboot.img "$W/tsxboot.img" 2>/dev/null || die "the image has no p1:tsxboot.img"

# ---------------------------------------------------------------- 1. full backup of the card (verified)
BK=$BKDIR/card-backup-$TS.img
say "backing up the whole card to $BK (this reads $((CARD_BYTES/1000000)) MB)"
rd "$DEV" 0 $CARD_BYTES | tee >(sha256sum | cut -d' ' -f1 > "$W/bk.sum") | dd of="$BK" bs=4M conv=sparse status=none
truncate -s $CARD_BYTES "$BK"
sleep 1; BSUM=$(cat "$W/bk.sum")
[ "$(sha256sum < "$BK" | cut -d' ' -f1)" = "$BSUM" ] || die "backup file differs from what was read"
echo "$BSUM  $(basename "$BK")" > "$BK.sha256"
say "backup verified: $BSUM"

# ---------------------------------------------------------------- 2. what is on the card
CRESTRON=0
python3 - "$BK" <<'PY' && CRESTRON=1 || true
import struct, sys
d = open(sys.argv[1], 'rb').read(512)
ent = [struct.unpack_from('<B3xB3xII', d, 446 + 16 * i) for i in range(4)]
ok = d[510:512] == b'\x55\xaa' and [(e[2], e[3]) for e in ent[:3]] == [(81920, 81920), (206849, 1638400), (2048, 2048)] \
    and ent[3][1] == 5 and ent[3][2] == 1845249
sys.exit(0 if ok else 1)
PY
dd if="$BK" of="$W/card-env.bin" bs=64K skip=16 count=1 status=none
CARDENV=0; $ENVPY check "$W/card-env.bin" >> "$LOG" 2>&1 && CARDENV=1
UNIT=$($ENVPY show "$W/card-env.bin" ethaddr 2>/dev/null | sed -n 's/^ethaddr=//p' | tr -d ':')
[ -n "$UNIT" ] && { mv "$BK" "$BKDIR/card-backup-$UNIT-$TS.img"; mv "$BK.sha256" "$BKDIR/card-backup-$UNIT-$TS.img.sha256"
	sed -i "s/card-backup-$TS.img/card-backup-$UNIT-$TS.img/" "$BKDIR/card-backup-$UNIT-$TS.img.sha256"; BK=$BKDIR/card-backup-$UNIT-$TS.img; }
cp "$W/card-env.bin" "$BKDIR/card-env-${UNIT:-unknown}-$TS.bin"
HOOKST=$($ENVPY check "$W/card-env.bin" 2>/dev/null | sed -n 's/.*hook \([a-z]*\).*/\1/p' || true)
say "card: Crestron layout $( [ $CRESTRON = 1 ] && echo yes || echo NO ), env $( [ $CARDENV = 1 ] && echo "valid (unit ${UNIT:-?}, hook ${HOOKST:-?})" || echo 'NOT valid')"
[ "$MODE" = auto ] && { [ $CRESTRON = 1 ] && [ $CARDENV = 1 ] && MODE=update || MODE=full; }

# model check: the image is for one model, the card's env says which unit this is
IMODEL=$($ENVPY show "$IMG" lcdsize | sed -n 's/^lcdsize=//p')
if [ $CARDENV = 1 ]; then
	CMODEL=$($ENVPY show "$W/card-env.bin" lcdsize | sed -n 's/^lcdsize=//p')
	[ "$CMODEL" = "$IMODEL" ] || die "the card belongs to a $CMODEL panel, the image is for $IMODEL"
fi

# ---------------------------------------------------------------- 3. the env to write
if [ $CARDENV = 1 ]; then SRCENV=$W/card-env.bin; KIND="the card's own env (unit $UNIT)"
elif [ -n "$UNITENV" ]; then $ENVPY check "$UNITENV" >> "$LOG" || die "--unit-env is not a valid xx60 env"; SRCENV=$UNITENV; KIND="--unit-env $(basename "$UNITENV")"
elif [ $GENERIC = 1 ]; then SRCENV=; KIND="the image's generic env (no MAC in the env)"
else die "the card has no valid env and no --unit-env was given. Per-unit values (MAC, tsid, product name) would be lost. Use a backup env of this unit (--unit-env) or --generic-env"; fi
if [ -n "$SRCENV" ]; then $ENVPY merge "$SRCENV" "$W/env.bin" --guard $GUARD $DEFUSE >> "$LOG"
else rd "$IMG" $ENV_OFF $ENV_LEN > "$W/env.bin"; fi
say "env: $KIND + hook $GUARD$( [ "$DEFUSE" = --defuse-golden ] && echo " + DataRecoveryDone=1")"

# ---------------------------------------------------------------- 4. plan
PLAN=$W/plan   # lines: name srcfile srcoff len dstoff
: > "$PLAN"
if [ "$MODE" = update ]; then
	[ $CRESTRON = 1 ] && [ $CARDENV = 1 ] || die "update mode needs a card with the Crestron layout and a valid env (use --mode full)"
	rd "$BK" $P1_OFF $P1_LEN > "$W/p1.fat"
	mdir -i "$W/p1.fat" ::boot.img >/dev/null 2>&1 || die "the card's p1 has no golden boot.img: not a xx60 boot partition?"
	mdel -i "$W/p1.fat" ::tsxboot.img ::tsxboot.new ::tsxboot.off ::tsxinst.cfg 2>/dev/null || true
	mcopy -i "$W/p1.fat" "$W/tsxboot.img" ::tsxboot.img || die "the card's p1 has no room for tsxboot.img"
	mcopy -o -i "$W/p1.fat" "$W/card-env.bin" ::tsxenv.bak
	echo "p1 $W/p1.fat 0 $P1_LEN $P1_OFF" >> "$PLAN"
	echo "p5 $IMG $P5_OFF $P5_LEN $P5_OFF" >> "$PLAN"
else
	if [ $CRESTRON = 1 ]; then START=$((ENV_OFF + ENV_LEN)); say "full: the card's MBR and U-Boot copy (first MiB) are kept"
	else START=$((ENV_OFF + ENV_LEN)); echo "head $IMG 0 $ENV_OFF 0" >> "$PLAN"; say "full: blank/foreign card: MBR + U-Boot copy from the image"; fi
	END=$CARD_BYTES; [ $KEEPDATA = 1 ] && [ $CRESTRON = 1 ] && END=$P6_OFF
	[ $KEEPDATA = 1 ] && [ $CRESTRON = 0 ] && die "--keep-data needs a card with the Crestron layout"
	echo "body $IMG $START $((END - START)) $START" >> "$PLAN"
	[ $KEEPDATA = 1 ] && say "full: p6/p7/p8 (Crestron /data, cache, logs) kept"
fi
echo "env $W/env.bin 0 $ENV_LEN $ENV_OFF" >> "$PLAN"     # always last
say "plan ($MODE):"; while read -r n f o l d; do say "  write $n: $l bytes at $d"; done < "$PLAN"
$ENVPY diff "$W/card-env.bin" "$W/env.bin" 2>/dev/null | sed 's/^/flash-card:   env change: /' | cut -c1-160 >&2 || true
if [ $DRY = 1 ]; then say "dry run: nothing written. Backup: $BK"; exit 0; fi
[ $YES = 1 ] || { read -r -p "Write to $DEV now? Type FLASH: " a; [ "$a" = FLASH ] || die "not confirmed (backup kept: $BK)"; }

# ---------------------------------------------------------------- 5. write (env last), 6. verify
while read -r n f o l d; do say "writing $n"; wr "$f" $o $l $d; done < "$PLAN"
sync
while read -r n f o l d; do
	[ "$(sum "$DEV" $d $l)" = "$(sum "$f" $o $l)" ] || die "verify of $n failed. Re-run, or restore: $0 --restore $BK --device $DEV"
done < "$PLAN"
$ENVPY check "$DEV" >> "$LOG" || die "env on the card is not valid after the write (restore the backup)"
say "done and verified. Put the card back; the panel boots the kiosk. Backup: $BK"
say "undo: $0 --restore $BK --device $DEV"
