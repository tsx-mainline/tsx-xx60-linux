#!/bin/sh
# zlgaintest.sh TAG GAIN LEVELS... : ZL master bypass for the mic (0x0300 |= 2) and
# TDMB-1/2 (amp feed) cross-point gain 0x0244/0x0246 = GAIN (signed dB, e.g. 0x0000)
# for the measurement; both restored at the end.
TAG=$1; G=$2; shift 2
A0=$(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2); G1=$(sh /tmp/zlreg.sh 0x0244 | cut -d' ' -f2); G2=$(sh /tmp/zlreg.sh 0x0246 | cut -d' ' -f2)
sh /tmp/zlreg.sh -w 0x0300 $((A0 | 2)); sh /tmp/zlreg.sh -w 0x0244 $G; sh /tmp/zlreg.sh -w 0x0246 $G
echo "$(date +%H:%M:%S) ZL 0x0300 $A0 -> $(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2), 0x0244/6 $G1/$G2 -> $(sh /tmp/zlreg.sh 0x0244 2 | cut -d' ' -f2 | tr '\n' /)"
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
sh /tmp/zlreg.sh -w 0x0244 $G1; sh /tmp/zlreg.sh -w 0x0246 $G2; sh /tmp/zlreg.sh -w 0x0300 $A0
echo "$(date +%H:%M:%S) restored: 0x0300 $(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2) 0x0244/6 $(sh /tmp/zlreg.sh 0x0244 2 | cut -d' ' -f2 | tr '\n' /)"
