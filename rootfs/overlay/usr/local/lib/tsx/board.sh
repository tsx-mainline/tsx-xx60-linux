# board.sh: the values and the small functions of this board. Shell scripts
# of the panel software source it:
#   . "${TSX_BOARD_CONF:-/usr/local/lib/tsx/board.sh}"
# Each board family has its own file with the same names (the xx60 here).
# The shared scripts never test the family. They read these names only.
# The file has plain variables and functions, and it has no side effects when
# a script sources it. A value that is in the environment wins (host tests
# use that). Python reads a value with `tsx-board get NAME`.
#
# This file holds the fixed facts of the board. The parts that a panel may
# lack (microphone, Bluetooth) are not here. tsx-hw detects them at boot into
# /run/tsx/hw.conf.
#
# Variables
#   TSX_FAMILY             family name: xx60. It also names the packages
#                          (tsx-$TSX_FAMILY-chromium, tsx-$TSX_FAMILY-kernel).
#   TSX_APK_CATEGORY       the repository category after the Alpine branch
#                          (<APK_URL>/<branch>/common and .../$TSX_APK_CATEGORY)
#   TSX_HA_MODEL           the model name in Home Assistant ("xx60" gives the
#                          device model "xx60 (mainline Linux)")
#   TSX_SOUND_CARD         ALSA card name
#   TSX_DISPLAY_DRM        DRM driver names (shell patterns, separated by
#                          spaces) of the display that gets GPU compositing
#   TSX_RENDER_DRM         DRM driver names of GPUs without a display. The
#                          kiosk uses their render node.
#   TSX_RENDER_ES2_DRM     the render drivers that offer OpenGL ES 2.0 only
#   TSX_DISPLAY_ENV        NAME=value words that the kiosk exports when the
#                          display driver is in TSX_DISPLAY_DRM
#   TSX_BT_CHIP            the chip file of tsx-bt, or "none" (the chip needs
#                          no help from user space)
#   TSX_BT_PROXY_DEFAULT   on | off: BT_PROXY when panel.conf leaves it empty
#   TSX_BT_MAC_SETTABLE    yes | no: BT_MAC can set the Bluetooth address
#   TSX_MAC_SOURCE         name of the source of the eth0 MAC (uboot)
#   TSX_MAC_DEV            the device that tsx_board_mac_early reads
#
# Functions (print the value, print nothing when the board has none)
#   tsx_board_model        the model, for example TSS-10
#   tsx_board_stock_fw     the version of the stock firmware, for example
#                          v3.002.1061
#   tsx_board_unit_id      the unit id for file names (the MAC without colons)
#   tsx_board_mac          the MAC that the board gives eth0 (a valid one only)
#   tsx_board_mac_early    the same, read at early boot: it reads the env
#                          area of the disk and needs no other tool
#   tsx_board_mac_source   TSX_MAC_SOURCE
#   tsx_board_hostname_hint  the host name that the board suggests
#   tsx_board_rescue_extra extra lines for the rescue screen (none here)
#   tsx_board_load         read the board data once, on a running system
#   tsx_board_probe DIR    point the data reader at the board data from the
#                          rescue system. DIR takes one scratch file. Fails
#                          when the board data is not there.
# Test hooks: TSX_ENV_CONF, TSX_RUN, TSX_FWENV_TIMEOUT, TSX_MMCBLK0,
# TSX_BT_LIB.

TSX_FAMILY=${TSX_FAMILY:-xx60}
TSX_APK_CATEGORY=${TSX_APK_CATEGORY:-xx60}
TSX_HA_MODEL=${TSX_HA_MODEL:-xx60}
TSX_SOUND_CARD=${TSX_SOUND_CARD:-TSW1060}
TSX_DISPLAY_DRM=${TSX_DISPLAY_DRM:-meson*}
TSX_RENDER_DRM=${TSX_RENDER_DRM:-lima panfrost}
TSX_RENDER_ES2_DRM=${TSX_RENDER_ES2_DRM:-lima}
TSX_DISPLAY_ENV=${TSX_DISPLAY_ENV:-WLR_DRM_NO_MODIFIERS=1 CAGE_RENDER_FORMAT=argb8888}
TSX_BT_CHIP=${TSX_BT_CHIP:-${TSX_BT_LIB:-/usr/local/lib/tsx}/bt-chip-csr8811.sh}
TSX_BT_PROXY_DEFAULT=${TSX_BT_PROXY_DEFAULT:-off}
TSX_BT_MAC_SETTABLE=${TSX_BT_MAC_SETTABLE:-yes}
TSX_MAC_SOURCE=${TSX_MAC_SOURCE:-uboot}
TSX_MAC_DEV=${TSX_MAC_DEV:-${TSX_MMCBLK0:-/dev/mmcblk0}}

# The xx60 keeps its data in the U-Boot env. tsx_board_env NAME prints one
# variable of it. In the rescue system and in the installers, tsx-lib.sh
# defines tsx_env, and the function uses that. On a running system,
# tsx_board_load fills TSX_BOARD_ENV.
tsx_board_env() {
	if type tsx_env >/dev/null 2>&1; then
		tsx_env "$1"
		return
	fi
	_tb_v=$(printf '%s\n' "${TSX_BOARD_ENV:-}" | sed -n "s/^$1=//p" | head -n 1)
	[ -n "$_tb_v" ] || return 1
	printf '%s\n' "$_tb_v"
}

# tsx_board_load: read the whole U-Boot env once (read only). It finds the
# env disk with /etc/tsx/uboot-env.conf, like tsx-boot-ok does. A hang or an
# error leaves TSX_BOARD_ENV empty and returns 1 with a message on stderr.
tsx_board_load() {
	TSX_BOARD_ENV=
	_tb_conf=${TSX_ENV_CONF:-/etc/tsx/uboot-env.conf}
	[ -r "$_tb_conf" ] || return 0
	ENV_DISK= ENV_OFFSET= ENV_SIZE=
	. "$_tb_conf"
	_tb_disk=
	for _tb_d in /sys/block/mmcblk[0-9]; do
		[ -e "$_tb_d" ] || continue
		_tb_t=$(cat "$_tb_d/device/type" 2>/dev/null || true)
		case "$ENV_DISK" in
		emmc) [ "$_tb_t" = MMC ] && [ -e "${_tb_d}boot0" ] && _tb_disk=/dev/${_tb_d##*/};;
		sd) [ -e "$_tb_d/${_tb_d##*/}p2" ] && [ "$(cat "$_tb_d/${_tb_d##*/}p1/start" 2>/dev/null)" = 81920 ] && \
			[ "$(cat "$_tb_d/${_tb_d##*/}p2/start" 2>/dev/null)" = 206849 ] && _tb_disk=/dev/${_tb_d##*/};;
		/dev/*) _tb_disk=$ENV_DISK;;
		esac
		[ -n "$_tb_disk" ] && break
	done
	case "$ENV_DISK" in /dev/*) _tb_disk=$ENV_DISK;; esac
	if [ -n "$_tb_disk" ] && [ -b "$_tb_disk" ] && [ -n "${ENV_OFFSET:-}" ] && [ "$ENV_OFFSET" != TODO ]; then
		_tb_cfg=${TSX_RUN:-/run}/tsx-fw_env.config
		echo "$_tb_disk $ENV_OFFSET ${ENV_SIZE:-0x10000}" > "$_tb_cfg"
		# Limit the run time. The read loop in fw_env.c of u-boot-tools spins
		# at 100% CPU forever on a config/size mismatch and does not report
		# an error (docs/boot.md "fw_printenv can hang"). A caller can be an
		# early boot service, so it must not wait for that.
		_tb_to=${TSX_FWENV_TIMEOUT:-10}
		_tb_tc=; command -v timeout >/dev/null 2>&1 && _tb_tc="timeout -s KILL $_tb_to"
		TSX_BOARD_ENV=$($_tb_tc fw_printenv -c "$_tb_cfg" 2>/dev/null) || {
			TSX_BOARD_ENV=
			echo "fw_printenv failed or timed out after ${_tb_to}s" >&2
			return 1
		}
	fi
	return 0
}

# tsx_board_probe DIR: for the rescue system. It needs the functions of
# tsx-lib.sh. It finds the boot disk and points the env reader at it.
tsx_board_probe() {
	type tsx_find_disk >/dev/null 2>&1 || return 1
	tsx_find_disk 2>/dev/null || return 1
	# fw_env.config needs a hex offset and size (installer/steps/tsx-rescue-arm.sh says why)
	printf '%s 0x%x 0x%x\n' "$WHOLE" "${TSX_ENV_OFFSET:-1048576}" "${TSX_ENV_SIZE:-65536}" > "$1/tsx-status-env.cfg" 2>/dev/null
	FWCFG=$1/tsx-status-env.cfg
	tsx_pick_fwenv 2>/dev/null
	return 0
}

# product_name looks like "TSS-10_[v3.002.1061,_#0A1B2C3D]". It has the
# model, then the stock firmware version and the tsid.
tsx_board_model() {
	_tb_p=$(tsx_board_env product_name 2>/dev/null) || _tb_p=
	printf '%s\n' "${_tb_p%%_\[*}"
}
tsx_board_stock_fw() {
	_tb_p=$(tsx_board_env product_name 2>/dev/null) || _tb_p=
	printf '%s\n' "$_tb_p" | sed -n 's/^[^[]*\[\(v[0-9][0-9.]*\).*/\1/p'
}
tsx_board_unit_id() {
	_tb_m=$(tsx_board_env ethaddr 2>/dev/null) && [ -n "$_tb_m" ] && { echo "$_tb_m" | tr -d ':' | tr 'A-F' 'a-f'; return; }
	_tb_m=$(tsx_board_env tsid 2>/dev/null) && [ -n "$_tb_m" ] && { echo "tsid-$_tb_m"; return; }
	echo unknown
}
tsx_board_hostname_hint() {
	tsx_board_env lan_hostname 2>/dev/null || true
}
tsx_board_mac() {
	_tb_m=$(tsx_board_env ethaddr 2>/dev/null) || return 0
	echo "$_tb_m" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && echo "$_tb_m"
	return 0
}
# The env area starts at 1 MiB (64 KiB * 16) of the disk. This reads it as
# text. It needs no fw_printenv, which can hang.
tsx_board_mac_early() {
	_tb_m=
	if [ -b "$TSX_MAC_DEV" ] || [ -f "$TSX_MAC_DEV" ]; then
		_tb_m=$(dd if="$TSX_MAC_DEV" bs=64k skip=16 count=1 2>/dev/null | tr '\0' '\n' | sed -n 's/^ethaddr=//p' | head -1)
	fi
	echo "$_tb_m" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && echo "$_tb_m"
	return 0
}
tsx_board_mac_source() { echo "$TSX_MAC_SOURCE"; }
tsx_board_rescue_extra() { :; }
