#!/bin/bash
# Pull a block device from the live TSW-1060 over TCP.
# The panel listens (it cannot reach the host), the host connects.
# The panel hashes the exact stream it sends (FIFO + tee).
# Usage: PANEL_IP=<panel-ip> pull-block.sh <panel-dev> <out-file> [port]
set -e
DEV=$1; OUT=$2; PORT=${3:-9000}
: "${PANEL_IP:?set PANEL_IP to the panel address}"
PANEL=admin@$PANEL_IP
T=/data/local/tmp
LOG=$OUT.panel.log
(
printf '%s\n' \
 "echo MARK1" \
 "rm -f $T/f.fifo $T/f.sum; mkfifo $T/f.fifo" \
 "sha256sum < $T/f.fifo > $T/f.sum &" \
 "dd if=$DEV bs=4194304 2>$T/f.dd | busybox tee $T/f.fifo | busybox nc -l -p $PORT; wait" \
 "cat $T/f.dd; echo PANELSUM \$(cat $T/f.sum)" \
 "rm -f $T/f.fifo $T/f.sum $T/f.dd; echo MARK2" "exit" \
 | sshpass -p password ssh -o ServerAliveInterval=30 -tt $PANEL 2>&1 | tr -d '\r' | sed -n '/^MARK1/,/^MARK2/p' > "$LOG"
) &
SSHPID=$!
sleep 8
nc "$PANEL_IP" $PORT > "$OUT"
wait $SSHPID
cat "$LOG"
PS=$(grep '^PANELSUM' "$LOG" | awk '{print $2}')
HS=$(sha256sum "$OUT" | awk '{print $1}')
echo "panel $PS"; echo "host  $HS"
[ "$PS" = "$HS" ] && echo "VERIFIED $OUT" && echo "$HS  $(basename $OUT)" >> "$(dirname $OUT)/SHA256SUMS" || { echo "MISMATCH"; exit 1; }
