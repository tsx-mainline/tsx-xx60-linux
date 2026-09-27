#!/bin/sh
# chaintest.sh TAG PCM MASTER%... : 1 s 1 kHz -20 dBFS bursts through ALSA PCM (e.g. media)
# at the given Master settings, panel mic recorded (ZL master bypass, restored), Master restored.
TAG=$1; PCM=$2; shift 2
M0=$(amixer -c TSW1060 cget name=Master | sed -n 's/.*: values=\([0-9]*\).*/\1/p')
A0=$(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2); sh /tmp/zlreg.sh -w 0x0300 $((A0 | 2)); sleep 1
arecord -q -D tsx_dsnoop -f S16_LE -r 48000 -c 2 -d $((3 + 5 * $#)) /tmp/rec-$TAG.wav & RP=$!
sleep 2
for m in "$@"; do
  amixer -q -c TSW1060 cset name=Master $m%
  echo "$(date +%H:%M:%S) $PCM -20 dBFS at Master $m% ($(amixer -c TSW1060 cget name=Master | sed -n 's/.*values=//p'))"
  aplay -q -D $PCM /tmp/burst-1k-m20dB.wav 2>&1 | grep -c underrun | sed 's/^/  underruns /'
  sleep 4
done
wait $RP
amixer -q -c TSW1060 cset name=Master $M0%; sh /tmp/zlreg.sh -w 0x0300 $A0
echo "restored Master $M0% ZL 0x0300 $(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2)"
