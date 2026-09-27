#!/bin/sh
# Runs IN THE VM as root: start one browser under cage (pixman, software) on
# the kiosk URL, wait, print memory (measure-mem.sh), stop it.
# Usage: run-browser.sh chromium|firefox|webkit [seconds]   (kiosk service must be stopped)
B=$1; WAIT=${2:-240}; . /etc/kiosk.conf
uid=$(id -u kiosk); mkdir -p /run/user/$uid; chown kiosk /run/user/$uid; chmod 700 /run/user/$uid
case $B in
chromium) CMD="chromium-browser --ozone-platform=wayland --kiosk --no-first-run --no-sandbox --disable-gpu --disable-gpu-compositing --user-data-dir=/tmp/bench-chromium $KIOSK_URL";;
firefox)  CMD="env MOZ_ENABLE_WAYLAND=1 firefox-esr --kiosk --profile /tmp/bench-firefox $KIOSK_URL"; mkdir -p /tmp/bench-firefox; chown kiosk /tmp/bench-firefox;;
webkit)   CMD="python3 /tmp/webkit-kiosk.py $KIOSK_URL";;
esac
su -s /bin/sh kiosk -c "export XDG_RUNTIME_DIR=/run/user/$uid WLR_RENDERER=pixman WLR_BACKENDS=drm,libinput WLR_LIBINPUT_NO_DEVICES=1 HOME=/tmp; exec cage -d -- $CMD" >/tmp/bench-$B.log 2>&1 &
sleep "$WAIT"
sh /tmp/measure-mem.sh "$B after ${WAIT}s"
pkill -x cage; sleep 5; pkill -9 -u kiosk 2>/dev/null; sleep 2
