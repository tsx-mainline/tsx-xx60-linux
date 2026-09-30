#!/bin/bash
# Host test of the SD-card method (sdcard/mkcard.sh, sdcard/flash-card.sh, sdcard/tsx-env.py).
# "The card of the unit" is the verified full backup of TSW-1060 A
# (captures/tsw-1060/backup, sha256 df33e741...). The test also uses the env
# of TSW-1060 B (the bench unit, from the env capture of the rootfs bring-up)
# and the TSW-760 card xx60-FACTORY.img.
# File targets run without root. The block-device path runs on a loop device
# in a privileged Alpine container. The test needs about 6 GB in $TMPDIR
# (default /var/tmp) and a few minutes.
set -uo pipefail
INSTALLER_DIR=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$INSTALLER_DIR/.." && pwd); CAPTURES=${CAPTURES_DIR:-}
SD=$INSTALLER_DIR/sdcard; ENVPY="python3 $SD/tsx-env.py"
BASE=$CAPTURES/tsw-1060/backup/tsw1060-mmcblk0.img
FACT=${FACT_IMG:-}   # optional: a real TSW-760 factory card image (xx60-FACTORY.img)
BOOTIMG=$ROOT/rootfs/out/tsxboot.img   # = mkcard.sh default (the current p1 image)
if [ -z "$CAPTURES" ] || [ ! -f "$BASE" ]; then
	echo "SKIPPED: needs a real unit's card backup (set CAPTURES_DIR to the captures/ tree). Not present here"
	exit 0
fi
W=${TMPDIR:-/var/tmp}/tsx-sdcard-test; rm -rf "$W"; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
t() { local m=$1; shift; if "$@" >/dev/null 2>&1; then ok "$m"; else bad "$m"; fi; }
nt() { local m=$1; shift; if "$@" >> "$W/refusals.log" 2>&1; then bad "$m (was accepted)"; else ok "$m"; fi; }
CARD=3980394496
off() { case $1 in p1) echo 41943040 41943040;; p2) echo 105906688 838860800;; p5) echo 945816064 1564475392;; p6) echo 2511340032 524288000;; p7) echo 3036676608 104857600;; p8) echo 3142582784 314572800;; env) echo 1048576 65536;; head) echo 0 1048576;; esac; }
rsum() { set -- "$1" $(off $2); dd if="$1" bs=4M iflag=skip_bytes,count_bytes skip=$2 count=$3 status=none | sha256sum | cut -d' ' -f1; }
fwp() { echo "$1 0x100000 0x10000" > "$W/fw.cfg"; shift; fw_printenv -l "$W" -c "$W/fw.cfg" "$@"; }
# U-Boot's view of a card: env CRC over 65532 bytes (common/env_common.c), MBR entry 1 = "mmc 0" FAT
# (fat_register_device(dev,1)), tsxboot.img there (fatexist), Android header + legacy uImage (bootm)
uboot_view() {
	python3 - "$1" <<'PY'
import struct, sys, zlib, subprocess, os
img = sys.argv[1]; f = open(img, 'rb')
f.seek(0x100000); b = f.read(0x10000)
assert zlib.crc32(b[4:]) & 0xffffffff == struct.unpack('<I', b[:4])[0], 'env CRC'
f.seek(0); mbr = f.read(512); st, ln = struct.unpack_from('<II', mbr, 446 + 8)
assert mbr[446 + 4] != 0 and st == 81920, 'MBR entry 1'
env = dict(x.split('=', 1) for x in b[4:].split(b'\0\0')[0].decode('latin1').split('\0') if '=' in x)
assert 'run tsx_boot' in env['switch_bootmode'] and env['tsx_boot'].startswith('mmcinfo;')
out = subprocess.run(['mcopy', '-n', '-i', '%s@@%d' % (img, st * 512), '::tsxboot.img', '/dev/stdout'],
                     capture_output=True, env=dict(os.environ, MTOOLS_SKIP_CHECK='1')).stdout
assert out[:8] == b'ANDROID!', 'tsxboot.img header'
ps = struct.unpack_from('<I', out, 36)[0]
assert out[ps:ps + 4] == bytes.fromhex('27051956'), 'legacy uImage at +page'
print('uboot view ok: env CRC, MBR p1 FAT, tsxboot.img (%d bytes) bootm-able, boot_retry=%s' % (len(out), env['boot_retry']))
PY
}
# the env entries as raw byte strings, in order
entries() { python3 -c "
import sys
b=open(sys.argv[1],'rb').read(); o=0 if len(b)==65536 else 0x100000
d=b[o+4:o+65536]; print('\n'.join(x.decode('latin1') for x in d.split(b'\0\0')[0].split(b'\0')))" "$1"; }
# byte ranges where two card images differ (MiB granularity), as region names
diffregions() {
	python3 - "$1" "$2" <<'PY'
import sys
R = [('head', 0, 1048576), ('env', 1048576, 65536), ('p1', 41943040, 41943040), ('p2', 105906688, 838860800),
     ('p5', 945816064, 1564475392), ('p6', 2511340032, 524288000), ('p7', 3036676608, 104857600),
     ('p8', 3142582784, 314572800)]
a, b = open(sys.argv[1], 'rb'), open(sys.argv[2], 'rb'); seen = set(); pos = 0; C = 1 << 20
while True:
    x, y = a.read(C), b.read(C)
    if not x and not y: break
    if x != y:
        # sub-chunk resolution: 64 KiB
        for k in range(0, max(len(x), len(y)), 65536):
            if x[k:k + 65536] != y[k:k + 65536]:
                for q in range(k, k + 65536, 512):     # sector resolution (p5 starts at an odd sector)
                    if x[q:q + 512] == y[q:q + 512]: continue
                    p = pos + q; name = 'gap@%d' % p
                    for n, o, l in R:
                        if o <= p < o + l: name = n
                    seen.add(name)
    pos += C
print(' '.join(sorted(seen)) or 'none')
PY
}

echo "== 1. mkcard: generic TSW-1060 image from the backup of unit A"
"$SD/mkcard.sh" --out "$W/out" --base "$BASE" --compress gz > "$W/mk1.txt" 2>&1 || { cat "$W/mk1.txt"; exit 1; }
I=$W/out/card-tsw1060.img
t "image is exactly $CARD bytes" test "$(stat -c %s "$I")" = $CARD
t "first MiB (MBR + U-Boot copy) = donor" test "$(rsum "$I" head)" = "$(rsum "$BASE" head)"
t "p2 (golden /system) = donor" test "$(rsum "$I" p2)" = "$(rsum "$BASE" p2)"
t "env CRC valid (u-boot-tools fw_printenv, independent code)" fwp "$I" boot_retry
t "generic env: no ethaddr, tsid FFFFFFFF, hook fallback, boot_retry 0" bash -c "! fw_printenv -l $W -c $W/fw.cfg ethaddr && [ \"\$(fw_printenv -l $W -c $W/fw.cfg -n tsid)\" = FFFFFFFF ] && fw_printenv -l $W -c $W/fw.cfg -n switch_bootmode | grep -q 'lt 6; then run tsx_boot' && [ \"\$(fw_printenv -l $W -c $W/fw.cfg -n boot_retry)\" = 0 ]"
t "generic env: DataRecoveryDone=1 by default" test "$(fw_printenv -l $W -c $W/fw.cfg -n DataRecoveryDone)" = 1
uboot_view "$I" && ok "U-Boot view of the image" || bad "U-Boot view of the image"
export MTOOLS_SKIP_CHECK=1
t "p1: golden boot.img unchanged" cmp -s <(mcopy -n -i "$I@@41943040" ::boot.img -) <(mcopy -n -i "$BASE@@41943040" ::boot.img -)
t "p1: tsxboot.img = $(basename "$BOOTIMG")" cmp -s <(mcopy -n -i "$I@@41943040" ::tsxboot.img -) "$BOOTIMG"
dd if="$I" bs=4M iflag=skip_bytes,count_bytes skip=945816064 count=1564475392 of="$W/p5.ext4" status=none
t "p5: e2fsck -fn clean" e2fsck -fn "$W/p5.ext4"
t "p5: features within kernel 3.10 (no csum_seed, no metadata_csum)" python3 -c "
import struct; d=open('$W/p5.ext4','rb').read(2048)[1024:]; c,i,r=struct.unpack_from('<III',d,0x5C); assert i & 0x2000 == 0 and i & ~0x83d6 == 0 and r & 0x400 == 0, (hex(i), hex(r))"
t "p5: /etc/fstab has /dev/mmcblk0p1 /media/bootfat, owned by root" bash -c "debugfs -R 'cat /etc/fstab' $W/p5.ext4 2>/dev/null | grep -q '^/dev/mmcblk0p1  /media/bootfat' && debugfs -R 'stat /etc/fstab' $W/p5.ext4 2>/dev/null | grep -q 'User:     0'"
t "p5: install.info" bash -c "debugfs -R 'cat /var/lib/tsx/install.info' $W/p5.ext4 2>/dev/null | grep -q '^model=tsw1060'"
rm -f "$W/p5.ext4"
for p in 6:data:ext2 7:cache:ext2 8:logs:ext4; do n=${p%%:*}; l=$(echo $p | cut -d: -f2); ty=${p##*:}; set -- $(off p$n)
	t "p$n: fresh $ty '$l', e2fsck clean, no donor data" bash -c "blkid -p -O $1 $I | grep -q 'LABEL=\"$l\".*TYPE=\"$ty\"' && e2fsck -fn '$I?offset=$1' >/dev/null 2>&1"
done
t "gz form decompresses to the same image" test "$(gzip -dc "$I.gz" | sha256sum | cut -d' ' -f1)" = "$(sed -n 's/^image_sha256=//p' "$W/out/card-tsw1060.manifest")"
echo "     sizes: raw $(du -h "$I" | cut -f1) allocated, gz $(du -h "$I.gz" | cut -f1)"

echo "== 2. flash-card update on unit A's card (a file copy of the backup)"
cp --sparse=always "$BASE" "$W/cardA.img"
"$SD/flash-card.sh" --image "$I.gz" --device "$W/cardA.img" --backup-dir "$W/bk" --yes > "$W/fl1.txt" 2>&1 || { cat "$W/fl1.txt"; bad "flash update"; }
BK=$(ls "$W"/bk/card-backup-*.img | head -1)
t "card backup = the original card (sha256 df33e741...)" test "$(sha256sum < "$BK" | cut -d' ' -f1)" = "$(sha256sum < "$BASE" | cut -d' ' -f1)"
D=$(diffregions "$BASE" "$W/cardA.img"); echo "     changed regions: $D"
t "only p1, p5 and the env block changed (MBR, U-Boot copy, p2, p6, p7, p8, gaps untouched)" test "$D" = "env p1 p5"
entries "$BASE" > "$W/e0"; entries "$W/cardA.img" > "$W/e1"
grep -v -e '^switch_bootmode=' -e '^boot_retry=' -e '^golden_boot_retry=' -e '^DataRecoveryDone=' "$W/e0" > "$W/e0u"
grep -v -e '^switch_bootmode=' -e '^boot_retry=' -e '^golden_boot_retry=' -e '^DataRecoveryDone=' -e '^tsx_boot=' "$W/e1" > "$W/e1u"
t "env: the $(wc -l < "$W/e0u") untouched variables byte-identical and in the same order" cmp -s "$W/e0u" "$W/e1u"
t "env: exactly 88 untouched variables (92 - switch_bootmode, boot_retry, golden_boot_retry, DataRecoveryDone)" test "$(wc -l < "$W/e0u")" = 88
t "env: DataRecoveryDone 0 -> 1" bash -c "grep -qx DataRecoveryDone=0 $W/e0 && grep -qx DataRecoveryDone=1 $W/e1"
t "env: per-unit values kept (ethaddr, tsid unchanged)" bash -c "grep -qxF \"\$(grep '^ethaddr=' $W/e0)\" $W/e1 && grep -qxF \"\$(grep '^tsid=' $W/e0)\" $W/e1"
t "env: tsx_boot appended last, switch_bootmode = fallback hook" bash -c "tail -1 $W/e1 | grep -q '^tsx_boot=mmcinfo;' && grep -q '^switch_bootmode=.*-lt 6; then run tsx_boot; fi\$' $W/e1"
t "env CRC valid (fw_printenv)" fwp "$W/cardA.img" tsx_boot
uboot_view "$W/cardA.img" && ok "U-Boot view of the flashed card" || bad "U-Boot view of the flashed card"
t "p1: golden boot.img unchanged, tsxboot.img added, tsxenv.bak = the old env" bash -c "cmp -s <(mcopy -n -i $W/cardA.img@@41943040 ::boot.img -) <(mcopy -n -i $BASE@@41943040 ::boot.img -) && cmp -s <(mcopy -n -i $W/cardA.img@@41943040 ::tsxboot.img -) $BOOTIMG && cmp -s <(mcopy -n -i $W/cardA.img@@41943040 ::tsxenv.bak -) <(dd if=$BASE bs=64K skip=16 count=1 status=none)"
t "p1: the card's Android files kept" bash -c "mdir -b -i $W/cardA.img@@41943040 :: | grep -q Android"
t "p5 = the image's p5" test "$(rsum "$W/cardA.img" p5)" = "$(rsum "$I" p5)"

echo "== 3. second flash (idempotent) and restore"
"$SD/flash-card.sh" --image "$I" --device "$W/cardA.img" --backup-dir "$W/bk2" --yes > "$W/fl2.txt" 2>&1
t "second flash: hook state 'fallback' recognized, env unchanged" bash -c "grep -q 'hook fallback' $W/fl2.txt && cmp -s <(dd if=$W/cardA.img bs=64K skip=16 count=1 status=none) <(dd if=$(ls $W/bk2/card-backup-*.img | head -1) bs=64K skip=16 count=1 status=none)"
"$SD/flash-card.sh" --restore "$BK" --device "$W/cardA.img" --yes > "$W/rs.txt" 2>&1
t "--restore: card byte-identical to the original" test "$(sha256sum < "$W/cardA.img" | cut -d' ' -f1)" = "$(sha256sum < "$BASE" | cut -d' ' -f1)"
rm -rf "$W/bk2"

echo "== 4. full mode"
truncate -s $CARD "$W/blank.img"
nt "blank card without a unit env refused (MAC etc. would be lost)" "$SD/flash-card.sh" --image "$I" --device "$W/blank.img" --backup-dir "$W/bk3" --yes
ENVB_SRC=${ENVB_CAPTURE:-}
if [ -n "$ENVB_SRC" ] && [ -f "$ENVB_SRC" ]; then
	dd if="$ENVB_SRC" bs=64K skip=16 count=1 of="$W/envB.bin" status=none
else
	echo "SKIP: unit-B env capture not found (set ENVB_CAPTURE=/path/to/mmcblk0-head2M.img). Using the donor's own env instead" >&2
	dd if="$BASE" bs=64K skip=16 count=1 of="$W/envB.bin" status=none
fi
"$SD/flash-card.sh" --image "$I" --device "$W/blank.img" --backup-dir "$W/bk3" --unit-env "$W/envB.bin" --yes > "$W/fl3.txt" 2>&1 || { cat "$W/fl3.txt"; bad "full flash"; }
t "blank card + unit B's env: whole image written (MBR, p1, p2, p5, p6-p8 = image)" bash -c "for r in head p1 p2 p5 p6 p7 p8; do [ \"\$($(declare -f off rsum); rsum $W/blank.img \$r)\" = \"\$($(declare -f off rsum); rsum $I \$r)\" ] || exit 1; done"
entries "$W/envB.bin" | grep -v -e '^switch_bootmode=' -e '^boot_retry=' -e '^golden_boot_retry=' -e '^DataRecoveryDone=' > "$W/b0"
entries "$W/blank.img" | grep -v -e '^switch_bootmode=' -e '^boot_retry=' -e '^golden_boot_retry=' -e '^DataRecoveryDone=' -e '^tsx_boot=' > "$W/b1"
t "unit B env merged: its $(wc -l < "$W/b0") other variables byte-identical (ethaddr kept)" bash -c "cmp -s $W/b0 $W/b1 && grep -qxF \"\$(grep '^ethaddr=' $W/b0)\" $W/b1"
uboot_view "$W/blank.img" && ok "U-Boot view of the blank-card flash" || bad "U-Boot view of the blank-card flash"
rm -f "$W/blank.img"; rm -rf "$W/bk3"
cp --sparse=always "$BASE" "$W/cardA.img"
"$SD/flash-card.sh" --image "$I" --device "$W/cardA.img" --mode full --keep-data --backup-dir "$W/bk4" --yes > "$W/fl4.txt" 2>&1 || { cat "$W/fl4.txt"; bad "full --keep-data"; }
D=$(diffregions "$BASE" "$W/cardA.img"); echo "     changed regions: $D"
t "full --keep-data on a Crestron card: head, p6, p7, p8 untouched" bash -c "echo '$D' | grep -qv -e head -e p6 -e p7 -e p8 && ! echo '$D' | grep -q -e head -e p6 -e p7 -e p8"
t "full --keep-data: env = unit A's own + hook" bash -c "fw_printenv -l $W -c <(echo $W/cardA.img 0x100000 0x10000) -n ethaddr 2>/dev/null | grep -q b8:30 || { echo $W/cardA.img 0x100000 0x10000 > $W/fw.cfg; fw_printenv -l $W -c $W/fw.cfg -n ethaddr | grep -q b8:30; }"
rm -rf "$W/bk4"

echo "== 5. refusals"
truncate -s $((CARD - 512*1024*1024)) "$W/small.img"
nt "smaller card refused" "$SD/flash-card.sh" --image "$I" --device "$W/small.img" --backup-dir "$W/bk5" --yes
truncate -s $((CARD + 4*1024*1024*1024)) "$W/big.img"
t "larger card accepted (dry run: backup + plan, nothing written)" "$SD/flash-card.sh" --image "$I" --device "$W/big.img" --backup-dir "$W/bk5" --mode full --generic-env --dry-run --yes
rm -rf "$W/bk5"
rm -f "$W/small.img" "$W/big.img"
cp --sparse=always "$I" "$W/corrupt.img"; cp "$W/out/card-tsw1060.manifest" "$W/corrupt.manifest"
printf 'X' | dd of="$W/corrupt.img" bs=1 seek=$((945816064 + 5000000)) conv=notrunc status=none
nt "image not matching its manifest refused" "$SD/flash-card.sh" --image "$W/corrupt.img" --device "$W/cardA.img" --backup-dir "$W/bk5" --yes
rm -f "$W/corrupt.img"
cp --sparse=always "$I" "$W/csumseed.img"      # no manifest next to it: only the ext4-feature check can stop it
python3 -c "
import struct; f=open('$W/csumseed.img','r+b'); o=945816064+1024+0x60; f.seek(o); i=struct.unpack('<I',f.read(4))[0]; f.seek(o); f.write(struct.pack('<I',i|0x2000))"
t "image whose p5 has metadata_csum_seed refused (Android 3.10 cannot mount it)" bash -c "! '$SD/flash-card.sh' --image '$W/csumseed.img' --device '$W/cardA.img' --backup-dir '$W/bk5' --yes > '$W/csumseed-err.txt' 2>&1 && grep -q 'cannot mount' '$W/csumseed-err.txt'"
rm -f "$W/csumseed.img"
python3 "$SD/tsx-env.py" merge "$W/envB.bin" "$W/x.bin" --set 'switch_bootmode=usb start 0;run evil' --force > /dev/null 2>&1 || true
nt "tsx-env.py refuses to merge an env with a foreign switch_bootmode" python3 "$SD/tsx-env.py" merge "$W/x.bin" "$W/y.bin"
printf 'garbage' > "$W/g.bin"; truncate -s 65536 "$W/g.bin"
nt "tsx-env.py write refuses a block with a bad CRC" python3 "$SD/tsx-env.py" write "$W/g.bin" "$W/cardA.img"

echo "== 6. TSW-760: image from the TSW-760 card (xx60-FACTORY.img), flashed onto that card"
if [ -r "$FACT" ]; then
	# no TSW-760 boot image exists : the TSW-1060 image stands in for the plumbing
	"$SD/mkcard.sh" --out "$W/out760" --base "$FACT" --model tsw760 --bootimg "$BOOTIMG" --compress none > "$W/mk2.txt" 2>&1 || { cat "$W/mk2.txt"; bad mkcard760; }
	I7=$W/out760/card-tsw760.img
	t "tsw760 generic env: lcdsize 7inch, aml_dt yushan_one_7inch, 1024x600" bash -c "echo $I7 0x100000 0x10000 > $W/fw.cfg; [ \"\$(fw_printenv -l $W -c $W/fw.cfg -n lcdsize)\" = 7inch ] && [ \"\$(fw_printenv -l $W -c $W/fw.cfg -n aml_dt)\" = yushan_one_7inch ] && [ \"\$(fw_printenv -l $W -c $W/fw.cfg -n fb_width)\" = 1024 ]"
	cp --sparse=always "$FACT" "$W/card760.img"
	nt "TSW-1060 image refused on the TSW-760 card (model check)" "$SD/flash-card.sh" --image "$I" --device "$W/card760.img" --backup-dir "$W/bk6" --yes
	"$SD/flash-card.sh" --image "$I7" --device "$W/card760.img" --backup-dir "$W/bk6" --yes > "$W/fl6.txt" 2>&1 || { cat "$W/fl6.txt"; bad "flash 760"; }
	t "TSW-760 card flashed: its env (ethaddr ..:bd:13:cd, TSW-760 product) kept + hook" bash -c "echo $W/card760.img 0x100000 0x10000 > $W/fw.cfg; fw_printenv -l $W -c $W/fw.cfg -n ethaddr | grep -q bd:13:cd && fw_printenv -l $W -c $W/fw.cfg -n product_name | grep -q TSW-760 && fw_printenv -l $W -c $W/fw.cfg -n tsx_boot >/dev/null"
	uboot_view "$W/card760.img" && ok "U-Boot view of the TSW-760 card" || bad "U-Boot view of the TSW-760 card"
	rm -rf "$W/card760.img" "$W/bk6" "$W/out760"
else echo "  (skipped: FACT_IMG not set or not readable)"; fi

echo "== 7. block device: loop device in a privileged container"
cp --sparse=always "$BASE" "$W/loopcard.img"; truncate -s $((CARD - 1048576)) "$W/loopsmall.img"
docker run --rm --privileged --platform linux/amd64 -v "$INSTALLER_DIR:/installer:ro" -v "$W:/w" -v "$I:/img/card.img:ro" -v "$W/out/card-tsw1060.manifest:/img/card.manifest:ro" alpine:3.24 sh -c '
apk add -q --no-cache bash python3 mtools coreutils util-linux losetup lsblk gzip >/dev/null 2>&1
for i in $(seq 0 31); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
L=$(losetup -f --show /w/loopcard.img); S=$(losetup -f --show /w/loopsmall.img)
/installer/sdcard/flash-card.sh --image /img/card.img --device $S --backup-dir /w/bkl --yes >/w/lsmall.txt 2>&1 && echo "SMALL ACCEPTED" || echo "small refused"
/installer/sdcard/flash-card.sh --image /img/card.img --device $L --backup-dir /w/bkl --yes --force-device >/w/l.txt 2>&1 && echo "loop flashed" || { echo "loop FAILED"; tail -5 /w/l.txt; }
losetup -d $L $S; chown -R '"$(id -u):$(id -g)"' /w' > "$W/docker.txt" 2>&1
cat "$W/docker.txt" | sed 's/^/     /'
t "loop device: smaller card refused" grep -q "small refused" "$W/docker.txt"
t "loop device: update flash + verify ok" grep -q "loop flashed" "$W/docker.txt"
t "loop device result: only p1, p5, env changed" test "$(diffregions "$BASE" "$W/loopcard.img")" = "env p1 p5"
uboot_view "$W/loopcard.img" && ok "U-Boot view of the loop-device card" || bad "U-Boot view of the loop-device card"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo "PASS test-sdcard" || echo "FAIL test-sdcard"
exit $F
