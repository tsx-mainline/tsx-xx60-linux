# SPDX-License-Identifier: GPL-2.0-or-later
# The chip part of tsx-bt for the CSR8811 Bluetooth controller of the xx60
# panel (docs/hardware.md "Bluetooth (CSR8811)"). /usr/local/sbin/tsx-bt
# reads this file with ". " and calls the functions below. It is not a
# program. A board with another controller sets TSX_BT_CHIP to its own file
# with the same functions. A board whose kernel driver registers hciN with no
# help from user space sets TSX_BT_CHIP=none.
#
# The functions of a chip file:
#
#   chip_absent_reason   print why this board has no Bluetooth module. tsx-bt
#                        calls it when hw.conf says BT=no.
#   chip_up              reset the chip, load its firmware, attach it to the
#                        kernel. Set HCI to the new hciN if the file knows it.
#                        MAC is the address to load, or empty (the chip keeps
#                        its own address). Call fail TEXT on an error.
#   chip_down            detach the chip and hold it in reset.
#
# The file can use these names of tsx-bt: log, fail, hw_get, hci_list, state,
# the variables RUN, SYS, PROC, HCI, MAC, PSRKIND. The file owns the rest.
# Test hooks: TSX_BT_TTY, TSX_BT_PSR, TSX_BT_LIB, TSX_BT_SETTLE.
#
# chip_up does the same steps as the vendor Android script (bt_init.sh):
#   1. Block and unblock the "bluetooth" rfkill. This pulses the reset line
#      (GPIOY_8).
#   2. Load the PSR over BCSP (csr_psload.py = "bccmd psload -r"). The PSR is
#      the vendor file (if the installer found one) plus a PSKEY_BDADDR line
#      with MAC. Without a vendor file, only the address loads, and the chip
#      runs on its ROM defaults.
#   3. hciattach -s 115200 TTY bcsp 115200 (BlueZ, package bluez-deprecated).
# The kernel powers hciN on. tsx-bt then does the HCIDEVUP.

TTY=${TSX_BT_TTY:-/dev/ttyAML1}
PSR=${TSX_BT_PSR:-/usr/local/share/tsx/csr8811/PSR-CSR8811.psr}
LIB=${TSX_BT_LIB:-/usr/local/lib/tsx}
SETTLE=${TSX_BT_SETTLE:-0.3}
BAUD=115200
# The sha256 of PSR-CSR8811.psr in the public Crestron firmware
# tsw-xx60_3.002.1061.001 (system.img, /bin). The same value is in
# installer/lib/tsx-psr.sh.
PSR_PINNED=96709f6ca529efb0dc8cf48165ba0c1c1934236794424aa539810376676aa8be

chip_absent_reason() { echo "no Bluetooth module on this panel (government=$(hw_get GOVERNMENT))"; }

# bdaddr_line MAC: PSKEY_BDADDR (&0001) as the vendor bt_getprop_mac.sh
# writes it: "&0001 = 00m4 m5m6 00m3 m1m2".
bdaddr_line() {
	IFS=: read -r m1 m2 m3 m4 m5 m6 <<EOF
$1
EOF
	echo "&0001 = 00$m4 $m5$m6 00$m3 $m1$m2" | tr 'A-F' 'a-f'
}

bt_rfkill() {  # print the sysfs dir of the bluetooth rfkill (the bt-dev one first)
	best=
	for d in "$SYS"/class/rfkill/rfkill*; do
		[ "$(cat "$d/type" 2>/dev/null)" = bluetooth ] || continue
		[ "$(cat "$d/name" 2>/dev/null)" = bt-dev ] && { echo "$d"; return 0; }
		[ -n "$best" ] || best=$d
	done
	[ -n "$best" ] && echo "$best"
}

# attach_pids: the hciattach processes on $TTY (from /proc, not pkill: the
# match must be exact, and busybox pkill -f matches any substring)
attach_pids() {
	for d in "$PROC"/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		set -- $(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
		case "${1:-}" in hciattach|*/hciattach) ;; *) continue;; esac
		for a in "$@"; do [ "$a" = "$TTY" ] && { echo "${d##*/}"; break; }; done
	done
}

stop_attach() {
	for h in $(hci_list); do hciconfig "$h" down >/dev/null 2>&1 || true; done
	pids=$(attach_pids)
	[ -n "$pids" ] || return 0
	kill $pids 2>/dev/null
	i=0
	while [ $i -lt 20 ] && [ -n "$(attach_pids)" ]; do sleep 0.1; i=$((i + 1)); done
	log "stopped hciattach ($(echo $pids))"
}

chip_up() {
	[ -e "$TTY" ] || fail "$TTY does not exist (the kernel has no UART A node)"
	command -v hciattach >/dev/null 2>&1 || fail "hciattach is missing (apk add bluez-deprecated)"
	command -v hciconfig >/dev/null 2>&1 || fail "hciconfig is missing (apk add bluez-deprecated)"
	command -v python3 >/dev/null 2>&1 || fail "python3 is missing"
	[ -r "$LIB/csr_psload.py" ] || fail "$LIB/csr_psload.py is missing"

	# The PSR: the vendor file if it is there and parses, then our address.
	mkdir -p "$RUN"
	set --
	if [ -r "$PSR" ]; then
		if python3 "$LIB/csr_psload.py" --check "$PSR" >/dev/null 2>&1; then
			sum=$(sha256sum < "$PSR" | cut -d' ' -f1)
			if [ "$sum" = "$PSR_PINNED" ]; then PSRKIND=vendor
			else PSRKIND=vendor-unpinned; log "WARNING: $PSR has sha256 $sum, not the pinned one. Loading it anyway"
			fi
			set -- "$PSR"
		else
			log "WARNING: $PSR does not parse as a PSR file. Loading only the Bluetooth address"
			PSRKIND=bdaddr-only
		fi
	else
		log "no vendor PSR file ($PSR): loading only the Bluetooth address, the chip runs on its ROM defaults"
		PSRKIND=bdaddr-only
	fi
	if [ -n "$MAC" ]; then
		bdaddr_line "$MAC" > "$RUN/bt-bdaddr.psr"
		set -- "$@" "$RUN/bt-bdaddr.psr"
		log "Bluetooth address $MAC, PSR: $PSRKIND"
	else
		log "no Bluetooth address to load: the chip keeps its own address. PSR: $PSRKIND"
	fi
	if [ $# = 0 ]; then
		log "WARNING: nothing to load into the chip, the PSR upload is skipped"
	fi

	stop_attach
	rf=$(bt_rfkill)
	if [ -n "$rf" ]; then
		echo 1 > "$rf/soft" 2>/dev/null || log "WARNING: cannot block $rf"
		sleep "$SETTLE"
		echo 0 > "$rf/soft" 2>/dev/null || fail "cannot unblock $rf (the chip stays in reset)"
		sleep "$SETTLE"
		log "chip reset through $(basename "$rf") ($(cat "$rf/name" 2>/dev/null))"
	else
		log "WARNING: no bluetooth rfkill in $SYS/class/rfkill: no reset pulse (the board DTS has bt-rfkill)"
	fi

	if [ $# != 0 ]; then
		out=$(python3 "$LIB/csr_psload.py" --device "$TTY" --baud "$BAUD" "$@" 2>&1) || {
			echo "$out" | sed 's/^/  /'
			# A panel without the module has government=1 and never gets
			# here (absent in tsx-bt). Name the flag for the person who
			# reads this (docs/hardware.md "Panel variants").
			gov=$(hw_get GOVERNMENT)
			fail "PSR upload: $(echo "$out" | tail -n 1) (this panel has government=${gov:-unknown}. A panel with government=1 has no Bluetooth module)"
		}
		log "PSR upload: $(echo "$out" | tail -n 1)"
	fi

	before=$(hci_list)
	out=$(hciattach -s "$BAUD" "$TTY" bcsp "$BAUD" 2>&1) || {
		echo "$out" | sed 's/^/  /'
		fail "hciattach: $(echo "$out" | tail -n 1)"
	}
	i=0
	while [ $i -lt 50 ]; do
		for h in $(hci_list); do
			case " $(echo $before) " in *" $h "*) ;; *) HCI=$h;; esac
		done
		[ -n "$HCI" ] && break
		sleep 0.1; i=$((i + 1))
	done
	[ -n "$HCI" ] || fail "hciattach ran, but no new hci device showed up"
}

chip_down() {
	stop_attach
	rf=$(bt_rfkill)
	[ -n "$rf" ] && echo 1 > "$rf/soft" 2>/dev/null
	return 0
}
