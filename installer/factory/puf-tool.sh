#!/bin/bash
# Crestron xx60 firmware package (.puf) tool: extract, verify, and rebuild the
# SD card's Crestron partitions from it (used by the factory restore driver).
#
# .puf format (reversed 2026-09-26 from tsw-xx60_3.002.1061.001.puf and the
# stock scripts /system/bin/crestronLocalUpgrade.sh, crestronUpgrade.sh):
#   PUF        = ZIP: ~.package.ini (Crestron Toolbox actions: FirmwareUpdate of
#                tsx-xx60_<ver>.zip, OOTB project load), ~.package.dat, release notes,
#                tsx-xx60_<ver>.ini, tsx-xx60_<ver>.zip, schedulingproject_*.zip/.ini
#   tsx zip    = ZIP: ~info.ini ([Firmware] Version, Targets, Filename, Signature),
#                image_<ver>_r<svn>.zip + .zip.sig (256-byte signature. No public key)
#   image zip  = what the panel unzips to /mnt/sdcard/ROMDISK/romdisk/user/system/image:
#                u-boot.bin      -> card sectors 0..441 bytes + sector 1.., eMMC boot0/1/bootloader
#                boot.img        -> eMMC "boot" (normal Android kernel)       logo.img -> eMMC "logo"
#                system.img      -> eMMC "system". The SAME file is the golden /system on card p2
#                boot-golden.img -> card p1 FAT: boot.img (golden = factory recovery)
#                *.hash          POSIX `cksum` CRC of each file (backupAndRecover.sh VALIDATEHASH)
#                new_manifest    NUMBER_OF_FILES=5, VERSION=.... crestronUbootVersion.txt
#
#   puf-tool.sh extract PUF DIR           unzip all layers to DIR/, check every cksum and
#                                         NUMBER_OF_FILES, write DIR/puf.info
#   puf-tool.sh bundle PUF|DIR --env SRC --out BUNDLE [--other-unit]
#       the input of tsx-factory-restore (rescue system) and of `card`: env.bin
#       (the env of SRC with our hook removed by tsx-env.py unhook. SRC is a 64 KiB
#       env block, p1:tsxenv.bak, an installer backup env-0x100000.bin, or a card
#       image), boot-golden.img, system.img, crestron-mbr.sfdisk, crestron-fs.sh,
#       factory.manifest (sha256s)
#   puf-tool.sh card BUNDLE --out IMG [--uboot-copy]
#       a full 3,980,394,496-byte card image in the factory layout (host tests, or
#       flash-card.sh --mode full on a card in a PC). --uboot-copy also puts the
#       U-Boot copy from u-boot.bin into the first MiB (a blank card). Default: MBR only.
#
# The .puf alone can restore: the MBR/partition table, the p1 FAT + golden
# boot.img, p2 (golden /system = system.img), p5..p8 as EMPTY factory file
# systems (the same parameters as the factory cards) and the U-Boot copy. The
# .puf does NOT hold the identity in the env (ethaddr, tsid, product_name,
# lan_hostname, updater_*, and lcdsize/aml_dt, which U-Boot detects again on 2 GB
# units). Use --env from the own backup of the unit for that. The /data of
# Crestron (p6: settings, passwords, ssh keys, licenses), the ROMDISK project
# and user files on p5, and the logs (p8) come only from a backup of that unit
# (unit B: captures/tsw-1060-unitB).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); INSTALLER_DIR=$(cd "$HERE/.." && pwd); ROOTFS_DIR=$(cd "$INSTALLER_DIR/../rootfs" && pwd)
ENVPY="python3 $INSTALLER_DIR/sdcard/tsx-env.py"
die() { echo "puf-tool: ERROR: $*" >&2; exit 1; }
say() { echo "puf-tool: $*" >&2; }
CARD=3980394496

verify_img() {   # verify_img DIR: Crestron's own checks (crestronLocalUpgrade.sh verifyManifest)
	local d=$1 f want got
	for f in "$d"/*.hash; do
		want=$(tr -d ' \r\n' < "$f"); got=$(cksum < "${f%.hash}" | cut -d' ' -f1)
		[ "$want" = "$got" ] || die "$(basename "${f%.hash}"): cksum $got != $want (.hash)"
	done
	n=$(ls -1 "$d" | grep -v hash | grep -v manifest | grep -v '~info.ini' | grep -vc crestronUbootVersion.txt || true)
	want=$(sed -n 's/^NUMBER_OF_FILES=//p' "$d/new_manifest" | tr -d '\r')
	[ "$n" = "$want" ] || die "new_manifest says $want files, found $n"
	for f in boot-golden.img system.img u-boot.bin; do [ -f "$d/$f" ] || die "no $f in the image zip"; done
	[ "$(head -c 8 "$d/boot-golden.img")" = ANDROID! ] || die "boot-golden.img is not an Android boot image"
}
extract() {   # extract PUF DIR
	local puf=$1 d=$2 z f
	mkdir -p "$d"
	unzip -o -q "$puf" -d "$d/puf" || die "$puf is not a zip (.puf)"
	z=$(ls "$d"/puf/tsx-*.zip 2>/dev/null | head -n 1); [ -n "$z" ] || die "no tsx-*.zip in the package"
	unzip -o -q "$z" -d "$d/tsx"
	z=$(ls "$d"/tsx/image_*.zip | head -n 1); [ -n "$z" ] || die "no image_*.zip in $(basename "$(ls "$d"/puf/tsx-*.zip)")"
	unzip -o -q "$z" -d "$d/img"
	verify_img "$d/img"
	{
		echo "# puf-tool.sh extract $(date -Iseconds)"
		echo "puf=$(basename "$puf")"; echo "puf_sha256=$(sha256sum < "$puf" | cut -d' ' -f1)"
		sed -n 's/^Version=/package_version=/p; s/^Description=/package_description=/p' "$d/puf/~.package.ini" | head -n 2
		sed -n 's/^Version=/firmware_version=/p; s/^Targets=/targets=/p' "$d/tsx/~info.ini" | tr -d '\r'
		echo "manifest_version=$(sed -n 's/^VERSION=//p' "$d/img/new_manifest" | tr -d '\r')"
		echo "uboot_version=$(head -n 1 "$d/img/crestronUbootVersion.txt" | tr -d '\r')"
		echo "cksum_check=ok (NUMBER_OF_FILES=$(sed -n 's/^NUMBER_OF_FILES=//p' "$d/img/new_manifest" | tr -d '\r'))"
		echo "signature=not verified (image zip .sig is 256 bytes, Crestron's key is not available)"
		unzip -Z -T "$z" | awk 'NR>1 && $NF ~ /img$|bin$/ {print "zip_entry " $NF " " $(NF-1)}'
		for f in boot-golden.img boot.img system.img u-boot.bin logo.img; do [ -f "$d/img/$f" ] && echo "sha256 $f $(sha256sum < "$d/img/$f" | cut -d' ' -f1) $(stat -c %s "$d/img/$f")"; done
	} > "$d/puf.info"
	say "extracted to $d/img (cksum ok)"; cat "$d/puf.info"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
extract) [ $# = 2 ] || die "extract PUF DIR"; extract "$1" "$2";;
bundle)
	SRC=$1; shift; ENVSRC= OUT= OTHER=0
	while [ $# -gt 0 ]; do case $1 in --env) ENVSRC=$2; shift;; --out) OUT=$2; shift;; --other-unit) OTHER=1;; *) die "bundle: $1?";; esac; shift; done
	[ -n "$ENVSRC" ] && [ -n "$OUT" ] || die "bundle PUF|DIR --env SRC --out BUNDLE"
	mkdir -p "$OUT"
	if [ -f "$SRC" ]; then extract "$SRC" "$OUT/.x" > "$OUT/extract.log"; D=$OUT/.x; else D=$SRC; fi
	[ -f "$D/img/system.img" ] || die "$SRC: no extracted image"
	verify_img "$D/img"
	$ENVPY unhook "$ENVSRC" "$OUT/env.bin" > /dev/null || die "the env from $ENVSRC is not usable"
	ETH=$($ENVPY show "$OUT/env.bin" ethaddr | sed -n 's/^ethaddr=//p')
	[ -n "$ETH" ] || [ $OTHER = 1 ] || die "the env has no ethaddr: identity missing (--other-unit to accept)"
	cp "$D/img/boot-golden.img" "$D/img/system.img" "$D/img/u-boot.bin" "$OUT/"
	cp "$ROOTFS_DIR/tests/crestron-mbr.sfdisk" "$OUT/crestron-mbr.sfdisk"; cp "$HERE/crestron-fs.sh" "$OUT/"
	{
		echo "# xx60 factory-restore bundle, puf-tool.sh $(date -Iseconds)"
		echo "format=tsx-factory-bundle-1"
		[ -f "$D/puf.info" ] && grep -E '^(puf|puf_sha256|firmware_version|uboot_version)=' "$D/puf.info"
		echo "unit=$(echo "$ETH" | tr -d ':' | tr 'A-F' 'a-f')"; echo "ethaddr=$ETH"
		echo "lcdsize=$($ENVPY show "$OUT/env.bin" lcdsize | sed -n 's/^lcdsize=//p')"
		for f in env.bin boot-golden.img system.img u-boot.bin crestron-mbr.sfdisk crestron-fs.sh; do echo "file $f $(stat -c %s "$OUT/$f") $(sha256sum < "$OUT/$f" | cut -d' ' -f1)"; done
	} > "$OUT/factory.manifest"
	rm -rf "$OUT/.x"
	say "bundle $OUT for unit ${ETH:-?}"; cat "$OUT/factory.manifest";;
card)
	B=$1; shift; OUT= UB=0
	while [ $# -gt 0 ]; do case $1 in --out) OUT=$2; shift;; --uboot-copy) UB=1;; *) die "card: $1?";; esac; shift; done
	[ -n "$OUT" ] || die "card BUNDLE --out IMG"
	grep -q '^format=tsx-factory-bundle-1$' "$B/factory.manifest" || die "$B is not a factory bundle"
	while read -r _ f sz sha; do [ "$(sha256sum < "$B/$f" | cut -d' ' -f1)" = "$sha" ] || die "$f does not match the manifest"; done < <(grep '^file ' "$B/factory.manifest")
	. "$B/crestron-fs.sh"
	rm -f "$OUT"; truncate -s $CARD "$OUT"
	sfdisk -q "$OUT" < "$B/crestron-mbr.sfdisk" >/dev/null
	if [ $UB = 1 ]; then
		dd if="$B/u-boot.bin" of="$OUT" bs=442 count=1 conv=notrunc status=none
		dd if="$B/u-boot.bin" of="$OUT" bs=512 skip=1 seek=1 conv=notrunc status=none
	fi
	W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
	truncate -s $((CRESTRON_P1_SECTORS * 512)) "$W/p1.fat"; crestron_mkfat "$W/p1.fat"
	MTOOLS_SKIP_CHECK=1 mcopy -i "$W/p1.fat" "$B/boot-golden.img" ::boot.img
	dd if="$W/p1.fat" of="$OUT" bs=512 seek=$CRESTRON_P1_START conv=notrunc status=none
	dd if="$B/system.img" of="$OUT" bs=512 seek=$CRESTRON_P2_START conv=notrunc,sparse status=none
	for p in 5 6 7 8; do st=$(echo "$CRESTRON_FS" | awk -v p=$p '$1 == p {print $2}'); crestron_mke2fs $p "$OUT" $((st * 512)) 2>/dev/null || die "mke2fs p$p"; done
	dd if="$B/env.bin" of="$OUT" bs=65536 seek=16 conv=notrunc status=none
	say "card image $OUT (factory layout, unit $(sed -n 's/^unit=//p' "$B/factory.manifest"))";;
*) sed -n '2,41p' "$0"; exit 2;;
esac
