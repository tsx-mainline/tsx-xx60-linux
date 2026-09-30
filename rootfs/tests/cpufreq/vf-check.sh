#!/bin/sh
# cpufreq (ON THE PANEL): step the CPU through OPPs, check that VCCK follows AND
# that the real CPU clock (clk-msr a9_clk_div16 x 16) matches the requested rate.
# performance governor + scaling_max_freq pins each step. The tsx DT has no
# 1800 MHz OPP any more (removed, not stable). The default list is every OPP
# of the tsx DT (192 and 96 MHz: sys_pll OD, docs/kernel.md "CPU frequency").
# With a test DT that enables it: 1800 MHz is a boost
# OPP: enable with BOOST=1 (echo 1 > .../cpufreq/boost), always reset to 0 at the end.
# Usage: [BOOST=1] vf-check.sh [kHz ...]   Ends at 1608 MHz max, previous governor.
# WARNING: boost is not stable under real load (docs/hardware.md). On 7.2 a
# boost 1 -> 0 leaves cpuinfo_max_freq at 1800000, only scaling_max_freq
# (1608000, written first below) caps it: reboot after a BOOST=1 run.
# The PMIC setpoint itself: i2cget -f -y 0 0x32 0x36 (DCDC1, 600 mV + n x 12.5 mV).
CF=/sys/devices/system/cpu/cpufreq/policy0 B=/sys/devices/system/cpu/cpufreq/boost
M=/sys/kernel/debug/meson-clk-msr/measure_summary
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
VREG=; for r in /sys/class/regulator/regulator.*; do [ "$(cat $r/name)" = vcck ] && VREG=$r; done
[ -n "$VREG" ] || { echo "no vcck regulator"; exit 1; }
expv() { case $1 in 96000|192000|312000|408000|504000) echo 825000;; 600000|720000) echo 850000;;
	816000) echo 875000;; 1008000) echo 925000;; 1200000) echo 975000;; 1416000) echo 1025000;;
	1608000) echo 1100000;; 1800000) echo 1125000;; 1992000) echo 1150000;; *) echo 0;; esac; }
msr() { awk '$1=="a9_clk_div16"{printf "%d", $2*16/1000}' $M; }   # kHz
echo "boost=$(cat $B 2>/dev/null) cpuinfo_max_freq=$(cat $CF/cpuinfo_max_freq) latency=$(cat $CF/cpuinfo_transition_latency) ns"
echo "available: $(cat $CF/scaling_available_frequencies) boost: $(cat $CF/scaling_boost_frequencies 2>/dev/null)"
echo "regulator: $(cat $VREG/name) uV=$(cat $VREG/microvolts) users=$(cat $VREG/num_users)"
G=$(cat $CF/scaling_governor); echo performance > $CF/scaling_governor
[ "${BOOST:-0}" = 1 ] && echo 1 > $B
bad=0
for f in ${*:-1608000 1416000 1200000 1008000 816000 720000 600000 504000 408000 312000 192000 96000 1608000}; do
	echo $f > $CF/scaling_max_freq; sleep 1
	c=$(cat $CF/scaling_cur_freq); v=$(cat $VREG/microvolts); e=$(expv $c); m=$(msr)
	d=$((m - c)); [ $d -lt 0 ] && d=$((-d))
	[ "$c" = "$f" ] && [ "$v" = "$e" ] && [ $d -lt 2000 ] && r=OK || { r=BAD; bad=$((bad+1)); }
	echo "set $f cur $c measured ${m} kHz vcck $v expected $e $r temp $(cat /sys/class/thermal/thermal_zone0/temp)"
done
echo 1608000 > $CF/scaling_max_freq; echo 0 > $B 2>/dev/null; echo $G > $CF/scaling_governor
echo "bad=$bad"; [ $bad = 0 ]
