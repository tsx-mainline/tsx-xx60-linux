#!/bin/bash
# Host test: the LED map of the xx60 board file and the LED bar service of
# tsx-linux-common. The LED bar tools are in tsx-linux-common (package
# tsx-ledbar). The xx60 board file gives them the LED map of the panel model
# with the function tsx_board_ledbar_map. The test checks:
#   - the function: the TSW-1060-LB map for the TSW-1060, the TSW-1060-NC and
#     the TSS-10, no map for the TSW-760 and for an unknown model, and the
#     device tree as the source of the model when /run/tsx/model is missing
#   - the real tsx-ledbard with the real board file, a fake bar and a fake
#     tsx-ledbar: the LEDMAP line that the daemon sends for each model
#   - LEDMAP in ledbar.conf wins over the board file
#   - the key LEDBAR: the real tsx-hw writes LEDBAR=yes on every panel model,
#     and the real tsx-panelctl says "has ledbar" for that hw.conf (with a
#     fake tsx-ledbar tool). LEDBAR=no in hw.conf says no.
# The test needs no panel and no compiler.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED common/test-ledbar-xx60: no busybox on this host"; exit 0; }
D=$(P usr/local/sbin/tsx-ledbard)
[ -r "$D" ] || { echo "FAIL: no tsx-ledbard in $COMMON (the package folder ledbar is missing)"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
BOARD=$TSX_BOARD_CONF

echo "== tsx_board_ledbar_map =="
# map MODEL [DTFILE]: the answer of the board function. The DT file is the
# compatible file of the device tree (default: none).
map() { env -i PATH="$PATH" TSX_DT_COMPATIBLE="${2:-$T/no-dt}" busybox sh -c '. "$1"; tsx_board_ledbar_map "$2"; echo "rc=$?"' sh "$BOARD" "$1" | tr '\n' '|'; }
eq "$(map TSW-1060)" "TSW-1060-LB|rc=0|" "TSW-1060 has the TSW-1060-LB map"
eq "$(map TSW-1060-NC)" "TSW-1060-LB|rc=0|" "TSW-1060-NC has the TSW-1060-LB map"
eq "$(map TSS-10)" "TSW-1060-LB|rc=0|" "TSS-10 has the TSW-1060-LB map"
eq "$(map TSW-760)" "rc=0|" "TSW-760: no map"
eq "$(map TSW-760-NC)" "rc=0|" "TSW-760-NC: no map"
eq "$(map TSW-1060X)" "rc=0|" "a name that only starts like a TSW-1060: no map"
eq "$(map UNKNOWN-1)" "rc=0|" "an unknown model: no map"
eq "$(map '')" "rc=0|" "no model and no device tree: no map"
# the device tree names the board when the model is empty
printf 'crestron,tsw1060\000amlogic,meson8m2\000' > "$T/dt-1060"
printf 'crestron,tsw760\000amlogic,meson8m2\000' > "$T/dt-760"
printf 'other,board\000' > "$T/dt-other"
eq "$(map '' "$T/dt-1060")" "TSW-1060-LB|rc=0|" "no model, device tree crestron,tsw1060: TSW-1060-LB"
eq "$(map '' "$T/dt-760")" "rc=0|" "no model, device tree crestron,tsw760: no map"
eq "$(map '' "$T/dt-other")" "rc=0|" "no model, another device tree: no map"
eq "$(map TSW-760 "$T/dt-1060")" "rc=0|" "the model wins over the device tree (TSW-760)"
eq "$(map TSW-1060 "$T/dt-760")" "TSW-1060-LB|rc=0|" "the model wins over the device tree (TSW-1060)"

echo "== tsx-ledbard with the xx60 board file (fake bar, fake tsx-ledbar) =="
mkdir -p "$T/bin" "$T/usb/2-1" "$T/usb/2-1:1.0" "$T/run"
echo 14be > "$T/usb/2-1/idVendor"; echo 001b > "$T/usb/2-1/idProduct"
echo 2 > "$T/usb/2-1/busnum"; echo 2 > "$T/usb/2-1/devnum"
: > "$T/usb/2-1:1.0/bInterfaceNumber"
cat > "$T/bin/tsx-ledbar" <<EOF
#!/bin/sh
echo "\$*" >> "$T/calls"
case \$1 in
fw) printf 'firmware TSX-LEDBAR [v0.1.5]\neffects yes\nleds yes\n';;
console)
	case \$2 in
	CAPS) echo "tsx-ledbar fade blink breathe rainbow smooth cap status leds16 chase fill spectrum split ledmap";;
	tlcoutmode*) echo "LED driver - led-0 output mode is:3";;
	LEDMAP*) echo "variant 1 map \${2#LEDMAP } source";;
	esac;;
esac
exit 0
EOF
chmod +x "$T/bin/tsx-ledbar"
printf 'BOOT_COLOR="0 0 20"\n' > "$T/ledbar.conf"
# daemon MODEL [DTFILE] [CONF]: run "tsx-ledbard check" with the xx60 board file
# and print the LEDMAP line that it sends. MODEL empty: no /run/tsx/model.
daemon() {
	: > "$T/calls"; rm -f "$T/run/model"
	[ -z "$1" ] || echo "$1" > "$T/run/model"
	env -i PATH="$T/bin:$PATH" TSX_BOARD_CONF="$BOARD" TSX_DT_COMPATIBLE="${2:-$T/no-dt}" TSX_RUN_DIR="$T/run" \
		TSX_USB_SYSFS="$T/usb" TSX_LEDBAR_SYSFS="$T/led" TSX_LEDBAR_DRIVER="$T/nodriver" \
		TSX_LEDBAR_CONF="${3:-$T/ledbar.conf}" busybox sh "$D" check > "$T/log" 2>&1
	grep '^console LEDMAP' "$T/calls" | sed 's/^console //' | tr '\n' '|'
}
for m in TSW-1060 TSW-1060-NC TSS-10; do
	eq "$(daemon $m)" "LEDMAP TSW-1060-LB PANEL|" "$m: the daemon sends LEDMAP TSW-1060-LB PANEL"
	grep -q "LED map: sent LEDMAP TSW-1060-LB PANEL (panel $m)" "$T/log" && ok "$m: log line" || bad "$m: log: $(cat "$T/log")"
done
eq "$(daemon TSW-760)" "LEDMAP DEFAULT|" "TSW-760: the daemon sends LEDMAP DEFAULT"
grep -q "sent LEDMAP DEFAULT (panel TSW-760, no tested LED bar)" "$T/log" && ok "TSW-760: log line" || bad "TSW-760: log: $(cat "$T/log")"
eq "$(daemon '' "$T/dt-1060")" "LEDMAP TSW-1060-LB PANEL|" "no model file, device tree crestron,tsw1060: LEDMAP TSW-1060-LB PANEL"
eq "$(daemon '' "$T/dt-760")" "LEDMAP DEFAULT|" "no model file, device tree crestron,tsw760: LEDMAP DEFAULT"
eq "$(daemon '')" "LEDMAP DEFAULT|" "no model file and no device tree: LEDMAP DEFAULT"
echo "LEDMAP=outputs" > "$T/map.conf"
eq "$(daemon TSS-10 '' "$T/map.conf")" "LEDMAP outputs PANEL|" "LEDMAP=outputs in ledbar.conf wins over the board file"
echo "LEDMAP=default" > "$T/map.conf"
eq "$(daemon TSS-10 '' "$T/map.conf")" "LEDMAP DEFAULT|" "LEDMAP=default in ledbar.conf wins over the board file"

echo "== tsx-hw writes LEDBAR=yes, tsx-panelctl has ledbar reads it (real tsx-hw, real tsx-panelctl) =="
H=$T/hw; mkdir -p "$H/bin" "$H/proc" "$H/run"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/tsx-ledbar"; printf '#!/bin/sh\nexit 0\n' > "$H/bin/logger"
chmod +x "$H/bin/tsx-ledbar" "$H/bin/logger"
PCTL=$(P usr/local/sbin/tsx-panelctl)
# detect CMDLINE: tsx-hw detect for a kernel command line
detect() { echo "$1" > "$H/proc/cmdline"; rm -f "$H/run/hw.conf"; env -i PATH="$H/bin:$PATH" TSX_RUN_DIR="$H/run" TSX_PROC="$H/proc" busybox sh "$XX60_HW" detect > "$H/detect.out" 2>&1; }
# has_ledbar [TOOLDIR]: the exit code of "tsx-panelctl has ledbar" with the hw.conf of $H/run
has_ledbar() { env -i PATH="${1:-$H/bin}:$PATH" TSX_RUN_DIR="$H/run" TSX_BOARD_CONF="$BOARD" busybox sh "$PCTL" has ledbar >/dev/null 2>&1; echo $?; }
for c in 'console=tty0 androidboot.government=0' 'console=tty0 androidboot.government=1' 'console=tty0'; do
	detect "$c"
	eq "$(grep -c '^LEDBAR=' "$H/run/hw.conf")" 1 "tsx-hw ($c): one LEDBAR line"
	eq "$(sed -n 's/^LEDBAR=//p' "$H/run/hw.conf")" yes "tsx-hw ($c): LEDBAR=yes"
	eq "$(env -i PATH="$H/bin:$PATH" TSX_RUN_DIR="$H/run" TSX_PROC="$H/proc" busybox sh "$XX60_HW" get LEDBAR)" yes "tsx-hw get LEDBAR ($c)"
	eq "$(has_ledbar)" 0 "has ledbar with that hw.conf and the tool: yes ($c)"
done
eq "$(has_ledbar "$H/none")" 1 "has ledbar without the tool: no, also with LEDBAR=yes"
sed -i 's/^LEDBAR=yes$/LEDBAR=no/' "$H/run/hw.conf"
eq "$(has_ledbar)" 1 "has ledbar with LEDBAR=no in hw.conf: no, also with the tool"
rm -f "$H/run/hw.conf"
eq "$(has_ledbar)" 0 "has ledbar with no hw.conf and the tool: yes (a missing file means present)"

echo "== $N ok, $F failed =="
[ "$F" = 0 ]
