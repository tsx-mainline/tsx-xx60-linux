#!/bin/bash
# After a power-cycle with the serial logger running in --stop mode: DHCP, TFTP test.img, boot.
# Usage: tftpboot.sh <TFTP_SERVER_IP>
SRV=${1:?usage: tftpboot.sh <tftp-server-ip>}; P=$(cd "$(dirname "$0")" && pwd); LOG=$P/boot-2200.log
wait_for() { for i in $(seq 1 ${2:-60}); do tail -5 $LOG | grep -aqE "$1" && return 0; sleep 1; done; echo "timeout waiting for: $1"; exit 1; }
wait_for 'yushan_one_2G#' 120
$P/uc.sh -w 1 'setenv autoload no' 'dhcp' >/dev/null; wait_for 'DHCP client bound' 60
$P/uc.sh -w 1 "setenv serverip $SRV" 'tftpboot ${loadaddr} test.img' >/dev/null; wait_for 'Bytes transferred' 90
$P/uc.sh -w 1 'setenv bootargs ${bootargs} earlycon=meson,0xc81004c0 keep_bootcon' 'bootm' >/dev/null
wait_for 'eth0: [0-9.]+/' 90; grep -aoE 'eth0: [0-9.]+/[0-9]+' $LOG | tail -1
