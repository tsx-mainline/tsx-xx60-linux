#!/bin/sh
# Host test for the rescue screen (rootfs/initramfs/overlay/usr/sbin/tsx-rescue-status),
# no panel needed:
#   - idle: the banner and "rescue", no "reason for rescue" or "status" rows,
#     the model without the firmware/tsid suffix, and the Enter line. An
#     operation section appears ONLY while an install or restore runs (name,
#     step, progress bar, do-not-power-off warning). The test also covers the
#     failed, done, stopped and stale-progress cases.
#   - no line is longer than the console (80 on 1280x800, 85 on 1024x600),
#     and there are at most 24 rows.
#   - no power-cycle advice on any rescue path.
#   - Enter on the keyboard tty opens the shell (the fake tty is a file). No
#     Enter does not. The shell banner warns while an operation runs.
#   - the state files that the tools write (tsx-install-state, tsx-op).
#   - the network line before rcS has set the MAC: "starting" and the MAC from
#     the U-Boot env, never the random kernel MAC or "no address yet".
#   - tsx-rescue and tsx-boot-ok are in the base initramfs (one source each).
# The test runs under busybox or dash sh and needs no compiler.
set -eu
# The board file (rootfs/overlay/usr/local/lib/tsx/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/lib/tsx/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")/../.." && pwd)
RS=$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-rescue-status
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\n[ -e "%s/noip" ] || echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' "$T" > "$T/sbin/ip"
printf '#!/bin/sh\necho 7.2.8-00116-gb5862166389d\n' > "$T/sbin/uname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname"
echo "00:10:7f:00:00:01" > "$T/mac"
echo "built 2026-09-29, kernel flavor stable" > "$T/rver"
echo "quiet console=tty0" > "$T/cmdline"
cat > "$T/lib.sh" <<EOF
tsx_find_disk() { WHOLE=/dev/null; }
tsx_pick_fwenv() { :; }
tsx_env() {
	case \$1 in
	product_name) echo "TSS-10_[v3.002.1061,_#0A1B2C3D]";;
	ethaddr) [ -e "$T/noenvmac" ] && return 1; echo "00:10:7f:00:00:01";;
	*) return 1;;
	esac
}
tsx_unit_id() { echo 00107f000001; }
EOF
echo "rescue image active" > "$T/run/rescue-reason"
echo uboot > "$T/run/tsx-eth0-mac-src"
touch "$T/rescue-image"
sed -e "s|/proc/cmdline|$T/cmdline|g; s|/etc/tsx/rescue-image|$T/rescue-image|g" \
    -e "s|ip -4 -o addr show eth0|$T/sbin/ip|g; s|uname -r|$T/sbin/uname|; s|/sys/class/net/eth0/address|$T/mac|" \
    -e 's|> /dev/kmsg|> /dev/null|; s|> "\$TTY"|>> "$TTY"|' "$RS" > "$T/rs.sh"
export TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw TSX_LIB=$T/lib.sh TSX_VERFILE=$T/rver TSX_STATUS_IN=$T/keys TSX_STATUS_WAIT=1

# render [COLS]: one frame, escape codes stripped
render() {
	: > "$T/frame.raw"
	TSX_STATUS_COLS=${1:-80} sh "$T/rs.sh" once
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
clear_op() { rm -f "$T/run/tsx-install-state" "$T/run/tsx-op" "$T/run/tsx-progress"; }
running() { echo "$$ install" > "$T/run/tsx-op"; echo "$1" > "$T/run/tsx-install-state"; }

echo "== idle =="
clear_op; render
want '^\\___)=(___/   rescue$' "the line under the banner is just \"rescue\""
wantnot 'mainline rescue' "no \"mainline rescue -- TSW ...\" line"
wantnot 'reason for rescue' "no reason row"
wantnot '^status' "no status row"
wantnot 'idle: waiting' "no idle status text"
want '^model        : TSS-10   stock fw v3.002.1061   unit 00107f000001$' "model cleaned, unit shown"
wantnot '0A1B2C3D' "no tsid on the screen"
want '^rescue       : built 2026-09-29, kernel flavor stable$' "rescue version + flavor"
want '^kernel       : 7.2.8-00116-gb5862166389d$' "kernel"
want '^network      : eth0 192.0.2.10 (dhcp, MAC 00:10:7f:00:00:01, uboot)$' "network"
want '^repair shell : ssh root@192.0.2.10   (password: tsx)$' "repair shell"
want '^Press Enter for a rescue shell$' "Enter line"
wantnot 'DO NOT power off' "no warning while idle"
wantnot '^install' "no operation section while idle"
wantnot 'Power-cycle' "rescue image: no power-cycle advice"
fit 80
render 85; fit 85

echo "== network before rcS has set the MAC =="
# rcS has not written tsx-eth0-mac-src yet: eth0 has the random kernel MAC and no address.
rm -f "$T/run/tsx-eth0-mac-src"; touch "$T/noip"; echo "02:5a:11:22:33:44" > "$T/mac"; render
want '^network      : eth0 (starting) (dhcp, MAC 00:10:7f:00:00:01, uboot)$' "starting: the MAC from the U-Boot env"
wantnot '02:5a:11:22:33:44' "starting: no random kernel MAC"
wantnot 'no address yet' "starting: no \"no address yet\""
touch "$T/noenvmac"; render
want '^network      : eth0 (starting) (dhcp)$' "starting, no env ethaddr: no MAC"
wantnot '02:5a:11:22:33:44' "starting, no env ethaddr: no random kernel MAC"
rm -f "$T/noenvmac"
echo random > "$T/run/tsx-eth0-mac-src"; render
want '^network      : eth0 (no address yet) (dhcp, MAC 02:5a:11:22:33:44, random)$' "rcS done, DHCP runs: the MAC that eth0 has"
echo uboot > "$T/run/tsx-eth0-mac-src"; rm -f "$T/noip"; echo "00:10:7f:00:00:01" > "$T/mac"; render
want '^network      : eth0 192.0.2.10 (dhcp, MAC 00:10:7f:00:00:01, uboot)$' "address assigned"

echo "== install running =="
running "writing eMMC root (p8)"
echo "314572800 0 838860800 eMMC root" > "$T/run/tsx-progress"
render
want '^install: writing eMMC root (p8)$' "operation name and step"
want '^  \[###############-*\]  38%  300 of 800 MiB$' "progress bar with MiB and percent"
want '^DO NOT power off the system\.$' "warning while running"
want '^Press Enter for a rescue shell$' "Enter line while running"
wantnot 'Power-cycle' "no power-cycle advice while running"
wantnot 'reason for rescue' "still no reason row"
fit 80
render 85; fit 85
bar=$(sed -n 's/^  \[\(.*\)\].*/\1/p' "$T/frame"); [ ${#bar} -eq 40 ] && ok "bar is 40 cells" || bad "bar is ${#bar} cells"
echo "838860800 0 838860800 eMMC root" > "$T/run/tsx-progress"; render
want '\[########################################\] 100%  800 of 800 MiB' "100% bar"
echo "5000000 0 0 unknown length" > "$T/run/tsx-progress"; render
want '^  5 MiB written$' "unknown length: MiB written, no bar"
# progress from an earlier step (file older than 2 minutes) is not shown
echo "314572800 0 838860800 eMMC root" > "$T/run/tsx-progress"; touch -d '2020-01-01 00:00:00' "$T/run/tsx-progress"; render
wantnot '\[#' "stale progress file ignored"
want '^install: writing eMMC root (p8)$' "step still shown"
rm -f "$T/run/tsx-progress"
echo "factory restore" > /dev/null; echo "$$ factory restore" > "$T/run/tsx-op"; echo "2/5 writing region p2" > "$T/run/tsx-install-state"; render
want '^factory restore: 2/5 writing region p2$' "another tool's name"
running "verifying"
sh -c 'exit 0' & dead=$!; wait $dead
echo "$dead install" > "$T/run/tsx-op"; render
want 'install stopped' "dead tool pid: stopped, not running"
wantnot 'DO NOT power off' "no power-off warning for a stopped tool"
echo "failed: no root partition found on /dev/mmcblk1 and this text goes on and on and on past the width" > "$T/run/tsx-install-state"; echo "$$ install" > "$T/run/tsx-op"; render
want '^install FAILED: failed: no root' "failed operation shown"
fit 80
echo "done, rebooting" > "$T/run/tsx-install-state"; render
want '^install: done, rebooting$' "done shown"
echo "checked OK" > "$T/run/tsx-install-state"; render
wantnot '^install' "a finished check is not an operation"
echo "idle: waiting" > "$T/run/tsx-install-state"; render
wantnot '^install' "idle state file is not an operation"

echo "== rescue paths =="
clear_op
rm -f "$T/rescue-image"; export TSX_VERFILE=$T/none; render
wantnot 'Power-cycle' "initramfs rescue: no power-cycle advice"
wantnot 'stock Android' "initramfs rescue: no stock Android claim"
want '^rescue       : initramfs rescue' "initramfs rescue: no version file needed"
echo "quiet tsx.rescue console=tty0" > "$T/cmdline"; render
wantnot 'Power-cycle' "tsx.rescue on the command line: no power-cycle advice"
echo "quiet tsx.ip=192.0.2.9/24,192.0.2.1" > "$T/cmdline"; touch "$T/rescue-image"; export TSX_VERFILE=$T/rver; render
want '(static, MAC' "static network"

echo "== Enter opens the shell =="
clear_op
printf '#!/bin/sh\necho "$$ shell" >> "%s/shell.calls"\nexit 0\n' "$T" > "$T/shell-stub"; chmod 755 "$T/shell-stub"
export TSX_STATUS_SHELL=$T/shell-stub TSX_STATUS_LOOPS=2
: > "$T/keys"; : > "$T/frame.raw"; rm -f "$T/shell.calls"
sh "$T/rs.sh" loop
[ ! -e "$T/shell.calls" ] && ok "no Enter: no shell" || bad "shell started without Enter"
echo > "$T/keys"; : > "$T/frame.raw"
sh "$T/rs.sh" loop
[ "$(wc -l < "$T/shell.calls" 2>/dev/null || echo 0)" -eq 1 ] && ok "Enter: one shell" || bad "Enter: shell calls: $(cat "$T/shell.calls" 2>/dev/null)"
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
want "Rescue shell on this console (no password)" "shell banner on the screen"
want "Why this rescue: rescue image active" "shell banner says why"
wantnot 'WARNING' "no warning while idle"
want '^Press Enter for a rescue shell$' "the screen is drawn again after exit"
n=$(grep -c '^\\___)=(___/   rescue$' "$T/frame"); [ "$n" -ge 2 ] && ok "frame before and after the shell" || bad "frame drawn $n times"
running "writing eMMC root (p8)"; echo > "$T/keys"; : > "$T/frame.raw"
sh "$T/rs.sh" loop
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
want '^WARNING: install is running (writing eMMC root (p8)). DO NOT power off the system\.$' "shell banner warns while an install runs"
: > "$T/keys"; : > "$T/frame.raw"; rm -f "$T/shell.calls"
sh "$T/rs.sh" loop && ok "loop exits with its round limit" || bad "loop"

echo "== wiring =="
grep -q '^tty1::respawn:/usr/sbin/tsx-rescue-status loop$' "$HERE/rootfs/initramfs/overlay/etc/inittab" && ok "inittab: the screen on tty1" || bad "inittab does not start the screen on tty1"
grep -q 'getty.*tty1' "$HERE/rootfs/initramfs/overlay/etc/inittab" && bad "inittab still has a getty on tty1" || ok "no getty on tty1"
[ -x "$RS" ] && ok "screen script executable" || bad "not executable"
for f in installer/steps/tsx-rescue-install installer/factory/tsx-factory-restore installer/factory/tsx-emmc-restore; do
	grep -q 'tsx-op' "$HERE/$f" && ok "$f writes tsx-op" || bad "$f does not write tsx-op"
done
cmp -s "$HERE/installer/factory/tsx-factory-restore" "$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-factory-restore" && ok "initramfs tsx-factory-restore in sync" || bad "run installer/initramfs/integrate.sh"
# tsx-rescue and tsx-boot-ok: one source each, in the base initramfs, so
# `tsx-rescue status` works in both rescues.
MK=$HERE/rootfs/initramfs/mkinitramfs-switchroot.sh
[ -x "$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-rescue" ] && ok "tsx-rescue is in the initramfs overlay" || bad "tsx-rescue missing in the initramfs overlay"
[ ! -e "$HERE/installer/rescue/overlay/usr/sbin/tsx-rescue" ] && ok "no second tsx-rescue in the rescue overlay" || bad "installer/rescue/overlay has its own tsx-rescue again"
grep -q 'overlay/usr/local/sbin/tsx-boot-ok" \$R/usr/local/sbin/tsx-boot-ok' "$MK" && ok "mkinitramfs installs tsx-boot-ok from the rootfs overlay" || bad "mkinitramfs does not install tsx-boot-ok"
grep -q 'overlay/etc/tsx/uboot-env.conf" \$R/etc/tsx/uboot-env.conf' "$MK" && ok "mkinitramfs installs uboot-env.conf from the rootfs overlay" || bad "mkinitramfs does not install uboot-env.conf"
grep -q 'tsx-boot-ok\|uboot-env.conf' "$HERE/installer/rescue/mkrescue.sh" && ! grep -q '^install .*tsx-boot-ok\|^install .*uboot-env.conf' "$HERE/installer/rescue/mkrescue.sh" \
	&& ok "mkrescue.sh checks the tools in BASE and adds no copy" || bad "mkrescue.sh copies tsx-boot-ok or uboot-env.conf, or does not check BASE"

echo "== mkrescue.sh with a synthetic BASE =="
# A fake Android v0 boot image: the kernel is a uImage magic plus dummy bytes,
# and the DTB is dummy bytes. The rescue image must take tsx-rescue and
# tsx-boot-ok from BASE and add no copy.
if command -v python3 >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
	B=$T/base; mkdir -p "$B/etc/init.d" "$B/etc/tsx" "$B/usr/sbin" "$B/usr/local/sbin"
	echo '[ -e /etc/tsx/rescue-image ] && rescue' > "$B/init"
	echo 'tty1::respawn:/usr/sbin/tsx-rescue-status loop' > "$B/etc/inittab"
	echo 'ethaddr' > "$B/etc/init.d/rcS"
	echo 'ENV_VERIFIED=yes' > "$B/etc/tsx/uboot-env.conf"
	for f in usr/sbin/tsx-rescue-status usr/sbin/tsx-rescue usr/local/sbin/tsx-boot-ok; do printf '#!/bin/sh\n' > "$B/$f"; chmod 755 "$B/$f"; done
	mkbase() { # OUT.img
		(cd "$B" && find . -mindepth 1 | sort | cpio -o -H newc --quiet | gzip -9n) > "$T/base-rd.gz"
		python3 -c '
import struct, sys
rd = open(sys.argv[1], "rb").read(); ps = 2048; k = bytes.fromhex("27051956") + b"K" * 3000; s2 = b"D" * 500
pad = lambda b: b + b"\0" * (-len(b) % ps)
h = struct.pack("<8s10I16s512s32s", b"ANDROID!", len(k), 0x10008000, len(rd), 0x11000000, len(s2), 0x10f00000, 0x10000100, ps, 0, 0, b"", b"", b"")
open(sys.argv[2], "wb").write(pad(h) + pad(k) + pad(rd) + pad(s2))
' "$T/base-rd.gz" "$1"
	}
	mkbase "$T/base.img"
	if bash "$HERE/installer/rescue/mkrescue.sh" --base "$T/base.img" --out "$T/rescue.img" > "$T/mk.log" 2>&1; then
		ok "mkrescue.sh accepts a BASE with tsx-rescue, tsx-boot-ok and uboot-env.conf"
		ov=$(sed -n 's/^rescue overlay: //p' "$T/mk.log")
		[ "$ov" = "./etc/inittab ./etc/tsx/rescue-image " ] && ok "the rescue overlay adds only inittab and the rescue-image flag" || bad "rescue overlay: $ov"
	else bad "mkrescue.sh refused a good BASE: $(tail -n 1 "$T/mk.log")"; fi
	rm -f "$B/usr/sbin/tsx-rescue"; mkbase "$T/base2.img"
	if bash "$HERE/installer/rescue/mkrescue.sh" --base "$T/base2.img" --out "$T/rescue2.img" > "$T/mk2.log" 2>&1; then bad "mkrescue.sh accepted a BASE without tsx-rescue"
	else grep -q 'no usr/sbin/tsx-rescue' "$T/mk2.log" && ok "mkrescue.sh refuses a BASE without tsx-rescue" || bad "mkrescue.sh failed for another reason: $(tail -n 1 "$T/mk2.log")"; fi
else
	echo "  skip: mkrescue.sh check needs python3, cpio and bash"
fi

echo "$N ok, $F failed"
[ "$F" -eq 0 ]
