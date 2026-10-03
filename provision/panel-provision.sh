#!/bin/sh
# panel-provision.sh: put the Home Assistant credentials on the panel and
# verify them. Run it from a workstation that reaches the panel over ssh. It
# needs the secrets from ./ha-provision.py mint.
#
#   ./panel-provision.sh --panel <panel-ip> --ha-url <https://ha.example> --light <light.entity>
#                        [--key FILE | --password-file FILE] [--broker <host>]
#                        [--user NAME] [--dashboard PATH] [--check] [--no-verify]
#
# Login: the script logs in as root with the key or the password that you set in
# panel.conf (ROOT_PASSWORD_HASH or SSH_AUTHORIZED_KEY, docs/rootfs.md "Root
# login"). There is no default password.
#   --key FILE            use this private key (ssh -i, no password prompt)
#   --password-file FILE  read the root password from this file (sshpass -f).
#                         Also: $PANEL_PASSWORD_FILE.
#   neither               use your ssh agent or ~/.ssh/id_* keys
# The script never puts a password on a command line, never prints it and
# never stores it.
# Before it writes anything, it prints the panel, the login method and the
# Home Assistant URL, and it tests the login. --check stops after that.
#
# Over ssh, with every secret sent on stdin (never in argv), it does:
#   1. /etc/tsx/ha-token      <- secrets/ha-token (0600)            tsx-buttons
#   2. /etc/tsx/buttons.conf  HA_URL=$HA, light.CHANGE_ME -> $LIGHT
#   3. tsx-config set MQTT_HOST/MQTT_USER/MQTT_PASSWORD + apply (panel.conf,
#      docs/rootfs.md "Panel configuration"). This creates /run/tsx/mqtt.conf.
#      tsx-mqtt reads it after its own defaults in /etc/tsx/mqtt.conf.
#   4. rc-service tsx-buttons restart, rc-service tsx-mqtt restart
#   5. tsx-config set KIOSK_URL $HA/$DASH + apply (the same file).
#      kiosk-session reads /run/tsx/kiosk.conf after /etc/kiosk.conf.
#   6. kiosk-set-token --file <secrets/kiosk-token>  (restarts the kiosk)
# Then it verifies:
#   a. tsx-keypad press lights toggles $LIGHT in HA (then toggles it back)
#   b. the tsx_button event reaches HA. The script subscribes as the panel user.
#      If a non-admin cannot subscribe, /var/log/tsx-buttons.log has no curl error.
#   c. MQTT discovery entities appear in HA (entity ids containing "tsx")
#   d. the kiosk shows the dashboard, logged in (CDP via ssh -L 9222)
# Backups of the edited files: /etc/tsx/*.pre-provision, /etc/kiosk.conf.pre-provision.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
S=$HERE/secrets
PANEL=${PANEL_IP:-}
HA=${HA_URL:-}
DASH=tsw-1060/home   # path of the example dashboard in dashboard-tsw1060.yaml
LIGHT=${LIGHT:-}
BROKER=${BROKER:-}
MQTT_USER=tsw1060    # the Home Assistant user of the panel (ha-provision.py --user)
KEY=
PWFILE=${PANEL_PASSWORD_FILE:-}
VERIFY=1
CHECK=0
usage() { sed -n '2,36p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
	--no-verify) VERIFY=0;;
	--check) CHECK=1;;
	--light) [ $# -ge 2 ] || die "--light needs a value"; LIGHT=$2; shift;;
	--panel) [ $# -ge 2 ] || die "--panel needs a value"; PANEL=$2; shift;;
	--broker) [ $# -ge 2 ] || die "--broker needs a value"; BROKER=$2; shift;;
	--ha-url) [ $# -ge 2 ] || die "--ha-url needs a value"; HA=$2; shift;;
	--user) [ $# -ge 2 ] || die "--user needs a value"; MQTT_USER=$2; shift;;
	--dashboard) [ $# -ge 2 ] || die "--dashboard needs a value"; DASH=$2; shift;;
	--key) [ $# -ge 2 ] || die "--key needs a file"; KEY=$2; shift;;
	--password-file) [ $# -ge 2 ] || die "--password-file needs a file"; PWFILE=$2; shift;;
	-h|--help) usage; exit 0;;
	*) usage; exit 2;;
	esac; shift
done
[ -n "$PANEL" ] || die "no panel. Give --panel <panel-ip> or set PANEL_IP."
[ -n "$HA" ] || die "no Home Assistant URL. Give --ha-url https://ha.example.org or set HA_URL."
[ -n "$LIGHT" ] || die "no light. Give --light <light.entity>, the light that the Lights key toggles."
case $LIGHT in light.*) ;; *) die "bad --light $LIGHT (it must start with light.)";; esac
case $HA in http://*|https://*) ;; *) die "bad --ha-url $HA (it must start with http:// or https://)";; esac
HA=${HA%/}
[ -z "$KEY" ] || [ -z "$PWFILE" ] || die "give --key or --password-file, not both."

# Login method. A password file wins over keys only when no key file is given.
if [ -n "$KEY" ]; then
	[ -r "$KEY" ] || die "cannot read the key file $KEY"
	METHOD="ssh key $KEY"
elif [ -n "$PWFILE" ]; then
	[ -r "$PWFILE" ] && [ -s "$PWFILE" ] || die "cannot read the password file $PWFILE, or it is empty"
	command -v sshpass >/dev/null 2>&1 || die "--password-file needs sshpass on this host."
	METHOD="password from $PWFILE"
else
	if [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1; then
		METHOD="ssh agent"
	elif ls "${HOME:-/nonexistent}"/.ssh/id_* >/dev/null 2>&1; then
		METHOD="default keys in ~/.ssh"
	else
		cat >&2 <<MSG
ERROR: no login for root@$PANEL. The script changed nothing.
There is no default password. Use the login that you set in panel.conf
(ROOT_PASSWORD_HASH or SSH_AUTHORIZED_KEY). Give one of these:
  --key FILE             a private key for the panel
  --password-file FILE   a file with the root password (or set PANEL_PASSWORD_FILE)
  or load a key into your ssh agent
MSG
		exit 2
	fi
fi
CDP=$HERE/../rootfs/tests/cdp.py
HP=$HERE/ha-provision.py

SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
# sshx [ssh options] -- the ssh call with the chosen login
sshx() {
	if [ -n "$PWFILE" ]; then
		sshpass -f "$PWFILE" ssh $SSHO -o PubkeyAuthentication=no "$@"
	elif [ -n "$KEY" ]; then
		ssh $SSHO -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" "$@"
	else
		ssh $SSHO -o BatchMode=yes "$@"
	fi
}
p() { sshx root@$PANEL "$@"; }
say() { printf '\n== %s\n' "$*"; }
fail=0
bad() { echo "FAIL: $*"; fail=1; }

say "preflight"
echo "panel:       $PANEL"
echo "login:       root, $METHOD"
echo "HA URL:      $HA"
echo "dashboard:   $HA/$DASH"
echo "light:       $LIGHT"
echo "MQTT:        host ${BROKER:-(none)}, user $MQTT_USER"
echo "verify:      $([ $VERIFY = 1 ] && echo yes || echo no)"
for f in ha-token kiosk-token tsw1060.password; do
	[ -s "$S/$f" ] || { echo "ERROR: missing $S/$f (run ./ha-provision.py mint first). The script changed nothing."; exit 1; }
done
echo "secrets:     found in $S"
printf 'login test:  '
if ! p true </dev/null; then
	echo "FAILED"
	echo "ERROR: cannot log in to root@$PANEL with $METHOD. The script changed nothing." >&2
	echo "Check the address and that the login matches ROOT_PASSWORD_HASH or SSH_AUTHORIZED_KEY in panel.conf." >&2
	exit 1
fi
echo "ok"
[ $CHECK = 0 ] || { echo "preflight done (--check): nothing written"; exit 0; }

say "panel $PANEL reachable, services present"
p 'uname -r; for s in tsx-buttons tsx-mqtt kiosk; do [ -x /etc/init.d/$s ] && echo "service $s ok" || echo "service $s MISSING"; done; command -v kiosk-set-token tsx-keypad mosquitto_pub || true'

say "1. /etc/tsx/ha-token"
p 'umask 077; mkdir -p /etc/tsx; cat > /etc/tsx/ha-token.new && chmod 600 /etc/tsx/ha-token.new && mv /etc/tsx/ha-token.new /etc/tsx/ha-token && ls -l /etc/tsx/ha-token | cut -c1-10,24-' < "$S/ha-token"

say "2. /etc/tsx/buttons.conf: HA_URL=$HA, lights key -> $LIGHT"
p "set -e; f=/etc/tsx/buttons.conf; [ -e \$f.pre-provision ] || cp -p \$f \$f.pre-provision
sed -i -e 's#^HA_URL=.*#HA_URL=$HA#' -e 's#light\\.CHANGE_ME#$LIGHT#' \$f
grep -n '^HA_URL=\\|^HA_TOKEN_FILE=\\|^HA_EVENT=\\|^on lights' \$f"

say "3. panel.conf: MQTT_HOST=$BROKER MQTT_USER=$MQTT_USER MQTT_PASSWORD=(from stdin)"
p "set -e
IFS= read -r pw; case \$pw in *[!A-Za-z0-9]*|'') echo 'password must be alphanumeric'; exit 1;; esac
tsx-config set MQTT_HOST '$BROKER'
tsx-config set MQTT_USER '$MQTT_USER'
tsx-config set MQTT_PASSWORD \"\$pw\"
tsx-config apply
tsx-config show | grep '^MQTT_'" < "$S/tsw1060.password"

say "4. restart tsx-buttons and tsx-mqtt"
p 'rc-service tsx-buttons restart >/dev/null 2>&1; rc-service tsx-mqtt restart >/dev/null 2>&1; sleep 3; rc-service tsx-buttons status; rc-service tsx-mqtt status; tail -3 /var/log/tsx-buttons.log; tail -5 /var/log/tsx-mqtt.log'

say "5. panel.conf: KIOSK_URL=$HA/$DASH (KIOSK_DEVTOOLS=1 for the checks stays a plain /etc/kiosk.conf edit, because it is not a panel.conf key)"
p "set -e; f=/etc/kiosk.conf; [ -e \$f.pre-provision ] || cp -p \$f \$f.pre-provision
tsx-config set KIOSK_URL '$HA/$DASH'
tsx-config apply
grep -q '^KIOSK_DEVTOOLS=1' \$f || sed -i 's#^KIOSK_DEVTOOLS=.*#KIOSK_DEVTOOLS=1#' \$f
tsx-config get KIOSK_URL; grep -n '^KIOSK_DEVTOOLS=' \$f"

say "6. kiosk-set-token --file (the kiosk logs in as the panel user, and restarts)"
p 'umask 077; t=$(mktemp); cat > "$t"; kiosk-set-token --file "$t"; rc=$?; rm -f "$t"; kiosk-set-token --show; exit $rc' < "$S/kiosk-token"

[ $VERIFY = 1 ] || { echo "done (no verification)"; exit 0; }

say "a+b. lights key -> $LIGHT, tsx_button event"
before=$("$HP" light-state --url "$HA" --light "$LIGHT")
echo "$LIGHT before: $before"
"$HP" wait-event --url "$HA" --timeout 25 > /tmp/provision-event.$$ 2>&1 & WPID=$!
sleep 3
p 'n=$(wc -l < /var/log/tsx-buttons.log); tsx-keypad press lights short; sleep 4; tail -n +$((n + 1)) /var/log/tsx-buttons.log' | tee /tmp/provision-blog.$$
after=$("$HP" light-state --url "$HA" --light "$LIGHT")
echo "$LIGHT after press: $after"
[ "$before" != "$after" ] || bad "light did not change ($before -> $after)"
wait $WPID && ev=1 || ev=0
cat /tmp/provision-event.$$
if [ $ev = 0 ]; then
	if grep -qi 'curl\|error\|no token' /tmp/provision-blog.$$; then bad "tsx-buttons logged an HA error"
	else echo "event: a non-admin cannot observe it. tsx-buttons logged no HA error (POST /api/events/tsx_button accepted)"; fi
fi
rm -f /tmp/provision-event.$$ /tmp/provision-blog.$$
if [ "$before" != "$after" ]; then
	echo "toggling back"; p 'tsx-keypad press lights short'; sleep 4
	back=$("$HP" light-state --url "$HA" --light "$LIGHT"); echo "$LIGHT now: $back"
	[ "$back" = "$before" ] || bad "light not restored ($back, want $before)"
fi

say "c. MQTT discovery entities (visible to the panel user)"
sleep 5
"$HP" states-grep --url "$HA" --pattern tsx || bad "no tsx entities in HA (tsx-mqtt log above)"

say "d. kiosk dashboard logged in (CDP through ssh -L 9222)"
sleep 30   # the kiosk restarts and loads the dashboard (about 40 s after kiosk-set-token)
sshx -o ExitOnForwardFailure=yes -N -L 19222:127.0.0.1:9222 \
	root@$PANEL & TPID=$!
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

[ $fail = 0 ] && printf '\nPANEL PROVISION: ALL CHECKS PASSED\n' || printf '\nPANEL PROVISION: SOME CHECKS FAILED\n'
exit $fail
