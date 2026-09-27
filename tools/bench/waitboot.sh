#!/bin/bash
# Wait for the next U-Boot stop in the serial log (after the current end), then TFTP-boot mainline.
# Start this (with serlog.py --stop running) before power-cycling the panel.
HERE=$(cd "$(dirname "$0")" && pwd); LOG=$HERE/boot-2200.log; n=$(wc -l < $LOG)
until tail -n +$n $LOG | grep -aq 'exit abortboot: 1'; do sleep 1; done
$HERE/tftpboot.sh
