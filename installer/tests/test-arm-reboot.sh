#!/bin/bash
# Host test of the arm step's reboot on stock Android (installer/android/tsx-lib.sh
# tsx_reboot_detached) and of the host's "did it go down" check
# (installer/lib/tsx-rescue.sh android_went_down). Nothing is rebooted:
# TSX_REBOOT_CMD=false stands in for `busybox reboot -f` and TSX_SYSRQ_DIR is
# a scratch dir. Needs busybox (setsid, sh, sleep, date, cut, sync).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # installer
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
BB=$(command -v busybox) || { echo "SKIPPED: no busybox"; exit 0; }
mkdir -p "$W/proc/sys/kernel"

wait_for() {  # wait_for FILE PATTERN SECONDS
	local i=0; while [ $i -lt $(($3 * 10)) ]; do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; i=$((i + 1)); done; return 1
}

echo "== 1. tsx_reboot_detached: the job outlives a killed ssh session (process group SIGKILLed)"
# the 'session': its own process group. It arms the reboot, then the whole
# group is killed, as a session teardown that kills every process of the
# session's group would do
setsid bash -c "BB=$BB TSX_REBOOT_CMD=false TSX_SYSRQ_DIR=$W/proc; . '$HERE/android/tsx-lib.sh'; tsx_reboot_detached '$W/trace' 1; echo \$\$ > '$W/sess.pid'; sleep 30" &
wait_for "$W/sess.pid" . 5 || bad "the session never started"
kill -9 -- "-$(cat "$W/sess.pid")" 2>/dev/null
wait 2>/dev/null
wait_for "$W/trace" "sysrq b written" 15 && ok "the job ran to the end after its session died" || bad "the job did not finish: $(cat "$W/trace" 2>/dev/null)"
grep -q "arming a detached reboot in 1s (setsid: $BB setsid" "$W/trace" && ok "detached with busybox setsid" || bad "no setsid: $(head -1 "$W/trace")"
grep -q "running: false" "$W/trace" && grep -q "false returned rc=1 (still up)" "$W/trace" && ok "the reboot command and its failure are traced" || bad "trace: $(cat "$W/trace")"
[ "$(cat "$W/proc/sys/kernel/sysrq")" = 1 ] && [ "$(cat "$W/proc/sysrq-trigger")" = b ] && ok "falls back to sysrq b" || bad "no sysrq fallback"
sess=$(cat "$W/sess.pid"); jobsid=$(sed -n 's/.*reboot job pid [0-9]*, sid \([0-9]*\):.*/\1/p' "$W/trace")
[ -n "$jobsid" ] && [ "$jobsid" != "$sess" ] && ok "the job runs in its own session (sid $jobsid, not $sess)" || bad "job sid '$jobsid'"

echo "== 2. tsx_reboot_detached returns at once"
t0=$(date +%s%N)
BB=$BB TSX_REBOOT_CMD=true TSX_SYSRQ_DIR=$W/proc bash -c ". '$HERE/android/tsx-lib.sh'; tsx_reboot_detached '$W/trace2' 2"
dt=$(( ($(date +%s%N) - t0) / 1000000 ))
[ "$dt" -lt 1500 ] && ok "returned after ${dt} ms" || bad "took ${dt} ms"
wait_for "$W/trace2" "sysrq b written" 15 && ok "second job finished too" || bad "trace2: $(cat "$W/trace2" 2>/dev/null)"

echo "== 3. android_went_down (host)"
. "$HERE/lib/tsx-rescue.sh"
is_crestron_sshd() { return 0; }   # Android never goes away
TSX_POLL_S=1 android_went_down 10.0.0.1 2 && bad "reported down while Crestron sshd still answers" || ok "still up after 2 s: false"
n=0; is_crestron_sshd() { n=$((n + 1)); [ $n -lt 3 ]; }   # gone on the third probe
TSX_POLL_S=0 android_went_down 10.0.0.1 30 && ok "goes down: true" || bad "missed the reboot"

echo "== 4. the arm step and the driver use them"
grep -q 'tsx_reboot_detached "$BK/reboot.trace" 3' "$HERE/steps/tsx-rescue-arm.sh" && ok "tsx-rescue-arm.sh reboots through tsx_reboot_detached" || bad "arm step does not use it"
grep -q 'android_went_down "$PANEL" 90' "$HERE/tsx-install-mainline" && ok "tsx-install-mainline checks that Android went down" || bad "driver does not check"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-arm-reboot || echo FAIL test-arm-reboot
exit $F
