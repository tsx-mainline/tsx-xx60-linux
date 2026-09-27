#!/bin/sh
# vstep.sh N: on the panel, set the DSP volume step (preset + EQ + VOL) with a silent stream for the clocks
aplay -q -D default -t raw -f S16_LE -r 48000 -c 2 /dev/zero 2>/dev/null & ap=$!; sleep 1
python3 /usr/local/lib/tsx/tfa_dsp.py vstep /usr/local/share/tsx/tfa9890/settings_yushan/stereo.cnt $1 --bus 1 --yes; rc=$?
kill $ap; wait $ap 2>/dev/null; echo "vstep $1 rc=$rc $(date +%T)"; exit $rc
