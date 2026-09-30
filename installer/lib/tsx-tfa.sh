# tsx-tfa.sh: find the TFA9890 speaker DSP files (.cnt containers) on the
# panel itself. Then an install does not have to download the 357 MB Crestron
# firmware package (docs/install.md "TFA9890 speaker DSP tuning").
# These files source it:
#   - installer/steps/tsx-rescue-install (the `tfa` command, in the rescue:
#     busybox ash, RAM root). It runs BEFORE anything is written to the eMMC.
#   - installer/tsx-install-mainline (host: tsx_tfa_plan only)
#   - installer/lib/tests/test-tsx-tfa.sh (host tests, synthetic files only)
# Use POSIX sh + `local`. The code reads block devices and never writes them.
# It mounts the old root read-only with `noload` (no journal replay).
#
# The sources, in order. The first source with all three variants valid wins.
#   root          the current mainline root (a reinstall):
#                 usr/local/share/tsx/tfa9890/<variant>/stereo.cnt on eMMC p8
#   android-boot  stock Android: the Android boot image in the eMMC `boot`
#                 region (p7). It has an Android v0 header and a gzip cpio
#                 ramdisk with jabil/tfa9890/<variant>/stereo.cnt. These are
#                 the same files that rootfs/vendor-fetch.sh takes out of the
#                 boot.img of the .puf.
#   earlier       files that an earlier attempt in this same rescue session
#                 already collected (a re-run after a failed install, when p7
#                 or p8 may already have new data)
# If no source is complete, the code keeps the source with the most valid
# variants. The host then decides (tsx_tfa_plan) whether to try the .puf
# download first.
#
# How tsx_tfa_validate checks each stereo.cnt:
#   sha256 = the pinned one (the same list as rootfs/vendor-fetch.sh)  -> ok
#   another sha256, but a sane NXP container ("PM" id, size field = file
#   size, 1 KiB..1 MiB, CRC32 correct when awk can compute it)
#                                   -> accepted with a warning (hash + firmware)
#   anything else                   -> rejected (the code tries the next source)
# Test hooks: TSX_TFA_PINS (a file of "variant sha256" lines, replaces the
# pinned list) and a directory as the root device (used as the mounted root).

TSX_TFA_VARIANTS="settings_yushan settings_yushan_2nd settings_yushan_3rd"
TSX_TFA_REL=usr/local/share/tsx/tfa9890

# tsx_tfa_pinned VARIANT: print the known-good sha256. It comes from the public
# Crestron tsw-xx60_3.002.1061.001 package and is identical to the Android
# vendor tree.
tsx_tfa_pinned() {
	if [ -n "${TSX_TFA_PINS:-}" ]; then
		awk -v v="$1" '$1 == v { print $2; exit }' "$TSX_TFA_PINS"
		return 0
	fi
	case $1 in
	settings_yushan) echo b479300ed44a7663afe04fd271b8e059ea4d6e1778939a18e87d004613288de8 ;;
	settings_yushan_2nd) echo fe5157aa0213b640a3e40fa4bc79ce88849b2589361079fefcfcda14b0ad0c14 ;;
	settings_yushan_3rd) echo 6d5952abe66ca83d0c08cbc77ae8e56eb95eef18e5ad6a33ed6f19f981071067 ;;
	*) return 1 ;;
	esac
}

tsx_tfa_sha256() { sha256sum < "$1" | cut -d' ' -f1; }

# tsx_tfa_u32le FILE OFFSET: print a little-endian u32 as a decimal number
tsx_tfa_u32le() {
	set -- $(od -An -v -tu1 -j "$2" -N4 "$1" 2>/dev/null)
	[ $# = 4 ] || return 1
	echo $(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))
}

# tsx_tfa_crc32 FILE SKIP: print the zlib CRC32 of FILE from byte SKIP on, as
# a decimal number. If this awk cannot compute it, return 2 and print nothing.
# This happens when awk has no and, xor and rshift functions, or when the
# result fails the "123456789" self-test.
tsx_tfa_crc32() {
	{ printf '123456789' | od -An -v -tu1; echo X; od -An -v -tu1 -j "$2" "$1"; } 2>/dev/null | awk '
	BEGIN {
		for (i = 0; i < 256; i++) {
			c = i
			for (k = 0; k < 8; k++) { if (and(c, 1)) c = xor(rshift(c, 1), 3988292384); else c = rshift(c, 1) }
			T[i] = c
		}
		crc = 4294967295; part = 0
	}
	$1 == "X" {
		if (xor(crc, 4294967295) != 3421780262) exit 2
		crc = 4294967295; part = 1; next
	}
	{ for (i = 1; i <= NF; i++) crc = xor(rshift(crc, 8), T[and(xor(crc, $i), 255)]) }
	END { if (part == 1) printf "%.0f\n", xor(crc, 4294967295) }' 2>/dev/null
	# An awk without these functions fails to parse and prints nothing.
}

# tsx_tfa_validate FILE VARIANT: print one line. Return 0 (pinned sha256),
# 1 (unknown sha256, sane container) or 2 (reject).
tsx_tfa_validate() {
	local f=$1 v=$2 size sha want id hsize hcrc crc
	[ -f "$f" ] || { echo "missing"; return 2; }
	size=$(wc -c < "$f" | tr -d ' ')
	sha=$(tsx_tfa_sha256 "$f")
	want=$(tsx_tfa_pinned "$v")
	if [ -n "$want" ] && [ "$sha" = "$want" ]; then echo "sha256 $sha (pinned)"; return 0; fi
	id=$(head -c 2 "$f")
	[ "$id" = PM ] || { echo "not an NXP container (id '$id', sha256 $sha)"; return 2; }
	[ "$size" -ge 1024 ] && [ "$size" -le 1048576 ] || { echo "implausible size $size bytes (sha256 $sha)"; return 2; }
	hsize=$(tsx_tfa_u32le "$f" 6) || { echo "unreadable header (sha256 $sha)"; return 2; }
	[ "$hsize" = "$size" ] || { echo "header size $hsize != file size $size (truncated? sha256 $sha)"; return 2; }
	hcrc=$(tsx_tfa_u32le "$f" 10)
	crc=$(tsx_tfa_crc32 "$f" 14) || crc=
	if [ -z "$crc" ]; then
		echo "sha256 $sha is NOT the pinned one. NXP container, $size bytes (CRC not checked: awk cannot)"; return 1
	fi
	[ "$crc" = "$hcrc" ] || { echo "container CRC mismatch (header $hcrc, data $crc. sha256 $sha)"; return 2; }
	echo "sha256 $sha is NOT the pinned one. Valid NXP container, $size bytes, CRC ok"
	return 1
}

# tsx_tfa_take SRCDIR OKDIR LABEL FWINFO: validate SRCDIR/<variant>/stereo.cnt
# and copy the accepted files to OKDIR/<variant>/stereo.cnt. Set TSX_TFA_N (the
# count of accepted files) and TSX_TFA_SUMS (lines "variant=sha256 pinned|unpinned").
tsx_tfa_take() {
	local src=$1 ok=$2 label=$3 fw=$4 v why rc
	TSX_TFA_N=0 TSX_TFA_SUMS=
	rm -rf "$ok"; mkdir -p "$ok"
	ls "$src"/*/stereo.cnt >/dev/null 2>&1 || return 0   # the source already printed why
	for v in $TSX_TFA_VARIANTS; do
		[ -f "$src/$v/stereo.cnt" ] || { echo "  $label: $v/stereo.cnt not there"; continue; }
		rc=0; why=$(tsx_tfa_validate "$src/$v/stereo.cnt" "$v") || rc=$?
		case $rc in
		0) echo "  $label: $v/stereo.cnt ok: $why";;
		1) echo "  $label: WARNING: $v/stereo.cnt: $why. Accepted (from firmware: ${fw:-unknown})";;
		*) echo "  $label: $v/stereo.cnt REJECTED: $why"; continue;;
		esac
		mkdir -p "$ok/$v"
		cp "$src/$v/stereo.cnt" "$ok/$v/stereo.cnt" || { echo "  $label: copy of $v failed"; continue; }
		TSX_TFA_N=$((TSX_TFA_N + 1))
		[ $rc = 0 ] && why=pinned || why=unpinned
		TSX_TFA_SUMS="$TSX_TFA_SUMS$v=$(tsx_tfa_sha256 "$ok/$v/stereo.cnt") $why
"
	done
}

# tsx_tfa_from_root DEV OUTDIR: copy the DSP files of the old root (if any) to
# OUTDIR/<variant>/stereo.cnt. The function mounts DEV ro,noload. A directory
# works as the mounted root as it is (host tests). The function also sets
# TSX_TFA_ROOT_FW (the firmware line in the SOURCE file of the old root). If
# DEV is the system partition of Android instead, it sets TSX_TFA_ANDROID (the
# build id of stock Android).
tsx_tfa_from_root() {
	local dev=$1 out=$2 m v rc=1
	TSX_TFA_ROOT_FW= TSX_TFA_ANDROID=
	mkdir -p "$out"
	if [ -d "$dev" ]; then m=$dev
	else
		m=${TSX_RUN:-/run}/tsx-tfa-oldroot; mkdir -p "$m"
		mount -t ext4 -o ro,noload "$dev" "$m" 2>/dev/null || { echo "  root: $dev does not mount as ext4"; return 1; }
	fi
	if [ -f "$m/build.prop" ]; then
		TSX_TFA_ANDROID=$(sed -n 's/^ro\.build\.display\.id=//p' "$m/build.prop" | head -n 1)
		echo "  root: $dev is stock Android's system partition (${TSX_TFA_ANDROID:-no build id}), not a mainline root"
	elif [ -d "$m/$TSX_TFA_REL" ]; then
		for v in $TSX_TFA_VARIANTS; do
			[ -f "$m/$TSX_TFA_REL/$v/stereo.cnt" ] || continue
			mkdir -p "$out/$v"; cp "$m/$TSX_TFA_REL/$v/stereo.cnt" "$out/$v/stereo.cnt" && rc=0
		done
		[ -f "$m/$TSX_TFA_REL/SOURCE" ] && TSX_TFA_ROOT_FW=$(sed -n 's/^firmware=//p' "$m/$TSX_TFA_REL/SOURCE" | head -n 1)
		[ $rc = 0 ] || echo "  root: $TSX_TFA_REL has no stereo.cnt"
	else
		echo "  root: no $TSX_TFA_REL on $dev"
	fi
	[ -d "$dev" ] || umount "$m" 2>/dev/null
	return $rc
}

# tsx_tfa_from_bootimg DEV OUTDIR: DEV holds an Android v0 boot image. Copy
# jabil/tfa9890/<variant>/stereo.cnt from its gzip cpio ramdisk to
# OUTDIR/<variant>/stereo.cnt. Set TSX_TFA_BOOT_FW from jabil/yushan_version.txt.
tsx_tfa_from_bootimg() {
	local dev=$1 out=$2 w ks rs ps off v rc=1
	TSX_TFA_BOOT_FW=
	w=$out.work; rm -rf "$w"; mkdir -p "$w/x" "$out"
	dd if="$dev" of="$w/hdr" bs=4096 count=1 2>/dev/null
	if [ "$(head -c 8 "$w/hdr" 2>/dev/null)" != "ANDROID!" ]; then
		echo "  android-boot: $dev holds no Android boot image"; rm -rf "$w"; return 1
	fi
	ks=$(tsx_tfa_u32le "$w/hdr" 8); rs=$(tsx_tfa_u32le "$w/hdr" 16); ps=$(tsx_tfa_u32le "$w/hdr" 36)
	case "$ps" in 2048|4096|8192|16384) ;; *) echo "  android-boot: page size '$ps' makes no sense"; rm -rf "$w"; return 1;; esac
	if [ -z "$ks" ] || [ -z "$rs" ] || [ "$rs" -le 0 ] || [ "$rs" -gt 67108864 ] || [ "$ks" -gt 67108864 ]; then
		echo "  android-boot: kernel/ramdisk sizes '$ks'/'$rs' make no sense"; rm -rf "$w"; return 1
	fi
	off=$((ps + (ks + ps - 1) / ps * ps))
	dd if="$dev" bs="$ps" skip=$((off / ps)) count=$(((rs + ps - 1) / ps)) 2>/dev/null | head -c "$rs" > "$w/rd.gz"
	if [ "$(od -An -tx1 -N2 "$w/rd.gz" | tr -d ' \n')" != 1f8b ]; then
		echo "  android-boot: the ramdisk is not gzip"; rm -rf "$w"; return 1
	fi
	(cd "$w/x" && gzip -dc ../rd.gz 2>/dev/null | cpio -i -d 'jabil/tfa9890/*/stereo.cnt' jabil/yushan_version.txt >/dev/null 2>&1) || true
	for v in $TSX_TFA_VARIANTS; do
		[ -f "$w/x/jabil/tfa9890/$v/stereo.cnt" ] || continue
		mkdir -p "$out/$v"; cp "$w/x/jabil/tfa9890/$v/stereo.cnt" "$out/$v/stereo.cnt" && rc=0
	done
	if [ -f "$w/x/jabil/yushan_version.txt" ]; then
		TSX_TFA_BOOT_FW="$(sed -n 's/^VERSION://p' "$w/x/jabil/yushan_version.txt" | head -n 1), boot image built $(sed -n 's/^BUILD TIME://p' "$w/x/jabil/yushan_version.txt" | head -n 1)"
	fi
	[ $rc = 0 ] || echo "  android-boot: the boot image on $dev has no jabil/tfa9890 files (not stock Android's)"
	rm -rf "$w"
	return $rc
}

# tsx_tfa_collect OUTDIR BOOTDEV ROOTDEV [EARLIERDIR]: try the sources in
# order (see the top of this file). OUTDIR gets the files of the winner and a
# SOURCE file (source=, firmware=, and one "variant=sha256 pinned|unpinned"
# line for each variant). The last line printed is
# "TFA-RESULT source=<name> count=<n>". If nothing valid is found, it says
# count 0 and source=none. The function always returns 0.
tsx_tfa_collect() {
	local out=$1 boot=$2 root=$3 earlier=${4:-} w src fw best=none bestn=0 bestfw= bestsums=
	w=$out.tmp; rm -rf "$w" "$out"; mkdir -p "$w"
	for src in root android-boot earlier; do
		fw=
		case $src in
		root)
			echo "tfa: source 1/3: the current root ($root)"
			tsx_tfa_from_root "$root" "$w/$src" || true
			fw=${TSX_TFA_ROOT_FW:-copied from the previous mainline root}
			;;
		android-boot)
			echo "tfa: source 2/3: stock Android's boot image ($boot)"
			tsx_tfa_from_bootimg "$boot" "$w/$src" || true
			fw=${TSX_TFA_BOOT_FW:-unknown}
			[ -n "${TSX_TFA_ANDROID:-}" ] && fw="$fw; Android $TSX_TFA_ANDROID"
			;;
		earlier)
			[ -n "$earlier" ] && [ -f "$earlier/SOURCE" ] || continue
			echo "tfa: source 3/3: kept from an earlier attempt in this rescue session ($earlier)"
			mkdir -p "$w/$src"; cp -r "$earlier"/settings_* "$w/$src/" 2>/dev/null || true
			fw="$(sed -n 's/^firmware=//p' "$earlier/SOURCE" | head -n 1) (source $(sed -n 's/^source=//p' "$earlier/SOURCE" | head -n 1))"
			;;
		esac
		tsx_tfa_take "$w/$src" "$w/ok-$src" "$src" "$fw"
		if [ "$TSX_TFA_N" -gt "$bestn" ]; then best=$src bestn=$TSX_TFA_N bestfw=$fw bestsums=$TSX_TFA_SUMS; fi
		[ "$TSX_TFA_N" = 3 ] && break
	done
	if [ "$bestn" -gt 0 ]; then
		mv "$w/ok-$best" "$out"
		{ echo "source=$best"; echo "firmware=$bestfw"; printf '%s' "$bestsums"; } > "$out/SOURCE"
		echo "tfa: using source '$best': $bestn of 3 variants"
	else
		echo "tfa: no valid DSP files on the panel"
	fi
	rm -rf "$w"
	echo "TFA-RESULT source=$best count=$bestn"
	return 0
}

# tsx_tfa_plan MODE PANEL_COUNT: print what the host does next (--tfa-source
# MODE). PANEL_COUNT is the number of valid variants that the rescue found, or
# "-" if nobody asked the rescue.
#   use-panel      take the files of the panel, no download
#   puf            run rootfs/vendor-fetch.sh (the .puf download) and push its files
#   puf-or-panel   try the .puf. If that fails, take the partial set of the panel
#   none           no DSP files
tsx_tfa_plan() {
	case "$1:$2" in
	none:*) echo none;;
	puf:*) echo puf;;
	panel:3|auto:3) echo use-panel;;
	panel:0|panel:-) echo none;;
	panel:*) echo use-panel;;
	auto:0|auto:-) echo puf;;
	auto:*) echo puf-or-panel;;
	*) echo none; return 1;;
	esac
}
