#!/bin/sh
# leveltest2.sh TAG AECREG LEVELS... : like leveltest.sh but without the ALSA AEC
# switch (no ZL soft reset): writes ZL AecCtrl0 (0x0300) = AECREG directly for the
# measurement (e.g. 0x9c06 = master bypass), restores the old value at the end.
TAG=$1; NEW=$2; shift 2
OLD=$(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2)
sh /tmp/zlreg.sh -w 0x0300 $NEW
echo "$(date +%H:%M:%S) ZL 0x0300 $OLD -> $(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2)"
sleep 1
arecord -q -D tsx_dsnoop -f S16_LE -r 48000 -c 2 -d $((3 + 5 * $#)) /tmp/rec-$TAG.wav &
RP=$!
sleep 2
for l in "$@"; do
  echo "$(date +%H:%M:%S) play -${l} dBFS"
  aplay -q -D tsx_dmix /tmp/burst-1k-m${l}dB.wav 2>/dev/null
  sleep 4
done
wait $RP
sh /tmp/zlreg.sh -w 0x0300 $OLD
echo "$(date +%H:%M:%S) ZL 0x0300 restored: $(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2)"
