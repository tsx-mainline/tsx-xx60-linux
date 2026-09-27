#!/bin/bash
# Send U-Boot commands through the logger FIFO and print the new log output.
# Usage: uc.sh [-w SECONDS] 'cmd1' 'cmd2' ...
D=$(dirname "$0"); W=3; [ "$1" = -w ] && { W=$2; shift 2; }
n=$(wc -l < $D/boot-2200.log)
for c in "$@"; do echo "$c" > $D/cmd; sleep 0.3; done
sleep $W; tail -n +$((n+1)) $D/boot-2200.log | cut -c12-
