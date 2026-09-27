#!/bin/sh
# dsptone.sh TAG FILE: on the panel. meas.sh (mic recording + play FILE via default) in the background,
# DSP state (tfa_dsp.py status --state) during playback, register status afterwards.
TAG=$1; F=$2
sh /tmp/meas.sh $TAG $F &
MP=$!; sleep 3
echo "--- during playback $(date +%H:%M:%S)"
python3 /usr/local/lib/tsx/tfa_dsp.py status --bus 1 --state
wait $MP
echo "--- after $(date +%H:%M:%S)"
python3 /usr/local/lib/tsx/tfa_dsp.py status --bus 1
