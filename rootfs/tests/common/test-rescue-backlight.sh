#!/bin/sh
# Host test for rescue/usr/sbin/tsx-rescue-backlight of tsx-linux-common with
# the xx60 board file of this repository. The xx60 backlight (mp3309c) has the
# range 0 to 31. The board file gives a rescue level that is not full. The test
# needs no panel and no compiler.
set -eu
. "$(dirname "$0")/lib.sh"
RB=$COMMON/rescue/usr/sbin/tsx-rescue-backlight
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax =="
busybox sh -n "$RB" && ok "passes busybox sh -n" || bad "busybox sh -n"

echo "== xx60 board file =="
b=$TSX_BOARD_CONF
pct=$(sh -c ". $b; echo \$TSX_RESCUE_BACKLIGHT")
[ "$pct" -ge 1 ] && [ "$pct" -le 80 ] && ok "xx60 board value $pct is between 1 and 80" || bad "xx60 board value '$pct'"
# rescue MAX: prints the level that the script wrote with the xx60 board file
rescue() {
	rm -rf "$T/sys"; mkdir -p "$T/sys/bl"; echo "$1" > "$T/sys/bl/max_brightness"; echo "$1" > "$T/sys/bl/brightness"
	TSX_BOARD_CONF=$b TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > "$T/out"
	cat "$T/sys/bl/brightness"
}
lvl=$(rescue 31)
eq "$lvl" 16 "the xx60 backlight range 0 to 31: the rescue level is 16"
[ "$lvl" -lt 31 ] && ok "xx60: the rescue level is not full" || bad "xx60: the level is full"
eq "$(cat "$T/out")" "tsx-rescue-backlight: bl 16 of 31" "the output names the level"
rescue 4095 > /dev/null
[ "$(cat "$T/sys/bl/brightness")" -lt 4095 ] && ok "a larger range: the level is not full either" || bad "a larger range: the level is full"
# the environment wins over the board file, as for every board value
rm -rf "$T/sys"; mkdir -p "$T/sys/bl"; echo 31 > "$T/sys/bl/max_brightness"; echo 31 > "$T/sys/bl/brightness"
TSX_BOARD_CONF=$b TSX_RESCUE_BACKLIGHT=25 TSX_RESCUE_SYS="$T/sys" TSX_RESCUE_BL_WAIT=0 sh "$RB" > /dev/null
eq "$(cat "$T/sys/bl/brightness")" 8 "TSX_RESCUE_BACKLIGHT in the environment wins over the board file"

echo "== $N ok, $F failed =="
[ "$F" = 0 ] && echo "PASS common/test-rescue-backlight" || { echo "FAIL common/test-rescue-backlight"; exit 1; }
