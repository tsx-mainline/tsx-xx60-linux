#!/bin/bash
# browser hardware matrix: one configuration.
#   matrix-run.sh CFG KIOSK_GPU 'EXTRA_FLAGS' 'DISABLE_FEATURES' CPUFREQ_AWAKE [IP]
# Sets the four kiosk.conf values on the panel (backup kiosk.conf.pre-matrix
# once), restarts the kiosk (and reloads tsx-cpufreq), waits for the page,
# then: kiosk.log head, chrome://gpu + benchmark (perf-bench.sh), grim
# screenshot of the dashboard and of cards.html, OSK check, and after
# 5 minutes of running the GPU-process crash count (chrome://gpu + log).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../results
CFG=$1 GPU=$2 EXTRA=$3 FEAT=$4 GOV=$5 IP=${6:-${PANEL_IP:?set PANEL_IP or pass IP as arg 6}}
p() { sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP "$@"; }
CDP="python3 $HERE/../../rootfs/tests/cdp.py 9222"
shot() { p 'su -s /bin/sh kiosk -c "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(ls /run/user/1000 | grep -m1 "^wayland-[0-9]*$") grim -"' > "$R/perf-$CFG-$1.png"; }
L=$R/perf-$CFG-log.txt
t0=$(date +%s)
echo "=== $CFG: KIOSK_GPU=$GPU EXTRA='$EXTRA' FEAT='$FEAT' CPUFREQ_AWAKE=$GOV $(date)" | tee "$L"
p "[ -f /etc/kiosk.conf.pre-matrix ] || cp /etc/kiosk.conf /etc/kiosk.conf.pre-matrix
sed -i -e 's|^KIOSK_GPU=.*|KIOSK_GPU=$GPU|' -e 's|^KIOSK_EXTRA_FLAGS=.*|KIOSK_EXTRA_FLAGS=\"$EXTRA\"|' \
  -e 's|^KIOSK_DISABLE_FEATURES=.*|KIOSK_DISABLE_FEATURES=\"$FEAT\"|' -e 's|^CPUFREQ_AWAKE=.*|CPUFREQ_AWAKE=$GOV|' /etc/kiosk.conf
grep -E '^(KIOSK_GPU|KIOSK_EXTRA_FLAGS|KIOSK_DISABLE_FEATURES|CPUFREQ_AWAKE)=' /etc/kiosk.conf
rc-service tsx-cpufreq restart >/dev/null 2>&1; [ '$GOV' = off ] && for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo schedutil > \$g; done
echo '--- kiosk restart' \$(date +%T) >> /var/log/kiosk.log
rc-service kiosk restart >/dev/null 2>&1; echo restarted" | tee -a "$L"
# wait for DevTools + a loaded page
for i in $(seq 90); do
	s=$($CDP eval 'document.readyState' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["value"])' 2>/dev/null)
	[ "$s" = complete ] && break; sleep 2
done
sleep 20
echo "page ready after $(( $(date +%s) - t0 )) s" | tee -a "$L"
LAST='awk "/--- kiosk restart/{n=NR} {l[NR]=\$0} END{for(i=n;i<=NR;i++) print l[i]}" /var/log/kiosk.log'
p "$LAST | grep -vE 'dbus|Gtk|squeekboard' | head -40; ps -o pid,args | grep -c '[c]hromium/chromium'" >> "$L"
shot dashboard
"$HERE/perf-bench.sh" "$CFG" "$IP" 2>&1 | tail -2 | tee -a "$L"
python3 $HERE/../../rootfs/tests/cdp.py 9222 nav file:///tmp/tsx-perf/cards.html >/dev/null 2>&1; sleep 3; shot cards
"$HERE/osk-check.sh" "$CFG" "$IP" >/dev/null 2>&1; tail -4 "$R/perf-$CFG-osk.txt" | tee -a "$L"
el=$(( $(date +%s) - t0 )); [ $el -lt 300 ] && sleep $((300 - el))
echo "--- after $(( $(date +%s) - t0 )) s:" | tee -a "$L"
$CDP gpu "$R/perf-$CFG-gpu-5min.txt" >/dev/null 2>&1
grep -E "^(Compositing|Rasterization|OpenGL|GPU process crash count|GL_RENDERER|GL_VERSION|GL implementation parts)" "$R/perf-$CFG-gpu-5min.txt" | tee -a "$L"
p "ls -la /var/log/kiosk.log; $LAST | grep -ciE 'GPU process (exited|isn)'; $LAST | grep -E '^\[.*(ERROR|FATAL)' | sed 's/^\[[^]]*\]//' | sort | uniq -c | sort -rn | head -15" | tee -a "$L"
# real output vs Chromium's own frame: alpha-0 pixels = nothing drawn (shows black on the panel)
python3 $HERE/../../rootfs/tests/cdp.py 9222 shot "$R/perf-$CFG-cdp.png" >/dev/null 2>&1; shot grim-final
python3 - "$R/perf-$CFG-grim-final.png" "$R/perf-$CFG-cdp.png" "$R/perf-$CFG-cards.png" <<'PY' | tee -a "$L"
import sys
from PIL import Image
for f in sys.argv[1:]:
    try:
        im = Image.open(f).convert("RGBA"); a = im.getchannel("A").histogram()
        n = im.size[0] * im.size[1]; print(f"{f.rsplit('/',1)[1]}: transparent {100*a[0]/n:.1f} %, extrema {im.convert('RGB').getextrema()}")
    except Exception as e: print(f, e)
PY
