#!/bin/bash
# Build a complete xx60 SD card image (the whole mmcblk0: 3,980,394,496 bytes,
# Crestron MBR) with the mainline kiosk pre-installed. Runs on the dev host, no
# root, no docker. Write it with flash-card.sh (recommended: keeps the unit's
# own env/MAC and data) or, for a blank card, with any dd/Etcher-style tool.
#
#   sdcard/mkcard.sh --out DIR [options]
#     --base IMG        donor card image (default: captures/tsw-1060/backup/tsw1060-mmcblk0.img;
#                       xx60-FACTORY.img is a TSW-760 card). Gives MBR, U-Boot copy,
#                       p1 golden boot.img, p2 golden system. Must have the Crestron layout.
#     --model tsw1060|tsw760   (default tsw1060)
#     --bootimg IMG     mainline boot image for p1:tsxboot.img (default: rootfs/out/tsxboot.img,
#                       the current p1 image; a recent build (see the audio bring-up notes) f36b275e... on
#                       2026-09-26; tsw1060 only, tsw760 has no default yet)
#     --rootfs-ext4 IMG p5 image (default rootfs/out/rootfs.ext4, exactly the p5 size)
#     --unit-env FILE   build a PER-UNIT image: the env of this unit (64 KiB block, e.g. a
#                       backup env-0x100000.bin or p1:tsxenv.bak) + the hook. Default: GENERIC
#                       env = donor env without its identity (MAC, tsid, names) + the hook
#     --guard fallback|nogolden, --no-defuse-golden  as the other installers (default:
#                       fallback hook + DataRecoveryDone=1)
#     --url URL, --token-file F                      kiosk URL / HA token in the rootfs
#     --keep-base-data  keep the donor's p6 (/data), p7, p8. Default: fresh empty file
#                       systems (same type/label/block size as Crestron's), no donor data
#     --golden IMG      replace p1:boot.img (Crestron's factory-recovery Android) with IMG
#                       (a mainline rescue image; the original is saved to DIR)
#     --compress gz|xz|zst|none   compressed copy next to the raw image (default gz)
#     --name NAME       output base name (default card-<model>[-<unit>])
# Outputs in DIR: NAME.img (sparse raw), NAME.img.gz, NAME.manifest (sha256 per region
# and of the whole image), NAME.env (the env block), NAME.log.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CAPTURES=${CAPTURES_DIR:-}
ENVPY="python3 $HERE/tsx-env.py"
CARD_BYTES=3980394496
# name:start:size (sectors), the Crestron MBR (the Crestron MBR layout notes)
LAYOUT="1:81920:81920 2:206849:1638400 3:2048:2048 5:1847297:3055616 6:4904961:1024000 7:5931009:204800 8:6137857:614400"
BASE=$CAPTURES/tsw-1060/backup/tsw1060-mmcblk0.img MODEL=tsw1060 BOOTIMG= EXT4=$ROOT/rootfs/out/rootfs.ext4
UNITENV= GUARD=fallback DEFUSE=--defuse-golden URL= TOKEN= KEEPDATA=0 GOLDEN= COMP=gz NAME= OUT=
while [ $# -gt 0 ]; do
	case "$1" in
	--out) OUT=$2; shift;; --base) BASE=$2; shift;; --model) MODEL=$2; shift;;
	--bootimg) BOOTIMG=$2; shift;; --rootfs-ext4) EXT4=$2; shift;; --unit-env) UNITENV=$2; shift;;
	--guard) GUARD=$2; shift;; --defuse-golden) DEFUSE=--defuse-golden;; --no-defuse-golden) DEFUSE=--no-defuse-golden;;
	--url) URL=$2; shift;; --token-file) TOKEN=$2; shift;; --keep-base-data) KEEPDATA=1;;
	--golden) GOLDEN=$2; shift;;
	--compress) COMP=$2; shift;; --name) NAME=$2; shift;;
	*) sed -n '2,29p' "$0"; exit 2;;
	esac; shift
done
die() { echo "mkcard: ERROR: $*" >&2; exit 1; }
say() { echo "mkcard: $*" >&2; [ -n "${LOG:-}" ] && echo "$*" >> "$LOG"; return 0; }
[ -n "$OUT" ] || { sed -n '2,29p' "$0"; exit 2; }
case "$MODEL" in tsw1060) [ -n "$BOOTIMG" ] || BOOTIMG=$ROOT/rootfs/out/tsxboot.img;; tsw760) [ -n "$BOOTIMG" ] || die "no TSW-760 boot image yet: give --bootimg";; *) die "--model tsw1060|tsw760";; esac
for t in mcopy mdir mdel mke2fs tune2fs e2fsck debugfs fallocate python3 sha256sum; do command -v $t >/dev/null || die "needs $t"; done
mkdir -p "$OUT"
[ -n "$NAME" ] || NAME=card-$MODEL
IMG=$OUT/$NAME.img LOG=$OUT/$NAME.log; : > "$LOG"
W=$(mktemp -d "$OUT/.mkcard.XXXX"); trap 'rm -rf "$W"' EXIT
off() { local e; for e in $LAYOUT; do [ "${e%%:*}" = "$1" ] && { e=${e#*:}; echo $(( ${e%%:*} * 512 )); return; }; done; }
len() { local e; for e in $LAYOUT; do [ "${e%%:*}" = "$1" ] && { echo $(( ${e##*:} * 512 )); return; }; done; }

# ---- checks
[ "$(stat -c %s "$BASE")" = $CARD_BYTES ] || die "$BASE is not a $CARD_BYTES-byte card image"
python3 - "$BASE" "$LAYOUT" <<'PY' || die "$BASE does not have the Crestron MBR layout"
import struct, sys
d = open(sys.argv[1], 'rb').read(512)
assert d[510:512] == b'\x55\xaa'
want = {int(e.split(':')[0]): (int(e.split(':')[1]), int(e.split(':')[2])) for e in sys.argv[2].split()}
ent = [struct.unpack_from('<B3xB3xII', d, 446 + 16 * i) for i in range(4)]
for n in (1, 2, 3):
    assert (ent[n - 1][2], ent[n - 1][3]) == want[n], n
assert ent[3][1] == 5 and ent[3][2] == 1845249
PY
$ENVPY check "$BASE" >> "$LOG" || die "the donor env is not usable (see $LOG)"
[ -n "$UNITENV" ] && { $ENVPY check "$UNITENV" >> "$LOG" || die "--unit-env: not a usable xx60 env (see $LOG)"; }
[ "$(stat -c %s "$EXT4")" = "$(len 5)" ] || die "$EXT4 is not exactly the p5 size ($(len 5) bytes)"
[ "$(dd if="$BOOTIMG" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || die "$BOOTIMG is not an Android boot image"
df_free=$(df -k --output=avail "$OUT" | tail -1)
[ "$df_free" -gt $((5 * 1024 * 1024)) ] || die "need ~5 GiB free in $OUT"
say "base $(basename "$BASE") model $MODEL boot $(basename "$BOOTIMG") ($(sha256sum < "$BOOTIMG" | cut -c1-12)) rootfs $(basename "$EXT4")"

# ---- 1. copy the donor card (sparse)
cp --sparse=always "$BASE" "$IMG.tmp"

# ---- 2. p1: add tsxboot.img (golden boot.img kept unless --golden)
dd if="$BASE" of="$W/p1.fat" bs=512 skip=$(( $(off 1) / 512 )) count=$(( $(len 1) / 512 )) status=none
export MTOOLS_SKIP_CHECK=1
mdel -i "$W/p1.fat" ::tsxboot.img ::tsxboot.new ::tsxboot.off ::tsxinst.cfg ::tsxinst.done 2>/dev/null || true
if [ -n "$GOLDEN" ]; then
	mcopy -i "$W/p1.fat" ::boot.img "$OUT/$NAME.crestron-golden-boot.img"
	mdel -i "$W/p1.fat" ::boot.img
	mcopy -i "$W/p1.fat" "$GOLDEN" ::boot.img
	say "p1:boot.img replaced by $(basename "$GOLDEN"); Crestron's golden image saved as $NAME.crestron-golden-boot.img"
fi
mcopy -i "$W/p1.fat" "$BOOTIMG" ::tsxboot.img || die "p1 full? $(minfo -i "$W/p1.fat" :: 2>/dev/null | grep -i free)"
mcopy -n -i "$W/p1.fat" ::tsxboot.img "$W/chk.img"; cmp -s "$W/chk.img" "$BOOTIMG" || die "p1 copy check failed"
dd if="$W/p1.fat" of="$IMG.tmp" bs=512 seek=$(( $(off 1) / 512 )) conv=notrunc status=none
say "p1: $(mdir -b -i "$W/p1.fat" :: | tr '\n' ' ')"

# ---- 3. p5: the rootfs, made mountable by the stock Android kernel 3.10
cp --sparse=always "$EXT4" "$W/p5.ext4"
# 3.10 rejects INCOMPAT_CSUM_SEED (0x2000) at mount; orphan_file is unknown to e2fsck 1.42.9.
# rootfs/mkrootfs.sh builds rootfs.ext4 without both (mkrootfs.sh -O ^metadata_csum_seed,^orphan_file);
# these two calls are then no-ops and only matter for an older rootfs.ext4. The check below
# (after all edits) is what guarantees the result.
tune2fs -O ^metadata_csum_seed "$W/p5.ext4" >> "$LOG" 2>&1 || true
tune2fs -O ^orphan_file "$W/p5.ext4" >> "$LOG" 2>&1 || true
# hardware pass B3 (2026-09-26): 3.10 also fails on metadata_csum ("error loading journal",
# e2fsck 1.42.9 "unsupported feature metadata_csum"): off, and a fresh journal without csum v3
tune2fs -O ^metadata_csum "$W/p5.ext4" >> "$LOG" 2>&1
tune2fs -O ^has_journal "$W/p5.ext4" >> "$LOG" 2>&1 && tune2fs -j "$W/p5.ext4" >> "$LOG" 2>&1
dbg() { debugfs -w -R "$1" "$W/p5.ext4" >> "$LOG" 2>&1; }
put() {   # put LOCALFILE PATH MODE
	dbg "rm $2" || true; dbg "write $1 $2"
	dbg "sif $2 uid 0"; dbg "sif $2 gid 0"; dbg "sif $2 mode $3"
}
debugfs -R "cat /etc/fstab" "$W/p5.ext4" 2>/dev/null | grep -v '/media/bootfat\|^LABEL=tsxdata' > "$W/fstab"
echo "/dev/mmcblk0p1  /media/bootfat  vfat  noauto,rw,noatime,umask=022  0 0" >> "$W/fstab"
put "$W/fstab" /etc/fstab 0100644
dbg "mkdir /media/bootfat" || true
if [ -n "$URL" ]; then
	debugfs -R "cat /etc/kiosk.conf" "$W/p5.ext4" 2>/dev/null | sed "s|^KIOSK_URL=.*|KIOSK_URL=\"$URL\"|" > "$W/kiosk.conf"
	grep -q "^KIOSK_URL=\"$URL\"" "$W/kiosk.conf" || die "cannot set KIOSK_URL"
	put "$W/kiosk.conf" /etc/kiosk.conf 0100644
fi
[ -n "$TOKEN" ] && put "$TOKEN" /var/lib/kiosk/pending-token 0100600
RSHA=$(sha256sum < "$EXT4" | cut -d' ' -f1)
{ echo "installed=$(date -Iseconds) (sdcard image, mkcard.sh)"; echo "disk=/dev/mmcblk0"; echo "rootfs_ext4_sha256=$RSHA"
  echo "bootimg_sha256=$(sha256sum < "$BOOTIMG" | cut -d' ' -f1)"; echo "model=$MODEL"; } > "$W/install.info"
dbg "mkdir /var/lib/tsx" || true; put "$W/install.info" /var/lib/tsx/install.info 0100644
e2fsck -fn "$W/p5.ext4" >> "$LOG" 2>&1 || die "p5 image does not pass e2fsck -fn (see $LOG)"
python3 - "$W/p5.ext4" <<'PY' || die "p5 still has features the stock Android kernel (3.10) cannot mount"
import struct, sys
d = open(sys.argv[1], 'rb').read(2048)[1024:]
compat, incompat, ro = struct.unpack_from('<III', d, 0x5C)
INC_OK = 0x2 | 0x4 | 0x10 | 0x40 | 0x80 | 0x200 | 0x100 | 0x8000   # 3.10 EXT4_FEATURE_INCOMPAT_SUPP
RO_OK = 0x1 | 0x2 | 0x10 | 0x20 | 0x40 | 0x4 | 0x8 | 0x200 | 0x100   # no 0x400 metadata_csum: hardware pass B3, 3.10 'error loading journal'
assert incompat & ~INC_OK == 0 and ro & ~RO_OK == 0 and not compat & 0x1000, (hex(compat), hex(incompat), hex(ro))  # 0x1000 = orphan_file
PY
fallocate -p -o $(off 5) -l $(len 5) "$IMG.tmp"      # no donor sdcard data in the gaps
dd if="$W/p5.ext4" of="$IMG.tmp" bs=1M oflag=seek_bytes seek=$(off 5) conv=notrunc,sparse status=none
say "p5: tsxroot from $(basename "$EXT4") ($(echo $RSHA | cut -c1-12)), csum_seed/orphan_file off (Android 3.10 can mount it)"

# ---- 4. p6/p7/p8: fresh file systems, no donor data
mkpart() {   # mkpart N TYPE LABEL BLOCKSIZE EXTRA-MKE2FS-OPTS
	local o=$(off $1) l=$(len $1)
	fallocate -p -o $o -l $l "$IMG.tmp"
	mke2fs -q -F -t $2 -L $3 -b $4 $5 -E offset=$o "$IMG.tmp" $(( l / $4 )) >> "$LOG" 2>&1
}
OLD_FEAT='-O ^metadata_csum,^metadata_csum_seed,^64bit,^orphan_file'
if [ $KEEPDATA = 0 ]; then
	mkpart 6 ext2 data 1024 "$OLD_FEAT"
	mkpart 7 ext2 cache 1024 "$OLD_FEAT"
	mkpart 8 ext4 logs 1024 "$OLD_FEAT,^extent"
	say "p6/p7/p8: fresh ext2 data, ext2 cache, ext4 logs (Crestron types; Android sets them up at first boot)"
else
	say "p6/p7/p8: donor data KEPT (--keep-base-data): this image carries another unit's Crestron config"
fi

# ---- 5. env
if [ -n "$UNITENV" ]; then
	$ENVPY merge "$UNITENV" "$W/env.bin" --guard $GUARD $DEFUSE >> "$LOG"; KIND="per-unit ($($ENVPY show "$UNITENV" ethaddr))"
else
	$ENVPY generic "$BASE" "$W/env.bin" --model $MODEL --guard $GUARD $DEFUSE >> "$LOG"; KIND="generic (no MAC/tsid; flash-card.sh merges the unit's own)"
fi
$ENVPY write "$W/env.bin" "$IMG.tmp" >> "$LOG"
cp "$W/env.bin" "$OUT/$NAME.env"
say "env: $KIND, hook $GUARD$( [ "$DEFUSE" = --defuse-golden ] && echo ", DataRecoveryDone=1")"

# ---- 6. manifest, compressed copy
mv "$IMG.tmp" "$IMG"
{
	echo "# mkcard.sh $(date -Iseconds) base=$(basename "$BASE") model=$MODEL env=${UNITENV:+per-unit}${UNITENV:-generic}"
	echo "card_bytes=$CARD_BYTES"
	echo "model=$MODEL"
	echo "region head 0 $((0x100000)) $(dd if="$IMG" bs=1M count=1 status=none | sha256sum | cut -d' ' -f1)"
	echo "region env $((0x100000)) $((0x10000)) $(sha256sum < "$W/env.bin" | cut -d' ' -f1)"
	for p in 1 2 5 6 7 8; do
		echo "region p$p $(off $p) $(len $p) $(dd if="$IMG" bs=1M iflag=skip_bytes,count_bytes skip=$(off $p) count=$(len $p) status=none | sha256sum | cut -d' ' -f1)"
	done
	echo "image_sha256=$(sha256sum < "$IMG" | cut -d' ' -f1)"
} > "$OUT/$NAME.manifest"
case "$COMP" in
gz) (command -v pigz >/dev/null && pigz -c -3 "$IMG" || gzip -c -3 "$IMG") > "$IMG.gz";;
xz) xz -T0 -3 -c "$IMG" > "$IMG.xz";;
zst) zstd -q -T0 -10 -c "$IMG" > "$IMG.zst";;
none) ;;
*) die "--compress gz|xz|zst|none";;
esac
say "done: $IMG ($(du -h "$IMG" | cut -f1) allocated of $((CARD_BYTES/1000000)) MB)$( [ "$COMP" != none ] && echo ", compressed $(du -h "$IMG.$COMP" | cut -f1)")"
say "manifest: $OUT/$NAME.manifest"
