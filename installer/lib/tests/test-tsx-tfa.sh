#!/bin/bash
# Host test of installer/lib/tsx-tfa.sh: the TFA9890 DSP files taken from the
# panel itself (tsx-rescue-install tfa). Synthetic files only: made-up NXP
# containers ("PM" id, size, CRC32; random payload) and made-up Android boot
# images; no vendor data. The pinned-sha256 path uses TSX_TFA_PINS with the
# synthetic hashes. Runs every case twice: with the host's tools and with
# busybox applets only (awk, cpio, gzip, od, ... as in the rescue).
# Needs: python3, cpio, gzip, busybox.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # installer/lib
LIB=$HERE/tsx-tfa.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
VARIANTS="settings_yushan settings_yushan_2nd settings_yushan_3rd"

mkcnt() {   # mkcnt OUT SEED [SIZE]: a valid synthetic NXP container
	python3 - "$1" "$2" "${3:-12477}" <<'PY'
import random, struct, sys, zlib
out, seed, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = random.Random(seed)
body = b"CrestronSynth\0\0\0" + bytes(r.randrange(256) for _ in range(size - 14 - 16))
tail = body
hdr = b"PM1_00" + struct.pack("<I", size)
crc = zlib.crc32(tail) & 0xffffffff
open(out, "wb").write(hdr + struct.pack("<I", crc) + tail)
PY
}
mkset() {   # mkset DIR SEED0 [variants...]: DIR/<variant>/stereo.cnt
	local d=$1 s=$2 v; shift 2
	[ $# -gt 0 ] || set -- $VARIANTS
	for v in "$@"; do mkdir -p "$d/$v"; mkcnt "$d/$v/stereo.cnt" $((s + ${#v})); done
}
mkboot() {  # mkboot OUT RAMDISK_DIR [PAGE]: Android v0 boot image, gzip newc ramdisk
	(cd "$2" && find . -mindepth 1 | sed 's#^\./##' | sort | cpio -o -H newc --quiet | gzip -9n) > "$W/rd.gz"
	python3 - "$1" "$W/rd.gz" "${3:-2048}" <<'PY'
import struct, sys
out, rdf, ps = sys.argv[1], sys.argv[2], int(sys.argv[3])
rd = open(rdf, "rb").read()
kernel = b"\x11" * 70001
second = b"\x22" * 5000
pad = lambda b: b + b"\0" * ((-len(b)) % ps)
hdr = struct.pack("<8s10I16s512s32s", b"ANDROID!", len(kernel), 0x10008000, len(rd), 0x11000000,
                  len(second), 0x10f00000, 0x10000100, ps, 0, 0, b"", b"", b"")
open(out, "wb").write(pad(hdr) + pad(kernel) + pad(rd) + pad(second) + b"\0" * 4096)
PY
}
sha() { sha256sum < "$1" | cut -d' ' -f1; }

# fixtures: a "stock" set, a second (different) set, a ramdisk with it, a
# mainline-like ramdisk without jabil/, and a non-Android region
mkset "$W/stock" 100
mkset "$W/other" 500
: > "$W/pins"; for v in $VARIANTS; do echo "$v $(sha "$W/stock/$v/stereo.cnt")" >> "$W/pins"; done
mkdir -p "$W/rd-android/jabil/tfa9890" "$W/rd-android/sbin" "$W/rd-mainline/usr/sbin"
cp -r "$W/stock"/settings_* "$W/rd-android/jabil/tfa9890/"
for v in $VARIANTS; do echo "[ini]" > "$W/rd-android/jabil/tfa9890/$v/stereo.ini"; done
printf 'VERSION:Synth.Board_00_00_03\nTAG NAME:SYNTH\nBUILD TIME:Tue Jun  4 16:48:37 EDT 2024\n' > "$W/rd-android/jabil/yushan_version.txt"
echo init > "$W/rd-android/init"; echo x > "$W/rd-mainline/init"; echo y > "$W/rd-mainline/usr/sbin/tsx"
mkboot "$W/boot-android.img" "$W/rd-android"
mkboot "$W/boot-android4k.img" "$W/rd-android" 4096
mkboot "$W/boot-mainline.img" "$W/rd-mainline"
head -c 1048576 /dev/zero > "$W/boot-empty.img"
mkroot() {  # mkroot DIR [SETDIR [variants...]]: a directory standing in for the mounted old root
	local d=$1 src=${2:-} v; shift 2 2>/dev/null || shift $#
	mkdir -p "$d/etc" "$d/usr/local/share/tsx"
	[ -n "$src" ] || return 0
	mkdir -p "$d/usr/local/share/tsx/tfa9890"
	[ $# -gt 0 ] || set -- $VARIANTS
	for v in "$@"; do mkdir -p "$d/usr/local/share/tsx/tfa9890/$v"; cp "$src/$v/stereo.cnt" "$d/usr/local/share/tsx/tfa9890/$v/"; done
}
mkroot "$W/root-full" "$W/stock"
printf 'source=android-boot\nfirmware=Synth.Board_00_00_03, boot image built then\n' > "$W/root-full/usr/local/share/tsx/tfa9890/SOURCE"
mkroot "$W/root-one" "$W/other" settings_yushan
mkroot "$W/root-none"
mkroot "$W/root-bad" "$W/stock"
printf 'XX' | dd of="$W/root-bad/usr/local/share/tsx/tfa9890/settings_yushan/stereo.cnt" bs=1 seek=0 conv=notrunc 2>/dev/null
mkdir -p "$W/android-system"; echo 'ro.build.display.id=SYNTH-1.0' > "$W/android-system/build.prop"

# busybox applet dir: the rescue's tool set, nothing else in PATH
BB=$W/bb; mkdir -p "$BB"
for a in sh awk od cpio gzip head dd sha256sum cut tr sed wc mkdir rm cp mv cat printf echo basename ls find sort mount umount date; do
	ln -s "$(command -v busybox)" "$BB/$a"
done

run() {  # run MODE 'shell code': source the lib and run the code with host tools or busybox only
	if [ "$1" = busybox ]; then
		PATH=$BB TSX_TFA_PINS=$W/pins TSX_RUN=$W/run "$BB/sh" -c ". '$LIB'; $2"
	else
		TSX_TFA_PINS=$W/pins TSX_RUN=$W/run sh -c ". '$LIB'; $2"
	fi
}

for MODE in host busybox; do
echo "=== tools: $MODE"
echo "== 1. tsx_tfa_crc32 matches zlib"
got=$(run $MODE "tsx_tfa_crc32 '$W/stock/settings_yushan/stereo.cnt' 14")
want=$(python3 -c "import zlib;print(zlib.crc32(open('$W/stock/settings_yushan/stereo.cnt','rb').read()[14:])&0xffffffff)")
[ "$got" = "$want" ] && ok "crc32 $got" || bad "crc32 '$got' != '$want'"

echo "== 2. tsx_tfa_validate"
f=$W/stock/settings_yushan/stereo.cnt
out=$(run $MODE "tsx_tfa_validate '$f' settings_yushan"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q pinned && ok "pinned sha256: rc 0 ($out)" || bad "pinned: rc $rc ($out)"
out=$(run $MODE "tsx_tfa_validate '$W/other/settings_yushan/stereo.cnt' settings_yushan"); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "NOT the pinned one; valid NXP container, 12477 bytes, CRC ok" && ok "unknown sha256, valid container: rc 1 ($out)" || bad "unpinned: rc $rc ($out)"
cp "$f" "$W/badmagic"; printf 'QQ' | dd of="$W/badmagic" bs=1 conv=notrunc 2>/dev/null
out=$(run $MODE "tsx_tfa_validate '$W/badmagic' settings_yushan"); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q "not an NXP container" && ok "bad id: rejected" || bad "bad id: rc $rc ($out)"
head -c 12000 "$f" > "$W/trunc"
out=$(run $MODE "tsx_tfa_validate '$W/trunc' settings_yushan"); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q "header size 12477 != file size 12000" && ok "truncated: rejected" || bad "truncated: rc $rc ($out)"
cp "$f" "$W/badcrc"; printf '\377' | dd of="$W/badcrc" bs=1 seek=5000 conv=notrunc 2>/dev/null
out=$(run $MODE "tsx_tfa_validate '$W/badcrc' settings_yushan"); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q "CRC mismatch" && ok "one flipped byte: CRC mismatch, rejected" || bad "bad crc: rc $rc ($out)"
mkcnt "$W/tiny" 7 600
out=$(run $MODE "tsx_tfa_validate '$W/tiny' settings_yushan"); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q "implausible size" && ok "600-byte container: rejected" || bad "tiny: rc $rc ($out)"

collect() {  # collect NAME BOOT ROOT [EARLIER]: tsx_tfa_collect into $W/c-NAME; sets OUT and RES
	rm -rf "$W/c-$1"
	OUT=$(run $MODE "tsx_tfa_collect '$W/c-$1' '$2' '$3' '${4:-}'" 2>&1)
	RES=$(printf '%s\n' "$OUT" | sed -n 's/^TFA-RESULT //p')
}
same_as() {  # same_as DIR SETDIR: the three files are byte-equal
	local v; for v in $VARIANTS; do cmp -s "$1/$v/stereo.cnt" "$2/$v/stereo.cnt" || return 1; done
}

echo "== 3. source 1: the old mainline root wins (the boot image is not needed)"
collect root "$W/boot-android.img" "$W/root-full"
[ "$RES" = "source=root count=3" ] && ok "$RES" || bad "got '$RES': $OUT"
same_as "$W/c-root" "$W/stock" && ok "files byte-equal" || bad "files differ"
echo "$OUT" | grep -q "source 2/3" && bad "the boot image was read although the root had a full set" || ok "boot image not read"
grep -q '^source=root$' "$W/c-root/SOURCE" && grep -q '^firmware=Synth.Board_00_00_03' "$W/c-root/SOURCE" && ok "SOURCE: root, carrying the old root's firmware line" || bad "SOURCE: $(cat "$W/c-root/SOURCE")"
[ "$(grep -c ' pinned$' "$W/c-root/SOURCE")" = 3 ] && ok "SOURCE lists 3 pinned sha256s" || bad "SOURCE sums: $(cat "$W/c-root/SOURCE")"

echo "== 4. source 2: stock Android's boot image (no mainline root)"
collect android "$W/boot-android.img" "$W/root-none"
[ "$RES" = "source=android-boot count=3" ] && ok "$RES" || bad "got '$RES': $OUT"
same_as "$W/c-android" "$W/stock" && ok "files byte-equal to the ramdisk's" || bad "files differ"
grep -q '^firmware=Synth.Board_00_00_03, boot image built Tue Jun  4 16:48:37 EDT 2024$' "$W/c-android/SOURCE" && ok "firmware from jabil/yushan_version.txt" || bad "SOURCE: $(cat "$W/c-android/SOURCE")"
[ ! -e "$W/c-android/settings_yushan/stereo.ini" ] && ok "only stereo.cnt taken" || bad "extra files copied"
collect android4k "$W/boot-android4k.img" "$W/root-none"
[ "$RES" = "source=android-boot count=3" ] && ok "4 KiB page size: $RES" || bad "4k: '$RES': $OUT"
collect sys "$W/boot-android.img" "$W/android-system"
[ "$RES" = "source=android-boot count=3" ] && grep -q '; Android SYNTH-1.0$' "$W/c-sys/SOURCE" && ok "p8 = Android system: build id recorded ($(sed -n 's/^firmware=//p' "$W/c-sys/SOURCE"))" || bad "android system: '$RES' $(cat "$W/c-sys/SOURCE" 2>/dev/null)"

echo "== 5. order and fallback"
collect partial "$W/boot-android.img" "$W/root-one"
[ "$RES" = "source=android-boot count=3" ] && ok "root with 1 variant -> the full set from the boot image wins" || bad "got '$RES'"
collect bad "$W/boot-android.img" "$W/root-bad"
[ "$RES" = "source=android-boot count=3" ] && echo "$OUT" | grep -q "root: settings_yushan/stereo.cnt REJECTED" && ok "a corrupt file in the root is rejected, the boot image wins" || bad "got '$RES': $OUT"
collect onlyone "$W/boot-mainline.img" "$W/root-one"
[ "$RES" = "source=root count=1" ] && echo "$OUT" | grep -q "WARNING: settings_yushan/stereo.cnt: sha256 .* NOT the pinned one" && ok "nothing better: the partial root set is kept, unknown hash warned" || bad "got '$RES': $OUT"
grep -q '^settings_yushan=.* unpinned$' "$W/c-onlyone/SOURCE" && ok "SOURCE marks it unpinned" || bad "SOURCE: $(cat "$W/c-onlyone/SOURCE")"
collect nothing "$W/boot-mainline.img" "$W/root-none"
[ "$RES" = "source=none count=0" ] && [ ! -e "$W/c-nothing" ] && ok "mainline boot image, no root files: none, no output dir" || bad "got '$RES': $OUT"
echo "$OUT" | grep -q "has no jabil/tfa9890 files" && ok "says why the boot image gave nothing" || bad "no reason given: $OUT"
collect empty "$W/boot-empty.img" "$W/root-none"
[ "$RES" = "source=none count=0" ] && echo "$OUT" | grep -q "holds no Android boot image" && ok "zeroed boot region: none" || bad "got '$RES': $OUT"
collect missing "$W/no-such-device" "$W/no-such-root"
[ "$RES" = "source=none count=0" ] && ok "missing devices: none, no error" || bad "got '$RES': $OUT"
collect earlier "$W/boot-mainline.img" "$W/root-none" "$W/c-android"
[ "$RES" = "source=earlier count=3" ] && grep -q '(source android-boot)' "$W/c-earlier/SOURCE" && ok "a re-run keeps the earlier attempt's set: $RES" || bad "got '$RES': $OUT $(cat "$W/c-earlier/SOURCE" 2>/dev/null)"
done

echo "== 6. tsx_tfa_plan (the host's decision)"
. "$LIB"
for c in "auto 3 use-panel" "auto 1 puf-or-panel" "auto 0 puf" "auto - puf" "panel 3 use-panel" "panel 2 use-panel" \
         "panel 0 none" "panel - none" "puf 3 puf" "puf - puf" "none 3 none"; do
	set -- $c
	[ "$(tsx_tfa_plan "$1" "$2")" = "$3" ] && ok "$1 with $2 -> $3" || bad "$1 with $2 -> $(tsx_tfa_plan "$1" "$2"), want $3"
done
tsx_tfa_plan bogus 3 >/dev/null && bad "bogus mode accepted" || ok "bogus mode refused"

echo "== 7. the pinned list is the same as rootfs/vendor-fetch.sh's"
VF=$HERE/../../rootfs/vendor-fetch.sh
unset TSX_TFA_PINS
for v in $VARIANTS; do
	want=$(sed -n "s/^[[:space:]]*$v) echo \([0-9a-f]\{64\}\) ;;/\1/p" "$VF")
	[ -n "$want" ] && [ "$(tsx_tfa_pinned "$v")" = "$want" ] && ok "$v" || bad "$v: lib $(tsx_tfa_pinned "$v"), vendor-fetch.sh '$want'"
done

echo "== $N passed, $F failed"
[ $F = 0 ]
