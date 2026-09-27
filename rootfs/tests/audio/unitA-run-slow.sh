#!/bin/sh
# ua-slow.sh: like ua.sh, but feeds stdin line by line (the Android tty drops fast input).
# Needs PANEL_IP and TSX_ADMIN_PW (the Crestron console/root login for that unit).
[ -n "$PANEL_IP" ] && [ -n "$TSX_ADMIN_PW" ] || { echo "set PANEL_IP and TSX_ADMIN_PW" >&2; exit 2; }
{ sleep 3; while IFS= read -r l; do printf '%s\n' "$l"; sleep ${D:-0.15}; done; echo; echo exit; sleep 2; } | timeout ${T:-60} sshpass -p "$TSX_ADMIN_PW" ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "admin@$PANEL_IP" 2>&1 | tr -d '\r'
