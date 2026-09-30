#!/bin/bash
# Push pattern.raw to the panel framebuffer. Usage: showpattern.sh <IP> [--console]
# Detaches fbcon first so the text console does not draw over it. --console re-attaches it.
IP=${1:?usage: showpattern.sh <panel-ip> [--console]}; D=$(dirname "$0")
S="sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP"
if [ "$2" = --console ]; then
  $S 'for v in /sys/class/vtconsole/vtcon*; do grep -q "frame buffer" $v/name && echo 1 > $v/bind; done; echo attached'
  exit
fi
$S 'for v in /sys/class/vtconsole/vtcon*; do grep -q "frame buffer" $v/name && echo 0 > $v/bind; done; echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null; true'
$S 'cat > /dev/fb0' < $D/pattern.raw && echo "pattern written ($(stat -c %s $D/pattern.raw) bytes)"
