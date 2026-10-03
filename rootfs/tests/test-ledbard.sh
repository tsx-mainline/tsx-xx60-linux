#!/bin/sh
# Host test of tsx-ledbard: the start check of the LED driver chips and the
# restart of the STM32. A fake tsx-ledbar answers the console commands, and a
# fake USB sysfs dir holds the bar (14be:001b). A restart gives the bar a new
# USB device number, as on the panel. No compiler and no hardware needed.
#
# Fake console: the chips report "not initialized" until the bar had
# OK_AFTER restarts (file $T/ok_after). "silent" gives no answer.
# Fake firmware: "tsx-ledbar fw" prints the file $T/fw (stock by default).
# "console CAPS" prints the file $T/caps. "console LEDMAP ..." answers as
# TSX-LEDBAR 0.1.5 with the maps TSW-1060-LB and outputs.
# Panel model: the file $T/run/model, or the device tree file $T/dt.
# Fake package tool: "tsx-ledbar-fw-install" (only when the test puts it in
# $T/bin) answers --recover-image with the file $T/fwi_image (no file or an
# empty file: no image, exit 3) and --recover with a flash that takes 1 s. The
# flash gives the bar a new USB device (001b), or fails when $T/fwi_rc is not
# 0. With the file $T/fwi_old, the tool is an old version: every call fails
# with exit 1 (usage). The file $T/fwi_calls lists each call.
# SH selects the shell for tsx-ledbard (default sh, for example SH="busybox sh").
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D=$HERE/../overlay/usr/local/sbin/tsx-ledbard
SH=${SH:-sh}
T=$(mktemp -d)
DPID=
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$T/bin" "$T/usb"
cat > "$T/bin/tsx-ledbar" <<EOF
#!/bin/sh
T=$T
echo "\$*" >> "\$T/calls"
case \$1 in
console)
	r=\$(cat "\$T/reboots")
	case \$2 in
	reboot)
		echo \$((r + 1)) > "\$T/reboots"
		[ -e "\$T/no_reenum" ] && exit 0
		read -r d < "\$T/usb/2-1/devnum"
		echo \$((d + 1)) > "\$T/usb/2-1/devnum"
		exit 0;;
	CAPS) cat "\$T/caps" 2>/dev/null; exit 0;;
	"LEDMAP "*)
		set -- \$2
		case \$2:\${3:-} in
		DEFAULT:) echo "variant 1 map TSW-1060-LB default";;
		TSW-1060-LB:PANEL|outputs:PANEL) echo "variant 1 map \$2 panel";;
		*) echo "no LED map \$2"; echo "maps TSW-1060-LB outputs";;
		esac
		exit 0;;
	"tlcoutmode "*)
		[ "\$(cat "\$T/ok_after")" = silent ] && exit 0
		if [ "\$r" -ge "\$(cat "\$T/ok_after")" ]; then
			set -- \$2
			echo "\$2 LED driver - led-0 output mode is:3"
		else
			echo "LED driver not initialized!"
		fi
		exit 0;;
	esac;;
get) echo "want 0 0 20";;
fw) cat "\$T/fw";;
esac
exit 0
EOF
chmod +x "$T/bin/tsx-ledbar"
PATH=$T/bin:$PATH
export TSX_USB_SYSFS=$T/usb TSX_LEDBAR_SYSFS=$T/led TSX_LEDBAR_DRIVER=$T/nodriver
export TSX_LEDBAR_WAIT=3
# no panel model and no device tree of the host
mkdir -p "$T/run"
export TSX_RUN_DIR=$T/run TSX_DT_COMPATIBLE=$T/dt

plug() {
	mkdir -p "$T/usb/2-1" "$T/usb/2-1:1.0"
	echo 14be > "$T/usb/2-1/idVendor"; echo 001b > "$T/usb/2-1/idProduct"
	echo 2 > "$T/usb/2-1/busnum"; echo "${1:-2}" > "$T/usb/2-1/devnum"
	: > "$T/usb/2-1:1.0/bInterfaceNumber"
}
STOCK="firmware TSW-XX60-LB [v1.3443.00018]
effects no"
OWN="firmware TSX-LEDBAR [v0.1.1]
effects yes"
OWN15="firmware TSX-LEDBAR [v0.1.5]
effects yes"
CAPS14="tsx-ledbar fade blink breathe rainbow smooth cap status leds16 chase fill spectrum split"
CAPS15="$CAPS14 ledmap"
reset() { echo 0 > "$T/reboots"; echo "$1" > "$T/ok_after"; : > "$T/calls"; rm -f "$T/no_reenum"; echo "$STOCK" > "$T/fw"; : > "$T/caps"; }
reboots() { cat "$T/reboots"; }
ncalls() { grep -c "^$1" "$T/calls"; }

plug

# 1. not initialized, one restart, then the chips start
reset 1
out=$($SH "$D" check 2>&1); rc=$?
[ $rc = 0 ] && ok "restart: rc 0" || bad "restart: rc $rc"
[ "$(reboots)" = 1 ] && ok "restart: one reboot" || bad "restart: $(reboots) reboots"
echo "$out" | grep -q "Restarting the LED bar controller (try 1 of 3)" && ok "restart: log line" || bad "restart: log: $out"
echo "$out" | grep -q "LED drivers started after 1 restart" && ok "restart: started line" || bad "restart: no started line: $out"
[ "$(tail -n 1 "$T/calls")" = apply ] && ok "restart: color applied last" || bad "restart: last call $(tail -n 1 "$T/calls")"
[ "$(cat "$T/usb/2-1/devnum")" = 3 ] && ok "restart: new USB number" || bad "restart: devnum"

# 2. never initialized: three restarts, then give up
reset 99
out=$($SH "$D" check 2>&1); rc=$?
[ $rc = 1 ] && ok "give up: rc 1" || bad "give up: rc $rc"
[ "$(reboots)" = 3 ] && ok "give up: three reboots" || bad "give up: $(reboots) reboots"
echo "$out" | grep -q "did not start after 3 restarts. The LED bar stays dark" && ok "give up: log line" || bad "give up: log: $out"
[ "$(ncalls 'console tlcoutmode red 0')" = 4 ] && ok "give up: four checks" || bad "give up: $(ncalls 'console tlcoutmode red 0') checks"
[ "$(tail -n 1 "$T/calls")" = apply ] && ok "give up: color still applied" || bad "give up: last call"

# 3. already started: no restart, all three chips checked
reset 0
out=$($SH "$D" check 2>&1); rc=$?
[ $rc = 0 ] && ok "started: rc 0" || bad "started: rc $rc"
[ "$(reboots)" = 0 ] && ok "started: no reboot" || bad "started: $(reboots) reboots"
[ "$(ncalls 'console tlcoutmode')" = 3 ] && ok "started: red, green and blue checked" || bad "started: $(ncalls 'console tlcoutmode') checks"
[ "$(echo "$out" | sed 's/^[-0-9: ]*//')" = "tsx-ledbar: LED bar firmware TSW-XX60-LB [v1.3443.00018], no effects" ] && ok "started: only the firmware line" || bad "started: log: $out"
[ "$(ncalls fx)" = 0 ] && ok "stock firmware: no fx command" || bad "stock firmware: $(grep ^fx "$T/calls")"

# 3b. the effect settings of ledbar.conf: sent with TSX-LEDBAR, not with the stock firmware
printf 'FX_SMOOTH=500\nFX_CAP="120"\n' > "$T/fx.conf"
reset 0
out=$(TSX_LEDBAR_CONF=$T/fx.conf $SH "$D" check 2>&1)
[ "$(ncalls fx)" = 0 ] && ok "stock firmware: FX_SMOOTH and FX_CAP not sent" || bad "stock firmware: $(grep ^fx "$T/calls")"
echo "$out" | grep -q "FX_SMOOTH and FX_CAP need the LED bar firmware TSX-LEDBAR" && ok "stock firmware: settings log line" || bad "stock firmware: log: $out"
reset 0; echo "$OWN" > "$T/fw"
out=$(TSX_LEDBAR_CONF=$T/fx.conf $SH "$D" check 2>&1)
echo "$out" | grep -q "LED bar firmware TSX-LEDBAR \[v0.1.1\], effects on" && ok "own firmware: log line" || bad "own firmware: log: $out"
[ "$(grep -v '^console' "$T/calls" | tr '\n' '|')" = "fw|fx smooth 500|fx cap 120|apply|" ] && ok "own firmware: settings, then apply" || bad "own firmware: calls $(cat "$T/calls")"
reset 0; echo "$OWN" > "$T/fw"
out=$($SH "$D" check 2>&1)
[ "$(ncalls fx)" = 0 ] && ok "own firmware without settings: no fx command" || bad "own firmware: $(grep ^fx "$T/calls")"

# 4. no clear answer on the console: no restart
reset silent
out=$($SH "$D" check 2>&1); rc=$?
[ "$(reboots)" = 0 ] && ok "no answer: no reboot" || bad "no answer: $(reboots) reboots"
echo "$out" | grep -q "cannot read the LED driver state" && ok "no answer: log line" || bad "no answer: log: $out"

# 5. the bar does not come back after the restart
reset 99; : > "$T/no_reenum"
out=$($SH "$D" check 2>&1); rc=$?
[ $rc = 1 ] && [ "$(reboots)" = 1 ] && ok "no come back: rc 1 after one reboot" || bad "no come back: rc $rc, $(reboots) reboots"
echo "$out" | grep -q "did not come back within 3 s" && ok "no come back: log line" || bad "no come back: log: $out"

# 6. no bar
rm -rf "$T/usb/2-1" "$T/usb/2-1:1.0"; reset 0
out=$($SH "$D" check 2>&1); rc=$?
[ $rc = 1 ] && [ ! -s "$T/calls" ] && ok "no bar: rc 1, no command" || bad "no bar: rc $rc, calls $(cat "$T/calls")"

# 7. service: boot color at the first plug-in, a check after a hot plug-in
reset 0
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
sleep 2
[ ! -s "$T/calls" ] && ok "service: no command without the bar" || bad "service: calls without bar: $(cat "$T/calls")"
grep -q "LED bar not found yet" "$T/log" && ok "service: waiting line" || bad "service: no waiting line"
plug 5
sleep 3
grep -qx boot "$T/calls" && ok "service: boot color at the first plug-in" || bad "service: no boot call: $(cat "$T/calls")"
grep -q "LED bar firmware TSW-XX60-LB" "$T/log" && ok "service: firmware line" || bad "service: no firmware line"
[ "$(reboots)" = 0 ] && ok "service: good bar, no reboot" || bad "service: $(reboots) reboots"
rm -rf "$T/usb/2-1" "$T/usb/2-1:1.0"
sleep 2
grep -q "LED bar removed" "$T/log" && ok "service: removal seen" || bad "service: no removal line"
[ "$(grep -c "LED bar not found yet" "$T/log")" = 1 ] && ok "service: no waiting line after a removal" || bad "service: waiting line after a removal"
: > "$T/calls"; echo 1 > "$T/ok_after"
plug 9
sleep 4
[ "$(reboots)" = 1 ] && ok "service: hot plug-in, one restart" || bad "service: hot plug-in, $(reboots) reboots"
grep -q "LED bar plugged in" "$T/log" && ok "service: plug-in line" || bad "service: no plug-in line"
grep -qx apply "$T/calls" && ! grep -qx boot "$T/calls" && ok "service: wanted color applied, not the boot color" || bad "service: calls $(cat "$T/calls")"
n=$(ncalls 'console tlcoutmode red 0')
sleep 2
[ "$(ncalls 'console tlcoutmode red 0')" = "$n" ] && ok "service: no check while the bar stays" || bad "service: checks go on"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

# 8. an old ledbar.conf with BLANK keys: logged once, the screen state does nothing
for old in 'BLANK=off' 'BLANK=dim
BLANK_DIM=50'; do
	reset 0; plug 5; : > "$T/calls"
	echo "$old" > "$T/ledbar.conf"
	echo awake > "$T/idled.state"
	TSX_LEDBAR_CONF=$T/ledbar.conf TSX_IDLED_STATE=$T/idled.state $SH "$D" > "$T/log" 2>&1 &
	DPID=$!
	sleep 3
	: > "$T/calls"
	echo blank > "$T/idled.state"
	sleep 2
	echo awake > "$T/idled.state"
	sleep 2
	n=$(ncalls apply)
	[ "$n" = 0 ] && ! grep -Eq "screen (blank|awake)" "$T/log" && ok "old conf ($(echo "$old" | head -n 1)): no apply on blank or wake" || bad "old conf: $n apply calls, log $(cat "$T/log")"
	[ "$(grep -c 'BLANK and BLANK_DIM' "$T/log")" = 1 ] && ok "old conf: one log line" || bad "old conf: log $(cat "$T/log")"
	kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=
done

# 9. the bar in bootloader mode (14be:001a): one load for each start of the service
cat > "$T/fwi" <<EOF
#!/bin/sh
T=$T
echo "\$*" >> "\$T/fwi_calls"
if [ -e "\$T/fwi_old" ]; then
	echo "tsx-ledbar-fw-install: usage: tsx-ledbar-fw-install [FILE.upg | --check]" >&2
	exit 1
fi
case \$1 in
--recover-image)
	[ -s "\$T/fwi_image" ] || exit 3
	cat "\$T/fwi_image";;
--recover)
	echo "12:00:00 fake flash: bootloader ready"
	sleep 1
	if [ "\$(cat "\$T/fwi_rc")" != 0 ]; then
		echo "tsx-ledbar-fw-install: flash failed, the bar keeps its bootloader" >&2
		exit 1
	fi
	rm -rf "\$T/usb/2-1" "\$T/usb/2-1:1.0"
	mkdir -p "\$T/usb/2-1" "\$T/usb/2-1:1.0"
	echo 14be > "\$T/usb/2-1/idVendor"; echo 001b > "\$T/usb/2-1/idProduct"
	echo 2 > "\$T/usb/2-1/busnum"; echo 11 > "\$T/usb/2-1/devnum"
	: > "\$T/usb/2-1:1.0/bInterfaceNumber"
	echo "12:00:01 fake flash: flash done";;
esac
exit 0
EOF
chmod +x "$T/fwi"
fwi_on() { cp "$T/fwi" "$T/bin/tsx-ledbar-fw-install"; }
fwi_off() { rm -f "$T/bin/tsx-ledbar-fw-install"; }
fwi_reset() { : > "$T/fwi_calls"; echo 0 > "$T/fwi_rc"; echo /fake/tsx-ledbar.upg > "$T/fwi_image"; rm -f "$T/fwi_old"; }
fwi_n() { grep -c -x -e "$1" "$T/fwi_calls"; }
plug_btl() {
	rm -rf "$T/usb/2-1" "$T/usb/2-1:1.0"
	mkdir -p "$T/usb/2-1"
	echo 14be > "$T/usb/2-1/idVendor"; echo 001a > "$T/usb/2-1/idProduct"
	echo 2 > "$T/usb/2-1/busnum"; echo 7 > "$T/usb/2-1/devnum"
}
unplug() { rm -rf "$T/usb/2-1" "$T/usb/2-1:1.0"; }
# until the shell test $1 is true, at most 12 s
waitfor() { w=0; while [ $w -lt 12 ] && ! eval "$1"; do sleep 1; w=$((w + 1)); done; eval "$1"; }
lineno() { grep -n -e "$1" "$T/log" | head -n 1 | cut -d: -f1; }

# 9a. in bootloader mode at start, package and image there: one load, then the normal start
unplug; reset 0; fwi_reset; fwi_on; plug_btl
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
waitfor 'grep -qx boot "$T/calls"' && ok "btl start: boot color after the load" || bad "btl start: no boot call: $(cat "$T/calls")"
[ "$(fwi_n --recover)" = 1 ] && ok "btl start: one --recover" || bad "btl start: $(fwi_n --recover) --recover calls"
grep -q "bootloader mode (USB 14be:001a). Loading the image of this panel" "$T/log" && ok "btl start: start line" || bad "btl start: log: $(cat "$T/log")"
a=$(lineno "fake flash: bootloader ready"); b=$(lineno "load ended"); c=$(lineno "LED bar found")
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok "btl start: progress, result, then found" || bad "btl start: order $a $b $c: $(cat "$T/log")"
! grep -qi tlcreset "$T/calls" && ok "btl start: no TLCRESET" || bad "btl start: TLCRESET sent"
sleep 3
[ "$(fwi_n --recover)" = 1 ] && ok "btl start: still one --recover" || bad "btl start: $(fwi_n --recover) --recover calls later"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

# 9b. in bootloader mode, package there, but no image: one line, nothing else
unplug; reset 0; fwi_reset; : > "$T/fwi_image"; fwi_on; plug_btl
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
sleep 4
[ "$(wc -l < "$T/log")" = 1 ] && grep -q "bootloader mode (USB 14be:001a) and there is no image to load" "$T/log" && ok "btl no image: one log line" || bad "btl no image: log: $(cat "$T/log")"
[ "$(fwi_n --recover)" = 0 ] && ok "btl no image: no load" || bad "btl no image: --recover called"
[ ! -s "$T/calls" ] && ok "btl no image: no tsx-ledbar command" || bad "btl no image: calls $(cat "$T/calls")"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

# 9c. in bootloader mode, no package: one line, nothing else
unplug; reset 0; fwi_reset; fwi_off; plug_btl
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
sleep 4
[ "$(wc -l < "$T/log")" = 1 ] && grep -q "the package tsx-ledbar-fw is not installed" "$T/log" && ok "btl no package: one log line" || bad "btl no package: log: $(cat "$T/log")"
[ ! -s "$T/calls" ] && [ ! -s "$T/fwi_calls" ] && ok "btl no package: no command" || bad "btl no package: calls $(cat "$T/calls") $(cat "$T/fwi_calls")"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

# 9d. a normal bar: the package tool is never called
unplug; reset 0; fwi_reset; fwi_on; plug 5
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
waitfor 'grep -qx boot "$T/calls"' && ok "normal bar: boot color" || bad "normal bar: no boot call"
sleep 2
[ ! -s "$T/fwi_calls" ] && ok "normal bar: package tool not called" || bad "normal bar: fwi calls $(cat "$T/fwi_calls")"
! grep -q "bootloader" "$T/log" && ok "normal bar: no bootloader line" || bad "normal bar: log: $(cat "$T/log")"

# 9e. hot plug: the same service, the bar goes to the bootloader. One load, and no second one.
fwi_reset; : > "$T/calls"
plug_btl
waitfor 'grep -q "LED bar plugged in" "$T/log"' && ok "btl hotplug: application back" || bad "btl hotplug: log: $(cat "$T/log")"
[ "$(fwi_n --recover)" = 1 ] && ok "btl hotplug: one --recover" || bad "btl hotplug: $(fwi_n --recover) --recover calls"
waitfor 'grep -qx apply "$T/calls"' && ok "btl hotplug: wanted color applied" || bad "btl hotplug: calls $(cat "$T/calls")"
plug_btl
waitfor 'grep -q "The one try of this start is used" "$T/log"' && ok "btl again: try-used line" || bad "btl again: log: $(cat "$T/log")"
sleep 2
[ "$(fwi_n --recover)" = 1 ] && ok "btl again: no second --recover" || bad "btl again: $(fwi_n --recover) --recover calls"
[ "$(grep -c "The one try of this start is used" "$T/log")" = 1 ] && ok "btl again: the line comes once" || bad "btl again: log: $(cat "$T/log")"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

# 9f. the load fails: one try for this start of the service, also when the
# bootloader comes back again and again. A new start of the service tries once more.
unplug; reset 0; fwi_reset; echo 1 > "$T/fwi_rc"; plug_btl
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
waitfor 'grep -q "LED bar load failed" "$T/log"' && ok "btl fail: failure line" || bad "btl fail: log: $(cat "$T/log")"
for i in 1 2 3; do unplug; sleep 1; plug_btl; sleep 2; done
[ "$(fwi_n --recover)" = 1 ] && ok "btl fail: one --recover after 3 plug-ins" || bad "btl fail: $(fwi_n --recover) --recover calls"
[ "$(wc -l < "$T/log")" = 4 ] && ok "btl fail: no more log lines while only the bootloader comes back" || bad "btl fail: log: $(cat "$T/log")"
[ ! -s "$T/calls" ] && ok "btl fail: no tsx-ledbar command" || bad "btl fail: calls $(cat "$T/calls")"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
waitfor '[ "$(fwi_n --recover)" = 2 ]' && ok "btl fail: a new start tries again" || bad "btl fail: $(fwi_n --recover) --recover calls after the restart"
sleep 2
[ "$(fwi_n --recover)" = 2 ] && ok "btl fail: and only once" || bad "btl fail: $(fwi_n --recover) --recover calls"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

# 9g. an old package (no --recover-image): one line that says so, no load
unplug; reset 0; fwi_reset; touch "$T/fwi_old"; fwi_on; plug_btl
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
sleep 4
[ "$(wc -l < "$T/log")" = 1 ] && grep -q "the installed tsx-ledbar-fw is too old" "$T/log" && ok "btl old package: one log line" || bad "btl old package: log: $(cat "$T/log")"
[ "$(fwi_n --recover)" = 0 ] && [ ! -s "$T/calls" ] && ok "btl old package: no load, no command" || bad "btl old package: calls $(cat "$T/fwi_calls") $(cat "$T/calls")"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=
rm -f "$T/fwi_old"

# 9h. "tsx-ledbard check" does not load: it tells about the bootloader
unplug; reset 0; fwi_reset; fwi_on; plug_btl
out=$($SH "$D" check 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "bootloader mode (USB 14be:001a). Start the tsx-ledbar service" && ok "check: bootloader line, rc 1" || bad "check: rc $rc, $out"
[ ! -s "$T/fwi_calls" ] && [ ! -s "$T/calls" ] && ok "check: no command" || bad "check: calls"


# 10. the LED map: TSX-LEDBAR 0.1.5 and later ("ledmap" in CAPS) gets
# LEDMAP after the check and before the first color
own15() { reset "${1:-0}"; echo "$OWN15" > "$T/fw"; echo "$CAPS15" > "$T/caps"; }
model() { if [ -n "$1" ]; then echo "$1" > "$T/run/model"; else rm -f "$T/run/model"; fi; }
mapcalls() { grep '^console LEDMAP' "$T/calls" | sed 's/^console //' | tr '\n' '|'; }
callno() { grep -n -x -e "$1" "$T/calls" | head -n 1 | cut -d: -f1; }
unplug; plug 5; rm -f "$T/dt"
for m in TSS-10 TSW-1060 TSW-1060-NC; do
	own15; model "$m"
	out=$($SH "$D" check 2>&1); rc=$?
	[ $rc = 0 ] && [ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && ok "map $m: LEDMAP TSW-1060-LB PANEL" || bad "map $m: rc $rc, calls $(cat "$T/calls")"
	echo "$out" | grep -q "LED map: sent LEDMAP TSW-1060-LB PANEL (panel $m). Bar: variant 1 map TSW-1060-LB panel" && ok "map $m: log line" || bad "map $m: log: $out"
done
a=$(callno 'console LEDMAP TSW-1060-LB PANEL'); b=$(callno apply)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok "map: LEDMAP before the first color" || bad "map: order $a $b: $(cat "$T/calls")"
own15; model TSW-760
out=$($SH "$D" check 2>&1)
[ "$(mapcalls)" = "LEDMAP DEFAULT|" ] && ok "map TSW-760: no map name, only LEDMAP DEFAULT" || bad "map TSW-760: calls $(mapcalls)"
echo "$out" | grep -q "sent LEDMAP DEFAULT (panel TSW-760, no tested LED bar). Bar: variant 1 map TSW-1060-LB default" && ok "map TSW-760: log line" || bad "map TSW-760: log: $out"

# 10b. no model file: the device tree tells the board
own15; model ""
printf 'crestron,tsw1060\000amlogic,meson8m2\000' > "$T/dt"
out=$($SH "$D" check 2>&1)
[ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && echo "$out" | grep -q "(panel TSW-1060)" && ok "map from the device tree: crestron,tsw1060" || bad "map dt 1060: $(mapcalls) $out"
own15; printf 'crestron,tsw760\000amlogic,meson8m2\000' > "$T/dt"
$SH "$D" check >/dev/null 2>&1
[ "$(mapcalls)" = "LEDMAP DEFAULT|" ] && ok "map from the device tree: crestron,tsw760 gets the default" || bad "map dt 760: $(mapcalls)"
own15; rm -f "$T/dt"
out=$($SH "$D" check 2>&1)
[ "$(mapcalls)" = "LEDMAP DEFAULT|" ] && echo "$out" | grep -q "(panel model unknown, no tested LED bar)" && ok "map: no model, the default" || bad "map no model: $(mapcalls) $out"

# 10c. LEDMAP in ledbar.conf overrides the panel model
model TSS-10
for v in outputs '"outputs"' "'outputs' # bring-up"; do
	own15; echo "LEDMAP=$v" > "$T/map.conf"
	out=$(TSX_LEDBAR_CONF=$T/map.conf $SH "$D" check 2>&1)
	[ "$(mapcalls)" = "LEDMAP outputs PANEL|" ] && echo "$out" | grep -q "sent LEDMAP outputs PANEL (LEDMAP=outputs in ledbar.conf). Bar: variant 1 map outputs panel" && ok "conf LEDMAP=$v" || bad "conf LEDMAP=$v: $(mapcalls) $out"
done
own15; echo "LEDMAP=default" > "$T/map.conf"
TSX_LEDBAR_CONF=$T/map.conf $SH "$D" check >/dev/null 2>&1
[ "$(mapcalls)" = "LEDMAP DEFAULT|" ] && ok "conf LEDMAP=default: LEDMAP DEFAULT" || bad "conf default: $(mapcalls)"
own15; echo "LEDMAP=" > "$T/map.conf"
TSX_LEDBAR_CONF=$T/map.conf $SH "$D" check >/dev/null 2>&1
[ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && ok "conf LEDMAP= (empty): the map of the panel model" || bad "conf empty: $(mapcalls)"
own15; echo "LEDMAP=TSW-760-LB" > "$T/map.conf"
out=$(TSX_LEDBAR_CONF=$T/map.conf $SH "$D" check 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "the bar has no map TSW-760-LB (LEDMAP=TSW-760-LB in ledbar.conf). maps TSW-1060-LB outputs. The bar keeps its map" && [ "$(tail -n 1 "$T/calls")" = apply ] && ok "conf: a map that the bar does not have: log line, the color still comes" || bad "conf unknown map: rc $rc, $out"

# 10d. firmware without "ledmap" and the stock firmware: no LEDMAP
reset 0; echo "$OWN" > "$T/fw"; echo "$CAPS14" > "$T/caps"
out=$($SH "$D" check 2>&1)
[ -z "$(mapcalls)" ] && grep -qx 'console CAPS' "$T/calls" && ok "old TSX-LEDBAR: no LEDMAP" || bad "old firmware: calls $(cat "$T/calls")"
! echo "$out" | grep -q "LED map" && ok "old TSX-LEDBAR: no map line" || bad "old firmware: log: $out"
reset 0; echo "$OWN" > "$T/fw"; echo "$CAPS14" > "$T/caps"; echo "LEDMAP=outputs" > "$T/map.conf"
out=$(TSX_LEDBAR_CONF=$T/map.conf $SH "$D" check 2>&1)
[ -z "$(mapcalls)" ] && echo "$out" | grep -q "LEDMAP=outputs in ledbar.conf needs the LED bar firmware TSX-LEDBAR 0.1.5 or later" && ok "old TSX-LEDBAR with LEDMAP in the conf: one log line" || bad "old firmware conf: $out"
reset 0; echo "$CAPS15" > "$T/caps"
out=$(TSX_LEDBAR_CONF=$T/map.conf $SH "$D" check 2>&1)
! grep -q '^console CAPS' "$T/calls" && [ -z "$(mapcalls)" ] && ok "stock firmware: no CAPS, no LEDMAP" || bad "stock firmware: calls $(cat "$T/calls")"
echo "$out" | grep -q "LEDMAP in ledbar.conf needs the LED bar firmware TSX-LEDBAR 0.1.5 or later" && ok "stock firmware with LEDMAP in the conf: one log line" || bad "stock firmware conf: $out"

# 10e. a restart of the bar by the check: LEDMAP after the restart, one time
own15 1; model TSS-10
$SH "$D" check >/dev/null 2>&1
a=$(callno 'console reboot 500'); b=$(callno 'console LEDMAP TSW-1060-LB PANEL')
[ "$(reboots)" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && [ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && ok "map: sent once, after the restart of the bar" || bad "map after restart: $(cat "$T/calls")"

# 10f. service: LEDMAP at the first plug-in and again after each plug-in
unplug; own15; model TSS-10
$SH "$D" > "$T/log" 2>&1 &
DPID=$!
sleep 1
plug 5
waitfor 'grep -qx boot "$T/calls"' && ok "service map: boot color" || bad "service map: no boot call: $(cat "$T/calls")"
a=$(callno 'console LEDMAP TSW-1060-LB PANEL'); b=$(callno boot)
[ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && [ -n "$a" ] && [ "$a" -lt "$b" ] && ok "service map: LEDMAP before the boot color" || bad "service map: calls $(cat "$T/calls")"
unplug
waitfor 'grep -q "LED bar removed" "$T/log"' >/dev/null
: > "$T/calls"
plug 6
waitfor 'grep -qx apply "$T/calls"' && ok "service map: plug-in, color applied" || bad "service map: no apply after the plug-in: $(cat "$T/calls")"
a=$(callno 'console LEDMAP TSW-1060-LB PANEL'); b=$(callno apply)
[ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && [ -n "$a" ] && [ "$a" -lt "$b" ] && ok "service map: LEDMAP again after the plug-in, before the color" || bad "service map replug: calls $(cat "$T/calls")"
sleep 2
[ "$(mapcalls)" = "LEDMAP TSW-1060-LB PANEL|" ] && ok "service map: no LEDMAP while the bar stays" || bad "service map: LEDMAP repeats: $(mapcalls)"
[ "$(grep -c "LED map: sent LEDMAP TSW-1060-LB PANEL" "$T/log")" = 2 ] && ok "service map: one log line for each plug-in" || bad "service map: log $(cat "$T/log")"
kill "$DPID"; wait "$DPID" 2>/dev/null; DPID=

[ $fail = 0 ] && echo "PASS tsx-ledbard host test"
exit $fail
