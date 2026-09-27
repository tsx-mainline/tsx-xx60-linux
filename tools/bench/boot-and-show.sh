#!/bin/bash
# Wait for a fresh U-Boot prompt (after line 5431 of the log), TFTP-boot mainline, show the pattern.
P=$(cd "$(dirname "$0")" && pwd)
until tail -n +5431 $P/boot-2200.log | grep -aq 'exit abortboot: 1'; do sleep 1; done
IPL=$($P/tftpboot.sh) || { echo "$IPL"; exit 1; }; echo "$IPL"
IP=$(echo "$IPL" | grep -oE '[0-9]+(\.[0-9]+){3}')
for i in $(seq 1 30); do sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 root@$IP true 2>/dev/null && break; sleep 2; done
$P/showpattern.sh $IP
