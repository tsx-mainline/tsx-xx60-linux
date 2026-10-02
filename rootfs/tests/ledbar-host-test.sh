#!/bin/sh
# Host test of tsx-ledbar. It checks these parts: the frame encoder (against
# the frames captured from the vendor userland, LED.md), hex parsing, and
# packet validation. It also checks the kernel (sysfs) backend against a fake
# LED directory, screen-blank scaling and the state file.
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
[ $fail = 0 ] && echo "PASS tsx-ledbar host test"
exit $fail
