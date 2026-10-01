#!/bin/bash
# browser: does the on-screen keyboard still show and type under the current
# Chromium config? The script loads input.html (a text field at the top) and
# taps the field (a real injected touch). It types "kiosk" on the keys of
# squeekboard (coordinates from rootfs tests/osk-test.sh), reads the field
# back through CDP, and taps outside.
# Usage: osk-check.sh CFG [IP]   -> results/perf-CFG-osk.txt, -osk-shown.png
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOTFS_DIR=$HERE/../../rootfs
CFG=${1:?cfg}; IP=${2:-${PANEL_IP:?set PANEL_IP or pass IP as arg 2}}; R=$HERE/../results; PORT=${PORT:-9222}; mkdir -p "$R"
p() { sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP "$@"; }
CDP="python3 $ROOTFS_DIR/tests/cdp.py $PORT"
tap() { python3 $ROOTFS_DIR/tests/tap.py --ip $IP "$@" >/dev/null; }
shot() { p 'su -s /bin/sh kiosk -c "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 "^wayland-[0-9]*$") grim -"' > "$R/perf-$CFG-$1.png"; }
val() { $CDP eval 'JSON.stringify({v:document.getElementById("f").value,focus:document.activeElement&&document.activeElement.id,vp:innerWidth+"x"+innerHeight})' | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["result"]["value"]))'; }
{
echo "### osk check $CFG $(date)"
p 'mkdir -p /tmp/tsx-perf && cat > /tmp/tsx-perf/input.html && chmod 644 /tmp/tsx-perf/input.html' < "$HERE/input.html"
ORIG=$($CDP eval 'location.href' | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["value"])')
$CDP nav file:///tmp/tsx-perf/input.html >/dev/null; sleep 2
$CDP eval 'document.activeElement&&document.activeElement.blur()' >/dev/null; sleep 1
echo "before: $(p tsx-osk status) $(val)"
tap 640,70; sleep 2.5
echo "after tap on field: $(p tsx-osk status) $(val)"
shot osk-shown
tap --gap 400 894,633 852,567 937,567 384,633 894,633; sleep 1.5
echo "after typing: $(val)"
shot osk-typed
tap 1150,400; sleep 2
echo "after tap outside: $(p tsx-osk status) $(val)"
$CDP nav "$ORIG" >/dev/null 2>&1
} 2>&1 | tee "$R/perf-$CFG-osk.txt"
