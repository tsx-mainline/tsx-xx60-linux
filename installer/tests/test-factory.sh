#!/bin/bash
# Host test of the factory restore from the Crestron firmware package:
# factory/puf-tool.sh (host) + factory/tsx-factory-restore (rescue system).
# Inputs (read only): tsw-xx60_3.002.1061.001.puf, unit A's factory-state card
# (captures/tsw-1060/backup, fw 3.002.1061 = the .puf's version) as the reference,
# unit B's card (captures/tsw-1060-unitB/backup) as the card to restore, after a
# simulated card-stage conversion. The panel tool runs in a privileged Alpine 3.24
# container on a loop device (the rescue's tool set). ~10 GB in $TMPDIR.
set -uo pipefail
INSTALLER_DIR=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$INSTALLER_DIR/.." && pwd); CAPTURES=${CAPTURES_DIR:-}
PUF=${PUF_FILE:-}
A=$CAPTURES/tsw-1060/backup/tsw1060-mmcblk0.img
BU=$CAPTURES/tsw-1060-unitB/backup/tsw1060B-mmcblk0-20260926.img
T=$INSTALLER_DIR/factory/puf-tool.sh
if [ -z "$CAPTURES" ] || [ ! -f "$A" ] || [ ! -f "$BU" ] || [ ! -f "$PUF" ]; then
	echo "SKIPPED: needs the Crestron .puf (PUF_FILE) and real unit captures (CAPTURES_DIR); not present here"
	exit 0
fi
W=${TMPDIR:-/var/tmp}/tsx-factory-test; rm -rf "$W"; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
N=0 F=0; ok() { echo "  ok: $*"; N=$((N+1)); }; bad() { echo "  FAIL: $*"; F=$((F+1)); }
export MTOOLS_SKIP_CHECK=1
sb() {   # sb IMG SECTOR: ext2/3/4 superblock parameters (as in factory/crestron-fs.sh)
	python3 - "$1" "$2" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb'); f.seek(int(sys.argv[2]) * 512 + 1024); d = f.read(1024)
ic, bc = struct.unpack_from('<II', d, 0); lbs = struct.unpack_from('<I', d, 0x18)[0]
comp, inc, ro = struct.unpack_from('<III', d, 0x5C); isz = struct.unpack_from('<H', d, 0x58)[0]
print(ic, bc, 1024 << lbs, isz, hex(comp), hex(inc & ~0x4), hex(ro), struct.unpack_from('<I', d, 8)[0], d[0x78:0x88].rstrip(b'\0').decode())
PY
}

echo "== 1. extract + verify the .puf (Crestron's own cksum/.hash and NUMBER_OF_FILES checks)"
"$T" extract "$PUF" "$W/x" > "$W/x.log" 2>&1 && ok "extract: all .hash cksums and NUMBER_OF_FILES=5 match" || { cat "$W/x.log"; bad extract; }
grep -E '^(firmware_version|uboot_version|zip_entry system)' "$W/x/puf.info" | sed 's/^/    /'
cp -r "$W/x/img" "$W/bad"; printf X | dd of="$W/bad/u-boot.bin" bs=1 seek=1000 conv=notrunc status=none
mkdir -p "$W/badd"; mv "$W/bad" "$W/badd/img"
"$T" bundle "$W/badd" --env "$BU" --out "$W/nb" > "$W/nb.log" 2>&1 && bad "corrupted u-boot.bin accepted" || { grep -q "cksum" "$W/nb.log" && ok "a corrupted file in the image is refused (cksum)"; }
rm -rf "$W/badd" "$W/nb"
cmp -s "$W/x/img/boot-golden.img" <(mcopy -n -i "$A@@41943040" ::boot.img -) && ok "boot-golden.img = unit A's p1:boot.img (fw 3.002.1061)"
cmp -s <(head -c 442 "$W/x/img/u-boot.bin") <(head -c 442 "$A") && ok "u-boot.bin bytes 0..441 = unit A's MBR boot code"
D=$(python3 - "$A" "$W/x/img/system.img" <<'PY'
import sys
a = open(sys.argv[1], 'rb'); a.seek(206849 * 512); b = open(sys.argv[2], 'rb'); n = t = 0
while True:
    x = b.read(4096)
    if not x: break
    t += 1; n += x != a.read(len(x))
print(n, t)
PY
); echo "     system.img vs unit A's p2: $D 4-KiB blocks differ/total"
[ "${D%% *}" -lt 100 ] && ok "system.img = unit A's golden p2 except $(echo $D | cut -d' ' -f1) blocks (superblocks/journal after golden mounts)"

echo "== 2. bundle for unit B (env from unit B's own card backup)"
"$T" bundle "$W/x" --env "$BU" --out "$W/b" > "$W/b.log" 2>&1 && ok "bundle made" || { cat "$W/b.log"; bad bundle; }
UNITB_EXPECT=$(python3 "$INSTALLER_DIR/sdcard/tsx-env.py" show "$BU" ethaddr | sed -n 's/^ethaddr=//p' | tr -d ':' | tr 'A-F' 'a-f')
grep -qx "unit=$UNITB_EXPECT" "$W/b/factory.manifest" && ok "bundle unit = unit B's own ethaddr ($UNITB_EXPECT)"
python3 "$INSTALLER_DIR/sdcard/tsx-env.py" show "$W/b/env.bin" switch_bootmode tsx_boot boot_retry > "$W/e.txt"
grep -q '^switch_bootmode=usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;$' "$W/e.txt" && grep -q '## tsx_boot not set' "$W/e.txt" && ok "env.bin: stock switch_bootmode, tsx_boot removed, identity kept"
python3 "$INSTALLER_DIR/sdcard/tsx-env.py" generic "$A" "$W/noid.bin" --model tsw1060 > /dev/null
"$T" bundle "$W/x" --env "$W/noid.bin" --out "$W/nb" > "$W/nb.log" 2>&1 && bad "env without identity accepted" || { grep -q "identity missing" "$W/nb.log" && ok "an env without ethaddr is refused (identity is not in the .puf)"; }
rm -rf "$W/nb"

echo "== 3. card image from the .puf alone vs unit A's factory card"
"$T" card "$W/b" --out "$W/card.img" > "$W/c.log" 2>&1 && ok "card image built" || { cat "$W/c.log"; bad card; }
ptab() { sfdisk -d "$1" 2>/dev/null | grep -E '^(label-id|/)' | sed 's/^[^:]*: //'; }
cmp -s <(ptab "$W/card.img") <(ptab "$A") && ok "partition table (starts, sizes, types, EBR chain) + disk id 0x0dc9276f = unit A's"
cmp -s <(mcopy -n -i "$W/card.img@@41943040" ::boot.img -) "$W/x/img/boot-golden.img" && ok "p1: FAT16 with boot.img = golden"
bsg() { dd if="$1" bs=512 skip=81920 count=1 status=none | python3 -c "import sys; d=sys.stdin.buffer.read(); print(d[11:43].hex(), d[54:62])"; }
[ "$(bsg "$W/card.img")" = "$(bsg "$A")" ] && ok "p1 boot sector: geometry, FAT layout and volume id 1D14-2256 as on the factory card"
for s in 1847297 4904961 5931009 6137857; do
	x=$(sb "$W/card.img" $s); y=$(sb "$A" $s)
	[ "$x" = "$y" ] && ok "fs at sector $s = factory parameters ($x)" || bad "fs at $s: $x != $y"
done
t=0; for s in 1847297 4904961 5931009 6137857; do dd if="$W/card.img" of="$W/fs.img" bs=512 skip=$s count=$((s == 1847297 ? 3055616 : s == 4904961 ? 1024000 : s == 5931009 ? 204800 : 614400)) status=none; e2fsck -fn "$W/fs.img" >/dev/null 2>&1 && t=$((t+1)); done; rm -f "$W/fs.img"
[ $t = 4 ] && ok "p5..p8 e2fsck clean"
cmp -s <(dd if="$W/card.img" bs=65536 skip=16 count=1 status=none) "$W/b/env.bin" && ok "env block = bundle env.bin"

echo "== 4. panel tool (rescue) on unit B's card after a simulated card-stage conversion"
cp --sparse=always "$BU" "$W/unitB.img"
printf '\203' | dd of="$W/unitB.img" bs=1 seek=498 conv=notrunc status=none                 # card-stage MBR byte
[ -f "$INSTALLER_DIR/out/rootfs-p2.ext4" ] && dd if="$INSTALLER_DIR/out/rootfs-p2.ext4" of="$W/unitB.img" bs=512 seek=206849 conv=notrunc status=none
HEAD0=$(dd if="$W/unitB.img" bs=512 count=2048 status=none | python3 -c "import sys,hashlib; d=bytearray(sys.stdin.buffer.read()); d[440:512]=b'\0'*72; print(hashlib.sha256(d).hexdigest())")
"$T" bundle "$W/x" --env "$A" --out "$W/bA" > /dev/null 2>&1
docker run --rm --privileged --platform linux/amd64 -v "$INSTALLER_DIR:/installer:ro" -v "$W:/w" alpine:3.24 sh -c '
apk add -q --no-cache e2fsprogs dosfstools sfdisk blkid losetup u-boot-tools util-linux-misc >/dev/null 2>&1
for i in $(seq 0 63); do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
L=$(losetup -P -f --show /w/unitB.img); n=${L#/dev/}; trap "losetup -d $L" EXIT; sleep 1
for p in /sys/block/$n/${n}p*; do b=${p##*/}; [ -b /dev/$b ] || mknod /dev/$b b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev); done
export TSX_SHARE=/installer/android TSX_SYSBLOCK=/sys/block/$n TSX_DEVDIR=/dev TSX_RUN=/run/t
FR="sh /installer/factory/tsx-factory-restore"
ok() { echo "  ok: $*"; }; fail() { echo "  FAIL: $*"; }
ls /sys/block/$n | grep -c "${n}p" | grep -qx 4 && mkfs.ext4 -q -F -L tsxdata /dev/${n}p4 && ok "simulated card-stage card: 4 partitions, p4 = tsxdata, p2 = kiosk rootfs"
$FR check /w/b > /tmp/c 2>&1 && grep -q "layout now card" /tmp/c && ok "check: card-stage layout recognised, bundle verified, nothing written"
$FR run /w/bA --yes > /tmp/r 2>&1 && fail "env of unit A accepted on unit B" || { grep -q "wrong unit" /tmp/r && ok "bundle of another unit refused"; }
mkdir -p /mnt/x; mount /dev/${n}p2 /mnt/x; $FR run /w/b --yes > /tmp/r 2>&1 && fail "ran with p2 mounted" || { grep -q "is mounted" /tmp/r && ok "refused while a card partition is mounted"; }; umount /mnt/x
cp -r /w/b /tmp/bb; printf X | dd of=/tmp/bb/system.img bs=1 seek=4096000 conv=notrunc 2>/dev/null
$FR run /tmp/bb --yes > /tmp/r 2>&1 && fail "corrupt bundle accepted" || { grep -q "do not match" /tmp/r && ok "corrupt bundle refused"; }; rm -rf /tmp/bb
$FR run /w/b --yes > /tmp/r 2>&1 && ok "factory restore ran" || { cat /tmp/r; fail "restore"; }
sed "s/^/    /" /tmp/r
losetup -d $L; trap - EXIT; chown '"$(id -u):$(id -g)"' /w/unitB.img' 2>&1 | tee "$W/docker.txt"
N=$((N + $(grep -c "  ok: " "$W/docker.txt"))); F=$((F + $(grep -c "  FAIL" "$W/docker.txt")))

echo "== 5. unit B's card after the restore"
cmp -s <(ptab "$W/unitB.img") <(ptab "$A") && ok "partition table = the Crestron layout (p1..p8, as on unit A)"
H1=$(dd if="$W/unitB.img" bs=512 count=2048 status=none | python3 -c "import sys,hashlib; d=bytearray(sys.stdin.buffer.read()); d[440:512]=b'\0'*72; print(hashlib.sha256(d).hexdigest())")
[ "$H1" = "$HEAD0" ] && ok "first MiB unchanged except the partition table (boot code, U-Boot copy never written)"
cmp -s <(dd if="$W/unitB.img" bs=512 skip=206849 count=$((652414976/512)) status=none) "$W/x/img/system.img" && ok "p2 = system.img"
cmp -s <(mcopy -n -i "$W/unitB.img@@41943040" ::boot.img -) "$W/x/img/boot-golden.img" && [ "$(mdir -b -i "$W/unitB.img@@41943040" :: | wc -l)" = 1 ] && ok "p1 = only the golden boot.img (kiosk and rescue removed)"
t=0; for s in 1847297 4904961 5931009 6137857; do [ "$(sb "$W/unitB.img" $s)" = "$(sb "$A" $s)" ] && t=$((t+1)); done
[ $t = 4 ] && ok "p5..p8 = factory file systems (parameters as on unit A)"
cmp -s <(dd if="$W/unitB.img" bs=65536 skip=16 count=1 status=none) "$W/b/env.bin" && python3 "$INSTALLER_DIR/sdcard/tsx-env.py" show "$W/unitB.img" ethaddr | grep -qF "$(python3 "$INSTALLER_DIR/sdcard/tsx-env.py" show "$BU" ethaddr)" && ok "env = unit B's own env without the hook (ethaddr kept)"
echo "== $N ok, $F failed"; [ $F = 0 ] && [ $N = 30 ] && echo PASS test-factory || { echo "FAIL test-factory (expected 30 ok)"; exit 1; }
