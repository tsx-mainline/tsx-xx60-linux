#!/bin/sh
# Host test of tsx-ledbar. It checks these parts: the frame encoder (against
# the frames captured from the vendor userland, LED.md), hex parsing, and
# packet validation. It also checks the kernel (sysfs) backend against a fake
# LED directory, the state file, an old ledbar.conf with BLANK keys, the firmware check,
# the effects (fx) and the 16 LEDs (led, side, clear, zone effects) with a fake console.
# The test builds without libusb (-DNO_LIBUSB). The libusb path needs the panel.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../rootfs/src/tsx-ledbar.c
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
${CC:-gcc} -O2 -Wall -Wextra -DNO_LIBUSB -o "$T/tsx-ledbar" "$SRC"
B=$T/tsx-ledbar; fail=0
export TSX_RUN_DIR=$T/run TSX_LEDBAR_CONF=$T/ledbar.conf TSX_LEDBAR_SYSFS=$T/led
eq() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got '$2' want '$3'"; fail=1; }; }
# vendor frames (LED.md, strace of platformd writing .../2-1:1.1/stm32_io)
eq "analog red 100"   "$($B -n analog 3 100)" "00 05 14 00 03 00 64"
eq "analog green 100" "$($B -n analog 4 100)" "00 05 14 00 04 00 64"
eq "analog blue 100"  "$($B -n analog 5 100)" "00 05 14 00 05 00 64"
eq "analog blue 10"   "$($B -n analog 5 10)"  "00 05 14 00 05 00 0a"
eq "analog blue 0"    "$($B -n analog 5 0)"   "00 05 14 00 05 00 00"
eq "digital red on"   "$($B -n digital 0 on)"  "00 03 00 00 00"
eq "digital red off"  "$($B -n digital 0 off)" "00 03 00 00 80"
eq "digital green on" "$($B -n digital 1 on)"  "00 03 00 01 00"
eq "digital blue off" "$($B -n digital 2 off)" "00 03 00 02 80"
# libusb path: per color the analog join, then the digital join (on for a level above 0)
eq "set 100 0 0" "$($B -n set 100 0 0 | tr '\n' '|')" "00 05 14 00 03 00 64|00 03 00 00 00|00 05 14 00 04 00 00|00 03 00 01 80|00 05 14 00 05 00 00|00 03 00 02 80|"
eq "set 0 0 5" "$($B -n set 0 0 5 | tr '\n' '|')" "00 05 14 00 03 00 00|00 03 00 00 80|00 05 14 00 04 00 00|00 03 00 01 80|00 05 14 00 05 00 05|00 03 00 02 00|"
eq "console dry run" "$($B -n console 'tlcoutmode red 0')" "console tlcoutmode red 0"
$B console reboot >/dev/null 2>&1 && { echo "FAIL console without libusb accepted"; fail=1; } || echo "ok   console needs libusb"
$B -n console >/dev/null 2>&1 && { echo "FAIL console without a line accepted"; fail=1; } || echo "ok   console without a line rejected"
eq "raw spaced"  "$($B -n raw 00 05 14 00 03 00 64)" "00 05 14 00 03 00 64"
eq "raw packed"  "$($B -n raw 00051400030064)" "00 05 14 00 03 00 64"
eq "raw 0x"      "$($B -n raw 0x00 0x03 0x00 0x02 0x80)" "00 03 00 02 80"
$B -n raw 00 05 14 00 >/dev/null 2>&1 && { echo "FAIL bad length accepted"; fail=1; } || echo "ok   bad length rejected"
$B -n set 101 0 0 >/dev/null 2>&1 && { echo "FAIL 101 accepted"; fail=1; } || echo "ok   101 rejected"
# fake kernel LED dir
mkdir -p "$T/led"; echo "red green blue" > "$T/led/multi_index"; echo "0 0 0" > "$T/led/multi_intensity"; echo 0 > "$T/led/brightness"; : > "$T/led/raw"
printf 'BOOT_COLOR="0 0 20"\n' > "$T/ledbar.conf"
$B set 10 20 30
eq "sysfs intensity" "$(cat "$T/led/multi_intensity")" "10 20 30"
eq "sysfs brightness" "$(cat "$T/led/brightness")" "100"
eq "state want" "$(sed -n 's/^want //p' "$T/run/ledbar.state")" "10 20 30"
# an old conf with BLANK keys, and a screen state file: the bar does not change
for old in 'BLANK=off' 'BLANK=dim\nBLANK_DIM=50'; do
	lbl=$(printf '%s' "$old" | tr '\n' ' ')
	printf "BOOT_COLOR=\"0 0 20\"\n$old\n" > "$T/ledbar.conf"
	for scr in blank "on 17" blank; do
		echo "$scr" > "$T/idled"; export TSX_IDLED_STATE=$T/idled
		$B apply
		eq "old conf ($lbl), screen '$scr': color" "$(cat "$T/led/multi_intensity")" "10 20 30"
		eq "old conf ($lbl), screen '$scr': state" "$(sed -n 's/^want //p;s/^out //p' "$T/run/ledbar.state" | tr '\n' '|')" "10 20 30|10 20 30|"
	done
done
unset TSX_IDLED_STATE
eq "get has no screen line" "$($B get | grep -c screen || true)" "0"
printf 'BOOT_COLOR="0 0 20"\n' > "$T/ledbar.conf"
$B off
eq "off" "$(cat "$T/led/multi_intensity")" "0 0 0"
$B on
eq "on = last color" "$(cat "$T/led/multi_intensity")" "10 20 30"
$B boot
eq "boot color" "$(cat "$T/led/multi_intensity")" "0 0 20"
$B raw 00 03 00 02 80
eq "raw via sysfs" "$(od -An -tx1 "$T/led/raw" | tr -s ' ' | sed 's/^ //')" "00 03 00 02 80"
echo "green red blue" > "$T/led/multi_index"; $B set 1 2 3
eq "multi_index order" "$(cat "$T/led/multi_intensity")" "2 1 3"
# effects: the firmware name decides. The test build writes console lines to $CON.
CON=$T/console; export TSX_LEDBAR_CONSOLE=$CON
st() { sed -n "s/^$1 //p" "$T/run/ledbar.state"; }
no() { if "$@" >/dev/null 2>&1; then echo "FAIL accepted: $*"; fail=1; else echo "ok   rejected: $*"; fi; }
echo "red green blue" > "$T/led/multi_index"; out=$($B fw 2>/dev/null) && rc=0 || rc=$?
eq "fw without a bar" "$(echo "$out" | tr '\n' '|')rc $rc" "firmware unknown|effects no|leds no|rc 1"
# stock firmware: no effects, the colors work as before
echo "TSW-XX60-LB [v1.3443.00018]" > "$T/led/firmware"
eq "fw stock" "$($B fw | tr '\n' '|')" "firmware TSW-XX60-LB [v1.3443.00018]|effects no|leds no|"
$B set 10 20 30; rm -f "$CON"
out=$($B fx breathe 0 0 80 4000 2>&1) && { echo "FAIL stock: fx accepted"; fail=1; } || echo "ok   stock: fx refused"
case $out in *"effects need the LED bar firmware TSX-LEDBAR (this bar: TSW-XX60-LB"*) echo "ok   stock: refusal names the firmware";; *) echo "FAIL stock: message '$out'"; fail=1;; esac
$B fx off >/dev/null 2>&1 && { echo "FAIL stock: fx off accepted"; fail=1; } || echo "ok   stock: fx off refused"
$B set 40 0 0; $B apply; $B off; $B on
[ ! -e "$CON" ] && echo "ok   stock: no console line for set, apply, off, on" || { echo "FAIL stock: console $(cat "$CON")"; fail=1; }
eq "stock: state fx" "$(st fx)" "none"
eq "stock: get fx" "$($B get | sed -n 's/^fx //p')" "none"
# a stale effect record with the stock firmware: apply drops it and sends no console line
printf 'want 1 2 3\nlast 1 2 3\nout 1 2 3\nfx breathe 1 2 3 4000\n' > "$T/run/ledbar.state"
$B apply
[ ! -e "$CON" ] && eq "stock: stale record dropped" "$(st fx)" "none" || { echo "FAIL stock: console $(cat "$CON")"; fail=1; }
# our firmware
echo "TSX-LEDBAR [v0.1.1]" > "$T/led/firmware"
eq "fw tsx" "$($B fw | tr '\n' '|')" "firmware TSX-LEDBAR [v0.1.1]|effects yes|leds no|"
$B set 10 20 30; rm -f "$CON"
fx() { rm -f "$CON"; $B fx "$@"; }
$B set 10 20 30
fx fade 100 0 0 1000
eq "fx fade: line" "$(cat "$CON")" "FX FADE 100 0 0 1000"
eq "fx fade: record" "$(st fx)" "fade 100 0 0 1000"
eq "fx fade: want unchanged" "$(st want)" "10 20 30"
eq "fx fade: no joins" "$(cat "$T/led/multi_intensity")" "10 20 30"
eq "fx fade: last unchanged" "$(st last)" "10 20 30"
fx blink 0 50 0 300 700
eq "fx blink: line" "$(cat "$CON")" "FX BLINK 0 50 0 300 700"
eq "fx blink: record" "$(st fx)" "blink 0 50 0 300 700"
fx breathe 0 0 80 4000
eq "fx breathe: line" "$(cat "$CON")" "FX BREATHE 0 0 80 4000"
eq "fx breathe: want unchanged" "$(st want)" "10 20 30"
fx rainbow 10000
eq "fx rainbow: line" "$(cat "$CON")" "FX RAINBOW 10000"
eq "fx rainbow: want unchanged" "$(st want)" "10 20 30"
fx rainbow 10000 40
eq "fx rainbow level: line" "$(cat "$CON")" "FX RAINBOW 10000 40"
eq "fx rainbow level: want unchanged" "$(st want)" "10 20 30"
eq "fx rainbow level: get" "$($B get | sed -n 's/^want //p;s/^fx /fx /p' | tr '\n' '|')" "10 20 30|fx rainbow 10000 40|"
fx smooth 500
eq "fx smooth: line" "$(cat "$CON")" "FX SMOOTH 500"
eq "fx smooth: record kept" "$(st fx)" "rainbow 10000 40"
fx cap 120
eq "fx cap: line" "$(cat "$CON")" "FX CAP 120"
eq "fx query: answer" "$(fx)" "fx test"
eq "fx query: line" "$(cat "$CON")" "FX"
eq "fx dry run" "$($B -n fx breathe 1 2 3 4000)" "console FX BREATHE 1 2 3 4000"
# apply starts the recorded effect again after the color
rm -f "$CON"; $B apply
eq "apply: joins" "$(cat "$T/led/multi_intensity")" "10 20 30"
eq "apply: effect again" "$(cat "$CON")" "FX RAINBOW 10000 40"
# fx off: the joins of the wanted color, then FX OFF
fx breathe 0 0 80 4000; fx off
eq "fx off: joins" "$(cat "$T/led/multi_intensity")" "10 20 30"
eq "fx off: want" "$(st want)" "10 20 30"
eq "fx off: get" "$($B get | sed -n 's/^want //p;s/^fx /fx /p' | tr '\n' '|')" "10 20 30|fx none|"
eq "fx off: line" "$(cat "$CON")" "FX OFF"
eq "fx off: record" "$(st fx)" "none"
# every effect: fx off shows the color from before it
for e in "fade 100 0 0 1000" "blink 0 50 0 300 700" "breathe 0 0 80 4000" "rainbow 10000 50"; do
	$B set 33 22 11; fx $e; fx off
	eq "fx $e, fx off: joins" "$(cat "$T/led/multi_intensity")" "33 22 11"
	eq "fx $e, fx off: want" "$(st want)" "33 22 11"
done
# no effect color in the wanted color: on after fx off
$B set 33 22 11; fx breathe 0 0 80 4000; fx off; $B off; $B on
eq "on after an effect: last color" "$(cat "$T/led/multi_intensity")" "33 22 11"
# smooth and cap change no color
$B set 10 20 30; fx smooth 100; fx cap 100
eq "smooth and cap: want" "$(st want)" "10 20 30"
$B set 10 20 30
# a new color ends the effect: the joins, then FX OFF
fx blink 50 0 0 500 500; rm -f "$CON"; $B set 5 6 7
eq "set ends fx: joins" "$(cat "$T/led/multi_intensity")" "5 6 7"
eq "set ends fx: line" "$(cat "$CON")" "FX OFF"
eq "set ends fx: record" "$(st fx)" "none"
rm -f "$CON"; $B set 8 8 8
[ ! -e "$CON" ] && echo "ok   set without an effect: no console line" || { echo "FAIL console $(cat "$CON")"; fail=1; }
fx breathe 0 0 80 4000; rm -f "$CON"; $B off
eq "off ends fx" "$(cat "$CON"; st fx)" "FX OFF
none"
# apply starts the recorded effect again, the wanted color stays
$B set 10 20 30; fx breathe 0 0 80 4000; rm -f "$CON"; $B apply
eq "apply: joins, then the effect" "$(cat "$T/led/multi_intensity"; cat "$CON"; st want)" "10 20 30
FX BREATHE 0 0 80 4000
10 20 30"
# boot ends an effect and becomes the wanted color
fx rainbow 10000; rm -f "$CON"; $B boot
eq "boot ends fx" "$(cat "$CON"; st fx; st want)" "FX OFF
none
0 0 20"
# an old conf with BLANK=off: the effect does not wait for the screen
printf 'BLANK=off\n' > "$T/ledbar.conf"
fx breathe 0 0 80 4000; echo blank > "$T/idled"; rm -f "$CON"; TSX_IDLED_STATE=$T/idled $B apply
eq "blank screen: color, then the effect" "$(cat "$T/led/multi_intensity"; cat "$CON")" "0 0 20
FX BREATHE 0 0 80 4000"
rm -f "$CON"; TSX_IDLED_STATE=$T/idled $B fx blink 1 2 3 100 100
eq "blank screen: new effect is sent" "$(cat "$CON"; st fx)" "FX BLINK 1 2 3 100 100
blink 1 2 3 100 100"
printf 'BOOT_COLOR="0 0 20"\n' > "$T/ledbar.conf"
# the bar refuses: exit 1, the record stays as it was
$B fx off; TSX_LEDBAR_ANSWER="usage: see HELP" $B fx breathe 0 0 80 4000 2>/dev/null && { echo "FAIL refusal accepted"; fail=1; } || echo "ok   refusal: exit 1"
eq "refusal: record" "$(st fx)" "none"
# value ranges of the firmware
no $B -n fx breathe 0 0 80 99
no $B -n fx breathe 0 0 101 4000
no $B -n fx fade 0 0 0 600001
no $B -n fx blink 1 2 3 0 100
no $B -n fx blink 1 2 3 100
no $B -n fx rainbow 99
no $B -n fx rainbow 1000 101
no $B -n fx rainbow 1000 50 1
no $B -n fx smooth 60001
no $B -n fx cap 9
no $B -n fx cap 151
no $B -n fx off now
no $B -n fx sparkle 100
# ---- the 16 LEDs (firmware 0.1.3, "leds16" in CAPS) -------------------------
lines() { if [ -e "$CON" ]; then tr '\n' '|' < "$CON"; fi; }
run() { rm -f "$CON"; "$B" "$@"; }
# firmware 0.1.2: the LED commands and the zone effects refuse, nothing changes
echo "TSX-LEDBAR [v0.1.2]" > "$T/led/firmware"; unset TSX_LEDBAR_CAPS
eq "fw 0.1.2" "$($B fw | tr '\n' '|')" "firmware TSX-LEDBAR [v0.1.2]|effects yes|leds no|"
$B set 10 20 30; cp "$T/run/ledbar.state" "$T/before"
for c in "led R3 100 0 0" "side L 0 0 50" "clear" "fx chase 100 0 0 2000" "fx fill 0 80 0 50" "fx spectrum 8000" "fx split 100 0 0 0 0 100"; do
	rm -f "$CON"; out=$($B $c 2>&1) && rc=0 || rc=$?
	case $out in *"needs the LED bar firmware TSX-LEDBAR 0.1.3 or later with leds16 in CAPS (this bar: TSX-LEDBAR [v0.1.2])"*) m=ok;; *) m="'$out'";; esac
	eq "0.1.2: $c refused" "rc $rc, $m, $(lines)" "rc 1, ok, "
done
cmp -s "$T/before" "$T/run/ledbar.state" && echo "ok   0.1.2: state unchanged" || { echo "FAIL 0.1.2: state changed"; fail=1; }
fx breathe 0 0 80 4000
eq "0.1.2: the old effects still work" "$(lines)$(st fx)" "FX BREATHE 0 0 80 4000|breathe 0 0 80 4000"
$B set 10 20 30
# a stale pattern with 0.1.2: apply drops it and sends no LED line
printf 'want 1 2 3\nlast 1 2 3\nout 1 2 3\nfx none\npattern %s\n' "$(printf '5 5 5 %.0s' $(seq 16))" > "$T/run/ledbar.state"
run apply
eq "0.1.2: stale pattern dropped" "$(lines)$(st pattern)" "none"
# firmware 0.1.3
echo "TSX-LEDBAR [v0.1.3]" > "$T/led/firmware"
export TSX_LEDBAR_CAPS="tsx-ledbar fade blink breathe rainbow smooth cap status leds16 chase fill spectrum split"
eq "fw 0.1.3" "$($B fw | tr '\n' '|')" "firmware TSX-LEDBAR [v0.1.3]|effects yes|leds yes|"
$B set 10 20 30
eq "no pattern: get" "$($B get | sed -n 's/^leds //p')" "host"
eq "no pattern: state" "$(st pattern)" "none"
run led R3 100 0 0
eq "led R3: line" "$(lines)" "LED SET R3 100 0 0|"
eq "led R3: the first LED command copies the wanted color" "$(st pattern)" "10 20 30 10 20 30 100 0 0 $(printf '10 20 30 %.0s' $(seq 13) | sed 's/ $//')"
eq "led R3: want unchanged" "$(st want)$(cat "$T/led/multi_intensity")" "10 20 3010 20 30"
eq "led R3: get" "$($B get | sed -n 's/^leds //p;/^led R3 /p;/^led L8 /p' | tr '\n' '|')" "pattern|led R3 100 0 0|led L8 10 20 30|"
for c in "R1-R4:R1-R4" "r4-r1:R1-R4" "8-11:L1-L4" "R7-L2:R7-L2" "L8:L8" "15:L8" "0:R1" "ALL:ALL" "all:ALL" "R:R1-R8" "l:L1-L8" "3-3:R4"; do
	run led "${c%%:*}" 1 2 3
	eq "led ${c%%:*}: line" "$(lines)" "LED SET ${c#*:} 1 2 3|"
done
run side L 0 0 50
eq "side L: line" "$(lines)" "LED SIDE L 0 0 50|"
run side r 0 50 0
eq "side r: line" "$(lines)" "LED SIDE R 0 50 0|"
eq "side: pattern" "$(st pattern)" "$(printf '0 50 0 %.0s' $(seq 8))$(printf '0 0 50 %.0s' $(seq 8) | sed 's/ $//')"
for c in "led R9 1 2 3" "led 16 1 2 3" "led X1 1 2 3" "led R1- 1 2 3" "led -R1 1 2 3" "led R1-R2-R3 1 2 3" "led R1 101 0 0" "led R1 1 2" "led R1 1 2 3 4" \
	"side X 1 2 3" "side ALL 1 2 3" "side R 1 2" "clear now" "led R1 -1 0 0"; do
	rm -f "$CON"; no $B $c
done
[ ! -e "$CON" ] && echo "ok   bad LED commands send no line" || { echo "FAIL bad LED commands: $(lines)"; fail=1; }
# zone effects: on top of the pattern, the record keeps the pattern
for c in "chase 100 0 0 2000:FX CHASE 100 0 0 2000" "fill 0 80 0 50:FX FILL 0 80 0 50" "spectrum 8000:FX SPECTRUM 8000" \
	"spectrum 8000 40:FX SPECTRUM 8000 40" "spectrum 8000 40 rows:FX SPECTRUM 8000 40 ROWS" \
	"spectrum 8000 RING:FX SPECTRUM 8000 100 RING" "split 100 0 0 0 0 100:FX SPLIT 100 0 0 0 0 100"; do
	run fx ${c%%:*}
	eq "fx ${c%%:*}: line and record" "$(lines)$(st fx)" "${c#*:}|$(echo "${c#*:}" | cut -c4- | tr 'A-Z' 'a-z')"
done
no $B -n fx chase 1 2 3 99
no $B -n fx chase 1 2 3 600001
no $B -n fx fill 1 2 3 101
no $B -n fx fill 1 2 3
no $B -n fx spectrum 99
no $B -n fx spectrum 1000 101
no $B -n fx spectrum 1000 50 diagonal
no $B -n fx spectrum rows
no $B -n fx spectrum 1000 rows rows
no $B -n fx rainbow 1000 50 rows
no $B -n fx split 1 2 3 4 5
no $B -n fx split 1 2 3 4 5 101
eq "zone effect: the pattern stays" "$(st pattern | cut -d' ' -f1-3)" "0 50 0"
# apply after a restart of the bar: the color, the pattern in runs, then the effect
run fx chase 100 0 0 2000; run apply
eq "apply: joins" "$(cat "$T/led/multi_intensity")" "10 20 30"
eq "apply: pattern, then the effect" "$(lines)" "LED SET R1-R8 0 50 0|LED SET L1-L8 0 0 50|FX CHASE 100 0 0 2000|"
# fx off with a pattern: FX OFF only, the firmware goes back to the pattern
run fx off
eq "fx off with a pattern: line" "$(lines)" "FX OFF|"
eq "fx off with a pattern: records" "$(st fx)|$(st pattern | cut -d' ' -f1-3)" "none|0 50 0"
# a LED command ends the effect record
run fx spectrum 8000; run led L8 1 1 1
eq "led ends the effect" "$(lines)$(st fx)" "LED SET L8 1 1 1|none"
run apply
eq "apply: one run per color" "$(lines)" "LED SET R1-R8 0 50 0|LED SET L1-L7 0 0 50|LED SET L8 1 1 1|"
# the same pattern on all 16 LEDs is one line
run led ALL 7 7 7; run apply
eq "apply: ALL" "$(lines)" "LED SET ALL 7 7 7|"
# clear drops the pattern and the effect
run fx chase 1 2 3 1000; run clear
eq "clear: line" "$(lines)" "LED CLEAR|"
eq "clear: records" "$(st pattern)|$(st fx)|$($B get | sed -n 's/^leds //p')" "none|none|host"
run apply
eq "apply without a pattern: no LED line" "$(lines)" ""
# a new color ends the pattern and the effect: the joins, then LED CLEAR
run led R1 1 2 3; run fx chase 1 2 3 1000; run set 5 6 7
eq "set ends the pattern: joins" "$(cat "$T/led/multi_intensity")" "5 6 7"
eq "set ends the pattern: line" "$(lines)" "LED CLEAR|"
eq "set ends the pattern: records" "$(st pattern)|$(st fx)|$(st want)" "none|none|5 6 7"
run led R1 1 2 3; run off
eq "off ends the pattern" "$(lines)$(st pattern)" "LED CLEAR|none"
run led R1 1 2 3; run boot
eq "boot ends the pattern" "$(lines)$(st pattern)|$(st want)" "LED CLEAR|none|0 0 20"
# the new first LED command copies the new wanted color
run led L1 9 9 9
eq "pattern from the new wanted color" "$(st pattern | cut -d' ' -f1-3,25-27)" "0 0 20 9 9 9"
# the bar refuses: exit 1, the records stay
cp "$T/run/ledbar.state" "$T/before"
rm -f "$CON"; TSX_LEDBAR_ANSWER="usage: LED SET LEDS R G B" $B led R2 1 1 1 2>/dev/null && { echo "FAIL LED refusal accepted"; fail=1; } || echo "ok   LED refusal: exit 1"
cmp -s "$T/before" "$T/run/ledbar.state" && echo "ok   LED refusal: state unchanged" || { echo "FAIL LED refusal: state changed"; fail=1; }
eq "led dry run" "$($B -n led R2 1 2 3)" "console LED SET R2 1 2 3"
eq "clear dry run" "$($B -n clear)" "console LED CLEAR"
cmp -s "$T/before" "$T/run/ledbar.state" && echo "ok   dry run: state unchanged" || { echo "FAIL dry run: state changed"; fail=1; }
$B clear; unset TSX_LEDBAR_CAPS
[ $fail = 0 ] && echo "PASS tsx-ledbar host test"
exit $fail
