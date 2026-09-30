#!/bin/sh
# leveltest.sh TAG LEVELS... : play 1 kHz bursts (1 s, 5 s apart) through
# tsx_dmix (unity gain, bit-exact with raw hw:TSW1060,0 while sendspin holds
# the device). Record the panel mic (dsnoop, ZL AEC off) the whole time.
# The AEC switch soft-resets the ZL38051. Its capture output is zero for a
# while after that. So the script waits until the AUDIN ring holds live data
# (max 60 s).
TAG=$1; shift
AEC=$(amixer -c TSW1060 cget name='ZL AEC Switch' | sed -n 's/.*: values=//p')
amixer -q -c TSW1060 cset name='ZL AEC Switch' off
t0=$(date +%s)
while :; do
  n=$(python3 /tmp/ringdump.py 0 | sed -n 's/distinct words in ring: \([0-9]*\).*/\1/p')
  [ "${n:-0}" -gt 20 ] && break
  [ $(( $(date +%s) - t0 )) -gt 60 ] && { echo "capture stays dead"; break; }
  sleep 1
done
echo "$(date +%H:%M:%S) capture live after $(( $(date +%s) - t0 )) s (distinct $n)"
arecord -q -D tsx_dsnoop -f S16_LE -r 48000 -c 2 -d $((3 + 5 * $#)) /tmp/rec-$TAG.wav &
RP=$!
sleep 2
for l in "$@"; do
  echo "$(date +%H:%M:%S) play -${l} dBFS"
  aplay -q -D tsx_dmix /tmp/burst-1k-m${l}dB.wav 2>/dev/null
  sleep 4
done
wait $RP
amixer -q -c TSW1060 cset name='ZL AEC Switch' $AEC
echo "AEC restored to $AEC"
