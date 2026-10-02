#!/bin/sh
# Host test of tsx-ledbard: the start check of the LED driver chips and the
# restart of the STM32. A fake tsx-ledbar answers the console commands, and a
# fake USB sysfs dir holds the bar (14be:001b). A restart gives the bar a new
# USB device number, as on the panel. No compiler and no hardware needed.
#
# Fake console: the chips report "not initialized" until the bar had
# OK_AFTER restarts (file $T/ok_after). "silent" gives no answer.
# Fake firmware: "tsx-ledbar fw" prints the file $T/fw (stock by default).
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
reset() { echo 0 > "$T/reboots"; echo "$1" > "$T/ok_after"; : > "$T/calls"; rm -f "$T/no_reenum"; echo "$STOCK" > "$T/fw"; }
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

[ $fail = 0 ] && echo "PASS tsx-ledbard host test"
exit $fail
