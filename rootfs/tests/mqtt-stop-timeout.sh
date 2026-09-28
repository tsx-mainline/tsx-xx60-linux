#!/bin/sh
# Host test: tsx-mqtt with an unreachable broker (e.g. MQTT_HOST=192.0.2.1 on
# real hardware) must still stop within a few seconds. mosquitto_pub/sub are
# stubbed to hang the way a real client hangs on a dead TCP connect (they
# just sleep). Proves: (1) SIGTERM makes the running daemon exit quickly even
# while a publish is stuck mid-connect, (2) no mosquitto_pub/sub is left
# behind as an orphan.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/../../rootfs/overlay
T=$(mktemp -d); trap 'rc=$?; kill "${DAEMON:-}" 2>/dev/null || true; rm -rf "$T"; exit $rc' EXIT
mkdir -p "$T/bin" "$T/run" "$T/bl/x" "$T/none"
: > "$T/children.pids"

# mosquitto_pub/sub stand-ins for an unreachable broker: hang the way a real
# client hangs mid-TCP-connect. Each records its own pid before blocking so
# the test can check afterwards that nothing was left running.
for c in mosquitto_pub mosquitto_sub; do
	cat > "$T/bin/$c" <<EOF
#!/bin/sh
echo "\$\$ $c" >> "$T/children.pids"
exec sleep 9999
EOF
	chmod +x "$T/bin/$c"
done
for c in tsx-ledbar tsx-keypad tsx-blank tsx-autoupdate tsx-config; do
	printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"
done

printf 'BROKER=192.0.2.1\nNODE_ID=tsx-stoptest\n' > "$T/mqtt.conf"

# Long PUBTO on purpose: this proves the stop trap itself kills the stuck
# publisher (process-group kill) rather than just waiting out a short bound.
PATH="$T/bin:$PATH" TSX_MQTT_CONF="$T/mqtt.conf" TSX_RUN_DIR="$T/run" TSX_IDLED_STATE="$T/idled" \
	TSX_BUTTONS_CONF="$O/etc/tsx/buttons.conf" TSX_KIOSK_CONF="$O/etc/kiosk.conf" TSX_BACKLIGHT_DIR="$T/bl" \
	TSX_ALS_CONF="$T/none/als.conf" TSX_ASOUND_DIR="$T/none" TSX_MQTT_PUB_TIMEOUT=60 \
	sh "$O/usr/local/sbin/tsx-mqtt" > "$T/daemon.log" 2>&1 &
DAEMON=$!

# Wait for the daemon to be genuinely stuck inside its first publish: tsx-mqtt
# records the in-flight mosquitto_pub's pid in $TSX_RUN_DIR/mqtt/pub.pids
# (see pub() in tsx-mqtt). mosquitto_sub starts first and would also show up
# in children.pids straight away, so that file alone is not a safe signal.
n=0
while [ ! -s "$T/run/mqtt/pub.pids" ]; do
	n=$((n + 1)); [ $n -le 50 ] || { echo "FAIL: daemon never reached its first publish"; cat "$T/daemon.log"; exit 1; }
	sleep 0.1
done
sleep 0.2   # let it settle into `wait "$pp"`, not just past the fork

fail=0
start=$(date +%s)
kill -TERM "$DAEMON" 2>/dev/null

n=0
while kill -0 "$DAEMON" 2>/dev/null; do
	n=$((n + 1)); [ $n -le 100 ] || { echo "FAIL: daemon did not exit within 10s of SIGTERM"; fail=1; break; }
	sleep 0.1
done
end=$(date +%s)
elapsed=$((end - start))
wait "$DAEMON" 2>/dev/null || true

if [ "$fail" = 0 ]; then
	if [ "$elapsed" -le 5 ]; then echo "stop completed in ${elapsed}s"
	else echo "FAIL: stop took ${elapsed}s, want <=5s"; fail=1
	fi
fi

# Nothing recorded (mosquitto_pub/sub stand-ins, i.e. their pgid-mates) may
# still be alive: the trap's process-group kill must have reaped them all.
while read -r pid tag; do
	[ -n "$pid" ] || continue
	if kill -0 "$pid" 2>/dev/null; then echo "FAIL: $tag pid $pid still running (orphaned)"; fail=1; fi
done < "$T/children.pids"
if [ "$fail" = 0 ]; then echo "PASS no orphaned mosquitto_pub/sub after stop ($(wc -l < "$T/children.pids") spawned)"; fi

exit $fail
