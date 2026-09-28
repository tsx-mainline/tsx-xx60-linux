# tsx-lib.sh: shared code for the xx60 installers.
# Sourced by tsx-android-install.sh / tsx-android-uninstall.sh (stock Android
# root shell: /system/bin/bash 3.2 + /system/bin/busybox) and by
# tsx-autoinstall (mainline initramfs: busybox ash). POSIX sh + `local` only.
#
# Nothing in this file writes anything. Writers are in the callers.
#
# Test hooks (host tests only; never set them on a panel):
#   TSX_SYSBLOCK  sysfs dir of the boot disk   (default: autodetect /sys/block/mmcblk*)
#   TSX_DEVDIR    dir of the block device nodes (default /dev/block on Android, /dev elsewhere)
#   TSX_BB        busybox binary                (default /system/bin/busybox, else busybox in PATH)
#   TSX_FWENV     fw_printenv binary            (default /system/bin/fw_printenv, else in PATH)

# ---- the Crestron MBR layout, as shipped from the factory (the Crestron MBR
# layout notes, from the 2026-09-25 backup) ----
# p1 FAT16 golden boot.img, p2 ext4 golden /system, p3 U-Boot env (raw, at 1 MiB),
# p4 extended, p5 ext2 "sdcard" (now tsxroot), p6 data, p7 cache, p8 logs.
TSX_LAYOUT_STOCK="1:81920:81920 2:206849:1638400 3:2048:2048 4:1845249:- 5:1847297:3055616 6:4904961:1024000 7:5931009:204800 8:6137857:614400"
# The card stage (the fixed layout the installer converts every unit to): the
# same MBR with ONE byte changed, entry 4 type 0x05 (extended: p5..p8 =
# Android sdcard/data/cache/logs) -> 0x83: p4 = one primary partition over the
# old extended area (tsxdata), p2 = the kiosk rootfs. The logical partitions
# p5..p8 are gone. This is a temporary step inside tsx-install-mainline: the
# panel then migrates from here onto the eMMC (boot p7 + root p8).
TSX_LAYOUT_CARD="1:81920:81920 2:206849:1638400 3:2048:2048 4:1845249:5928959"
TSX_MBR_P4_TYPE_OFFSET=498   # 446 + 3*16 + 4
TSX_P5_SECTORS=3055616
TSX_ENV_OFFSET=1048576      # 0x100000 on the whole disk (= start of p3), proven in rootfs
TSX_ENV_SIZE=65536

# ---- the U-Boot env hook (rootfs/uboot/tsx-boot-hook.txt, installed on the TSW-1060) ----
TSX_STOCK_SWITCH='usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;'
TSX_BOOT_CMD='mmcinfo; if fatexist mmc 0 tsxboot.off; then echo tsx: mainline disabled; else if fatexist mmc 0 tsxboot.img; then echo tsx: booting tsxboot.img; fatload mmc 0 ${loadaddr} tsxboot.img; bootm; fi; fi'
# guard "fallback" (tested on hardware 2026-09-26): after 5 boots without
# tsx-boot-ok, U-Boot skips the hook and boots stock Android.
TSX_SWITCH_FALLBACK="${TSX_STOCK_SWITCH}"'if itest ${boot_retry} -lt 6; then run tsx_boot; fi'
# guard "nogolden" (NOT tested on hardware): also runs
# the hook when boot_retry > 9, so U-Boot never reaches the golden (factory
# recovery) image, which formats p5 and wipes /data.
TSX_SWITCH_NOGOLDEN="${TSX_STOCK_SWITCH}"'if itest ${boot_retry} -lt 6 || itest ${boot_retry} -gt 9; then run tsx_boot; fi'
# guard "once" (tested on hardware 2026-09-27, tsx-rescue-arm.sh's default):
# a TRUE one-shot, gated on tsx_once instead of boot_retry. U-Boot clears
# tsx_once (setenv 0; saveenv) BEFORE running tsx_boot, so the shot is spent
# the instant this line is reached -- whether or not tsxboot.img is present,
# and whether or not the rescue it boots ever checks in. With tsx_once unset
# or 0 the hook does nothing and stock bootcmd runs (see docs/boot.md "The v2
# env state machine"). boot_retry plays no part in this guard.
TSX_SWITCH_ONCE="${TSX_STOCK_SWITCH}"'if itest ${tsx_once} -eq 1; then setenv tsx_once 0; saveenv; run tsx_boot; fi'

# ---- tools ----
tsx_pick_bb() {
	if [ -n "${TSX_BB:-}" ]; then BB=$TSX_BB
	elif [ -x /system/bin/busybox ]; then BB=/system/bin/busybox
	elif [ -x /system/xbin/busybox ]; then BB=/system/xbin/busybox
	else BB=$(command -v busybox 2>/dev/null || true); fi
	[ -n "$BB" ] && [ -x "$BB" ]
}
# Every tool below runs as a busybox applet, never as the Android toolbox
# version that shadows it in PATH (toolbox dd/mount/cat behave differently).
# tests/check-applets.sh checks this list against the busybox in system.img.
TSX_APPLETS="awk basename cat chmod cmp cp cut date dd df dirname find grep gunzip head id ls mkdir mount mv od readlink rm sed sha256sum sleep sort stat sync tail tee touch tr umount uname wc zcat"
tsx_wrap_applets() {
	local a
	for a in $TSX_APPLETS; do eval "$a() { \"\$BB\" $a \"\$@\"; }"; done
}
tsx_pick_fwenv() {
	if [ -n "${TSX_FWENV:-}" ]; then FWP=$TSX_FWENV
	elif [ -x /system/bin/fw_printenv ]; then FWP=/system/bin/fw_printenv
	else FWP=$(command -v fw_printenv 2>/dev/null || true); fi
	FWS=$(dirname "$FWP")/fw_setenv
	[ -n "$FWP" ] && [ -x "$FWP" ] && [ -x "$FWS" ]
}

# ---- the boot disk ----
# tsx_find_disk: sets DISK (e.g. mmcblk0), DEVDIR, P1..P8 device paths and
# TSX_DISK_LAYOUT = stock (Crestron factory: p5..p8 logical) or card (the
# installer's fixed layout: p4 primary tsxdata). TSX_WANT_LAYOUT=stock|card
# restricts the match (default: either).
tsx_layout_match() {   # tsx_layout_match SYSDIR LAYOUT
	local d=$1 n=${1##*/} p e st sz
	for e in $2; do
		p=${e%%:*}; st=${e#*:}; st=${st%%:*}; sz=${e##*:}
		[ -e "$d/${n}p$p" ] || return 1
		[ "$(cat "$d/${n}p$p/start")" = "$st" ] || return 1
		[ "$sz" = - ] || [ "$(cat "$d/${n}p$p/size")" = "$sz" ] || return 1
	done
	return 0
}
tsx_find_disk() {
	local d n cand
	DISK= TSX_DISK_LAYOUT=
	cand=${TSX_SYSBLOCK:-$(ls -d /sys/block/mmcblk[0-9]* 2>/dev/null)}
	for d in $cand; do
		[ -e "$d" ] || continue
		n=${d##*/}
		[ -e "$d/${n}p9" ] && continue
		if [ "${TSX_WANT_LAYOUT:-stock}" = stock ] && tsx_layout_match "$d" "$TSX_LAYOUT_STOCK" && [ -e "$d/${n}p8" ]; then DISK=$n TSX_DISK_LAYOUT=stock; break; fi
		if [ "${TSX_WANT_LAYOUT:-card}" = card ] && tsx_layout_match "$d" "$TSX_LAYOUT_CARD" && [ ! -e "$d/${n}p5" ]; then DISK=$n TSX_DISK_LAYOUT=card; break; fi
	done
	[ -n "$DISK" ] || return 1
	if [ -n "${TSX_DEVDIR:-}" ]; then DEVDIR=$TSX_DEVDIR
	elif [ -b /dev/block/${DISK}p1 ]; then DEVDIR=/dev/block
	else DEVDIR=/dev; fi
	WHOLE=$DEVDIR/$DISK
	P1=$DEVDIR/${DISK}p1 P2=$DEVDIR/${DISK}p2 P3=$DEVDIR/${DISK}p3 P4=$DEVDIR/${DISK}p4 P5=$DEVDIR/${DISK}p5
	P6=$DEVDIR/${DISK}p6 P7=$DEVDIR/${DISK}p7 P8=$DEVDIR/${DISK}p8
	[ -b "$P1" ] && [ -b "$P2" ] && [ -b "$WHOLE" ] || return 1
	[ "$TSX_DISK_LAYOUT" = card ] || [ -b "$P5" ]
}
# mount points of a block device (one per line). Matched by major:minor through
# /proc/self/mountinfo (field 3), because Android's vold mounts the same device
# under an alias name (p1 = /dev/block/vold/179:1 on /mnt/media_rw/sdcard1: a
# second mount by name then fails with EBUSY, 2026-09-26); by name as a fallback.
tsx_mounts_of() {
	local mm
	# the stock busybox stat has no -c: take major:minor from sysfs
	if [ -b "$1" ] && [ -r /proc/self/mountinfo ] && mm=$(cat "/sys/class/block/${1##*/}/dev" 2>/dev/null) && [ -n "$mm" ]; then
		awk -v mm="$mm" '$3==mm{print $5}' /proc/self/mountinfo
	fi
	awk -v d="$1" '$1==d{print $2}' /proc/mounts
}

# ---- the U-Boot env through fw_printenv (Android: /system/etc/fw_env.config) ----
# tsx_env NAME: prints the value, returns 1 if the variable is not set
tsx_env() {
	local out
	out=$("$FWP" ${FWCFG:+-c "$FWCFG"} "$1" 2>/dev/null) || return 1
	case "$out" in "$1="*) printf '%s\n' "${out#"$1="}";; *) return 1;; esac
}
# tsx_env_sane: the env block has a valid CRC and is this board's env
tsx_env_sane() {
	local all
	all=$("$FWP" ${FWCFG:+-c "$FWCFG"} 2>&1) || { echo "fw_printenv failed: $all"; return 1; }
	case "$all" in *[Bb]ad\ [Cc][Rr][Cc]*) echo "env CRC is bad (U-Boot uses its default env)"; return 1;; esac
	echo "$all" | grep -q '^aml_dt=yushan_one' || { echo "env has no aml_dt=yushan_one*: not a xx60 env"; return 1; }
	echo "$all" | grep -q '^crestron_uboot_version=' || { echo "env has no crestron_uboot_version"; return 1; }
	echo "$all" | grep -q '^preboot=.*run switch_bootmode' || { echo "preboot does not end in 'run switch_bootmode'"; return 1; }
	return 0
}
# tsx_hook_state: prints stock | fallback | nogolden | foreign
tsx_hook_state() {
	local sw
	sw=$(tsx_env switch_bootmode) || { echo foreign; return; }
	if [ "$sw" = "$TSX_STOCK_SWITCH" ]; then echo stock
	elif [ "$sw" = "$TSX_SWITCH_FALLBACK" ]; then echo fallback
	elif [ "$sw" = "$TSX_SWITCH_NOGOLDEN" ]; then echo nogolden
	elif [ "$sw" = "$TSX_SWITCH_ONCE" ]; then echo once
	elif [ "$sw" = "${TSX_STOCK_SWITCH}run tsx_boot" ]; then echo plain
	else echo foreign; fi
}

# ---- which panel is this ----
# prints tsw1060 | tsw760, or returns 1. Sources: env lcdsize, product_name, aml_dt.
tsx_model() {
	local lcd prod dt
	lcd=$(tsx_env lcdsize) || lcd=
	prod=$(tsx_env product_name) || prod=
	dt=$(tsx_env aml_dt) || dt=
	case "$lcd:$dt:$prod" in
	10inch:yushan_one_10inch:TSW-1060*|10inch:yushan_one_10inch:TSS-10*) echo tsw1060;;   # TSS-10 = same hardware (unit B, 2026-09-26)
	7inch:yushan_one_7inch:TSW-760*|7inch:yushan_one_7inch:TSS-7*) echo tsw760;;
	*) return 1;;
	esac
}
# unit id for backup file names: MAC without colons, else tsid
tsx_unit_id() {
	local m
	m=$(tsx_env ethaddr 2>/dev/null) && [ -n "$m" ] && { echo "$m" | tr -d ':' | tr 'A-F' 'a-f'; return; }
	m=$(tsx_env tsid 2>/dev/null) && [ -n "$m" ] && { echo "tsid-$m"; return; }
	echo unknown
}

# ---- the stick ----
# tsx_find_stick [DIR...]: prints the stick root that holds tsx-install/tsx-install.conf
tsx_find_stick() {
	local d
	for d in "$@" /mnt/media_rw/udisk0 /mnt/media_rw/udisk1 /storage/udisk0 /storage/udisk1 /mnt/usb /mnt/udisk /mnt/tsx-stick; do
		[ -n "$d" ] && [ -f "$d/tsx-install/tsx-install.conf" ] && { (cd "$d" && pwd); return 0; }
	done
	return 1
}
# tsx_size FILE: size in bytes (the stock Android busybox stat has no -c; wc -c works everywhere)
tsx_size() { wc -c < "$1" | tr -d ' '; }
# tsx_conf KEY FILE: value of KEY=... in a plain key=value file (no shell evaluation)
tsx_conf() { sed -n "s/^$1=//p" "$2" | tail -n 1 | sed 's/^"\(.*\)"$/\1/'; }
