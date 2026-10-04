#!/bin/sh
# Host test for the rescue screen of tsx-linux-common
# (rescue/usr/sbin/tsx-rescue-status) with the xx60 board file of this
# repository. The xx60 keeps the data of the unit in the U-Boot env. The board
# file loads tsx-lib.sh of the rescue system and reads it through tsx_env. The
# test uses the real board.sh and the real tsx_env of tsx-lib.sh. Only the disk search and
# fw_printenv are fake. The test checks the model line, the firmware, the unit
# id, the MAC from the env and the line widths. It needs no panel and no
# compiler.
set -eu
. "$(dirname "$0")/lib.sh"
RS=$COMMON/rescue/usr/sbin/tsx-rescue-status
# The rescue system runs busybox ash. The screen script is for that shell only.
SH="busybox sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\n[ -e "%s/noip" ] || echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' "$T" > "$T/sbin/ip"
printf '#!/bin/sh\necho 7.2.8-00116-gb5862166389d\n' > "$T/sbin/uname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname"
echo "02:5a:11:22:33:44" > "$T/mac"
echo "quiet console=tty0" > "$T/cmdline"
# A fake fw_printenv: it prints NAME=value from a plain file, and it records the config file that it gets.
cat > "$T/fw_printenv" <<EOF2
#!/bin/sh
[ "\$1" = -c ] && { cat "\$2" > "$T/fwcfg.seen"; shift 2; }
grep "^\$1=" "$T/uboot.env"
EOF2
chmod 755 "$T/fw_printenv"
setenv() { # setenv PRODUCT_NAME [ETHADDR [TSID]]: the U-Boot env of the unit
	{ echo "product_name=$1"; [ -n "${2:-}" ] && echo "ethaddr=$2"; [ -n "${3:-}" ] && echo "tsid=$3"; echo "lcdsize=10inch"; } > "$T/uboot.env"
}
# The real tsx-lib.sh of the rescue system, with the disk search replaced: a host has no mmcblk0.
cat > "$T/lib.sh" <<EOF2
. "$XX60_LIB"
tsx_find_disk() { WHOLE=/dev/mmcblk0; }
tsx_pick_fwenv() { FWP=$T/fw_printenv; FWS=$T/fw_setenv; }
EOF2
setenv "TSS-10_[v3.002.1061,_#0A1B2C3D]" 00:10:7f:00:00:01 0A1B2C3D
echo uboot > "$T/run/tsx-eth0-mac-src"
sed -e "s|/proc/cmdline|$T/cmdline|g" \
    -e "s|ip -4 -o addr show eth0|$T/sbin/ip|g; s|uname -r|$T/sbin/uname|; s|/sys/class/net/eth0/address|$T/mac|" \
    -e 's|> /dev/kmsg|> /dev/null|; s|> "\$TTY"|>> "$TTY"|' "$RS" > "$T/rs.sh"
export TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw TSX_VERFILE=$T/none TSX_STATUS_IN=$T/keys TSX_STATUS_WAIT=1 TSX_LIB=$T/lib.sh

# render [COLS]: one frame, escape codes stripped
render() {
	: > "$T/frame.raw"
	TSX_STATUS_COLS=${1:-80} $SH "$T/rs.sh" once
	sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
}
has() { grep -q -- "$1" "$T/frame"; }
want()    { if has "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
wantnot() { if has "$1"; then bad "$2 (found: $1)"; else ok "$2"; fi; }
fit() { # COLS
	rows=$(wc -l < "$T/frame"); cols=$(awk '{ if (length > m) m = length } END { print m + 0 }' "$T/frame")
	[ "$cols" -le "$1" ] && ok "widest line $cols <= $1 columns" || bad "widest line $cols > $1 columns"
	[ "$rows" -le 24 ] && ok "$rows rows (+ the cursor row <= 25)" || bad "$rows rows"
}

echo "== the lines that the xx60 board gives =="
render
want '^model        : TSS-10   stock fw v3.002.1061   unit 00107f000001$' "model, stock firmware and unit id come from the U-Boot env"
wantnot '0A1B2C3D' "no tsid on the screen"
wantnot '_\[' "the product name loses the firmware and tsid suffix"
want '^network      : eth0 192.0.2.10 (dhcp, MAC 02:5a:11:22:33:44, uboot)$' "network line: the MAC of eth0 and the board MAC source"
wantnot '^board line' "the xx60 adds no extra rescue line"
fit 80
render 85; fit 85
[ "$(cat "$T/fwcfg.seen")" = "/dev/mmcblk0 0x100000 0x10000" ] && ok "the env is read at 1 MiB with a size of 64 KiB" || bad "fw_env.config: $(cat "$T/fwcfg.seen" 2>/dev/null)"

echo "== the MAC before rcS has set it =="
# rcS has not written tsx-eth0-mac-src yet: eth0 has the random kernel MAC.
rm -f "$T/run/tsx-eth0-mac-src"; touch "$T/noip"; render
want '^network      : eth0 (starting) (dhcp, MAC 00:10:7f:00:00:01, uboot)$' "starting: the MAC from the U-Boot env, source uboot"
wantnot '02:5a:11:22:33:44' "starting: no random kernel MAC"
setenv "TSS-10_[v3.002.1061,_#0A1B2C3D]" "" 0A1B2C3D; render
want '^network      : eth0 (starting) (dhcp)$' "starting, no ethaddr in the env: no MAC"
want '^model        : TSS-10   stock fw v3.002.1061   unit tsid-0A1B2C3D$' "no ethaddr: the unit id comes from the tsid"
setenv "TSS-10_[v3.002.1061,_#0A1B2C3D]" not-a-mac 0A1B2C3D; render
want '^network      : eth0 (starting) (dhcp)$' "starting, a malformed ethaddr: no MAC"
rm -f "$T/noip"; echo uboot > "$T/run/tsx-eth0-mac-src"

echo "== other models =="
setenv "TSW-1060_[v3.001.1017,_#0A1B2C3D]" 00:10:7f:00:00:02
render
want '^model        : TSW-1060   stock fw v3.001.1017   unit 00107f000002$' "TSW-1060"
setenv "" 00:10:7f:00:00:03
render
want '^model        : unknown   unit 00107f000003$' "no product name: the model is unknown"
: > "$T/uboot.env"
render
want '^model        : unknown   unit unknown$' "an empty env: no model, no firmware, unit unknown"

echo "== the screen sources only the board file =="
# The shared screen names no helper file. The xx60 board file loads tsx-lib.sh by itself (TSX_LIB is its path here).
grep -q 'tsx-lib\|TSX_LIB' "$RS" && bad "tsx-rescue-status of tsx-linux-common names tsx-lib.sh" || ok "tsx-rescue-status names no helper file"
grep -q 'tsx-lib.sh' "$TSX_BOARD_CONF" && ok "the xx60 board file loads tsx-lib.sh" || bad "board.sh does not load tsx-lib.sh"

echo "== no tsx-lib.sh =="
# A rescue image can come without tsx-lib.sh. busybox ash stops a script when
# "." cannot read its file, so board.sh must test the file first.
: > "$T/frame.raw"
rc=0; TSX_LIB=$T/no-such-lib.sh $SH "$T/rs.sh" once || rc=$?
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
[ "$rc" -eq 0 ] && ok "no tsx-lib.sh: exit 0 ($SH)" || bad "no tsx-lib.sh: exit $rc ($SH)"
want '^Press Enter for a rescue shell$' "no tsx-lib.sh: the frame is drawn"
want '^model        : ' "no tsx-lib.sh: the model line"

echo "== the rescue path of the xx60 =="
# Every rescue path of the xx60 sets the MAC of eth0 from the same board file (rcS of the initramfs).
RCS=$XX60/rootfs/initramfs/overlay/etc/init.d/rcS
grep -qF '. /usr/local/lib/tsx/board.sh' "$RCS" && grep -qF 'mac=$(tsx_board_mac_early)' "$RCS" && grep -qF 'ip link set dev eth0 address' "$RCS" \
	&& ok "rcS sets the MAC of eth0 with tsx_board_mac_early of the board file" || bad "rcS does not use the board MAC"

echo "== $N ok, $F failed =="
[ "$F" -eq 0 ] && echo "PASS common/test-rescue-screen" || { echo "FAIL common/test-rescue-screen"; exit 1; }
