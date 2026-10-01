#!/bin/sh
# vendor-fetch.sh [--check|--force] [--psr]
#
# Fetch the TFA9890 CoolFlux DSP tuning containers (.cnt) from the public
# Crestron firmware package. With --psr, fetch the CSR8811 Bluetooth PSR file
# from the same package instead (see --psr below). The Android vendor tree is
# proprietary and not published, so this script does not use it. Crestron
# ships the containers inside the panel firmware .puf. Anyone can download the
# .puf from the Crestron update CDN:
#
#   index    https://crestrondevicefiles.blob.core.windows.net/tsx-firmware/touchscreen.txt
#            (JSON; deviceModel "TSW-1060*" etc -> fileUrl of the .puf)
#   version  https://crestrondevicefiles.blob.core.windows.net/tsx-firmware/tss-version.txt
#   .puf     https://devicefiles.crestron.io/firmware/tsw-xx60_3.002.1061.001.puf (357 MB)
#
# .puf layout (installer/factory/puf-tool.sh has the full reverse-engineering
# notes): outer ZIP -> tsx-xx60_<ver>.zip -> image_<ver>_r<svn>.zip -> boot.img.
# boot.img is an Android v0 boot image with page size 2048
# (installer/initramfs/repack-bootimg.py describes the header layout).
# Its ramdisk is a gzip cpio. Among other files, the ramdisk holds
# jabil/tfa9890/settings_yushan{,_2nd,_3rd}/stereo.cnt.
#
# This script downloads the .puf (cached, sha256-pinned). It unzips only the
# two intermediate zip layers (tsx.zip and image.zip, about 370 MB each),
# because it must write them out to read them at random. From image.zip it
# pulls only the small boot.img entry. Without --psr, it never writes the
# 650 MB system.img entry of the same zip.
# It then parses the Android boot header by hand (it does not need python) and
# cuts the gzip ramdisk out of boot.img. It extracts the ramdisk with busybox
# cpio and copies the DSP containers into vendor-local/tfa9890/. It checks
# the three stereo.cnt files against the sha256 values pinned below.
#
# --psr      work on the CSR8811 Bluetooth PSR file (PSR-CSR8811.psr) instead
#            of the DSP containers. The file is /bin/PSR-CSR8811.psr in the
#            system.img entry of image.zip (a raw ext4 image, 650 MB). The
#            script writes system.img to its temporary directory, reads the
#            one file out of it with debugfs (e2fsprogs, no mount, no root)
#            and deletes system.img again. It checks the file against the
#            sha256 pinned below and puts it in vendor-local/csr8811/. The
#            installer uses this as the fallback when the panel has no PSR
#            file (docs/install.md "Bluetooth PSR file"). mkrootfs.sh never
#            reads vendor-local/csr8811/: no image ever carries the file.
# --check    only verify the output (vendor-local/tfa9890/*/stereo.cnt, or
#            with --psr vendor-local/csr8811/PSR-CSR8811.psr) against the
#            pinned hashes. No network, no extraction. Exit 0 means all files
#            are present and correct. Exit 1 means a file is missing or wrong.
# --force    redo the download and extraction even if vendor-local already has
#            correct files. By default the script then skips straight to "ok".
#
# Env overrides: TFA_PUF_URL, TFA_PUF_SHA256, TFA_PUF_CACHE (download cache
# dir), TFA_VENDOR_LOCAL (output dir, the same variable mkrootfs.sh reads),
# PSR_VENDOR_LOCAL (the output dir of --psr), PSR_SHA256 (the pinned sha256 of
# the PSR file, for tests with a made-up package).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
log() { echo "vendor-fetch: $*" >&2; }
die() { echo "vendor-fetch: ERROR: $*" >&2; exit 1; }

TFA_PUF_URL=${TFA_PUF_URL:-https://devicefiles.crestron.io/firmware/tsw-xx60_3.002.1061.001.puf}
TFA_PUF_SHA256=${TFA_PUF_SHA256:-96438108e3175b66c09f1df284ded5fe155593ba06e069e154688b04f395e40b}
TFA_PUF_CACHE=${TFA_PUF_CACHE:-"$HERE/vendor-cache"}
TFA_VENDOR_LOCAL=${TFA_VENDOR_LOCAL:-"$HERE/vendor-local/tfa9890"}
PSR_VENDOR_LOCAL=${PSR_VENDOR_LOCAL:-"$HERE/vendor-local/csr8811"}
PSR_NAME=PSR-CSR8811.psr
# The sha256 of /bin/PSR-CSR8811.psr in system.img of the .puf above (7814
# bytes). installer/lib/tsx-psr.sh and tsx-bt pin the same value.
PSR_SHA256=${PSR_SHA256:-96709f6ca529efb0dc8cf48165ba0c1c1934236794424aa539810376676aa8be}

# Pinned sha256 of the stereo.cnt of each variant. The values come from the
# .puf above (2026-09-26). The public firmware package and the Android vendor
# tree drop carry identical containers.
sha_for() {
	case $1 in
	settings_yushan) echo b479300ed44a7663afe04fd271b8e059ea4d6e1778939a18e87d004613288de8 ;;
	settings_yushan_2nd) echo fe5157aa0213b640a3e40fa4bc79ce88849b2589361079fefcfcda14b0ad0c14 ;;
	settings_yushan_3rd) echo 6d5952abe66ca83d0c08cbc77ae8e56eb95eef18e5ad6a33ed6f19f981071067 ;;
	*) die "sha_for: unknown variant $1" ;;
	esac
}
VARIANTS="settings_yushan settings_yushan_2nd settings_yushan_3rd"

sha256_of() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v openssl > /dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	else
		die "need sha256sum or openssl to verify hashes"
	fi
}

ensure_tool() { # ensure_tool BINARY [APK_PACKAGE]
	command -v "$1" > /dev/null 2>&1 && return 0
	if command -v apk > /dev/null 2>&1; then
		apk add -q --no-cache "${2:-$1}" > /dev/null 2>&1 || true
	fi
	command -v "$1" > /dev/null 2>&1 || die "missing required tool: $1 (install it, or run inside the Alpine build container)"
}

do_check() { # do_check: verify vendor-local against the pinned hashes, with no network
	[ "$WHAT" = psr ] && { do_check_psr; return; }
	ok=1
	for v in $VARIANTS; do
		f="$TFA_VENDOR_LOCAL/$v/stereo.cnt"
		want=$(sha_for "$v")
		if [ ! -r "$f" ]; then
			echo "vendor-fetch: MISSING $v/stereo.cnt"
			ok=0
			continue
		fi
		got=$(sha256_of "$f")
		if [ "$got" = "$want" ]; then
			echo "vendor-fetch: ok      $v/stereo.cnt ($got)"
		else
			echo "vendor-fetch: MISMATCH $v/stereo.cnt: got $got, want $want"
			ok=0
		fi
	done
	[ "$ok" = 1 ]
}

do_check_psr() { # do_check_psr: verify vendor-local/csr8811 against the pinned hash
	f="$PSR_VENDOR_LOCAL/$PSR_NAME"
	if [ ! -r "$f" ]; then
		echo "vendor-fetch: MISSING $PSR_NAME"
		return 1
	fi
	got=$(sha256_of "$f")
	if [ "$got" = "$PSR_SHA256" ]; then
		echo "vendor-fetch: ok      $PSR_NAME ($got)"
		return 0
	fi
	echo "vendor-fetch: MISMATCH $PSR_NAME: got $got, want $PSR_SHA256"
	return 1
}

MODE=fetch WHAT=tfa
for a in "$@"; do
	case $a in
	--check) MODE=check ;;
	--force) MODE=force ;;
	--psr) WHAT=psr ;;
	*) die "usage: $0 [--check|--force] [--psr]" ;;
	esac
done
if [ "$WHAT" = psr ]; then OUT_LABEL="vendor-local/csr8811 ($PSR_NAME)"; else OUT_LABEL=vendor-local/tfa9890; fi

if [ "$MODE" = check ]; then
	do_check && { log "$OUT_LABEL: present and verified"; exit 0; }
	exit 1
fi

if [ "$MODE" != force ] && do_check > /dev/null 2>&1; then
	log "$OUT_LABEL already present and verified. There is nothing to do (use --force to redo)"
	exit 0
fi

ensure_tool unzip
ensure_tool gzip
ensure_tool cpio
ensure_tool od
if ! command -v curl > /dev/null 2>&1 && ! command -v wget > /dev/null 2>&1; then
	ensure_tool curl
fi

fetch() { # fetch URL OUT
	if command -v curl > /dev/null 2>&1; then
		curl -fSL -o "$2" "$1"
	else
		wget -O "$2" "$1"
	fi
}

mkdir -p "$TFA_PUF_CACHE"
PUF_PATH="$TFA_PUF_CACHE/$(basename "$TFA_PUF_URL")"
if [ -r "$PUF_PATH" ] && [ "$(sha256_of "$PUF_PATH")" = "$TFA_PUF_SHA256" ]; then
	log "using cached $PUF_PATH (sha256 verified)"
else
	log "downloading $TFA_PUF_URL -> $PUF_PATH (357 MB)"
	fetch "$TFA_PUF_URL" "$PUF_PATH.part" || die "download failed"
	mv "$PUF_PATH.part" "$PUF_PATH"
fi
got=$(sha256_of "$PUF_PATH")
[ "$got" = "$TFA_PUF_SHA256" ] || die "$PUF_PATH: sha256 $got != pinned $TFA_PUF_SHA256 (Crestron changed the package, or the download is corrupt. Delete $TFA_PUF_CACHE and retry)"
log "puf sha256 ok: $got"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vendor-fetch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

zip_entry() { # zip_entry ZIPFILE GREP_PATTERN -> first matching entry name
	unzip -l "$1" | grep -E "$2" | awk '{print $NF}' | head -n 1
}

TSX_NAME=$(zip_entry "$PUF_PATH" 'tsx-.*\.zip$')
[ -n "$TSX_NAME" ] || die "no tsx-*.zip inside $PUF_PATH"
log "extracting $TSX_NAME"
unzip -p "$PUF_PATH" "$TSX_NAME" > "$WORK/tsx.zip"

IMAGE_NAME=$(zip_entry "$WORK/tsx.zip" 'image_.*\.zip$')
[ -n "$IMAGE_NAME" ] || die "no image_*.zip inside $TSX_NAME"
if [ "$WHAT" = psr ]; then log "extracting $IMAGE_NAME"; else log "extracting $IMAGE_NAME (not system.img)"; fi
unzip -p "$WORK/tsx.zip" "$IMAGE_NAME" > "$WORK/image.zip"
rm -f "$WORK/tsx.zip"

if [ "$WHAT" = psr ]; then
	# The PSR file: /bin/PSR-CSR8811.psr on the system partition. debugfs
	# reads it out of the ext4 image without a mount. It is in /sbin on some
	# distributions, which is not always in PATH.
	DEBUGFS=$(command -v debugfs 2> /dev/null || true)
	for d in /sbin/debugfs /usr/sbin/debugfs; do [ -n "$DEBUGFS" ] || { [ -x "$d" ] && DEBUGFS=$d; }; done
	if [ -z "$DEBUGFS" ]; then ensure_tool debugfs e2fsprogs-extra; DEBUGFS=$(command -v debugfs); fi
	log "extracting system.img (650 MB, temporary) to read /bin/$PSR_NAME"
	unzip -p "$WORK/image.zip" system.img > "$WORK/system.img"
	rm -f "$WORK/image.zip"
	# ext4 superblock magic 0xEF53 at byte 1080 (little endian: 53 ef)
	[ "$(od -An -tx1 -j 1080 -N2 "$WORK/system.img" | tr -d ' \n')" = "53ef" ] \
		|| die "system.img is not a raw ext4 image (no superblock magic)"
	"$DEBUGFS" -R "dump /bin/$PSR_NAME $WORK/$PSR_NAME" "$WORK/system.img" > /dev/null 2>&1 || true
	rm -f "$WORK/system.img"
	[ -s "$WORK/$PSR_NAME" ] || die "system.img has no /bin/$PSR_NAME"
	got=$(sha256_of "$WORK/$PSR_NAME")
	[ "$got" = "$PSR_SHA256" ] || die "$PSR_NAME sha256 $got != pinned $PSR_SHA256 (Crestron shipped a different file. Update PSR_SHA256 here and in installer/lib/tsx-psr.sh on purpose. Do not ignore this)"
	mkdir -p "$PSR_VENDOR_LOCAL"
	install -m 644 "$WORK/$PSR_NAME" "$PSR_VENDOR_LOCAL/$PSR_NAME"
	log "done: $PSR_VENDOR_LOCAL/$PSR_NAME from the public .puf (sha256 $got, ok)"
	exit 0
fi

unzip -p "$WORK/image.zip" boot.img > "$WORK/boot.img"
rm -f "$WORK/image.zip"
[ "$(head -c 8 "$WORK/boot.img")" = "ANDROID!" ] || die "boot.img is not an Android boot image (bad magic)"

# Android v0 boot header (installer/initramfs/repack-bootimg.py has details): magic(8),
# kernel_size(4) @8, kernel_addr(4), ramdisk_size(4) @16, ramdisk_addr(4),
# second_size(4), second_addr(4), tags_addr(4), page_size(4) @36.
read_u32le() { # read_u32le OFFSET FILE
	set -- $(od -An -tu1 -j "$1" -N4 "$2")
	echo $(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))
}
KERNEL_SIZE=$(read_u32le 8 "$WORK/boot.img")
RAMDISK_SIZE=$(read_u32le 16 "$WORK/boot.img")
PAGE_SIZE=$(read_u32le 36 "$WORK/boot.img")
[ "$PAGE_SIZE" -gt 0 ] || die "boot.img: page_size read as 0 (header parse failed)"
ROUNDUP_KERNEL=$((((KERNEL_SIZE + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE))
RAMDISK_OFFSET=$((PAGE_SIZE + ROUNDUP_KERNEL))
log "boot.img: kernel_size=$KERNEL_SIZE ramdisk_size=$RAMDISK_SIZE page_size=$PAGE_SIZE ramdisk_offset=$RAMDISK_OFFSET"

# ramdisk_offset is always a multiple of page_size. So dd can read page-sized
# blocks (fast), and head -c trims the result to the exact byte count.
dd if="$WORK/boot.img" bs="$PAGE_SIZE" skip=$((RAMDISK_OFFSET / PAGE_SIZE)) 2> /dev/null \
	| head -c "$RAMDISK_SIZE" > "$WORK/ramdisk.cpio.gz"
[ "$(od -An -tx1 -N2 "$WORK/ramdisk.cpio.gz" | tr -d ' \n')" = "1f8b" ] || die "cut ramdisk is not gzip (header math is wrong)"

mkdir -p "$WORK/rd"
(cd "$WORK/rd" && gzip -dc "$WORK/ramdisk.cpio.gz" | cpio -i -d -m > /dev/null 2>&1) || true
[ -d "$WORK/rd/jabil/tfa9890" ] || die "ramdisk did not contain jabil/tfa9890 (extraction failed)"

fail=0
for v in $VARIANTS; do
	src="$WORK/rd/jabil/tfa9890/$v"
	[ -d "$src" ] || { echo "vendor-fetch: ERROR: $v not in this package's ramdisk"; fail=1; continue; }
	dst="$TFA_VENDOR_LOCAL/$v"
	mkdir -p "$dst/config"
	got=$(sha256_of "$src/stereo.cnt")
	want=$(sha_for "$v")
	if [ "$got" != "$want" ]; then
		echo "vendor-fetch: ERROR: $v/stereo.cnt sha256 $got != pinned $want (Crestron shipped a different container. Update sha_for() in this script on purpose, and do not ignore this)"
		fail=1
		continue
	fi
	install -m 644 "$src/stereo.cnt" "$dst/stereo.cnt"
	[ -r "$src/mono.cnt" ] && install -m 644 "$src/mono.cnt" "$dst/mono.cnt"
	for f in "$src"/*.ini; do [ -r "$f" ] && install -m 644 "$f" "$dst/"; done
	for f in "$src"/config/*.config; do [ -r "$f" ] && install -m 644 "$f" "$dst/config/"; done
	log "installed $v (stereo.cnt sha256 $got, ok)"
done

[ "$fail" = 0 ] || die "one or more TFA9890 variants failed verification (see above); vendor-local/tfa9890 was NOT fully updated"
log "done: $TFA_VENDOR_LOCAL now has all $(echo $VARIANTS | wc -w) variants from the public .puf"
