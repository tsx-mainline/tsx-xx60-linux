#!/bin/sh
# an.sh TAG: fetch /tmp/rec-TAG.wav from the panel, print the 1 kHz level of the loudest windows
D=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$D/results/rec"
$D/tests/p.sh "cat /tmp/rec-$1.wav" > $D/results/rec/rec-$1.wav
python3 $D/../../rootfs/tests/audio/levels.py $D/results/rec/rec-$1.wav 1000 0.25 > $D/results/rec/rec-$1.levels
echo "== $1: top 1 kHz windows"; grep Hz $D/results/rec/rec-$1.levels | sort -k6,6 -g | tail -4
