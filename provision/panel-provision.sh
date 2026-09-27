#!/bin/sh
# panel-provision.sh: put the Home Assistant credentials on the TSW-1060
# and verify them. Run from this workstation, ONLY when the panel is free
# (no other agent redeploying p5). Needs secrets from ./ha-provision.py mint.
#
#   ./panel-provision.sh --panel <panel-ip> [--no-verify] [--light light.xyz] [--broker <host>]
#
# Does, over ssh (root/tsx), with every secret sent on stdin (never in argv):
#   1. /etc/tsx/ha-token      <- secrets/ha-token (0600)            tsx-buttons
#   2. /etc/tsx/buttons.conf  HA_URL=$HA, light.CHANGE_ME -> $LIGHT
#   3. /etc/tsx/mqtt.conf     BROKER/USER/PASSWORD (0600)           tsx-mqtt
#   4. rc-service tsx-buttons restart; rc-service tsx-mqtt restart
#   5. /etc/kiosk.conf        KIOSK_URL=$HA/tsw-1060/home
#   6. kiosk-set-token --file <secrets/kiosk-token>  (restarts the kiosk)
# and verifies:
#   a. tsx-keypad press lights toggles $LIGHT in HA (then toggles it back)
#   b. the tsx_button event reaches HA (subscribed as the panel user; if a
#      non-admin cannot subscribe: no curl error in /var/log/tsx-buttons.log)
#   c. MQTT discovery entities appear in HA (entity ids containing "tsx")
#   d. the kiosk shows the dashboard logged in (CDP via ssh -L 9222)
# Backups of the three edited files: /etc/tsx/*.pre-provision, /etc/kiosk.conf.pre-provision.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
S=$HERE/secrets
PANEL=${PANEL_IP:-}
HA=${HA_URL:-https://ha.example.org}
DASH=tsw-1060/home
LIGHT=${LIGHT:-light.example_light}
BROKER=${BROKER:-}
MQTT_USER=tsw1060
VERIFY=1
while [ $# -gt 0 ]; do
	case $1 in
	--no-verify) VERIFY=0;;
	--light) LIGHT=$2; shift;;
	--panel) PANEL=$2; shift;;
	--broker) BROKER=$2; shift;;
	*) sed -n '2,24p' "$0"; exit 2;;
	esac; shift
done
[ -n "$PANEL" ] || { echo "PANEL required: --panel <panel-ip> or \$PANEL_IP" >&2; exit 2; }
CDP=$HERE/../rootfs/tests/cdp.py
HP=$HERE/ha-provision.py

p() { sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$PANEL "$@"; }
say() { printf '\n== %s\n' "$*"; }
fail=0
bad() { echo "FAIL: $*"; fail=1; }

for f in ha-token kiosk-token tsw1060.password; do
	[ -s "$S/$f" ] || { echo "missing $S/$f (run ./ha-provision.py mint first)"; exit 1; }
done
case $LIGHT in light.*) ;; *) echo "bad --light $LIGHT"; exit 2;; esac

say "panel $PANEL reachable, services present"
p 'uname -r; for s in tsx-buttons tsx-mqtt kiosk; do [ -x /etc/init.d/$s ] && echo "service $s ok" || echo "service $s MISSING"; done; command -v kiosk-set-token tsx-keypad mosquitto_pub || true'

say "1. /etc/tsx/ha-token"
p 'umask 077; mkdir -p /etc/tsx; cat > /etc/tsx/ha-token.new && chmod 600 /etc/tsx/ha-token.new && mv /etc/tsx/ha-token.new /etc/tsx/ha-token && ls -l /etc/tsx/ha-token | cut -c1-10,24-' < "$S/ha-token"

say "2. /etc/tsx/buttons.conf: HA_URL=$HA, lights key -> $LIGHT"
p "set -e; f=/etc/tsx/buttons.conf; [ -e \$f.pre-provision ] || cp -p \$f \$f.pre-provision
sed -i -e 's#^HA_URL=.*#HA_URL=$HA#' -e 's#light\\.CHANGE_ME#$LIGHT#' \$f
grep -n '^HA_URL=\\|^HA_TOKEN_FILE=\\|^HA_EVENT=\\|^on lights' \$f"

say "3. /etc/tsx/mqtt.conf: BROKER=$BROKER USER=$MQTT_USER PASSWORD=(from stdin)"
p "set -e; f=/etc/tsx/mqtt.conf; [ -e \$f.pre-provision ] || cp -p \$f \$f.pre-provision
IFS= read -r pw; case \$pw in *[!A-Za-z0-9]*|'') echo 'password must be alphanumeric'; exit 1;; esac
sed -i -e 's#^BROKER=.*#BROKER=$BROKER#' -e 's#^USER=.*#USER=$MQTT_USER#' -e \"s#^PASSWORD=.*#PASSWORD=\$pw#\" \$f
chmod 600 \$f; ls -l \$f | cut -c1-10; grep -n '^BROKER=\\|^PORT=\\|^USER=' \$f; grep -c '^PASSWORD=.\\+' \$f | sed 's/^/PASSWORD lines set: /'" < "$S/tsw1060.password"

say "4. restart tsx-buttons and tsx-mqtt"
p 'rc-service tsx-buttons restart >/dev/null 2>&1; rc-service tsx-mqtt restart >/dev/null 2>&1; sleep 3; rc-service tsx-buttons status; rc-service tsx-mqtt status; tail -3 /var/log/tsx-buttons.log; tail -5 /var/log/tsx-mqtt.log'

say "5. /etc/kiosk.conf: KIOSK_URL=$HA/$DASH (and KIOSK_DEVTOOLS=1 for the checks)"
p "set -e; f=/etc/kiosk.conf; [ -e \$f.pre-provision ] || cp -p \$f \$f.pre-provision
sed -i -e 's#^KIOSK_URL=.*#KIOSK_URL=\"$HA/$DASH\"#' \$f
grep -q '^KIOSK_DEVTOOLS=1' \$f || sed -i 's#^KIOSK_DEVTOOLS=.*#KIOSK_DEVTOOLS=1#' \$f
grep -n '^KIOSK_URL=\\|^KIOSK_DEVTOOLS=' \$f"

say "6. kiosk-set-token --file (kiosk logs in as the panel user; restarts the kiosk)"
p 'umask 077; t=$(mktemp); cat > "$t"; kiosk-set-token --file "$t"; rc=$?; rm -f "$t"; kiosk-set-token --show; exit $rc' < "$S/kiosk-token"

[ $VERIFY = 1 ] || { echo "done (no verification)"; exit 0; }

say "a+b. lights key -> $LIGHT, tsx_button event"
before=$("$HP" light-state --light "$LIGHT")
echo "$LIGHT before: $before"
"$HP" wait-event --timeout 25 > /tmp/provision-event.$$ 2>&1 & WPID=$!
sleep 3
p 'n=$(wc -l < /var/log/tsx-buttons.log); tsx-keypad press lights short; sleep 4; tail -n +$((n + 1)) /var/log/tsx-buttons.log' | tee /tmp/provision-blog.$$
after=$("$HP" light-state --light "$LIGHT")
echo "$LIGHT after press: $after"
[ "$before" != "$after" ] || bad "light did not change ($before -> $after)"
wait $WPID && ev=1 || ev=0
cat /tmp/provision-event.$$
if [ $ev = 0 ]; then
	if grep -qi 'curl\|error\|no token' /tmp/provision-blog.$$; then bad "tsx-buttons logged an HA error"
	else echo "event: not observable as non-admin; tsx-buttons logged no HA error (POST /api/events/tsx_button accepted)"; fi
fi
rm -f /tmp/provision-event.$$ /tmp/provision-blog.$$
if [ "$before" != "$after" ]; then
	echo "toggling back"; p 'tsx-keypad press lights short'; sleep 4
	back=$("$HP" light-state --light "$LIGHT"); echo "$LIGHT now: $back"
	[ "$back" = "$before" ] || bad "light not restored ($back, want $before)"
fi

say "c. MQTT discovery entities (visible to the panel user)"
sleep 5
"$HP" states-grep --pattern tsx || bad "no tsx entities in HA (tsx-mqtt log above)"

say "d. kiosk dashboard logged in (CDP through ssh -L 9222)"
sleep 30   # kiosk restart + dashboard load (~40 s after kiosk-set-token)
sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	-o ExitOnForwardFailure=yes -N -L 19222:127.0.0.1:9222 root@$PANEL & TPID=$!
sleep 3
i=0; res=
while [ $i -lt 12 ]; do
	res=$(python3 "$CDP" 19222 eval 'document.title+" | "+location.href' 2>/dev/null || true)
	case $res in *"/$DASH"*) break;; esac
	sleep 5; i=$((i + 1))
done
mkdir -p "$HERE/results"; python3 "$CDP" 19222 shot "$HERE/results/kiosk-dashboard.png" || true
kill $TPID 2>/dev/null || true
echo "kiosk page: $res"
case $res in *auth/authorize*) bad "kiosk shows the HA login page";; *"/$DASH"*) echo "kiosk: dashboard loaded, logged in";; *) bad "kiosk not on $DASH (login page? $res)";; esac

[ $fail = 0 ] && echo "\nPANEL PROVISION: ALL CHECKS PASSED" || echo "\nPANEL PROVISION: SOME CHECKS FAILED"
exit $fail
