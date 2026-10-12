#!/bin/sh
# Host test of tsx-cpufreqd of the xx60 board (fake cpufreq sysfs and state
# file): the governor follows the screen state, a HUP reads the settings again,
# and the daemon starts no process while it waits. busybox sh.
set -eu
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); DPID=; trap '[ -z "$DPID" ] || kill "$DPID" 2>/dev/null; rm -rf "$T"' EXIT
CPUFREQD=$XX60/rootfs/overlay/usr/local/sbin/tsx-cpufreqd
mkdir -p "$T/sys/cpu0/cpufreq" "$T/sys/cpu1/cpufreq" "$T/run" "$T/cnt"
for c in cpu0 cpu1; do
	echo schedutil > "$T/sys/$c/cpufreq/scaling_governor"
	echo "ondemand performance schedutil powersave" > "$T/sys/$c/cpufreq/scaling_available_governors"
	echo 1608000 > "$T/sys/$c/cpufreq/scaling_cur_freq"
done
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
gov() { cat "$T/sys/cpu0/cpufreq/scaling_governor" "$T/sys/cpu1/cpufreq/scaling_governor" | tr '\n' ' '; }
# the processes that the daemon starts: wrappers in front of PATH write their name
: > "$T/cnt.log"
for u in sleep cat grep date head tail sed awk; do
	r=$(command -v "$u" 2>/dev/null) || continue
	printf '#!/bin/sh\necho %s >> "%s/cnt.log"\nexec "%s" "$@"\n' "$u" "$T" "$r" > "$T/cnt/$u"; chmod +x "$T/cnt/$u"
done
printf 'CPUFREQ_AWAKE=performance\nCPUFREQ_BLANK=powersave\n' > "$T/kiosk.conf"
# Some busybox builds (Debian, Ubuntu) run sleep as a built-in applet and never search PATH for it,
# so the wrapper in front of PATH cannot count it. Find out which kind this busybox is.
: > "$T/cnt.log"; PATH=$T/cnt:$PATH sh -c 'sleep 0'; [ -s "$T/cnt.log" ] && SEES_SLEEP=1 || SEES_SLEEP=
: > "$T/cnt.log"
start() {  # start [PATH-prefix]: run the daemon in the background
	PATH=${1:+$1:}$T/cnt:$PATH TSX_CPUFREQ_SYS=$T/sys TSX_IDLED_STATE=$T/state TSX_KIOSK_CONF=$T/kiosk.conf \
	TSX_PANEL_BOARD_CONF=$T/none TSX_RUN_DIR=$T/run TSX_CPUFREQ_NAP=0.2 sh "$CPUFREQD" >> "$T/log" 2>&1 &
	DPID=$!
}
waitfor() {  # waitfor "governors": up to 3 s
	i=0
	while [ $i -lt 60 ]; do [ "$(gov)" = "$1 " ] && return 0; sleep 0.05; i=$((i + 1)); done
	return 1
}
echo blank > "$T/state"; start
waitfor "powersave powersave" && ok "blank: governor powersave on both CPUs" || bad "blank: governors $(gov)"
echo "on 17" > "$T/state"
waitfor "performance performance" && ok "awake: governor performance" || bad "awake: governors $(gov)"
echo blank > "$T/state"
waitfor "powersave powersave" && ok "blank again: powersave" || bad "blank again: $(gov)"
# 10 looks at the state file (0.2 s each) start no sleep, cat, grep, date, head, tail, sed or awk
: > "$T/cnt.log"; sleep 2.2
[ ! -s "$T/cnt.log" ] && ok "the wait starts no process (2.2 s, 10 looks)" || bad "processes in the wait: $(sort "$T/cnt.log" | uniq -c | tr '\n' ' ')"
# a HUP reads the settings again and applies the governor of the state. A shell cannot trap
# a signal that was ignored when it started (a test run under nohup), so the check is skipped then.
printf 'CPUFREQ_AWAKE=performance\nCPUFREQ_BLANK=ondemand\n' > "$T/kiosk.conf"
case $(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/$$/status 2>/dev/null) in
*[13579bdf]) echo "skip HUP: SIGHUP is ignored in this environment (nohup)";;
*)
	kill -HUP "$DPID"
	waitfor "ondemand ondemand" && ok "HUP: new CPUFREQ_BLANK is applied" || bad "HUP: governors $(gov)"
	grep -q 'config reloaded' "$T/log" && ok "HUP: logged" || bad "HUP: no log line";;
esac
# TERM ends it at once
t0=$(date +%s%N); kill "$DPID"; wait "$DPID" 2>/dev/null || true; t1=$(date +%s%N); DPID=
[ $(( (t1 - t0) / 1000000 )) -lt 500 ] && ok "TERM ends the daemon in $(( (t1 - t0) / 1000000 )) ms" || bad "TERM took $(( (t1 - t0) / 1000000 )) ms"
[ -z "$(ls -A "$T/run")" ] && ok "no FIFO is left in the run folder" || bad "left in the run folder: $(ls -A "$T/run")"
# a governor that the CPU does not list is refused (and logged), not written
printf 'CPUFREQ_AWAKE=performance\nCPUFREQ_BLANK=conservative\n' > "$T/kiosk.conf"; echo blank > "$T/state"
echo schedutil > "$T/sys/cpu0/cpufreq/scaling_governor"; echo schedutil > "$T/sys/cpu1/cpufreq/scaling_governor"; : > "$T/log"
start; sleep 0.8; kill "$DPID"; wait "$DPID" 2>/dev/null || true; DPID=
[ "$(gov)" = "schedutil schedutil " ] && grep -q 'governor conservative not available' "$T/log" && ok "an unavailable governor is not written" || bad "unavailable governor: $(gov) $(cat "$T/log")"
# no mkfifo: the daemon falls back to sleep and works
printf 'CPUFREQ_AWAKE=performance\nCPUFREQ_BLANK=powersave\n' > "$T/kiosk.conf"; : > "$T/log"; echo blank > "$T/state"
mkdir -p "$T/nofifo"; printf '#!/bin/sh\nexit 1\n' > "$T/nofifo/mkfifo"; chmod +x "$T/nofifo/mkfifo"
: > "$T/cnt.log"; start "$T/nofifo"
waitfor "powersave powersave" && ok "no FIFO: the governor still follows the state" || bad "no FIFO: $(gov)"
if [ -n "$SEES_SLEEP" ]; then
	sleep 0.6; grep -q '^sleep$' "$T/cnt.log" && ok "no FIFO: sleep is the wait" || bad "no FIFO: no sleep started"
else
	echo "skip no FIFO: sleep is the wait (this busybox runs sleep as an applet, so the count cannot see it)"
fi
kill "$DPID"; wait "$DPID" 2>/dev/null || true; DPID=
[ $fail = 0 ] && echo "PASS tsx-cpufreqd" || { echo "--- log"; cat "$T/log"; exit 1; }
