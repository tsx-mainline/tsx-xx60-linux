#!/bin/bash
# tsx-idled + /run/tsx/als-level . Runs locally (gcc, no target hardware needed).
# To run on a separate build host instead: BUILD_HOST=<host> tools/build/remote-build.sh
# (or equivalent) with this script as the command.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../rootfs/src/tsx-idled.c
T=$(mktemp -d); PID=; trap '[ -n "$PID" ] && kill $PID 2>/dev/null; rm -rf $T' EXIT
gcc -O2 -Wall -Werror -o $T/tsx-idled $SRC
mkdir -p $T/bl/mp3309c $T/input $T/run
echo 31 > $T/bl/mp3309c/max_brightness; echo 17 > $T/bl/mp3309c/brightness
printf 'BLANK_TIMEOUT=0\nBRIGHTNESS_DAY=10\nBRIGHTNESS_NIGHT=10\nBACKLIGHT_MAX=23\nNIGHT_START=0\nNIGHT_END=0\n' > $T/kiosk.conf
TSX_INPUT_DIR=$T/input TSX_BACKLIGHT_DIR=$T/bl TSX_STATE_FILE=$T/state TSX_RUN_DIR=$T/run $T/tsx-idled -c $T/kiosk.conf -v > $T/log 2>&1 &
PID=$!
fail=0; b() { cat $T/bl/mp3309c/brightness; }
chk() { if [ "$(b)" = "$1" ]; then echo "ok   $2 ($1)"; else echo "FAIL $2: $(b), want $1"; fail=1; fi; }
sleep 1; chk 10 "day level without ALS"
echo 12 > $T/run/als-level; sleep 6; chk 12 "fresh als-level used"
echo 30 > $T/run/als-level; sleep 6; chk 23 "als-level capped by BACKLIGHT_MAX"
echo 12 > $T/run/als-level; echo 5 > $T/run/brightness; sleep 6; chk 5 "manual override beats ALS"
rm $T/run/brightness; touch -d '-60 seconds' $T/run/als-level; sleep 6; chk 10 "stale als-level ignored"
rm $T/run/als-level; sleep 6; chk 10 "no als-level: day level"
[ $fail = 0 ] && echo "PASS tsx-idled ALS" || { cat $T/log; exit 1; }
