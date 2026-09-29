# tsx-rescue.sh: shared code for the rescue-first installer (v2) and, later,
# tsx-restore-factory (both drive the same rescue system; see docs/recovery.md
# "The rescue system"). Sourced by:
#   - installer/steps/tsx-rescue-arm.sh   (stock Android root shell: bash 3.2 + busybox)
#   - installer/tsx-install-mainline       (host: bash)
#   - the rescue-side writer pushed to the panel at install time (busybox ash)
# POSIX sh + `local` only (same rule as installer/android/tsx-lib.sh, which this
# file complements: source THAT file too for tsx_find_disk / TSX_MBR_P4_TYPE_OFFSET /
# tsx_env / TSX_BOOT_CMD / TSX_SWITCH_FALLBACK -- on the rescue it is already present
# at /usr/share/tsx/tsx-lib.sh, part of the base initramfs; nothing here duplicates it).
#
# Nothing in this file writes anything by itself except the functions whose
# names say so (tsx_env_apply, tsx_mbr_fold, tsx_mkfs_tsxdata, tsx_conf_set_flavor,
# tsx_rootinfo_set_flavor); every write is read back and verified before
# returning success, the same discipline as tsx-boot-ok and
# installer/emmc/tsx-usb-recovery.

# ---------------------------------------------------------------- pr_dd -----
# Live progress for a background dd (BusyBox dd has no status=progress).
# pr_dd DEST OFF_MIB LEN_MIB NAME -- DD_ARGS...
# Copied unchanged from installer/factory/tsx-emmc-restore (same tool, same
# ash-stdin trap fix documented in docs/recovery.md "The ash dd stdin trap"):
# a background job under busybox ash gets /dev/null as stdin unless the real
# input is moved to a separate fd (7) first, which bash does not need but does
# no harm to.
pr_dd() {
	_pd_dev=$1; _pd_off=$2; _pd_len=$3; _pd_name=$4; shift 4; [ "${1:-}" = -- ] && shift
	exec 8<>"$_pd_dev"
	exec 7<&0
	dd "$@" <&7 1>&8 2>/dev/null 7<&- 8<&- &
	_pd_dp=$!
	( _pd_t0=$(date +%s)
	  while kill -0 $_pd_dp 2>/dev/null; do
		_pd_i=0
		while [ $_pd_i -lt 15 ] && kill -0 $_pd_dp 2>/dev/null; do sleep 1; _pd_i=$((_pd_i + 1)); done
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
		# numbers first, name last: the name may contain spaces ("eMMC root")
		printf '%.0f %.0f %.0f %s\n' "$_pd_pos" "$((_pd_off * 1048576))" "$((_pd_len * 1048576))" "$_pd_name" > "${TSX_PROGRESS_FILE:-/run/tsx-progress}" 2>/dev/null || true
	  done
	) &
	_pd_rp=$!
	wait $_pd_dp; _pd_rc=$?
	# no explicit "kill $_pd_rp": the reporter notices dd's exit via its own
	# kill -0 check and self-terminates (see docs/recovery.md for why a stray
	# signal to an already-recycled PID must be avoided here)
	wait $_pd_rp 2>/dev/null
	exec 7<&- 8<&-
	return $_pd_rc
}

# ---------------------------------------------------- verified env write ----
# tsx_env_apply CFG WANT: CFG is an fw_env.config-style line (already written
# to a file by the caller, e.g. "$disk $offset $size"); WANT is a
# fw_setenv --script text (one "name value" per line). Applies it in at most
# one write, verified: CRC valid both before and after, every requested name
# now has its wanted value, and no OTHER variable changed. Prints what it did
# (or "nothing to do") and returns 0, or prints "ERROR: ..." and returns 1 --
# never exits the caller's shell, so a driver can retry/report instead of dying
# mid-transfer.
tsx_env_apply() {
	local cfg=$1 want=$2 names env0 env1 n v out lockdir=${TSX_RUN:-/run}
	local fwto=${TSX_FWENV_TIMEOUT:-10}
	local fwto_cmd=; command -v timeout >/dev/null 2>&1 && fwto_cmd="timeout -s KILL $fwto"
	# -l "$lockdir": same lock-directory override installer/emmc/tsx-usb-recovery
	# uses, needed for host tests (root on the real panel can always lock /run).
	# $fwto_cmd bounds the call: u-boot-tools' fw_env.c read loop spins at 100%
	# CPU forever on a size/file mismatch instead of erroring out (see
	# docs/boot.md "fw_printenv can hang").
	out=$($fwto_cmd fw_printenv -c "$cfg" -l "$lockdir" 2>&1) || { echo "tsx_env_apply: ERROR: fw_printenv failed or timed out after ${fwto}s: $out"; return 1; }
	echo "$out" | grep -qi 'bad crc' && { echo "tsx_env_apply: ERROR: env CRC bad ($cfg): refusing to write"; return 1; }
	env0=$out
	names=$(printf '%s\n' "$want" | awk 'NF{print $1}' | tr '\n' ' ')
	# already correct?
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
# tsx_mbr_fold WHOLE OFFSET: MBR entry-4 type byte 0x05 (extended: Android's
# p5..p8) -> 0x83 (one primary partition, tsxdata), read back and verified.
# Byte-identical to the write installer/android/tsx-android-install.sh makes
# (LAST step there, kept last here too: every earlier state still boots).
# No-op (and success) if the byte is already 0x83.
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

# tsx_mkfs_tsxdata DEV UUID: the exact mke2fs invocation
# rootfs/initramfs/overlay/usr/sbin/tsx-autoinstall uses to format the card's
# tsxdata partition, kept identical here so a v2 install and an old card-stage
# install produce byte-for-byte the same on-disk feature set (the stale-label
# trap in docs/recovery.md is about exactly this: a later tool must be able to
# tell "this is MY tsxdata" apart from an older one by UUID, not just label).
tsx_mkfs_tsxdata() {
	local dev=$1 uuid=$2
	mkfs.ext4 -F -q -O ^metadata_csum_seed,^orphan_file -L tsxdata -m 1 -U "$uuid" "$dev"
}

# tsx_tsxdata_keepable DEV: can a reinstall keep DEV as it is (docs/install.md
# "Reinstalling or updating a mainline panel")? Read-only (e2fsck -n never
# writes; -f: a full check, not just the superblock's "clean" flag -- a few
# seconds to a minute on a used 2.9 GiB tsxdata). Prints one line with the
# reason and returns
#   0  ext4, LABEL=tsxdata, e2fsck -fn clean: keep it
#   1  not a tsxdata ext4 at all (never formatted, Android data, a stale fold)
#   2  a tsxdata ext4, but e2fsck -fn reports problems (or it was not
#      unmounted cleanly: -n does not replay the journal) (the caller may repair
#      it with e2fsck -fp and ask again)
# The label and type come from the plain blkid output, which busybox and
# util-linux both print as `DEV: LABEL="x" UUID="y" TYPE="z"` (busybox ignores
# -s/-o, see rootfs/overlay/etc/init.d/tsx-data).
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

# tsx_conf_set_flavor FILE FLAVOR: set KERNEL_FLAVOR in a kept panel.conf
# (the KEY="value" format tsx-config writes) without tsx-config itself, which
# the rescue does not have. Any other line is left as it is.
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

# tsx_rootinfo_set_flavor FILE FLAVOR: set kernel_flavor= in a NEW root's
# /etc/tsx/emmc-root.info (mk-tsxroot-emmc.sh's own key=value format, no
# quotes) to FLAVOR -- the flavor this install bundle's own manifest names
# (installer/emmc/mk-v2-bundle.sh), i.e. the boot image actually being
# written to the boot partition right now. This is always run, fresh install
# or reinstall: emmc-root.info's kernel_flavor= otherwise only reflects
# whatever --flavor mk-tsxroot-emmc.sh happened to be given when the root
# image was built at payload time, which can drift from the flavor actually
# selected/installed if the wrong image was ever paired into a bundle (the
# tsx-kernel-flavor package hook falls back to this field when panel.conf's
# own KERNEL_FLAVOR is unset, so a stale/wrong value here silently steers the
# next kernel package upgrade onto the wrong flavor). A no-op for anything
# but lts/stable; creates etc/tsx/ if the image is somehow missing it.
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

# ------------------------------------------------------- rescue discovery ---
# Adapted from installer/tsx-restore-factory (same problem: the rescue's eth0
# MAC is random unless the U-Boot ethaddr fix already applied -- see
# docs/recovery.md "Random MAC in the rescue, and the fix"). Kept POSIX and
# parameterised (no globals) so both the v2 driver and, later, a rewritten
# tsx-restore-factory can call these directly.

# ssh_server_id HOST: HOST's SSH identification line (e.g. SSH-2.0-dropbear,
# SSH-2.0-OpenSSH_..., SSH-2.0-CrestronSSH), or nothing. No login is attempted.
# Crestron's sshd sends its line only after the client's, so send one first.
ssh_server_id() {
	timeout 3 bash -c "exec 3<>/dev/tcp/$1/22 && printf 'SSH-2.0-tsx-probe\r\n' >&3 && head -c 64 <&3" 2>/dev/null \
		| tr -d '\r\0' | head -n 1
}
# is_crestron_sshd HOST: true if HOST runs stock Android's Crestron sshd.
# Never try a root/password login there: every failed login counts, and after
# 3 (Crestron's SETLOGINATTEMPTS default) the sshd blocks the source IP for
# 24 hours (SETLOCKOUTTIME), which also blocks steps/rootsh from that host.
is_crestron_sshd() {
	case "$(ssh_server_id "$1")" in *CrestronSSH*) return 0;; *) return 1;; esac
}

# ssh_test_rescue HOST PW: true if HOST answers ssh as the rescue (no login
# attempt when HOST is Crestron's sshd, see is_crestron_sshd)
ssh_test_rescue() {
	is_crestron_sshd "$1" && return 1
	sshpass -p "$2" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
		"root@$1" 'test -f /etc/tsx/rescue-image' >/dev/null 2>&1
}

# find_rescue_by_mac MAC PREFIX: sweep PREFIX.0/24 (fping if present, else a
# bounded parallel ping), then print an IP whose `ip neigh` MAC matches, or
# nothing.
find_rescue_by_mac() {
	local mac=$1 prefix=$2
	if command -v fping >/dev/null 2>&1; then fping -a -q -r0 -t200 -g "${prefix}.1" "${prefix}.254" >/dev/null 2>&1 || true
	else seq 1 254 | xargs -P 64 -I{} ping -c1 -W1 -q "${prefix}.{}" >/dev/null 2>&1 || true
	fi
	ip neigh | awk -v m="$mac" 'BEGIN{m=tolower(m)} tolower($0) ~ m {print $1; exit}'
}

# find_rescue_by_env MAC PREFIX PW: the rescue's eth0 MAC is set from the
# U-Boot env's ethaddr when a card is present and readable (docs/recovery.md
# "the rescue image itself now sets eth0's MAC from ... ethaddr"), but until
# that lands on every image in the field, fall back to matching by the card's
# live env instead of eth0: try every dropbear host on PREFIX.0/24 and accept
# the one whose card env (1 MiB offset) has ethaddr = MAC.
find_rescue_by_env() {
	local mac=$1 prefix=$2 pw=$3 ip e
	for ip in $(ip neigh | awk -v p="$prefix." 'index($1, p) == 1 && $0 ~ /lladdr/ {print $1}'); do
		case "$(timeout 2 bash -c "exec 3<>/dev/tcp/$ip/22 && head -c 64 <&3" 2>/dev/null | tr -d '\r\0' | head -n 1)" in *dropbear*) ;; *) continue;; esac
		e=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 "root@$ip" \
			'test -f /etc/tsx/rescue-image && dd if=/dev/mmcblk0 bs=65536 skip=16 count=1 2>/dev/null | tr "\0" "\n" | sed -n "s/^ethaddr=//p"' 2>/dev/null | head -n 1)
		[ -n "$e" ] && [ "$(echo "$e" | tr 'A-F' 'a-f')" = "$(echo "$mac" | tr 'A-F' 'a-f')" ] && { echo "$ip"; return 0; }
	done
	return 1
}

# wait_for_rescue KIOSK_IP MAC WSIP PW TIMEOUT_S: prints the rescue's IP once
# found (every ~10s: the kiosk's own IP -- the usual case with a DHCP
# reservation, since the rescue takes eth0's MAC from the env's ethaddr --
# then a MAC sweep of the panel's /24), or nothing after TIMEOUT_S with a
# non-zero return. The sweep reads MACs from `ip neigh`, so it only works
# when that /24 is on-link; through a router or a VPN (`ip route get` shows
# "via", or the source address is in another /24) only the kiosk IP is
# tried. Heartbeat lines go to stderr (stdout is the answer).
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
