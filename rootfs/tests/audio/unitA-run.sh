#!/bin/sh
# ua.sh: run the commands on stdin on the rooted-Android bench unit, in its root bash.
# Needs PANEL_IP and TSX_ADMIN_PW (the Crestron console/root login for that unit).
[ -n "$PANEL_IP" ] && [ -n "$TSX_ADMIN_PW" ] || { echo "set PANEL_IP and TSX_ADMIN_PW" >&2; exit 2; }
{ sleep 3; cat; echo; echo exit; sleep 2; } | timeout ${T:-60} sshpass -p "$TSX_ADMIN_PW" ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "admin@$PANEL_IP" 2>&1 | tr -d '\r'
