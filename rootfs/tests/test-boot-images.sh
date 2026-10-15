#!/bin/bash
# Host test for rootfs/check-boot-images.py, rootfs/initramfs-stamp.sh and
# rootfs/initramfs-stamp-history.sh. No kernel build, no container: fake boot
# images (an Android boot image v0 with a kernel that holds a gzip stream with a
# "Linux version" line, and a gzip cpio ramdisk) in a fake rootfs tree, and a
# temporary git repository for the stamp history (needs git).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$HERE/check-boot-images.py
STAMP=$HERE/initramfs-stamp.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

LTS_REV=afef745d87f3f4af3c69f42b6982e3d9afed60bd
STABLE_REV=1e22ff7948596e7e09698918e8ae522006570e5e
GOODL=6.18.54-00138-gafef745d87f3
GOODS=7.2.8-00136-g1e22ff794859
mkdir -p "$W/pins"
printf '# lts\n%s\n' "$LTS_REV" > "$W/pins/KERNEL_REV.lts"
printf '# stable\n%s\n' "$STABLE_REV" > "$W/pins/KERNEL_REV.stable"
GOODSTAMP=$(sh "$STAMP")

# fakeimg FILE RELEASE STAMP ("none" = no stamp file in the initramfs)
fakeimg() {
	python3 - "$@" <<'PY'
import gzip, os, struct, sys
out, rel, stamp = sys.argv[1:4]
def newc(name, data, mode=0o100644):
    n = name.encode() + b"\0"
    h = b"070701" + b"".join(b"%08x" % v for v in (1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0))
    h += n; h += b"\0" * (-len(h) % 4)
    h += data; h += b"\0" * (-len(h) % 4)
    return h
cpio = newc("init", b"#!/bin/sh\n")
if stamp != "none":
    cpio += newc("usr/share/tsx/initramfs.stamp", (stamp + "\n").encode())
cpio += newc("TRAILER!!!", b"")
ramdisk = gzip.compress(cpio)
payload = b"junk\x1f\x8b\x08 not gzip " + gzip.compress(
    b"junk Linux version %s (builder@host) #1 SMP\n" % rel.encode() + os.urandom(2048))
kernel = b"\x27\x05\x19\x56" + b"\0" * 60 + payload
page = 2048
hdr = b"ANDROID!" + struct.pack("<8I", len(kernel), 0x8000, len(ramdisk), 0x1000000, 0, 0, 0, page)
hdr += b"\0" * (page - len(hdr))
pad = lambda b: b + b"\0" * (-len(b) % page)
open(out, "wb").write(hdr + pad(kernel) + pad(ramdisk))
PY
}
# fakeroot DIR LTS_RELEASE STABLE_RELEASE LTS_STAMP STABLE_STAMP
fakeroot() {
	local d=$1 fl rel st
	rm -rf "$d"; mkdir -p "$d/boot" "$d/usr/share/tsx"
	for fl in lts stable; do
		if [ $fl = lts ]; then rel=$2; st=$4; else rel=$3; st=$5; fi
		fakeimg "$d/boot/tsxboot-emmc-$fl.img" "$rel" "$st"
		echo "$rel" > "$d/usr/share/tsx/kernel-$fl.release"
		mkdir -p "$d/lib/modules/$rel"
	done
}
run() { "$CHECK" "$W/root" "$W/pins" >"$W/out.txt" 2>&1; }

echo "== 1. stamp"
[ "${#GOODSTAMP}" = 64 ] && ok "the stamp is 64 digits" || bad "stamp: '$GOODSTAMP'"
[ "$(sh "$STAMP")" = "$GOODSTAMP" ] && ok "the stamp is stable" || bad "the stamp changes between runs"
cp -a "$HERE" "$W/copy"
echo "# changed" >> "$W/copy/initramfs/overlay/init"
[ "$(sh "$W/copy/initramfs-stamp.sh")" != "$GOODSTAMP" ] && ok "a changed initramfs file changes the stamp" || bad "stamp ignores initramfs/overlay/init"
cp -a "$HERE" "$W/copy2"
echo "# changed" >> "$W/copy2/initramfs/packages.pin"
[ "$(sh "$W/copy2/initramfs-stamp.sh")" != "$GOODSTAMP" ] && ok "a changed packages.pin changes the stamp" || bad "stamp ignores packages.pin"
cp -a "$HERE" "$W/copy3"
echo "# changed" >> "$W/copy3/initramfs/overlay/usr/sbin/tsx-confont"
echo "# changed" >> "$W/copy3/overlay/usr/local/lib/tsx/board.sh"
[ "$(sh "$W/copy3/initramfs-stamp.sh")" = "$GOODSTAMP" ] && ok "the stamp ignores the tools that come from packages and the board file of the rootfs" || bad "stamp covers tsx-confont or board.sh"
# The stamp of the initramfs sources of this checkout. The kernel packages of
# the next release carry it. A changed file under rootfs/initramfs (or
# install.sh, tsx-disk.sh, packages.pin) needs new kernel packages. rootfs.yml
# only warns while the published kernel packages have an older stamp, so this
# value catches a change that nobody planned. Change it together with the
# initramfs sources, and release new kernel packages.
SOURCE_STAMP=bb3b2e1fba59
[ "${GOODSTAMP:0:12}" = "$SOURCE_STAMP" ] && ok "the stamp is the planned stamp ($SOURCE_STAMP)" || bad "the stamp is ${GOODSTAMP:0:12}, the planned stamp is $SOURCE_STAMP (a change of the initramfs sources needs new kernel packages: change SOURCE_STAMP with it)"

echo "== 2. both images match the pins and the initramfs"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$GOODSTAMP"
run && ok "accepted" || bad "refused a good rootfs: $(cat "$W/out.txt")"
grep -q "lts $GOODL matches" "$W/out.txt" && grep -q "stable $GOODS matches" "$W/out.txt" && ok "both flavors reported" || bad "report: $(cat "$W/out.txt")"

echo "== 3. stale stable kernel"
fakeroot "$W/root" $GOODL 7.2.8-00063-g0dc16c8ba529 "$GOODSTAMP" "$GOODSTAMP"
run && bad "accepted a stale stable kernel" || ok "refused"
grep -q "stable: the boot image has kernel 7.2.8-00063-g0dc16c8ba529" "$W/out.txt" && ok "message names the kernel" || bad "message: $(cat "$W/out.txt")"
grep -q "^check-boot-images: lts .* matches" "$W/out.txt" && ok "lts still checked" || bad "lts not checked"

echo "== 4. initramfs without a stamp (the old initramfs)"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" none
run && bad "accepted an initramfs without a stamp" || ok "refused"
grep -q "stable: the initramfs has no usr/share/tsx/initramfs.stamp" "$W/out.txt" && ok "message names the stamp" || bad "message: $(cat "$W/out.txt")"

echo "== 5. initramfs with another stamp"
fakeroot "$W/root" $GOODL $GOODS 0000000000000000000000000000000000000000000000000000000000000000 "$GOODSTAMP"
run && bad "accepted another stamp" || ok "refused"
grep -q "lts: the initramfs stamp is 000000000000" "$W/out.txt" && ok "message names the stamp" || bad "message: $(cat "$W/out.txt")"

echo "== 6. release file stale"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$GOODSTAMP"
echo 7.2.8-00063-g0dc16c8ba529 > "$W/root/usr/share/tsx/kernel-stable.release"
run && bad "accepted a stale release file" || ok "refused"

echo "== 7. modules directory missing"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$GOODSTAMP"
rm -rf "$W/root/lib/modules/$GOODS"
run && bad "accepted a rootfs without the modules" || ok "refused"

echo "== 8. missing image"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$GOODSTAMP"
rm -f "$W/root/boot/tsxboot-emmc-stable.img"
run && bad "accepted a rootfs without the stable image" || ok "refused"

echo "== 9. not a boot image"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$GOODSTAMP"
head -c 3000000 /dev/zero > "$W/root/boot/tsxboot-emmc-lts.img"
run && bad "accepted an image without a kernel" || ok "refused"

echo "== 10. bad pin file"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$GOODSTAMP"
echo abc > "$W/pins/KERNEL_REV.lts"
run && bad "accepted a short pin" || ok "refused"

echo "== 11. the pins of this checkout"
[ "$(grep -v '^#' "$HERE/../kernel/KERNEL_REV.lts" | head -n1 | wc -c)" = 41 ] && ok "lts pin is 40 digits" || bad "lts pin length"
[ "$(grep -v '^#' "$HERE/../kernel/KERNEL_REV.stable" | head -n1 | wc -c)" = 41 ] && ok "stable pin is 40 digits" || bad "stable pin length"

echo "== 12. the build runs the guard and writes the stamp"
grep -q 'check-boot-images.py' "$HERE/mkrootfs.sh" && ok "mkrootfs.sh runs the check" || bad "mkrootfs.sh does not run the check"
grep -q 'initramfs-stamp.sh' "$HERE/initramfs/mkinitramfs-switchroot.sh" && ok "the initramfs build writes the stamp" || bad "mkinitramfs-switchroot.sh has no stamp"
grep -q "cpio -o -H newc -R 0:0" "$HERE/initramfs/mkinitramfs-switchroot.sh" && ok "the initramfs cpio has root-owned files" || bad "the initramfs cpio keeps the owner of the checkout"
for f in check-boot-images.py initramfs-stamp.sh; do [ $(grep -c "$f" "$HERE/../tools/build/remote-build.sh") -ge 2 ] && ok "remote-build.sh sends $f" || bad "remote-build.sh does not send $f"; done
grep -q ':/kernel:ro' "$HERE/build-rootfs.sh" && ok "build-rootfs.sh mounts the pins" || bad "build-rootfs.sh does not mount the pins"

OLDSTAMP=1111111111111111111111111111111111111111111111111111111111111111
OLDC=0123456789abcdef0123456789abcdef01234567
echo "== 13. an older stamp of this history (TSX_STAMP_OLDER) gives a warning"
printf '# lts\n%s\n' "$LTS_REV" > "$W/pins/KERNEL_REV.lts"
fakeroot "$W/root" $GOODL $GOODS "$OLDSTAMP" "$GOODSTAMP"
TSX_STAMP_OLDER="2222222222222222222222222222222222222222222222222222222222222222:aaaa $OLDSTAMP:$OLDC" run && ok "accepted" || bad "refused: $(cat "$W/out.txt")"
grep -q "^::warning title=initramfs stamp (lts)::.*$OLDSTAMP of the older commit ${OLDC:0:12}\. This checkout has the stamp $GOODSTAMP\." "$W/out.txt" && ok "a warning with both stamps and the commit" || bad "warning: $(cat "$W/out.txt")"
grep -q "^check-boot-images: stable $GOODS matches" "$W/out.txt" && ok "stable still checked" || bad "stable not checked"
fakeroot "$W/root" $GOODL $GOODS "$OLDSTAMP" "$OLDSTAMP"
TSX_STAMP_OLDER="$OLDSTAMP:$OLDC" run && ok "both flavors with the older stamp: accepted" || bad "refused: $(cat "$W/out.txt")"
[ "$(grep -c '^::warning' "$W/out.txt")" = 2 ] && ok "one warning for each flavor" || bad "warnings: $(cat "$W/out.txt")"

echo "== 14. TSX_STAMP_OLDER does not hide another difference"
fakeroot "$W/root" $GOODL $GOODS 3333333333333333333333333333333333333333333333333333333333333333 "$GOODSTAMP"
TSX_STAMP_OLDER="$OLDSTAMP:$OLDC" run && bad "accepted a stamp that the history does not have" || ok "a stamp outside the history: refused"
grep -q "lts: the initramfs stamp is 333333333333" "$W/out.txt" && ok "message names the stamp" || bad "message: $(cat "$W/out.txt")"
grep -q '^::warning' "$W/out.txt" && bad "a warning for a refused stamp" || ok "no warning"
fakeroot "$W/root" $GOODL $GOODS "$OLDSTAMP" none
TSX_STAMP_OLDER="$OLDSTAMP:$OLDC" run && bad "accepted an initramfs without a stamp" || ok "no stamp: refused"
fakeroot "$W/root" $GOODL 7.2.8-00063-g0dc16c8ba529 "$OLDSTAMP" "$OLDSTAMP"
TSX_STAMP_OLDER="$OLDSTAMP:$OLDC" run && bad "accepted a stale stable kernel" || ok "a kernel that is not the pin: refused"
fakeroot "$W/root" $GOODL $GOODS "$OLDSTAMP" "$OLDSTAMP"
echo 7.2.8-00063-g0dc16c8ba529 > "$W/root/usr/share/tsx/kernel-stable.release"
TSX_STAMP_OLDER="$OLDSTAMP:$OLDC" run && bad "accepted a stale release file" || ok "a stale release file: refused"
fakeroot "$W/root" $GOODL $GOODS "$OLDSTAMP" "$GOODSTAMP"
TSX_STAMP_OLDER="${OLDSTAMP:0:12}:$OLDC not-a-stamp" run && bad "accepted a short stamp in TSX_STAMP_OLDER" || ok "only full 64 digit stamps count"
run && bad "accepted an older stamp without TSX_STAMP_OLDER" || ok "without TSX_STAMP_OLDER an older stamp fails as before"

echo "== 15. one boot image (--image, release.yml)"
fakeroot "$W/root" $GOODL $GOODS "$GOODSTAMP" "$OLDSTAMP"
"$CHECK" --image lts "$W/root/boot/tsxboot-emmc-lts.img" "$W/pins" >"$W/out.txt" 2>&1 && ok "a good lts image: accepted" || bad "refused: $(cat "$W/out.txt")"
grep -q "^check-boot-images: lts $GOODL matches" "$W/out.txt" && ok "reported" || bad "report: $(cat "$W/out.txt")"
TSX_STAMP_OLDER="$OLDSTAMP:$OLDC" "$CHECK" --image stable "$W/root/boot/tsxboot-emmc-stable.img" "$W/pins" >"$W/out.txt" 2>&1 \
	&& bad "accepted an older stamp in --image" || ok "an older stamp: refused, also with TSX_STAMP_OLDER"
grep -q "stable: the initramfs stamp of .* is '111111111111', this checkout has ${GOODSTAMP:0:12}" "$W/out.txt" && ok "message names both stamps" || bad "message: $(cat "$W/out.txt")"
"$CHECK" --image stable "$W/root/boot/tsxboot-emmc-lts.img" "$W/pins" >"$W/out.txt" 2>&1 && bad "accepted the lts kernel as stable" || ok "the kernel of the other flavor: refused"
fakeroot "$W/root" $GOODL $GOODS none "$GOODSTAMP"
"$CHECK" --image lts "$W/root/boot/tsxboot-emmc-lts.img" "$W/pins" >"$W/out.txt" 2>&1 && bad "accepted an image without a stamp" || ok "no stamp: refused"
"$CHECK" --image lts >"$W/out.txt" 2>&1; [ $? = 2 ] && ok "no image: usage, exit 2" || bad "no image: $(cat "$W/out.txt")"
"$CHECK" --image bad "$W/root/boot/tsxboot-emmc-lts.img" >"$W/out.txt" 2>&1; [ $? = 2 ] && ok "a bad flavor: usage, exit 2" || bad "bad flavor: $(cat "$W/out.txt")"

echo "== 16. initramfs-stamp-history.sh"
if ! command -v git >/dev/null; then
	bad "git is missing"
else
	G=$W/repo
	mkdir -p "$G/rootfs"
	cp -a "$HERE/initramfs" "$HERE/install.sh" "$HERE/tsx-disk.sh" "$HERE/initramfs-stamp.sh" "$HERE/initramfs-stamp-history.sh" "$G/rootfs/"
	gc() { git -C "$G" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
	gc init -q
	gc add -A; gc commit -qm one
	S1=$(sh "$G/rootfs/initramfs-stamp.sh"); C1=$(gc rev-parse HEAD)
	echo "# changed" >> "$G/rootfs/initramfs/packages.pin"
	gc commit -qam two
	S2=$(sh "$G/rootfs/initramfs-stamp.sh"); C2=$(gc rev-parse HEAD)
	echo "other" > "$G/README"; gc add README; gc commit -qm three
	echo "# changed" >> "$G/rootfs/initramfs/overlay/usr/sbin/tsx-confont"
	gc commit -qam four
	C4=$(gc rev-parse HEAD)
	sh "$G/rootfs/initramfs-stamp-history.sh" > "$W/hist.txt" 2>"$W/hist.err" && ok "runs" || bad "history: $(cat "$W/hist.err")"
	[ "$S1" != "$S2" ] && ok "the two stamps differ" || bad "the change did not change the stamp"
	printf '%s %s\n%s %s\n%s %s\n' "$S2" "$C4" "$S2" "$C2" "$S1" "$C1" | cmp -s - "$W/hist.txt" \
		&& ok "one line for each commit that changed the sources, newest first, with the stamp of that commit" || bad "history: $(cat "$W/hist.txt")"
	sh "$G/rootfs/initramfs-stamp-history.sh" "$C2^" > "$W/hist.txt" 2>"$W/hist.err"
	[ "$(cat "$W/hist.txt")" = "$S1 $C1" ] && ok "REV selects the history" || bad "history of $C2^: $(cat "$W/hist.txt")"
	git clone -q --depth 1 "file://$G" "$W/shallow" 2>/dev/null
	sh "$W/shallow/rootfs/initramfs-stamp-history.sh" > "$W/hist.txt" 2>"$W/hist.err" && bad "a shallow clone gave a history" || ok "a shallow clone: refused"
	grep -q "shallow" "$W/hist.err" && ok "message names the shallow clone" || bad "message: $(cat "$W/hist.err")"
fi

echo "== 17. the wiring of the stamp checks"
WF=$HERE/../.github/workflows
grep -q 'TSX_STAMP_OLDER_OK: "1"' "$WF/rootfs.yml" && ok "rootfs.yml accepts an older stamp" || bad "rootfs.yml has no TSX_STAMP_OLDER_OK"
grep -q 'fetch-depth: 0' "$WF/rootfs.yml" && ok "rootfs.yml checks out the full history" || bad "rootfs.yml has a shallow checkout"
grep -q 'TSX_STAMP_OLDER_OK' "$WF/release.yml" && bad "release.yml accepts an older stamp" || ok "release.yml does not accept an older stamp"
grep -q 'check-boot-images.py --image ${{ matrix.flavor }} rootfs/out/tsxboot.img' "$WF/release.yml" && ok "release.yml checks the boot image it builds" || bad "release.yml does not check its boot image"
grep -q 'initramfs-stamp-history.sh' "$HERE/build-rootfs.sh" && grep -q -- '-e TSX_STAMP_OLDER=' "$HERE/build-rootfs.sh" && ok "build-rootfs.sh passes the history to the check" || bad "build-rootfs.sh does not pass TSX_STAMP_OLDER"

echo "boot images: $N ok, $F failed"
[ "$F" = 0 ]
