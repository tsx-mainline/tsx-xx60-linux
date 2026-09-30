#!/bin/sh
# cpufreq (ON THE PANEL): CPU stress + DVFS/thermal logger + silent-corruption check.
# The tsx DT no longer has the 1800 MHz boost OPP. The 1800 notes below apply
# only to a test DT that enables it again.
# WARNING: 1800 MHz (boost) passed constant load here but panicked the kernel
# under the bursty kiosk load (docs/hardware.md). On the 7.2 kernel, boost
# 1 -> 0 leaves cpuinfo_max_freq at 1800000 (docs/kernel.md "CPU frequency"):
# restore() writes scaling_max_freq=1608000 BEFORE boost 0 for that reason.
# Reboot after a boost run to reset the kernel's limit fully.
# busybox-only. Usage:
#   stress.sh -t MINUTES -f FREQ_KHZ|free [-g GOVERNOR] [-w WORKERS] [-o OUTDIR] [-n]
#     -f 1800000 : governor performance, scaling_max_freq=1800000 (pins 1.8 GHz.
#                  The userspace governor is a module and the rootfs has no modules)
#     -f free    : leave the governor alone (or set -g), scaling_max_freq=cpuinfo_max
#     1800000 (a boost OPP) turns boost on for the run. BOOST=1 with -f free
#     -a         : keep the screen awake (tsx-blank off whenever tsx-idled blanks)
#     -s         : stop the tsx-cpufreq service for the run (it rewrites the
#                  governor on blank/wake), restart it at the end
#     -n         : no load (log only, e.g. kiosk soak with its own load)
# Every 5 s one CSV line: time, cpu0 cur freq, vcck uV, expected uV for that
# freq, SoC temp, cpufreq cooling cur_state, verified/failed hash counts, load.
# Abort (exit 2, max freq restored to 1608000): hash mismatch, Oops/BUG in
# dmesg, temperature >= ABORT_TEMP (default 85000 = 5 C above the meson8 80 C
# passive trip, i.e. throttling not holding) for
# 3 consecutive samples, vcck != expected for 3 consecutive samples.
set -u
MIN=10 FREQ=free GOV= WORKERS=4 OUT=/root/cpufreq NOLOAD=0 AWAKE=0 STOPSVC=0
ABORT_TEMP=${ABORT_TEMP:-85000} SAFE_MAX=1608000
while getopts t:f:g:w:o:nas o; do case $o in
	a) AWAKE=1;; s) STOPSVC=1;;
	t) MIN=$OPTARG;; f) FREQ=$OPTARG;; g) GOV=$OPTARG;; w) WORKERS=$OPTARG;;
	o) OUT=$OPTARG;; n) NOLOAD=1;; *) exit 1;; esac; done
CF=/sys/devices/system/cpu/cpufreq/policy0 B=/sys/devices/system/cpu/cpufreq/boost
M=/sys/kernel/debug/meson-clk-msr/measure_summary
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
msr() { awk '$1=="a9_clk_div16"{printf "%d", $2*16/1000}' $M 2>/dev/null; }   # real CPU kHz
REF=5af7b95208fdcff454bab3f5eddf567a688a3796c703d4fef91072e38645c062  # seq 1 200000 | sha256sum
TAG=$(date +%Y%m%d-%H%M%S)-$FREQ; mkdir -p "$OUT"; LOG=$OUT/stress-$TAG.csv; EV=$OUT/stress-$TAG.events
RUN=/tmp/p11-$$; mkdir -p $RUN
ev() { echo "$(date +%T) $*" | tee -a "$EV"; }

# vcck regulator + cooling device + thermal zone
VREG=; for r in /sys/class/regulator/regulator.*; do [ "$(cat $r/name 2>/dev/null)" = vcck ] && VREG=$r; done
[ -n "$VREG" ] || ev "WARNING: no regulator named vcck (DTS not applied?)"
CDEV=; for c in /sys/class/thermal/cooling_device*; do case $(cat $c/type) in cpufreq*) CDEV=$c;; esac; done
TZ=/sys/class/thermal/thermal_zone0
# OPP table (kHz -> uV), meson8.dtsi
expv() { case $1 in 96000|192000|312000|408000|504000) echo 825000;; 600000|720000) echo 850000;;
	816000) echo 875000;; 1008000) echo 925000;; 1200000) echo 975000;; 1416000) echo 1025000;;
	1608000) echo 1100000;; 1800000) echo 1125000;; 1992000) echo 1150000;; *) echo 0;; esac; }

OLDGOV=$(cat $CF/scaling_governor) OLDMAX=$(cat $CF/scaling_max_freq)
restore() { echo $SAFE_MAX > $CF/scaling_max_freq; echo 0 > $B 2>/dev/null; echo "$OLDGOV" > $CF/scaling_governor 2>/dev/null
	[ "$OLDMAX" -le $SAFE_MAX ] 2>/dev/null && echo $OLDMAX > $CF/scaling_max_freq
	[ $STOPSVC = 1 ] && rc-service tsx-cpufreq start >/dev/null 2>&1; }
cleanup() { touch $RUN/stop; kill $(cat $RUN/pids 2>/dev/null) 2>/dev/null; wait 2>/dev/null; }
trap 'cleanup; restore; ev "interrupted"; exit 3' INT TERM

ev "start: $MIN min, freq=$FREQ gov=${GOV:-unchanged} workers=$WORKERS noload=$NOLOAD kernel=$(uname -r)"
ev "vcck=$VREG cdev=$CDEV ($(cat $CDEV/max_state 2>/dev/null) states) trips: $(cat $TZ/trip_point_*_temp | tr '\n' ' ')"
ev "available: $(cat $CF/scaling_available_frequencies) max=$(cat $CF/cpuinfo_max_freq)"
[ $STOPSVC = 1 ] && { rc-service tsx-cpufreq stop >/dev/null 2>&1; ev "tsx-cpufreq stopped for the run"; }
# reference hash at the safe frequency first
echo $SAFE_MAX > $CF/scaling_max_freq
h=$(seq 1 200000 | sha256sum | cut -d' ' -f1)
[ "$h" = "$REF" ] || { ev "ABORT: reference hash at 1608 MHz wrong: $h"; restore; exit 2; }
if [ "$FREQ" = free ]; then
	[ -n "$GOV" ] && echo "$GOV" > $CF/scaling_governor
	[ "${BOOST:-0}" = 1 ] && { echo 1 > $B; ev "boost enabled"; }
	cat $CF/cpuinfo_max_freq > $CF/scaling_max_freq
else
	[ "$FREQ" -gt "$(cat $CF/cpuinfo_max_freq)" ] && { echo 1 > $B; ev "boost enabled for $FREQ"; }
	echo performance > $CF/scaling_governor; echo "$FREQ" > $CF/scaling_max_freq
fi
ev "set: governor=$(cat $CF/scaling_governor) max=$(cat $CF/scaling_max_freq) cur=$(cat $CF/scaling_cur_freq) vcck=$(cat $VREG/microvolts 2>/dev/null)"

: > $RUN/pids
if [ $NOLOAD = 0 ]; then
	i=0; while [ $i -lt $WORKERS ]; do
		( n=0; while [ ! -e $RUN/stop ]; do
			h=$(seq 1 200000 | sha256sum | cut -d' ' -f1)
			if [ "$h" = "$REF" ]; then n=$((n+1)); echo $n > $RUN/ok.$i
			else echo "$(date +%T) worker $i: $h" >> $RUN/bad; fi
		  done ) &
		echo $! >> $RUN/pids
		command -v taskset >/dev/null && taskset -p -c $i $! >/dev/null 2>&1
		i=$((i+1)); done
fi
DM0=$(dmesg | wc -l)
echo "time,elapsed_s,cur_khz,msr_khz,vcck_uv,exp_uv,temp_mc,cdev_state,hash_ok,hash_bad,load1" > "$LOG"
END=$(( $(date +%s) + MIN*60 )) T0=$(date +%s) hot=0 vbad=0 rc=0
while [ $(date +%s) -lt $END ]; do
	sleep 5
	[ $AWAKE = 1 ] && case $(cat /run/tsx-idled.state 2>/dev/null) in blank*) tsx-blank off; ev "screen woken";; esac
	f=$(cat $CF/scaling_cur_freq); v=$(cat $VREG/microvolts 2>/dev/null || echo 0); f2=$(cat $CF/scaling_cur_freq); e=$(expv $f)
	t=$(cat $TZ/temp); s=$(cat $CDEV/cur_state 2>/dev/null || echo -)
	ok=0; for x in $RUN/ok.*; do [ -e "$x" ] && ok=$((ok + $(cat $x))); done
	bad=0; [ -e $RUN/bad ] && bad=$(wc -l < $RUN/bad)
	echo "$(date +%T),$(( $(date +%s) - T0 )),$f,$(msr),$v,$e,$t,$s,$ok,$bad,$(cut -d' ' -f1 /proc/loadavg)" >> "$LOG"
	[ "$bad" -gt 0 ] && { ev "ABORT: hash mismatch"; cat $RUN/bad | tee -a "$EV"; rc=2; break; }
	if dmesg | tail -n +$((DM0+1)) | grep -Eq 'Oops|BUG:|Internal error|Unable to handle|undefined instruction|rcu.*stall|soft lockup'; then
		ev "ABORT: kernel error"; dmesg | tail -n +$((DM0+1)) | tee -a "$EV"; rc=2; break; fi
	[ "$t" -ge "$ABORT_TEMP" ] && hot=$((hot+1)) || hot=0
	[ $hot -ge 3 ] && { ev "ABORT: temp $t >= $ABORT_TEMP for 15 s"; rc=2; break; }
	# compare only stable samples (same freq before and after the voltage read)
	if [ -n "$VREG" ] && [ "$f" = "$f2" ]; then [ "$v" != "$e" ] && vbad=$((vbad+1)) || vbad=0; fi
	[ $vbad -ge 3 ] && { ev "ABORT: vcck $v != expected $e at $f kHz"; rc=2; break; }
done
cleanup
ev "new dmesg lines:"; dmesg | tail -n +$((DM0+1)) >> "$EV"
ev "time_in_state:"; cat $CF/stats/time_in_state >> "$EV" 2>/dev/null
[ $rc = 0 ] || { restore; ev "RESULT: FAIL (max restored to $SAFE_MAX)"; rm -rf $RUN; exit $rc; }
restore
ev "RESULT: PASS, $(tail -1 "$LOG")"; ev "csv: $LOG"
awk -F, 'NR>1{if($7>m)m=$7; s+=$7; n++; if($8!=0&&$8!="-")th++} END{printf "temp max %.1f C avg %.1f C, samples throttled %d/%d\n", m/1000, s/n/1000, th, n}' "$LOG" | tee -a "$EV"
rm -rf $RUN
