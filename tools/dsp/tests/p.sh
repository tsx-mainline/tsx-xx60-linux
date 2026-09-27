#!/bin/sh
# p.sh 'cmd': run on the panel. Needs PANEL_IP (root password: rescue/panel default "tsx",
# see RESCUE_PW to override).
: "${PANEL_IP:?set PANEL_IP to the panel address}"
exec sshpass -p "${RESCUE_PW:-tsx}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$PANEL_IP" "$@"
