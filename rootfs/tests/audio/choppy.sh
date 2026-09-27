#!/bin/sh
# choppy.sh: playback continuity tests on raw hw:TSW1060,0 (5 s 1 kHz -20 dBFS),
# sendspin/voice stopped (they hold the PCMs), restarted at the end.
# T1: no capture, period 1024 / buffer 8192, TFA status polled
# T2: capture running (ZL master bypass), period 1500 / buffer 6000
# T3: capture running, period 1024 / buffer 8192
F=/tmp/tone5s-1k-m20dB.wav
tfapoll() { : > /tmp/tfapoll.$1; while [ -f /tmp/tfapoll.run ]; do
  echo "$(cut -d' ' -f1 /proc/uptime) $(i2ctransfer -f -y 1 w1@0x34 0 r2) $(i2ctransfer -f -y 1 w1@0x36 0 r2)" >> /tmp/tfapoll.$1; sleep 0.05; done; }
play() { # tag period buffer
  touch /tmp/tfapoll.run; tfapoll $1 & P=$!
  echo "$(date +%H:%M:%S) $1 start: aplay hw:TSW1060,0 period $2 buffer $3"
  aplay -v -D hw:TSW1060,0 --period-size=$2 --buffer-size=$3 $F > /tmp/aplay.$1 2>&1
  echo "$(date +%H:%M:%S) $1 end"; rm -f /tmp/tfapoll.run; wait $P
  grep -E "underrun|period_size|buffer_size|rate" /tmp/aplay.$1 | sort | uniq -c
  echo "TFA status values (0x34 / 0x36) during $1:"; awk '{print $2$3" "$4$5}' /tmp/tfapoll.$1 | sort | uniq -c
}
rc-service tsx-sendspin stop >/dev/null 2>&1; rc-service tsx-voice stop >/dev/null 2>&1; sleep 1
cat /proc/asound/TSW1060/pcm0p/sub0/status /proc/asound/TSW1060/pcm1c/sub0/status | grep state
play T1 1024 8192
sleep 3
A0=$(sh /tmp/zlreg.sh 0x0300 | cut -d' ' -f2); sh /tmp/zlreg.sh -w 0x0300 $((A0 | 2))
arecord -q -D hw:TSW1060,1 -f S16_LE -r 48000 -c 2 -d 8 /tmp/rec-T2.wav & R=$!; sleep 1
play T2 1500 6000
wait $R; sleep 2
arecord -q -D hw:TSW1060,1 -f S16_LE -r 48000 -c 2 -d 8 /tmp/rec-T3.wav & R=$!; sleep 1
play T3 1024 8192
wait $R
sh /tmp/zlreg.sh -w 0x0300 $A0; echo "ZL 0x0300 restored $(sh /tmp/zlreg.sh 0x0300)"
rc-service tsx-sendspin start >/dev/null 2>&1; rc-service tsx-voice start >/dev/null 2>&1
rc-service tsx-sendspin status; rc-service tsx-voice status
