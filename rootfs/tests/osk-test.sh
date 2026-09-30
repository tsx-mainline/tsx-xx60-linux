#!/bin/bash
# On-panel acceptance test for the on-screen keyboard (KIOSK_OSK=squeekboard).
# Host side. Needs KIOSK_DEVTOOLS=1 on the panel and a tunnel
#   ssh -f -N -L 9222:127.0.0.1:9222 root@PANEL
# It uses real injected touches (tests/tap.py -> /dev/input/event1 -> libinput
# -> sway -> Chromium or the keyboard layer). It takes grim screenshots of the
# composited sway output, which includes the keyboard layer. It reads the
# field value with CDP.
# Usage: tests/osk-test.sh PREFIX [IP]    -> results/PREFIX-*.png, results/PREFIX.txt
# It types the word "kiosk" (a test word, never real credentials).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PFX=${1:?prefix}; IP=${2:-${PANEL_IP:?set PANEL_IP or pass IP as arg 2}}
R=$HERE/results; OUT=$R/$PFX.txt
p() { sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP "$@"; }
shot() { p 'su -s /bin/sh kiosk -c "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 "^wayland-[0-9]*$") grim -"' > "$R/$PFX-$1.png"; echo "screenshot $PFX-$1.png ($(stat -c %s "$R/$PFX-$1.png") bytes)"; }
tap() { python3 $HERE/tests/tap.py --ip $IP "$@" >/dev/null; }
JS='(()=>{const all=[];const walk=r=>{for(const e of r.querySelectorAll("*")){if(e.tagName=="INPUT")all.push(e);if(e.shadowRoot)walk(e.shadowRoot)}};walk(document);let a=document.activeElement;while(a&&a.shadowRoot&&a.shadowRoot.activeElement)a=a.shadowRoot.activeElement;const u=all.find(i=>i.name=="username");return JSON.stringify({username:u?u.value:null,focus:a?(a.tagName+":"+(a.name||"")):null,viewport:innerWidth+"x"+innerHeight})})()'
state() { python3 $HERE/tests/cdp.py 9222 eval "$JS" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["result"]["value"]))'; }
osk() { p "tsx-osk status"; }
{
echo "### on-screen keyboard test $PFX, $(date)"
p 'grep "^KIOSK_OSK\|^OSK_" /etc/kiosk.conf; uname -r; cat /var/lib/tsx/install.info 2>/dev/null | head -3'
echo "--- 1. reload the login page (keyboard should be hidden)"
python3 $HERE/tests/cdp.py 9222 eval 'location.reload()' >/dev/null; sleep 12
python3 $HERE/tests/cdp.py 9222 eval 'document.activeElement && document.activeElement.blur && document.activeElement.blur()' >/dev/null; sleep 2
state; osk; shot 1-hidden
echo "--- 2. tap the Username field at (640,352) (full-height layout)"
tap 640,352; sleep 2.5
state; osk; shot 2-shown
echo "--- 3. tap the keys k i o s k"
tap --gap 400 894,633 852,567 937,567 384,633 894,633; sleep 1.5
state; shot 3-typed
echo "--- 4. tap the empty page background at (1150,400) (field loses focus)"
tap 1150,400; sleep 2
state; osk; shot 4-hidden-again
echo "--- 5. three-finger tap (tsx-idled gesture -> tsx-osk toggle): show"
tap --together 300,300 500,300 700,300; sleep 2
osk; shot 5-gesture-shown
echo "--- 6. three-finger tap again: hide"
tap --together 300,300 500,300 700,300; sleep 2
osk; state
echo "--- 7. Password field (tap at 600,437) shows the keyboard too. type x, read only the length"
tap 600,437; sleep 2.5; osk; tap 469,700; sleep 1
python3 $HERE/tests/cdp.py 9222 eval "$(echo "$JS" | sed 's/username:u?u.value:null/username:u?u.value:null,passwordLength:(all.find(i=>i.name==\"password\")||{value:\"\"}).value.length/')" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["result"]["value"]))'
tap 1150,400; sleep 2; osk
echo "--- 8. blank with the keyboard up, wake by a touch on a key (must not type)"
tap 640,352; sleep 2.5; osk; state
p 'tsx-blank on; sleep 1; tsx-blank status'
tap 257,567; sleep 1.5
p 'tsx-blank status'; osk; state
tap 1150,400; sleep 2; osk
echo "--- tsx-idled log"
p 'tail -4 /var/log/tsx-idled.log'
} 2>&1 | tee "$OUT"
