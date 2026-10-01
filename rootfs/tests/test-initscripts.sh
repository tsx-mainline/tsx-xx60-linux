#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test for the init scripts and the periodic jobs of the xx60 rootfs
# (rootfs/overlay/etc/init.d, rootfs/overlay/etc/periodic, docs/rootfs.md).
# OpenRC is not here: each script is sourced under busybox sh with
# stand-ins for einfo, checkpath and default_start. Its /usr/local/sbin,
# /run/tsx, /etc/tsx and /etc/crontabs paths move into a temp directory.
# A panel without a part, or without a setting, must start nothing and
# fail nothing.
set -uo pipefail
# The board file (rootfs/overlay/usr/local/lib/tsx/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/lib/tsx/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")/.." && pwd)
I=$HERE/overlay/etc/init.d
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-initscripts: no busybox on this host"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/log" "$T/sbin" "$T/pbin" "$T/run" "$T/etc/tsx" "$T/etc/crontabs"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

# run_fn FUNCTION SCRIPT [VAR=VALUE...]: source the script and run one
# function of it (start, start_pre). It prints what the stand-ins saw. The
# exit status is the one of the function. PATH starts with $T/pbin, so a
# stand-in of tsx-config or another tool wins.
run_fn() {
	local fn=$1 name=$2; shift 2
	sed "s|/usr/local/sbin|$T/sbin|g; s|/usr/local/bin|$T/sbin|g; s|/run/tsx|$T/run|g; s|/run/supervise-|$T/run/supervise-|g; s|/var/log|$T/log|g; s|/etc/tsx|$T/etc/tsx|g; s|/etc/crontabs|$T/etc/crontabs|g; s|/etc/init.d|$I|g; s|^#!.*||; s|supervisor=.*||" "$I/$name" > "$T/script"
	(
		einfo() { echo "info: $*"; }; eerror() { echo "error: $*"; }; ewarn() { echo "warn: $*"; }
		ebegin() { :; }; eend() { return "${1:-0}"; }; checkpath() { echo "checkpath $*"; }
		default_start() { echo "START ${command:-} ${command_args:-}"; }
		default_stop() { echo STOP; }
		export PATH="$T/pbin:$PATH"
		for kv in "$@"; do export "$kv"; done
		. "$T/script"
		"$fn"
	)
}
run_start() { run_fn start "$@"; }

echo "== all init scripts =="
for f in "$I"/*; do
	n=${f##*/}
	busybox sh -n "$f" 2>/dev/null || bad "$n: busybox sh -n"
	head -1 "$f" | grep -qx '#!/sbin/openrc-run' || bad "$n: first line is not #!/sbin/openrc-run"
	[ -x "$f" ] || bad "$n: not executable"
	grep -q '^description=' "$f" || bad "$n: no description"
done
ok "each script passes busybox sh -n, uses openrc-run, is executable and has a description"
# every script is in a runlevel of the ha profile (profiles/*.list), except the
# ones that a user turns on (tsx-voice: "tsx-audio enable voice")
for f in "$I"/*; do
	n=${f##*/}
	case $n in tsx-voice) continue;; esac
	sh "$HERE/profile.sh" has ha svc "$n" || bad "$n is in no runlevel of the profile lists"
done
ok "each script, except tsx-voice, is in a runlevel of the ha profile"
# the services in depend() exist: in this overlay, or on the Alpine list
alpine="localmount net udev udev-settle udev-postmount crond sshd dbus avahi-daemon seatd chronyd networking syslog bootmisc hostname root swclock modules sysctl sysinit"
for f in "$I"/*; do
	n=${f##*/}
	for dep in $(sed -n '/^depend()/,/^}/p; /^depend() {.*}$/p' "$f" | sed 's/^depend()[ {]*//; s/}.*$//' | tr ';' '\n' | sed -n 's/^[[:space:]]*\(need\|use\|after\|before\|provide\)[[:space:]]\{1,\}//p'); do
		case " $alpine " in *" $dep "*) continue;; esac
		[ -e "$I/$dep" ] || bad "$n: depend() names $dep, which is not in the overlay or on the Alpine list"
	done
done
ok "depend() names only services that exist"

echo "== tsx-mqtt =="
printf '#!/bin/sh\nexit 0\n' > "$T/sbin/tsx-mqtt"
out=$(run_start tsx-mqtt); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && echo "$out" | grep -q "BROKER not set" && ok "no BROKER: not started, no failure" || bad "no broker (rc $rc): $out"
echo 'BROKER=base.example.org' > "$T/etc/tsx/mqtt.conf"
out=$(run_start tsx-mqtt); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^START' && ok "BROKER in mqtt.conf: the daemon starts" || bad "broker in conf (rc $rc): $out"
echo 'BROKER=' > "$T/run/mqtt.conf"
out=$(run_start tsx-mqtt); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && ok "an empty BROKER in the panel.conf override: not started" || bad "empty override (rc $rc): $out"
rm -f "$T/etc/tsx/mqtt.conf" "$T/run/mqtt.conf"

echo "== tsx-esphome =="
printf '#!/bin/sh\ncase "$2" in HA_TRANSPORT) echo "${T_TRANSPORT:-esphome}";; VOICE) echo "${T_VOICE:-off}";; esac\n' > "$T/pbin/tsx-config"; chmod +x "$T/pbin/tsx-config"
out=$(run_start tsx-esphome); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^START' && ok "default: the device starts" || bad "default (rc $rc): $out"
out=$(run_start tsx-esphome T_TRANSPORT=mqtt); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && ok "HA_TRANSPORT=mqtt: not started, no failure" || bad "transport mqtt (rc $rc): $out"
out=$(run_start tsx-esphome T_VOICE=on TSX_TFLITE_SO="$T/libtflite.so"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^START' && ok "VOICE=on but the satellite is not enabled: the device starts (the runlevel decides)" || bad "voice on, not enabled (rc $rc): $out"
: > "$T/libtflite.so"; mkdir -p "$T/rl"; : > "$T/rl/tsx-voice"
out=$(run_start tsx-esphome TSX_RUNLEVEL_DIR="$T/rl" TSX_TFLITE_SO="$T/libtflite.so"); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && ok "satellite enabled: the device does not start, no failure" || bad "satellite enabled (rc $rc): $out"
out=$(run_start tsx-esphome TSX_RUNLEVEL_DIR="$T/rl" T_VOICE=off TSX_TFLITE_SO="$T/libtflite.so"); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && ok "satellite enabled by hand, VOICE=off: still only the satellite" || bad "hand enable (rc $rc): $out"
out=$(run_start tsx-esphome TSX_RUNLEVEL_DIR="$T/rl" T_TRANSPORT=mqtt); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && ok "satellite enabled, HA_TRANSPORT=mqtt: not started" || bad "mqtt (rc $rc): $out"
out=$(run_start tsx-esphome TSX_RUNLEVEL_DIR="$T/rl" TSX_TFLITE_SO="$T/no-such-lib"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^START' && echo "$out" | grep -q 'wake word library is missing' && ok "satellite enabled, no wake word library: the device starts and says why" || bad "no library (rc $rc): $out"
printf 'MIC=no\nREASON=test\n' > "$T/run/hw.conf"
out=$(run_start tsx-esphome TSX_RUNLEVEL_DIR="$T/rl" TSX_TFLITE_SO="$T/libtflite.so"); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^START' && ok "no microphone: starts even with the satellite enabled" || bad "no microphone (rc $rc): $out"
rm -f "$T/run/hw.conf"

echo "== tsx-voice =="
printf 'MIC=no\nREASON=government=1 (test)\n' > "$T/run/hw.conf"
out=$(run_fn start_pre tsx-voice); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q '^error: No microphone' && ok "no microphone: start_pre refuses with a clear error" || bad "MIC=no (rc $rc): $out"
rm -f "$T/run/hw.conf"

printf '#!/bin/sh\n[ "$1 $2" = "tsx-esphome status" ] && exit 3\necho "rc-service $*" >> "%s/rc.log"\n' "$T" > "$T/pbin/rc-service"; chmod +x "$T/pbin/rc-service"
: > "$T/rc.log"; rm -f "$T/run/supervise-tsx-esphome.pid"
out=$(run_fn start_pre tsx-voice); rc=$?
! grep -q 'tsx-esphome stop' "$T/rc.log" && ok "tsx-esphome not running: start_pre leaves it alone" || bad "esphome idle (rc $rc): $(cat "$T/rc.log")"
: > "$T/run/supervise-tsx-esphome.pid"
out=$(run_fn start_pre tsx-voice); rc=$?
grep -qx 'rc-service tsx-esphome stop' "$T/rc.log" && ok "tsx-esphome running (pid file): start_pre stops it before the satellite binds port 6053" || bad "esphome running (rc $rc): $(cat "$T/rc.log")"
rm -f "$T/run/supervise-tsx-esphome.pid"; : > "$T/rc.log"
printf '#!/bin/sh\n[ "$1 $2" = "tsx-esphome status" ] && exit 0\necho "rc-service $*" >> "%s/rc.log"\n' "$T" > "$T/pbin/rc-service"
out=$(run_fn start_pre tsx-voice); rc=$?
grep -qx 'rc-service tsx-esphome stop' "$T/rc.log" && ok "tsx-esphome started (rc-service status): start_pre stops it" || bad "esphome status (rc $rc): $(cat "$T/rc.log")"
grep -q 'after .*tsx-esphome' "$I/tsx-voice" && ok "tsx-voice starts after tsx-esphome at boot (no parallel bind)" || bad "tsx-voice has no after tsx-esphome"
rm -f "$T/pbin/rc-service"

echo "== tsx-audio enable and disable voice =="
for c in rc-update rc-service; do printf '#!/bin/sh\necho "%s $*" >> "%s/rc.log"\n' "$c" "$T" > "$T/pbin/$c"; chmod +x "$T/pbin/$c"; done
mkdir -p "$T/initd"; : > "$T/initd/tsx-voice"; : > "$T/initd/tsx-sendspin"
au() { PATH=$T/pbin:$PATH TSX_INITD=$T/initd busybox sh "$HERE/overlay/usr/local/bin/tsx-audio" "$@"; }
rl() { tr '\n' '|' < "$T/rc.log"; }
: > "$T/rc.log"; au enable voice >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(rl)" = "rc-update add tsx-voice default|rc-service tsx-esphome stop|rc-service tsx-voice start|" ] && ok "enable voice: runlevel, stop tsx-esphome, then start" || bad "enable voice (rc $rc): $(rl)"
rm -rf "$T/rl0"; : > "$T/rc.log"; TSX_RUNLEVEL_DIR=$T/rl0 au disable voice >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(rl)" = "rc-service tsx-voice stop|rc-update del tsx-voice default|" ] && ok "disable voice, never enabled (boot with VOICE=off): tsx-esphome is not touched" || bad "disable voice (rc $rc): $(rl)"
: > "$T/rc.log"; TSX_RUNLEVEL_DIR=$T/rl au disable voice >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(rl)" = "rc-service tsx-voice stop|rc-update del tsx-voice default|rc-service tsx-esphome restart|" ] && ok "disable voice, was enabled: stop, leave the runlevel, restart tsx-esphome" || bad "disable voice enabled (rc $rc): $(rl)"
# an image without the Home Assistant layer (the console and kiosk profiles) has neither service
rm -f "$T/initd/tsx-voice" "$T/initd/tsx-sendspin"; : > "$T/rc.log"
au disable voice >/dev/null; rc=$?
[ $rc = 0 ] && [ ! -s "$T/rc.log" ] && ok "no tsx-voice service: disable voice is a quiet no-op (tsx-config apply runs it at every boot)" || bad "disable voice, no service (rc $rc): $(rl)"
au disable sendspin >/dev/null; [ $? = 0 ] && [ ! -s "$T/rc.log" ] && ok "no tsx-sendspin service: disable sendspin is a no-op" || bad "disable sendspin, no service: $(rl)"
au enable voice >/dev/null 2>"$T/err"; rc=$?
[ $rc != 0 ] && [ ! -s "$T/rc.log" ] && grep -q 'not in this profile' "$T/err" && ok "no tsx-voice service: enable voice says why it cannot" || bad "enable voice, no service (rc $rc): $(cat "$T/err")"
rm -f "$T/pbin/rc-service" "$T/pbin/rc-update"

echo "== tsx-bt =="
printf '#!/bin/sh\necho "tsx-bt $*" >> "%s/bt.log"\n' "$T" > "$T/sbin/tsx-bt"; chmod +x "$T/sbin/tsx-bt"
printf 'BT=no\nREASON=test\n' > "$T/run/hw.conf"; : > "$T/bt.log"
out=$(run_start tsx-bt); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q START && grep -qx 'tsx-bt up' "$T/bt.log" && ok "BT=no: tsx-bt up records the absent state, nothing else starts, no failure" || bad "BT=no (rc $rc): $out $(cat "$T/bt.log")"
rm -f "$T/run/hw.conf"; : > "$T/bt.log"
printf '#!/bin/sh\n[ "$2" = BT_PROXY ] && echo "${T_PROXY:-off}"\n' > "$T/pbin/tsx-config"
out=$(run_start tsx-bt); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "BT_PROXY is off" && [ ! -s "$T/bt.log" ] && ok "BT_PROXY off: the chip stays untouched" || bad "proxy off (rc $rc): $out"
printf '#!/bin/sh\necho "tsx-bt $*" >> "%s/bt.log"\nprintf "state=up\\nhci=hci1\\n" > "%s/run/bt.state"\n' "$T" "$T" > "$T/sbin/tsx-bt"
: > "$T/bt.log"
out=$(run_start tsx-bt T_PROXY=on); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^START /usr/bin/python3 /usr/local/lib/tsx/btscan.py --hci hci1$' && grep -qx 'tsx-bt up' "$T/bt.log" \
	&& ok "BT_PROXY on: tsx-bt up runs first, then the daemon starts on the hci device that it reports" || bad "proxy on (rc $rc): $out"
grep -q '^supervisor=supervise-daemon' "$I/tsx-bt" && grep -q '^respawn_delay=' "$I/tsx-bt" && grep -q '^respawn_max=0' "$I/tsx-bt" \
	&& ok "tsx-btscan runs under supervise-daemon with respawn, no limit" || bad "tsx-bt: no supervise-daemon respawn"
: > "$T/bt.log"; run_fn stop_post tsx-bt >/dev/null
grep -qx 'tsx-bt down' "$T/bt.log" && ok "stop: the chip goes down after the daemon" || bad "stop_post: $(cat "$T/bt.log")"

: > "$T/bt.log"
printf '#!/bin/sh\n[ "$2" = BT_PROXY ] && echo ""\n' > "$T/pbin/tsx-config"
out=$(run_start tsx-bt); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "BT_PROXY is off" && [ ! -s "$T/bt.log" ] && ok "empty BT_PROXY: the board default (off on the xx60) keeps the chip untouched" || bad "empty proxy (rc $rc): $out"
: > "$T/bt.log"; printf '#!/bin/sh\necho "tsx-bt $*" >> "%s/bt.log"\nprintf "state=up\\nhci=hci0\\n" > "%s/run/bt.state"\n' "$T" "$T" > "$T/sbin/tsx-bt"
out=$(run_start tsx-bt TSX_BT_PROXY_DEFAULT=on); rc=$?
[ $rc = 0 ] && grep -qx 'tsx-bt up' "$T/bt.log" && echo "$out" | grep -q '^START' && ok "empty BT_PROXY with the board default on: tsx-bt starts" || bad "empty proxy, default on (rc $rc): $out"

echo "== tsx-config =="
for c in tsx-hw tsx-emmc-state tsx-config; do printf '#!/bin/sh\necho "%s $*" >> "%s/cfg.log"\nexit ${T_FAIL_%s:-0}\n' "$c" "$T" "$(echo $c | tr a-z- A-Z_)" > "$T/sbin/$c"; chmod +x "$T/sbin/$c"; done
: > "$T/cfg.log"; out=$(run_start tsx-config); rc=$?
[ $rc = 0 ] && [ "$(tr '\n' '|' < "$T/cfg.log")" = "tsx-hw detect|tsx-emmc-state |tsx-config apply|" ] \
	&& ok "start runs tsx-hw detect, tsx-emmc-state and tsx-config apply, in this order" || bad "tsx-config start (rc $rc): $(tr '\n' '|' < "$T/cfg.log")"
: > "$T/cfg.log"; out=$(run_start tsx-config T_FAIL_TSX_EMMC_STATE=1 T_FAIL_TSX_HW=1 T_FAIL_TSX_CONFIG=1); rc=$?
[ $rc = 0 ] && [ "$(grep -c . "$T/cfg.log")" = 3 ] && echo "$out" | grep -q '^warn: tsx-emmc-state failed' && ok "a failing helper is a warning, never a failed boot" || bad "failing helpers (rc $rc): $out"
sed -n '/^depend()/,/^}/p' "$I/tsx-config" | grep -q 'before .*tsx-mqtt' && ok "depend: before tsx-mqtt (it reads emmc.state at start)" || bad "tsx-config depend()"

echo "== tsx-autoupdate =="
printf '#!/bin/sh\nexit 0\n' > "$T/sbin/tsx-autoupdate"; chmod +x "$T/sbin/tsx-autoupdate"
printf '0 4 * * * other job\n' > "$T/etc/crontabs/root"
out=$(run_start tsx-autoupdate HEALTH_DELAY=0 CHECK_DELAY=0); rc=$?
[ $rc = 0 ] && grep -q '# tsx-autoupdate$' "$T/etc/crontabs/root" && grep -q 'other job' "$T/etc/crontabs/root" && ok "start adds its cron line and keeps the others" || bad "cron add (rc $rc): $(cat "$T/etc/crontabs/root")"
run_start tsx-autoupdate HEALTH_DELAY=0 CHECK_DELAY=0 >/dev/null
[ "$(grep -c '# tsx-autoupdate$' "$T/etc/crontabs/root")" = 1 ] && ok "a second start keeps one line" || bad "duplicate cron line"
echo 'ENABLED=0' > "$T/etc/tsx/autoupdate.conf"
run_start tsx-autoupdate HEALTH_DELAY=0 CHECK_DELAY=0 >/dev/null
! grep -q '# tsx-autoupdate$' "$T/etc/crontabs/root" && ok "ENABLED=0 removes the line" || bad "ENABLED=0 left the line"
rm -f "$T/etc/tsx/autoupdate.conf"

echo "== supervised services =="
for s in tsx-als tsx-buttons tsx-ledbar tsx-panelctl; do
	out=$(run_fn start_pre $s); rc=$?
	[ $rc = 0 ] && echo "$out" | grep -q "checkpath -d -m 0755 $T/run" && ok "$s: start_pre makes /run/tsx" || bad "$s start_pre (rc $rc): $out"
done

echo "== eMMC state =="
E=$HERE/overlay/usr/local/sbin/tsx-emmc-state
busybox sh -n "$E" && ok "tsx-emmc-state: busybox sh -n" || bad "tsx-emmc-state syntax"
mkdir -p "$T/emmc" "$T/bin"
printf '#!/bin/sh\necho "logger $*" >> "%s/emmc.log"\n' "$T" > "$T/bin/logger"; chmod +x "$T/bin/logger"
printf '0x01 0x0b\n' > "$T/emmc/life_time"; printf '0x01\n' > "$T/emmc/pre_eol_info"
rm -rf "$T/er"; : > "$T/emmc.log"; PATH=$T/bin:$PATH TSX_EMMC_DIR=$T/emmc TSX_RUN_DIR=$T/er sh "$E"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/er/emmc.state")" = "$(printf 'life_a 0x01\nlife_b 0x0b\neol 0x01')" ] && ok "writes life_a, life_b and eol, one value per line" || bad "emmc.state (rc $rc): $(cat "$T/er/emmc.state" 2>&1)"
[ ! -s "$T/emmc.log" ] && ok "a normal eol is not logged" || bad "normal eol logged: $(cat "$T/emmc.log")"
[ -z "$(ls "$T/er" | grep tmp)" ] && ok "no temporary file is left" || bad "temporary file left"
printf '0x01\n' > "$T/emmc/pre_eol_info"; printf '0x01 0x02\n' > "$T/emmc/life_time"
printf '0x02\n' > "$T/emmc/pre_eol_info"; PATH=$T/bin:$PATH TSX_EMMC_DIR=$T/emmc TSX_RUN_DIR=$T/er sh "$E"
grep -qx 'eol 0x02' "$T/er/emmc.state" && grep -q 'logger -t tsx-emmc-state eMMC pre-EOL info 0x02' "$T/emmc.log" && ok "a warning eol is written and logged" || bad "warning eol: $(cat "$T/er/emmc.state") $(cat "$T/emmc.log")"
rm -rf "$T/er"; PATH=$T/bin:$PATH TSX_EMMC_DIR=$T/none TSX_RUN_DIR=$T/er sh "$E"; rc=$?
[ $rc = 0 ] && [ ! -e "$T/er/emmc.state" ] && ok "no eMMC wear files: no state file, no failure" || bad "no eMMC (rc $rc)"
mkdir -p "$T/emmc-empty"; PATH=$T/bin:$PATH TSX_EMMC_DIR=$T/emmc-empty TSX_RUN_DIR=$T/er sh "$E"; rc=$?
[ $rc = 0 ] && [ ! -e "$T/er/emmc.state" ] && ok "a device without the wear files: no state file" || bad "empty device (rc $rc)"
printf '0x00 0x00\n' > "$T/emmc-empty/life_time"; printf '0x00\n' > "$T/emmc-empty/pre_eol_info"
rm -rf "$T/er"; PATH=$T/bin:$PATH TSX_EMMC_DIR=$T/emmc-empty TSX_RUN_DIR=$T/er sh "$E"; rc=$?
[ $rc = 0 ] && [ ! -e "$T/er/emmc.state" ] && ok "a chip with no defined values (0x00): no state file" || bad "undefined values (rc $rc): $(cat "$T/er/emmc.state" 2>&1)"
[ -x "$HERE/overlay/etc/periodic/hourly/tsx-emmc-state" ] && busybox sh -n "$HERE/overlay/etc/periodic/hourly/tsx-emmc-state" && ok "the hourly job is executable and has valid syntax" || bad "hourly job"

echo "== weekly fstrim =="
mkdir -p "$T/bin"
cat > "$T/bin/mountpoint" <<'EOS'
#!/bin/sh
case " $MOUNTED " in *" $2 "*) exit 0;; esac
exit 1
EOS
printf '#!/bin/sh\necho "fstrim $*" >> "%s/trim.log"\n[ -z "$FSTRIM_FAIL" ] || { echo "the discard operation is not supported"; exit 1; }\necho "$2: 1 GiB trimmed"\n' "$T" > "$T/bin/fstrim"
printf '#!/bin/sh\necho "logger $*" >> "%s/trim.log"\n' "$T" > "$T/bin/logger"
chmod +x "$T/bin/"*
busybox sh -n "$HERE/overlay/etc/periodic/weekly/tsx-fstrim" && ok "busybox sh -n" || bad "syntax"
: > "$T/trim.log"; PATH=$T/bin:$PATH MOUNTED="/ /data" sh "$HERE/overlay/etc/periodic/weekly/tsx-fstrim"; rc=$?
[ $rc = 0 ] && grep -qx 'fstrim -v /' "$T/trim.log" && grep -qx 'fstrim -v /data' "$T/trim.log" && grep -q 'logger -t tsx-fstrim /data: 1 GiB trimmed' "$T/trim.log" \
	&& ok "trims / and /data and logs the result" || bad "fstrim run (rc $rc): $(cat "$T/trim.log")"
: > "$T/trim.log"; PATH=$T/bin:$PATH MOUNTED="/" sh "$HERE/overlay/etc/periodic/weekly/tsx-fstrim"
[ "$(grep -c '^fstrim' "$T/trim.log")" = 1 ] && ok "no /data mounted: only /" || bad "unmounted /data trimmed: $(cat "$T/trim.log")"
: > "$T/trim.log"; PATH=$T/bin:$PATH MOUNTED="/ /data" FSTRIM_FAIL=1 sh "$HERE/overlay/etc/periodic/weekly/tsx-fstrim"; rc=$?
[ $rc = 0 ] && grep -q 'fstrim failed: the discard operation is not supported' "$T/trim.log" && ok "a failing fstrim is logged, the script still exits 0" || bad "failing fstrim (rc $rc): $(cat "$T/trim.log")"
[ -x "$HERE/overlay/etc/periodic/weekly/tsx-fstrim" ] && ok "the script is executable (run-parts skips others)" || bad "not executable"
grep -qx util-linux-misc "$HERE/packages.txt" && ok "packages.txt: util-linux-misc (fstrim)" || bad "no util-linux-misc package"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-initscripts || echo FAIL test-initscripts
exit $F
