#!/bin/bash
# cpufreq (WORKSTATION): run the test plan on the panel over ssh, results to
# results/. Only after the coordinator has released the panel and the
# panel runs tsxboot-cpufreq.img (TFTP). Usage: run-plan.sh [phase...]
#   phases: info vf base 1800 soak   (default; 1992 is not in the current DTS)
# Stops at the first failing phase. SOAK_MIN (default 30), PIN_MIN (default 10).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); RES=$HERE/../results; mkdir -p "$RES"
IP=${PANEL_IP:?set PANEL_IP to the panel address}
P() { sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=10 root@$IP "$@"; }
PIN_MIN=${PIN_MIN:-10} SOAK_MIN=${SOAK_MIN:-30}
P 'mkdir -p /root/cpufreq' && sshpass -p tsx scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	"$HERE/stress.sh" "$HERE/vf-check.sh" root@$IP:/root/cpufreq/ || exit 1
fetch() { sshpass -p tsx scp -O -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$IP:/root/cpufreq/stress-*" "$RES/" 2>/dev/null; }
run() { local n=$1; shift; echo "=== $n: $*"; P "$@" 2>&1 | tee "$RES/$n.txt"; local rc=${PIPESTATUS[0]}; fetch; [ $rc = 0 ] || { echo "phase $n FAILED rc=$rc"; exit $rc; }; }
for ph in ${@:-info vf base 1800 soak}; do case $ph in
	info) run 00-info 'uname -a; cat /proc/cmdline; cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null || { mount -t debugfs none /sys/kernel/debug; cat /sys/kernel/debug/regulator/regulator_summary; }; \
		cd /sys/devices/system/cpu/cpufreq/policy0 && grep . cpuinfo_* scaling_*; \
		for c in /sys/class/thermal/cooling_device*; do echo "$c $(cat $c/type) max=$(cat $c/max_state) cur=$(cat $c/cur_state)"; done; \
		for t in /sys/class/thermal/thermal_zone0/trip_point_*; do echo "$t $(cat $t)"; done; cat /sys/class/thermal/thermal_zone0/temp; \
		dmesg | grep -iE "vcck|DCDC|rn5t618|cpufreq|opp|thermal|regulator"';;
	vf)   run 01-vf-check "BOOST=1 sh /root/cpufreq/vf-check.sh";;
	base) run 02-base-1608 "sh /root/cpufreq/stress.sh -t $PIN_MIN -f 1608000";;
	1800) run 03-pin-1800 "sh /root/cpufreq/stress.sh -t $PIN_MIN -f 1800000";;
	1992) run 04-pin-1992 "sh /root/cpufreq/stress.sh -t $PIN_MIN -f 1992000";;
	soak) run 05-soak-free "BOOST=${SOAK_BOOST:-1} sh /root/cpufreq/stress.sh -t $SOAK_MIN -f free -g ${SOAK_GOV:-schedutil}";;
	*) echo "unknown phase $ph"; exit 1;; esac; done
echo "all phases passed; results in $RES"
