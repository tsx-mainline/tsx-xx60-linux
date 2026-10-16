# tsx-rescue.sh: shared code for the rescue-first installer (v2) and, later,
# tsx-restore-factory. Both drive the same rescue system (see docs/recovery.md
# "The rescue system"). These files source it:
#   - installer/steps/tsx-rescue-arm.sh   (stock Android root shell: bash 3.2 + busybox)
#   - installer/tsx-install-mainline       (host: bash)
#   - the rescue-side writer that the installer pushes to the panel (busybox ash)
# Use POSIX sh + `local` only. The same rule applies to installer/android/tsx-lib.sh.
# This file complements tsx-lib.sh, so source that file too for tsx_find_disk,
# TSX_MBR_P4_TYPE_OFFSET, tsx_env, TSX_BOOT_CMD and TSX_SWITCH_FALLBACK. On the
# rescue it is already at /usr/share/tsx/tsx-lib.sh, part of the base
# initramfs. Nothing here duplicates it.
#
# Only the functions whose names say so write anything by themselves
# (tsx_env_apply, tsx_mbr_fold, tsx_mkfs_tsxdata, tsx_conf_set_flavor,
# tsx_rootinfo_set_flavor). Every write is read back and verified before the
# function returns success. tsx-boot-ok and installer/emmc/tsx-usb-recovery
# follow the same rule.

# ---------------------------------------------------------------- pr_dd -----
# Live progress for a background dd (BusyBox dd has no status=progress).
# pr_dd DEST OFF_MIB LEN_MIB NAME -- DD_ARGS...
# Copied from installer/factory/tsx-emmc-restore (same tool, same fix for the
# ash stdin trap, see docs/recovery.md "The ash dd stdin trap"). One change:
# TSX_PR_DD_TICK sets the seconds between two progress lines (default 15), so
# the host tests do not wait 15 s for a line.
# A background job under busybox ash gets /dev/null as stdin, unless the real
# input first moves to a separate fd (7). Bash does not need this, but it does
# no harm there.
pr_dd() {
	_pd_dev=$1; _pd_off=$2; _pd_len=$3; _pd_name=$4; shift 4; [ "${1:-}" = -- ] && shift
	exec 8<>"$_pd_dev"
	exec 7<&0
	dd "$@" <&7 1>&8 2>/dev/null 7<&- 8<&- &
	_pd_dp=$!
	# A 0% line at the start, so the rescue screen never shows the bar of the
	# step before for the first tick. The file goes away at the end.
	printf '%.0f %.0f %.0f %s\n' "$((_pd_off * 1048576))" "$((_pd_off * 1048576))" "$((_pd_len * 1048576))" "$_pd_name" > "${TSX_PROGRESS_FILE:-/run/tsx-progress}" 2>/dev/null || true
	( _pd_t0=$(date +%s)
	  while kill -0 $_pd_dp 2>/dev/null; do
		_pd_i=0
		while [ $_pd_i -lt "${TSX_PR_DD_TICK:-15}" ] && kill -0 $_pd_dp 2>/dev/null; do sleep 1; _pd_i=$((_pd_i + 1)); done
		kill -0 $_pd_dp 2>/dev/null || break
		_pd_pos=$(sed -n 's/^pos:[[:space:]]*//p' "/proc/$_pd_dp/fdinfo/1" 2>/dev/null) || break
		[ -n "$_pd_pos" ] || continue
		_pd_now=$(date +%s); _pd_dt=$((_pd_now - _pd_t0)); [ $_pd_dt -lt 1 ] && _pd_dt=1
		awk -v pos="$_pd_pos" -v off="$_pd_off" -v mib=1048576 -v len="$_pd_len" -v dt="$_pd_dt" -v name="$_pd_name" 'BEGIN{
			d = (pos - off * mib) / mib; if (d < 0) d = 0;
			pct = len > 0 ? d * 100 / len : 0; rate = d / dt;
			if (rate > 0.01) {
				left = (len - d) / rate;
				if (left >= 60) printf "  %s: %.0f/%.0f MiB (%.0f%%), %.1f MiB/s, ~%.0f min left\n", name, d, len, pct, rate, left / 60;
				else printf "  %s: %.0f/%.0f MiB (%.0f%%), %.1f MiB/s, ~%.0f s left\n", name, d, len, pct, rate, left;
			} else printf "  %s: %.0f/%.0f MiB (%.0f%%), %.1f MiB/s\n", name, d, len, pct, rate;
		}' >&2
		# Numbers first, name last, because the name can contain spaces ("eMMC root").
		printf '%.0f %.0f %.0f %s\n' "$_pd_pos" "$((_pd_off * 1048576))" "$((_pd_len * 1048576))" "$_pd_name" > "${TSX_PROGRESS_FILE:-/run/tsx-progress}" 2>/dev/null || true
	  done
	) &
	_pd_rp=$!
	wait $_pd_dp; _pd_rc=$?
	# Do not kill $_pd_rp. The reporter sees the exit of dd in its own kill -0
	# check and ends itself. A stray signal to an already recycled PID must not
	# happen here (see docs/recovery.md).
	wait $_pd_rp 2>/dev/null
	rm -f "${TSX_PROGRESS_FILE:-/run/tsx-progress}" 2>/dev/null
	exec 7<&- 8<&-
	return $_pd_rc
}

# ------------------------------------------------- write and read back ------
# tsx_write_verify DEV SRC BYTES SHA256 NAME [LABEL]: write an image to the start of
# DEV with live progress (pr_dd), then read BYTES back from DEV and compare
# the sha256. SRC is a file, or "-" for stdin. With "-", the host streams the
# image over the ssh connection that it opened itself (docs/install.md
# "Network requirements"), so the panel opens no connection to the host.
# A stream that stops early (a lost connection) leaves a short write. The
# readback finds it. Run the same install command again to write it again.
# The function prints one line for the host to compare:
#   WRITE-RESULT name=NAME bytes=BYTES sha256=GOT ok=1|0
# It returns 0 only if GOT is SHA256. NAME has no spaces. LABEL (default NAME)
# names the progress lines and the rescue screen.
tsx_write_verify() {
	local dev=$1 src=$2 bytes=$3 want=$4 name=$5 label=${6:-$5} mib got ok=0
	mib=$(( (bytes + 1048575) / 1048576 ))
	if [ "$src" = - ]; then
		pr_dd "$dev" 0 "$mib" "$label" -- bs=1M conv=fsync || { echo "WRITE-RESULT name=$name bytes=$bytes sha256=none ok=0"; return 1; }
	else
		pr_dd "$dev" 0 "$mib" "$label" -- if="$src" bs=1M conv=fsync || { echo "WRITE-RESULT name=$name bytes=$bytes sha256=none ok=0"; return 1; }
	fi
	sync
	{ echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null
	got=$(dd if="$dev" bs=1M count="$mib" 2>/dev/null | head -c "$bytes" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$want" ] && ok=1
	echo "WRITE-RESULT name=$name bytes=$bytes sha256=$got ok=$ok"
	[ "$ok" = 1 ]
}

# tsx_write_result_check OUTPUT NAME SHA256: the host side of
# tsx_write_verify. True if OUTPUT (the streamed output of the rescue) has a
# WRITE-RESULT line for NAME with ok=1 and the sha256 that the host expects.
# The last line for NAME counts.
tsx_write_result_check() {
	local line
	line=$(printf '%s\n' "$1" | grep -F "WRITE-RESULT name=$2 " | tail -n 1)
	case "$line" in *"sha256=$3 ok=1"*) return 0;; *) return 1;; esac
}

# ---------------------------------------------------- verified env write ----
# tsx_env_apply CFG WANT: CFG is an fw_env.config-style line. The caller
# already wrote it to a file, e.g. "$disk $offset $size". WANT is a
# fw_setenv --script text (one "name value" per line). The function applies it
# in at most one write and verifies the result:
#   - the CRC is valid before and after
#   - every requested name has its wanted value
#   - no OTHER variable changed
# It prints what it did (or "nothing to do") and returns 0. On a failure it
# prints "ERROR: ..." and returns 1. It never exits the shell of the caller,
# so a driver can retry or report instead of dying in the middle of a transfer.
tsx_env_apply() {
	local cfg=$1 want=$2 names env0 env1 n v out lockdir=${TSX_RUN:-/run}
	local fwto=${TSX_FWENV_TIMEOUT:-10}
	local fwto_cmd=; command -v timeout >/dev/null 2>&1 && fwto_cmd="timeout -s KILL $fwto"
	# -l "$lockdir" is the same lock-directory override that
	# installer/emmc/tsx-usb-recovery uses. Host tests need it, because root on
	# the real panel can always lock /run.
	# $fwto_cmd puts a time limit on the call. On a size or file mismatch, the
	# read loop in fw_env.c of u-boot-tools spins at 100% CPU forever instead of
	# an error (see docs/boot.md "fw_printenv can hang").
	out=$($fwto_cmd fw_printenv -c "$cfg" -l "$lockdir" 2>&1) || { echo "tsx_env_apply: ERROR: fw_printenv failed or timed out after ${fwto}s: $out"; return 1; }
	echo "$out" | grep -qi 'bad crc' && { echo "tsx_env_apply: ERROR: env CRC bad ($cfg): refusing to write"; return 1; }
	env0=$out
	names=$(printf '%s\n' "$want" | awk 'NF{print $1}' | tr '\n' ' ')
	# Is it already correct?
	local ok=1
	for n in $names; do
		v=$(printf '%s\n' "$want" | awk -v n="$n" '$1==n{ $1=""; sub(/^ /,""); print; exit }')
		[ "$(printf '%s\n' "$env0" | sed -n "s/^$n=//p")" = "$v" ] || ok=0
	done
	if [ "$ok" = 1 ]; then echo "tsx_env_apply: env already matches (nothing written): $names"; return 0; fi
	local scr; scr=$(mktemp "$lockdir/tsx-env-apply.XXXXXX" 2>/dev/null) || scr=$lockdir/tsx-env-apply.$$
	printf '%s\n' "$want" > "$scr"
	$fwto_cmd fw_setenv -c "$cfg" -l "$lockdir" -s "$scr" >/dev/null 2>&1; local rc=$?
	rm -f "$scr"
	[ $rc = 0 ] || { echo "tsx_env_apply: ERROR: fw_setenv failed or timed out after ${fwto}s (wanted: $names)"; return 1; }
	env1=$($fwto_cmd fw_printenv -c "$cfg" -l "$lockdir" 2>&1) || { echo "tsx_env_apply: ERROR: fw_printenv (readback) failed or timed out after ${fwto}s: $env1"; return 1; }
	echo "$env1" | grep -qi 'bad crc' && { echo "tsx_env_apply: ERROR: env CRC bad after the write: $cfg"; return 1; }
	for n in $names; do
		v=$(printf '%s\n' "$want" | awk -v n="$n" '$1==n{ $1=""; sub(/^ /,""); print; exit }')
		[ "$(printf '%s\n' "$env1" | sed -n "s/^$n=//p")" = "$v" ] || { echo "tsx_env_apply: ERROR: readback: $n did not take"; return 1; }
	done
	set --; for n in $names; do set -- "$@" -e "^$n="; done
	[ "$(printf '%s\n' "$env0" | grep -v "$@" || true)" = "$(printf '%s\n' "$env1" | grep -v "$@" || true)" ] \
		|| { echo "tsx_env_apply: ERROR: readback: a variable other than $names changed"; return 1; }
	echo "tsx_env_apply: env updated and verified: $names"
	return 0
}

# --------------------------------------------------------------- p4 fold ----
# tsx_mbr_fold WHOLE OFFSET: change the type byte of MBR entry 4 from 0x05
# (extended: p5..p8 of Android) to 0x83 (one primary partition, tsxdata). The
# function reads the byte back and verifies it. The write is byte-identical to
# the one in installer/android/tsx-android-install.sh. It is the LAST step
# there and stays last here, so every earlier state still boots.
# If the byte is already 0x83, the function does nothing and succeeds.
tsx_mbr_fold() {
	local whole=$1 off=$2 cur
	cur=$(od -An -tx1 -j "$off" -N 1 "$whole" 2>/dev/null | tr -d ' ')
	case "$cur" in
	83) echo "tsx_mbr_fold: MBR entry 4 already 0x83 ($whole+$off)"; return 0;;
	05) ;;
	*) echo "tsx_mbr_fold: ERROR: MBR entry 4 type is 0x$cur at $whole+$off, expected 05 or 83"; return 1;;
	esac
	printf '\203' | dd of="$whole" bs=1 seek="$off" count=1 conv=notrunc 2>/dev/null || { echo "tsx_mbr_fold: ERROR: write failed"; return 1; }
	sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	cur=$(od -An -tx1 -j "$off" -N 1 "$whole" 2>/dev/null | tr -d ' ')
	[ "$cur" = 83 ] || { echo "tsx_mbr_fold: ERROR: readback is 0x$cur, not 0x83"; return 1; }
	echo "tsx_mbr_fold: MBR entry 4 = 0x83 ($whole+$off)"
	return 0
}

# tsx_mkfs_tsxdata DEV UUID: run the exact mke2fs command that
# rootfs/initramfs/overlay/usr/sbin/tsx-autoinstall uses to format the tsxdata
# partition of the card. Keep it identical, so a v2 install and an old
# card-stage install produce the same on-disk feature set byte for byte. The
# stale-label trap in docs/recovery.md is about exactly this. A later tool must
# tell "this is MY tsxdata" from an older one by UUID, not just by label.
tsx_mkfs_tsxdata() {
	local dev=$1 uuid=$2
	mkfs.ext4 -F -q -O ^metadata_csum_seed,^orphan_file -L tsxdata -m 1 -U "$uuid" "$dev"
}

# tsx_tsxdata_keepable DEV: can a reinstall keep DEV as it is (docs/install.md
# "Reinstalling or updating a mainline panel")? The function is read-only:
# e2fsck -n never writes. -f makes a full check, not just a look at the
# "clean" flag of the superblock. That takes a few seconds to a minute on a
# used 2.9 GiB tsxdata. It prints one line with the reason and returns:
#   0  ext4, LABEL=tsxdata, e2fsck -fn clean: keep it
#   1  not a tsxdata ext4 at all (never formatted, Android data, a stale fold)
#   2  a tsxdata ext4, but e2fsck -fn reports problems. The file system can
#      also be unclean because it was not unmounted, as -n does not replay the
#      journal. The caller may repair it with e2fsck -fp and ask again.
# The label and type come from the plain blkid output. Busybox and util-linux
# both print it as `DEV: LABEL="x" UUID="y" TYPE="z"`. Busybox ignores -s and
# -o (see etc/init.d/tsx-data of tsx-linux-common).
tsx_tsxdata_keepable() {
	local dev=$1 id label type rc
	id=$(blkid "$dev" 2>/dev/null) || id=
	label=$(printf '%s\n' "$id" | sed -n 's/.* LABEL="\([^"]*\)".*/\1/p')
	type=$(printf '%s\n' "$id" | sed -n 's/.* TYPE="\([^"]*\)".*/\1/p')
	if [ "$type" != ext4 ] || [ "$label" != tsxdata ]; then
		echo "not a tsxdata ext4 (TYPE=${type:-none} LABEL=${label:-none})"; return 1
	fi
	e2fsck -fn "$dev" >/dev/null 2>&1; rc=$?
	[ "$rc" = 0 ] || { echo "ext4 LABEL=tsxdata, but e2fsck -fn reports problems (exit $rc)"; return 2; }
	echo "ext4 LABEL=tsxdata, e2fsck -fn clean"
	return 0
}

# tsx_conf_set_flavor FILE FLAVOR: set KERNEL_FLAVOR in a kept panel.conf (the
# KEY="value" format that tsx-config writes). It does not use tsx-config,
# because the rescue does not have it. Any other line stays as it is.
tsx_conf_set_flavor() {
	local f=$1 v=$2
	case "$v" in lts|stable) ;; *) return 0;; esac
	[ -f "$f" ] || return 0
	if grep -q '^KERNEL_FLAVOR=' "$f"; then
		sed -i "s/^KERNEL_FLAVOR=.*/KERNEL_FLAVOR=\"$v\"/" "$f"
	else
		printf 'KERNEL_FLAVOR="%s"\n' "$v" >> "$f"
	fi
}

# tsx_rootinfo_set_flavor FILE FLAVOR: set kernel_flavor= in the
# /etc/tsx/emmc-root.info of a NEW root to FLAVOR. The file uses the own
# key=value format of mk-tsxroot-emmc.sh, with no quotes. FLAVOR is the flavor
# that the manifest of this install bundle names (installer/emmc/mk-v2-bundle.sh).
# It is the boot image that the installer writes to the boot partition now.
# Every install runs this, fresh or reinstall. Without it, kernel_flavor= in
# emmc-root.info only shows the --flavor that mk-tsxroot-emmc.sh got when it
# built the root image at payload time. That can differ from the flavor the
# installer actually selects, if a wrong image was ever paired into a bundle.
# The tsx-kernel-flavor package hook falls back to this field when KERNEL_FLAVOR
# in panel.conf is unset. A stale or wrong value here would silently steer the
# next kernel package upgrade onto the wrong flavor. The function does nothing
# for a value other than lts or stable. It creates etc/tsx/ if the image
# lacks it.
tsx_rootinfo_set_flavor() {
	local f=$1 v=$2
	case "$v" in lts|stable) ;; *) return 0;; esac
	mkdir -p "$(dirname "$f")"
	if [ -f "$f" ] && grep -q '^kernel_flavor=' "$f"; then
		sed -i "s/^kernel_flavor=.*/kernel_flavor=$v/" "$f"
	else
		echo "kernel_flavor=$v" >> "$f"
	fi
}

# ------------------------------------------------------- golden slot -------
# tsx_golden_update: in the rescue after a reinstall arm, copy p1:tsxboot.img
# (the rescue that just booted) to the golden slot p1:boot.img, so later
# recovery (tsx-restore-factory, docs/recovery.md) uses this version. The copy
# is verified. If p1 is too full for a side copy, the copy replaces the old
# file in place. Needs tsx_find_disk (tsx-lib.sh). Returns 1 on a failure.
tsx_golden_update() {
	local m t g rc=0 free need
	tsx_find_disk || { echo "no card found"; return 1; }
	m=${TSX_RUN:-/run}/tsx-p1g; mkdir -p "$m"; mount -t vfat "$P1" "$m" || { echo "cannot mount $P1"; return 1; }
	t=$(sha256sum < "$m/tsxboot.img" | cut -d" " -f1); g=; [ -f "$m/boot.img" ] && g=$(sha256sum < "$m/boot.img" | cut -d" " -f1)
	if [ "$t" = "$g" ]; then echo "golden p1:boot.img is already this rescue"
	else
		free=$(df -k "$m" | awk 'NR==2{print $4}'); need=$(( $(stat -c %s "$m/tsxboot.img") / 1024 + 256 ))
		if [ "$free" -gt "$need" ]; then cp "$m/tsxboot.img" "$m/boot.new"; sync
			if [ "$(sha256sum < "$m/boot.new" | cut -d" " -f1)" = "$t" ]; then mv "$m/boot.new" "$m/boot.img"; else rm -f "$m/boot.new"; echo "copy corrupt"; rc=1; fi
		else rm -f "$m/boot.img"; sync; cp "$m/tsxboot.img" "$m/boot.img"; sync
			[ "$(sha256sum < "$m/boot.img" | cut -d" " -f1)" = "$t" ] || { echo "copy corrupt"; rc=1; }
		fi
		[ $rc = 0 ] && echo "golden p1:boot.img = rescue $t"
	fi
	sync; umount "$m"; return $rc
}

# tsx_p1_rescue DIR IMG: put the rescue image IMG into the golden slot
# DIR/boot.img and the hook target DIR/tsxboot.img (DIR: the mounted p1), as
# the arm step does (installer/steps/tsx-rescue-arm.sh). Each copy goes to a
# .new file first and is verified before the rename. If p1 has no room for a
# side copy, the old file goes first. installer/steps/tsx-rescue-staged uses
# it for an install from a USB stick. Returns 1 on a failure.
tsx_p1_rescue() {
	local d=$1 img=$2 want f free need
	want=$(sha256sum < "$img" | cut -d' ' -f1)
	need=$(( $(tsx_dev_bytes "$img") / 1024 + 256 ))
	for f in boot tsxboot; do
		if [ -f "$d/$f.img" ] && [ "$(sha256sum < "$d/$f.img" | cut -d' ' -f1)" = "$want" ]; then echo "p1:$f.img is already this rescue"; continue; fi
		rm -f "$d/$f.new"
		free=$(df -Pk "$d" | awk 'NR==2{print $4}')
		[ "${free:-0}" -gt "$need" ] || { rm -f "$d/$f.img"; sync; }
		cp "$img" "$d/$f.new" && sync || { rm -f "$d/$f.new"; echo "p1:$f.img: copy failed"; return 1; }
		[ "$(sha256sum < "$d/$f.new" | cut -d' ' -f1)" = "$want" ] || { rm -f "$d/$f.new"; echo "p1:$f.img: copy corrupt"; return 1; }
		mv "$d/$f.new" "$d/$f.img" && sync || return 1
		echo "p1:$f.img = rescue $want"
	done
	return 0
}

# ------------------------------------------- the old root file system ------
# The eMMC root region of mainline (p8, blkdevparts) starts at 796 MiB. The
# stock Android system partition starts 8 MiB later, at 804 MiB (the table of
# U-Boot, docs/boot.md), so on a panel with stock Android, p8 holds 8 MiB of
# zeros and then the Android ext4. A mainline root starts at the first byte of
# p8. These functions find the ext4 file system in a small window at the start
# of the region and give a device that mounts it. They only read DEV, and the
# loop device is read-only.

# tsx_le_uint FILE POS LEN: print the unsigned little-endian number of LEN
# bytes at byte POS of FILE.
tsx_le_uint() {
	local v=0 m=1 b
	for b in $(od -An -tu1 -j "$2" -N "$3" "$1"); do v=$((v + b * m)); m=$((m * 256)); done
	echo "$v"
}

# tsx_dev_bytes DEV: print the size of a block device or a file in bytes.
tsx_dev_bytes() {
	local n
	if [ -b "$1" ]; then
		n=$(readlink -f "$1"); n=${n##*/}
		echo $(( $(cat "/sys/class/block/$n/size" 2>/dev/null || echo 0) * 512 ))
	else
		wc -c < "$1" | tr -d ' '
	fi
}

# tsx_ext4_at DEV OFFSET [SIZE]: return 0 if a primary ext4 superblock is at
# OFFSET + 1024 of DEV (OFFSET in bytes, a multiple of 1024). The checks: the
# magic 0xEF53, block group 0 (a backup superblock has another group number,
# for example the one of a 1 KiB-block file system 8 MiB after its start),
# a block size of 1 KiB to 64 KiB, and with SIZE (the size of DEV) a file
# system that fits in DEV after OFFSET.
tsx_ext4_at() {
	local sb=${TSX_RUN:-/run}/tsx-ext4-sb.$$ magic grp lbs blocks rc=1
	dd if="$1" of="$sb" bs=1024 skip=$(($2 / 1024 + 1)) count=1 2>/dev/null
	if [ "$(wc -c < "$sb" 2>/dev/null | tr -d ' ')" = 1024 ]; then
		magic=$(tsx_le_uint "$sb" 56 2); grp=$(tsx_le_uint "$sb" 90 2)
		lbs=$(tsx_le_uint "$sb" 24 4); blocks=$(tsx_le_uint "$sb" 4 4)
		if [ "$magic" = 61267 ] && [ "$grp" = 0 ] && [ "$lbs" -le 6 ] && [ "$blocks" -gt 0 ]; then
			if [ -z "${3:-}" ] || [ $((blocks * (1024 << lbs))) -le $(($3 - $2)) ]; then rc=0; fi
		fi
	fi
	rm -f "$sb"
	return $rc
}

# tsx_ext4_find DEV [MAX_MIB]: print the byte offset of the first ext4 file
# system in DEV at 0, 1, 2 ... MAX_MIB MiB (default TSX_EXT4_SCAN_MIB or 32).
# Return 1 if there is none.
tsx_ext4_find() {
	local dev=$1 max=${2:-${TSX_EXT4_SCAN_MIB:-32}} size i=0
	size=$(tsx_dev_bytes "$dev")
	[ "${size:-0}" -gt 0 ] || return 1
	while [ $i -le "$max" ]; do
		[ $((i * 1048576 + 2048)) -le "$size" ] || break
		tsx_ext4_at "$dev" $((i * 1048576)) "$size" && { echo $((i * 1048576)); return 0; }
		i=$((i + 1))
	done
	return 1
}

# tsx_ext4_open DEV: find the ext4 file system in DEV (tsx_ext4_find). Print
# DEV when it starts at byte 0, else attach a read-only loop device at the
# offset and print the loop device. Close the loop device with
# tsx_ext4_close. Return 1 and print nothing if DEV has no ext4 file system
# in the window. A note on stderr names the offset when it is not 0.
tsx_ext4_open() {
	local off l
	off=$(tsx_ext4_find "$1") || return 1
	[ "$off" = 0 ] && { echo "$1"; return 0; }
	l=$(losetup -f 2>/dev/null) && [ -n "$l" ] || { echo "ext4: no free loop device for $1 at $((off / 1048576)) MiB" >&2; return 1; }
	losetup -r -o "$off" "$l" "$1" 2>/dev/null || { echo "ext4: losetup -r -o $off $l $1 failed" >&2; return 1; }
	echo "ext4: the file system of $1 starts at $((off / 1048576)) MiB: read-only loop device $l" >&2
	echo "$l"
}

# tsx_ext4_close DEV OPENED: detach OPENED if tsx_ext4_open made it (it
# differs from DEV). Only that one loop device.
tsx_ext4_close() {
	[ -n "${2:-}" ] && [ "$2" != "$1" ] || return 0
	losetup -d "$2" 2>/dev/null || true
}

# ------------------------------------------------------- rescue discovery ---
# Adapted from installer/tsx-restore-factory. It has the same problem: the
# eth0 MAC of the rescue is random, unless the U-Boot ethaddr fix already
# applied (see docs/recovery.md "Random MAC in the rescue, and the fix"). The
# functions are POSIX and take parameters (no globals), so the v2 driver and,
# later, a rewritten tsx-restore-factory can call them directly.

# ssh_server_id HOST: print the SSH identification line of HOST (e.g.
# SSH-2.0-dropbear, SSH-2.0-OpenSSH_..., SSH-2.0-CrestronSSH), or nothing. The
# function does not try a login. The Crestron sshd sends its line only after
# the client sends one, so the function sends one first.
ssh_server_id() {
	timeout 3 bash -c "exec 3<>/dev/tcp/$1/22 && printf 'SSH-2.0-tsx-probe\r\n' >&3 && head -c 64 <&3" 2>/dev/null \
		| tr -d '\r\0' | head -n 1
}
# is_crestron_sshd HOST: true if HOST runs the Crestron sshd of stock Android.
# Never try a root/password login there. Every failed login counts. After 3
# (the default of SETLOGINATTEMPTS in Crestron) the sshd blocks the source IP
# for 24 hours (SETLOCKOUTTIME). That also blocks steps/rootsh from that host.
is_crestron_sshd() {
	case "$(ssh_server_id "$1")" in *CrestronSSH*) return 0;; *) return 1;; esac
}

# android_went_down HOST SECONDS: true once HOST stops answering as the
# Crestron sshd of stock Android (it is rebooting). False if it still answers
# after SECONDS. The function does not try a login. Test hook: TSX_POLL_S
# (default 5).
android_went_down() {
	local t0 now
	t0=$(date +%s)
	while is_crestron_sshd "$1"; do
		now=$(date +%s)
		[ $((now - t0)) -lt "$2" ] || return 1
		sleep "${TSX_POLL_S:-5}"
	done
	return 0
}

# tsx_rescue_ssh PW ARGS...: ssh to the rescue. The rescue has no fixed password:
# it takes the root password or the SSH key of the panel, or a one-time password
# that only the panel screen shows (docs/recovery.md "Rescue login"). With a
# PW, the call uses it (sshpass). With no PW, it uses your SSH key and never
# asks for a password.
tsx_rescue_ssh() {
	local pw=$1; shift
	if [ -n "$pw" ]; then SSHPASS=$pw sshpass -e ssh "$@"; else ssh -o BatchMode=yes "$@"; fi
}
# tsx_rescue_ssh_cur ARGS...: the same, with the password in $RESCUE_SSH_PW. A
# command string that holds this function name keeps the password out of it.
tsx_rescue_ssh_cur() { tsx_rescue_ssh "${RESCUE_SSH_PW:-}" "$@"; }

# tsx_tar_c ARGS...: tar with the owner root:root in the archive when the tar of
# the host can (GNU tar). busybox tar has no --owner (the installer runs on any
# Linux machine with bash, docs/install.md "Host requirements"). Its archive
# keeps the numeric owner, and the rescue extracts as root anyway.
tsx_tar_c() { if tar --help 2>&1 | grep -q -- '--owner='; then tar --owner=0 --group=0 "$@"; else tar "$@"; fi; }

# The cipher order for the ssh streams into the rescue. Its dropbear takes the
# first one that it supports. It has no GCM. chacha20-poly1305 is the fastest
# one there (4.5 MiB/s on the TSS-10, aes128-ctr 3.1 MiB/s), faster than the
# eMMC write (3.3 to 4.0 MiB/s). See docs/install.md "Network requirements".
# TSX_SSH_CIPHERS replaces the list.
TSX_SSH_CIPHERS_DEFAULT=chacha20-poly1305@openssh.com,aes128-gcm@openssh.com,aes128-ctr,aes256-ctr

# tsx_push_dir SRC DEST [--keep "NAMES"] SSH...: copy the host directory SRC
# to DEST on the rescue as one tar stream over the ssh command SSH... (for
# example tsx_rescue_ssh_cur -o ... root@IP). The host opens the connection,
# so the panel needs no connection to the host. SRC must have a SHA256SUMS
# file. The rescue checks every file against it before it replaces DEST.
# A symbolic link in SRC goes as the file that it points to (tar -h), so a
# caller can send a selection of files from another directory.
# --keep moves the named entries of the old DEST into the new one, if the new
# one does not have them. The install bundle keeps tfa, psr and ledstock this
# way: a run again in the same rescue session (a resume) finds the files of
# the earlier attempt there, after the earlier attempt wrote over the old
# root.
# Progress: in the rescue, the receiver registers on the rescue screen
# (tsx-rescue-status): it writes "PID OP" to /run/tsx-op, the state
# "receiving LABEL from the host: N of T MiB" to /run/tsx-install-state and
# the bytes to /run/tsx-progress (the format of pr_dd) about every second.
# TSX_PUSH_OP (default "install") and TSX_PUSH_LABEL (default "the install
# files") set the words. On a running kiosk (no rescue screen) the receiver
# writes the progress to the system log (logger -t tsx-install) instead. For
# a push of TSX_PUSH_PROGRESS_MIB (default 32) MiB or more, it also prints a
# progress line every TSX_PR_DD_TICK (default 15) seconds. It prints "pushed
# DEST: N files, sha256 checked", or the failed files. Use it on the host only
# (it needs a shell with pipefail for the tar status). Test hook:
# TSX_PUSH_SCREEN=1 writes the screen files on a host with no rescue image.
tsx_push_dir() {
	local src=$1 dest=$2 keep= k mv= totalb totalm print=0 op=${TSX_PUSH_OP:-install} label=${TSX_PUSH_LABEL:-the install files} r; shift 2
	[ "${1:-}" = --keep ] && { keep=$2; shift 2; }
	[ -f "$src/SHA256SUMS" ] || { echo "tsx_push_dir: $src has no SHA256SUMS"; return 1; }
	case "$op$label" in *[\'\"\\\$\`]*) echo "tsx_push_dir: no quotes or \$ in TSX_PUSH_OP or TSX_PUSH_LABEL"; return 1;; esac
	for k in $keep; do mv="$mv [ -e '$dest/$k' ] && [ ! -e '$dest.new/$k' ] && mv '$dest/$k' '$dest.new/$k' && echo 'kept $dest/$k from an earlier attempt';"; done
	totalb=$(find -L "$src" -type f -exec stat -L -c %s {} + | awk '{s += $1} END {print s + 0}')
	totalm=$(( (totalb + 1048575) / 1048576 ))
	[ "$totalm" -lt "${TSX_PUSH_PROGRESS_MIB:-32}" ] || print=1
	# The receiver. @X@ are filled in below. The reporter stops by itself when
	# the marker file exists. It is never killed (see pr_dd).
	r='D=@DEST@; R=${TSX_RUN:-/run}; P=${TSX_PROGRESS_FILE:-$R/tsx-progress}; L="@LABEL@"
scr=0; { [ -f /etc/tsx/rescue-image ] || [ -n "${TSX_PUSH_SCREEN:-}" ]; } && scr=1
st() { [ $scr = 1 ] && printf "%s\n" "$1" > "$R/tsx-install-state" 2>/dev/null; :; }
rm -rf "$D.new" "$D.new.done" && mkdir -p "$D.new" || exit 1
[ $scr = 1 ] && echo "$$ @OP@" > "$R/tsx-op" 2>/dev/null
st "receiving $L from the host: 0 of @TOTALM@ MiB"
( i=0; while [ ! -e "$D.new.done" ]; do sleep 1; i=$((i + 1))
	n=$(du -sk "$D.new" 2>/dev/null | cut -f1); n=${n:-0}; m=$((n / 1024))
	[ $scr = 1 ] && { printf "%s 0 %s %s\n" $((n * 1024)) @TOTALB@ "$L" > "$P" 2>/dev/null; st "receiving $L from the host: $m of @TOTALM@ MiB"; }
	[ $((i % @TICK@)) = 0 ] || continue
	line="push $D: $m/@TOTALM@ MiB ($((m * 100 / @TOTALMD@))%), $i s"
	[ @PRINT@ = 1 ] && echo "  $line"
	[ $scr = 1 ] || logger -t tsx-install "$line" 2>/dev/null
  done ) &
tar -xf - -C "$D.new"; rc=$?; : > "$D.new.done"; wait; rm -f "$D.new.done"
[ $rc = 0 ] || { echo "tar stream FAILED"; st "failed: receiving $L from the host (the stream stopped)"; exit 1; }
cd "$D.new" || exit 1
sha256sum -c SHA256SUMS > ../.tsx-sumcheck 2>&1 || { grep -v ": OK$" ../.tsx-sumcheck; echo "sha256 check FAILED"; st "failed: $L from the host: sha256 check"; exit 1; }
cd / && { @MV@ true; } && rm -rf "$D" && mv "$D.new" "$D" || { st "failed: $L: cannot replace $D"; exit 1; }
st "idle: received $L"
[ $scr = 1 ] || logger -t tsx-install "push $D: complete, sha256 checked" 2>/dev/null
echo "pushed $D: $(wc -l < "$D/SHA256SUMS") files, sha256 checked"'
	# A quoted replacement: bash 5.2 reads "&" in an unquoted one as the match.
	r=${r//@DEST@/"'$dest'"}; r=${r//@LABEL@/"$label"}; r=${r//@OP@/"$op"}
	r=${r//@TOTALB@/"$totalb"}; r=${r//@TOTALMD@/"$(( totalm > 0 ? totalm : 1 ))"}; r=${r//@TOTALM@/"$totalm"}
	r=${r//@TICK@/"${TSX_PR_DD_TICK:-15}"}; r=${r//@PRINT@/"$print"}; r=${r//@MV@/"$mv"}
	tsx_tar_c -h -C "$src" -cf - . | "$@" "$r"
}

# tsx_push_bundle SRC DEST SSH...: push the files that SRC/SHA256SUMS lists,
# and SHA256SUMS itself, to DEST on the rescue (tsx_push_dir). Other files in
# SRC stay on the host. The old DEST goes first, so the rescue RAM holds one
# copy only. tsx-restore-factory sends its factory bundle this way.
tsx_push_bundle() {
	local src=$1 dest=$2 st f rc; shift 2
	[ -f "$src/SHA256SUMS" ] || { echo "tsx_push_bundle: $src has no SHA256SUMS"; return 1; }
	st=$(mktemp -d) || return 1
	src=$(cd "$src" && pwd)
	ln -s "$src/SHA256SUMS" "$st/SHA256SUMS"
	for f in $(awk '{sub(/^\*/, "", $2); print $2}' "$src/SHA256SUMS"); do
		case "$f" in */*|..|.) echo "tsx_push_bundle: $f: only plain file names are supported"; rm -rf "$st"; return 1;; esac
		[ -f "$src/$f" ] || { echo "tsx_push_bundle: $src/$f is missing"; rm -rf "$st"; return 1; }
		ln -s "$src/$f" "$st/$f"
	done
	"$@" "rm -rf '$dest' '$dest.new'" </dev/null || { echo "tsx_push_bundle: could not remove the old $dest"; rm -rf "$st"; return 1; }
	tsx_push_dir "$st" "$dest" "$@"; rc=$?
	rm -rf "$st"
	return $rc
}

# ssh_test_rescue HOST PW: true if HOST answers ssh as the rescue. If HOST runs
# the Crestron sshd, the function does not try a login (see is_crestron_sshd).
ssh_test_rescue() {
	is_crestron_sshd "$1" && return 1
	tsx_rescue_ssh "$2" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
		"root@$1" 'test -f /etc/tsx/rescue-image' >/dev/null 2>&1
}

# find_rescue_by_mac MAC PREFIX: sweep PREFIX.0/24 (with fping if present, else
# with a bounded parallel ping). Then print an IP whose MAC in `ip neigh`
# matches, or nothing.
find_rescue_by_mac() {
	local mac=$1 prefix=$2
	if command -v fping >/dev/null 2>&1; then fping -a -q -r0 -t200 -g "${prefix}.1" "${prefix}.254" >/dev/null 2>&1 || true
	else seq 1 254 | xargs -P 64 -I{} ping -c1 -W1 -q "${prefix}.{}" >/dev/null 2>&1 || true
	fi
	ip neigh | awk -v m="$mac" 'BEGIN{m=tolower(m)} tolower($0) ~ m {print $1; exit}'
}

# find_rescue_by_env MAC PREFIX PW: the rescue sets its eth0 MAC from ethaddr
# in the U-Boot env when a card is present and readable (docs/recovery.md
# "the rescue image itself now sets eth0's MAC from ... ethaddr"). Not every
# image in the field does this yet. For those images, match by the live env of
# the card instead of eth0. Try every dropbear host on PREFIX.0/24. Accept the
# host whose card env (1 MiB offset) has ethaddr = MAC.
find_rescue_by_env() {
	local mac=$1 prefix=$2 pw=$3 ip e
	for ip in $(ip neigh | awk -v p="$prefix." 'index($1, p) == 1 && $0 ~ /lladdr/ {print $1}'); do
		case "$(timeout 2 bash -c "exec 3<>/dev/tcp/$ip/22 && head -c 64 <&3" 2>/dev/null | tr -d '\r\0' | head -n 1)" in *dropbear*) ;; *) continue;; esac
		e=$(tsx_rescue_ssh "$pw" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 "root@$ip" \
			'test -f /etc/tsx/rescue-image && dd if=/dev/mmcblk0 bs=65536 skip=16 count=1 2>/dev/null | tr "\0" "\n" | sed -n "s/^ethaddr=//p"' 2>/dev/null | head -n 1)
		[ -n "$e" ] && [ "$(echo "$e" | tr 'A-F' 'a-f')" = "$(echo "$mac" | tr 'A-F' 'a-f')" ] && { echo "$ip"; return 0; }
	done
	return 1
}

# wait_for_rescue KIOSK_IP MAC WSIP PW TIMEOUT_S: print the IP of the rescue
# once found. After TIMEOUT_S, print nothing and return non-zero. Every ~10 s
# the function tries the IP of the kiosk first. That is the usual case with a
# DHCP reservation, because the rescue takes the MAC of eth0 from ethaddr in
# the env. Then it sweeps the /24 of the panel by MAC. The sweep reads MACs
# from `ip neigh`, so it works only when that /24 is on-link. Through a router
# or a VPN (`ip route get` shows "via", or the source address is in another
# /24), the function tries only the kiosk IP. Heartbeat lines go to stderr
# (stdout is the answer).
wait_for_rescue() {
	local kiosk_ip=$1 mac=$2 wsip=$3 pw=$4 timeout=$5 prefix w=0 cand t0 sweep=1 where
	prefix=$(echo "$kiosk_ip" | cut -d. -f1-3)
	if ip route get "$kiosk_ip" 2>/dev/null | grep -q ' via ' || [ "$(echo "$wsip" | cut -d. -f1-3)" != "$prefix" ]; then
		sweep=0; where="$prefix.0/24 is not on-link from $wsip: no MAC sweep"
	else where="MAC $mac on $prefix.0/24"
	fi
	t0=$(date +%s)
	while [ $w -lt "$timeout" ]; do
		if ssh_test_rescue "$kiosk_ip" "$pw"; then echo "$kiosk_ip"; return 0; fi
		if [ $sweep = 1 ]; then
			cand=$(find_rescue_by_mac "$mac" "$prefix")
			if [ -n "$cand" ] && ssh_test_rescue "$cand" "$pw"; then echo "$cand"; return 0; fi
			cand=$(find_rescue_by_env "$mac" "$prefix" "$pw")
			[ -n "$cand" ] && { echo "$cand"; return 0; }
		fi
		sleep 10; w=$(( $(date +%s) - t0 ))
		echo "  still looking for the rescue (ssh at $kiosk_ip; $where): ${w}/${timeout} s" >&2
	done
	return 1
}
