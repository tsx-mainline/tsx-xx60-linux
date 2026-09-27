#!/bin/sh
# meas.sh TAG FILE [DEV]: on the panel. ZL AecCtrl0 (0x0300) -> 0x9c06 (master bypass, no soft reset,
# the standard leveltest2 method), record the mic (tsx_dsnoop) 5 s, play FILE through DEV (default) at +1.5 s,
# restore 0x0300.
TAG=$1; F=$2; D=${3:-default}
OLD=$(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2)
sh /tmp/zlreg.sh -w 0x0300 0x9c06; sleep 1
arecord -q -D tsx_dsnoop -f S16_LE -r 48000 -c 2 -d 5 /tmp/rec-$TAG.wav &
RP=$!; sleep 1.5
echo "$(date +%H:%M:%S) play $F via $D"
aplay -q -D $D $F
wait $RP
sh /tmp/zlreg.sh -w 0x0300 $OLD
echo "ZL 0x0300 $OLD restored: $(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2)"
