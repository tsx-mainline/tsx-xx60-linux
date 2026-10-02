#!/bin/sh
# Host test of tsx-ledbar. It checks these parts: the frame encoder (against
# the frames captured from the vendor userland, LED.md), hex parsing, and
# packet validation. It also checks the kernel (sysfs) backend against a fake
# LED directory, screen-blank scaling and the state file, the firmware check
# and the effects (fx) with a fake console.
# The test builds without libusb (-DNO_LIBUSB). The libusb path needs the panel.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../rootfs/src/tsx-ledbar.c
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
${CC:-gcc} -O2 -Wall -Wextra -DNO_LIBUSB -o "$T/tsx-ledbar" "$SRC"
B=$T/tsx-ledbar; fail=0
export TSX_RUN_DIR=$T/run TSX_IDLED_STATE=$T/idled TSX_LEDBAR_CONF=$T/ledbar.conf TSX_LEDBAR_SYSFS=$T/led
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
printf 'BOOT_COLOR="0 0 20"\nBLANK=dim\nBLANK_DIM=50\n' > "$T/ledbar.conf"
echo "on 17" > "$T/idled"
$B set 10 20 30
eq "sysfs intensity" "$(cat "$T/led/multi_intensity")" "10 20 30"
eq "sysfs brightness" "$(cat "$T/led/brightness")" "100"
eq "state want" "$(sed -n 's/^want //p' "$T/run/ledbar.state")" "10 20 30"
echo blank > "$T/idled"; $B apply
eq "blank dim 50%" "$(cat "$T/led/multi_intensity")" "5 10 15"
eq "want kept" "$(sed -n 's/^want //p' "$T/run/ledbar.state")" "10 20 30"
echo "on 17" > "$T/idled"; $B off
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
echo "red green blue" > "$T/led/multi_index"; printf 'BLANK=keep\n' > "$T/ledbar.conf"
out=$($B fw 2>/dev/null) && rc=0 || rc=$?
eq "fw without a bar" "$(echo "$out" | tr '\n' '|')rc $rc" "firmware unknown|effects no|rc 1"
# stock firmware: no effects, the colors work as before
echo "TSW-XX60-LB [v1.3443.00018]" > "$T/led/firmware"
eq "fw stock" "$($B fw | tr '\n' '|')" "firmware TSW-XX60-LB [v1.3443.00018]|effects no|"
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
eq "fw tsx" "$($B fw | tr '\n' '|')" "firmware TSX-LEDBAR [v0.1.1]|effects yes|"
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
printf 'BOOT_COLOR="0 0 20"\nBLANK=keep\n' > "$T/ledbar.conf"
fx rainbow 10000; rm -f "$CON"; $B boot
eq "boot ends fx" "$(cat "$CON"; st fx; st want)" "FX OFF
none
0 0 20"
# BLANK=off: the effect waits while the screen is blank
printf 'BLANK=off\n' > "$T/ledbar.conf"
fx breathe 0 0 80 4000; echo blank > "$T/idled"; rm -f "$CON"; $B apply
eq "blank: dark" "$(cat "$T/led/multi_intensity")" "0 0 0"
eq "blank: FX OFF, record kept" "$(cat "$CON"; st fx)" "FX OFF
breathe 0 0 80 4000"
rm -f "$CON"; $B fx blink 1 2 3 100 100
[ ! -e "$CON" ] && eq "blank: new effect recorded, not sent" "$(st fx)" "blink 1 2 3 100 100" || { echo "FAIL blank: console $(cat "$CON")"; fail=1; }
echo "on 17" > "$T/idled"; rm -f "$CON"; $B apply
eq "wake: wanted color, then the effect" "$(cat "$T/led/multi_intensity"; cat "$CON")" "0 0 20
FX BLINK 1 2 3 100 100"
printf 'BLANK=keep\n' > "$T/ledbar.conf"
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
[ $fail = 0 ] && echo "PASS tsx-ledbar host test"
exit $fail
