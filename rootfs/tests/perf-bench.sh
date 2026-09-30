#!/bin/bash
# Browser benchmark (host side). One CSV line per run in
# results/perf.csv, details in results/perf-CFG-N.json, chrome://gpu in
# results/perf-CFG-gpu.txt.
#
#   tests/perf-bench.sh CFG [IP]
#
# Needs KIOSK_DEVTOOLS=1 on the panel. Opens the tunnel ssh -L PORT:127.0.0.1:9222
# itself if nothing listens on PORT. Steps:
#   1. chrome://gpu (cdp.py gpu: the kiosk page goes there and back)
#   2. page load of LOAD_URL (default: the page the kiosk shows, i.e. KIOSK_URL):
#      navigation timing (TTFB, DCL, load, FCP)
#   3. page load of the synthetic dashboard cards.html (file:// on the panel,
#      no network: pure parse/style/layout/paint cost)
#   4. scroll: Input.synthesizeScrollGesture (touch) down and up SCROLL_PX at
#      SCROLL_SPEED px/s, REPEAT times, traced: DrawFrame fps, rAF fps, frames
#      presented/dropped, CPU time per Chromium process, compositor + system CPU
#   5. idle: IDLE_S seconds on cards.html?live=1 (20 value updates/s + clock):
#      system CPU %, per-process CPU
#   6. memory: measure-mem.sh (PSS per program)
#   7. back to the original page
# Env: PORT (9222), LOAD_URL, SCROLL_PX (6000), SCROLL_SPEED (1500), REPEAT (2),
#      IDLE_S (30), LOCAL=1 (validate against a local Chromium on PORT: no ssh,
#      local /proc. cards page from this directory)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOTFS_DIR=$(dirname "$HERE")
CFG=${1:?usage: perf-bench.sh CFG [IP]}; IP=${2:-${PANEL_IP:?set PANEL_IP or pass IP as arg 2}}
PORT=${PORT:-9222}; SCROLL_PX=${SCROLL_PX:-6000}; SCROLL_SPEED=${SCROLL_SPEED:-1500}
REPEAT=${REPEAT:-2}; IDLE_S=${IDLE_S:-30}; LOCAL=${LOCAL:-0}
R=${RESULTS:-$ROOTFS_DIR/results}; mkdir -p "$R"
CDP="python3 $ROOTFS_DIR/tests/cdp.py $PORT"
p() { if [ "$LOCAL" = 1 ]; then sh -c "$*"; else sshpass -p tsx ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP "$@"; fi; }
say() { echo "perf-bench[$CFG]: $*" >&2; }

if ! python3 -c "import socket,sys; socket.create_connection(('127.0.0.1',$PORT),2)" 2>/dev/null; then
	[ "$LOCAL" = 1 ] && { say "nothing on port $PORT"; exit 1; }
	say "opening tunnel 127.0.0.1:$PORT -> $IP:9222"
	sshpass -p tsx ssh -f -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		-o ExitOnForwardFailure=yes -L $PORT:127.0.0.1:9222 root@$IP || exit 1
	sleep 1
fi
if [ "$LOCAL" = 1 ]; then
	CARDS=file://$HERE/cards.html
else
	p 'mkdir -p /tmp/tsx-perf && chmod 755 /tmp/tsx-perf && cat > /tmp/tsx-perf/cards.html && chmod 644 /tmp/tsx-perf/cards.html' < "$HERE/cards.html"
	CARDS=file:///tmp/tsx-perf/cards.html
fi
# snapshot on the target: jiffies (all cpus), compositor ticks, temp, freq, governor
SNAP='set -- $(head -1 /proc/stat); echo "cpu_total $(( $2+$3+$4+$5+$6+$7+$8+$9 ))"; echo "cpu_idle $(( $5+$6 ))";
c=0; for x in $(pidof sway cage squeekboard 2>/dev/null); do set -- $(cut -d")" -f2 /proc/$x/stat); c=$((c+${12}+${13})); done; echo "comp_ticks $c";
echo "temp_mC $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)";
echo "freq_kHz $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)";
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo none)";
echo "ncpu $(grep -c ^processor /proc/cpuinfo)"'
snap() { p "$SNAP"; }

N=$(ls "$R"/perf-"$CFG"-*.json 2>/dev/null | wc -l); N=$((N + 1))
J=$R/perf-$CFG-$N.json; T=$(mktemp -d)
start=$(date +%s)
say "run $N -> $J"
p 'grep -E "^(KIOSK_GPU|KIOSK_EXTRA_FLAGS|KIOSK_DISABLE_FEATURES|KIOSK_OSK|CPUFREQ_AWAKE)=" /etc/kiosk.conf 2>/dev/null; uname -r; uptime' > "$T/conf" 2>&1
p 'grep -cE "GPU process exited unexpectedly|GPU process isn.t usable|gpu_process_host.*(crash|exit)" /var/log/kiosk.log 2>/dev/null; true' > "$T/crash0"
ORIG=$($CDP eval 'location.href' | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["value"])')
# a previous run that stopped half way may have left the kiosk on the test page
case "$ORIG" in file://*/cards.html*|chrome://*) ORIG=${LOAD_URL:-https://ha.example.org};; esac
LOAD_URL=${LOAD_URL:-$ORIG}

say "1/6 chrome://gpu"
$CDP gpu "$R/perf-$CFG-gpu.txt" >/dev/null 2>"$T/gpu.err" || say "gpu failed: $(tail -1 "$T/gpu.err")"
sleep 3
say "2/6 load $LOAD_URL"
$CDP nav "$LOAD_URL" > "$T/load.json" 2>"$T/load.err" || { say "load failed"; echo '{}' > "$T/load.json"; }
sleep 5
say "3/6 load cards.html"
$CDP nav "$CARDS" > "$T/cards.json" 2>"$T/cards.err" || echo '{}' > "$T/cards.json"
sleep 5
say "4/6 scroll ${SCROLL_PX}px x$REPEAT at ${SCROLL_SPEED}px/s"
snap > "$T/s0"
$CDP scroll --distance "$SCROLL_PX" --speed "$SCROLL_SPEED" --repeat "$REPEAT" > "$T/scroll.json" 2>"$T/scroll.err" || echo '{}' > "$T/scroll.json"
snap > "$T/s1"
say "5/6 idle ${IDLE_S}s on cards.html?live=1"
$CDP nav "$CARDS?live=1" > /dev/null 2>&1; sleep 5
snap > "$T/i0"
$CDP idle "$IDLE_S" > "$T/idle.json" 2>"$T/idle.err" || echo '{}' > "$T/idle.json"
snap > "$T/i1"
say "6/6 memory"
if [ "$LOCAL" = 1 ]; then sh "$ROOTFS_DIR/tests/measure-mem.sh" "$CFG" > "$T/mem" 2>&1; else p 'sh -s' "$CFG" < "$ROOTFS_DIR/tests/measure-mem.sh" > "$T/mem" 2>&1; fi
p 'grep -cE "GPU process exited unexpectedly|GPU process isn.t usable|gpu_process_host.*(crash|exit)" /var/log/kiosk.log 2>/dev/null; true' > "$T/crash1"
$CDP nav "$ORIG" > /dev/null 2>&1 || say "could not go back to $ORIG"

python3 - "$T" "$CFG" "$N" "$J" "$R/perf.csv" "$R/perf-$CFG-gpu.txt" "$start" <<'PY'
import json, os, re, sys, time
T, cfg, n, jpath, csv, gpu, start = sys.argv[1:8]
rd = lambda f: open(os.path.join(T, f)).read()
def js(f):
    try: return json.loads(rd(f).strip() or "{}")
    except Exception: return {}
def snap(f):
    d = {}
    for l in rd(f).splitlines():
        k, _, v = l.partition(" ")
        d[k] = v
    return d
def sysload(a, b):
    a, b = snap(a), snap(b)
    try:
        tot = int(b["cpu_total"]) - int(a["cpu_total"]); idle = int(b["cpu_idle"]) - int(a["cpu_idle"])
        return round(100 * (tot - idle) / tot, 1), round(100 * (int(b["comp_ticks"]) - int(a["comp_ticks"])) / (tot / int(a["ncpu"])), 1), a, b
    except Exception:
        return None, None, a, b
sc_sys, sc_comp, s0, s1 = sysload("s0", "s1")
id_sys, id_comp, i0, i1 = sysload("i0", "i1")
g = open(gpu).read() if os.path.exists(gpu) else ""
def gl(label):
    m = re.search(r"^" + re.escape(label) + r"[:\s]+(.*)$", g, re.M)
    return m.group(1).strip() if m else ""
mem = rd("mem")
m = re.search(r"TOTAL kiosk\s+PSS\s+([\d.]+)", mem); pss = m.group(1) if m else ""
m = re.search(r"MemAvailable:? (\d+) MiB", mem); avail = m.group(1) if m else ""
load, cards, scroll, idle = js("load.json"), js("cards.json"), js("scroll.json"), js("idle.json")
cpu = scroll.get("cpu", {})
pc = lambda d, k: d.get(k, {}).get("pct_core", "")
try: crashes = int(rd("crash1").strip()) - int(rd("crash0").strip())
except Exception: crashes = ""
conf = dict(l.split("=", 1) for l in rd("conf").splitlines() if "=" in l and l.split("=")[0].isupper())
row = {
 "date": time.strftime("%Y-%m-%d %H:%M"), "cfg": cfg, "run": n,
 "kiosk_gpu": conf.get("KIOSK_GPU", "").strip('"'), "extra_flags": conf.get("KIOSK_EXTRA_FLAGS", "").strip('"'),
 "compositing": gl("Compositing"), "rasterization": gl("Rasterization"), "gl_renderer": gl("GL_RENDERER"),
 "gpu_crash_count": gl("GPU process crash count"), "gpu_crashes_during_run": crashes,
 "load_url": load.get("url", ""), "load_fcp_ms": load.get("fcp", ""), "load_ms": load.get("load", ""), "load_wall_ms": load.get("wall_ms", ""),
 "cards_fcp_ms": cards.get("fcp", ""), "cards_load_ms": cards.get("load", ""),
 "scroll_gesture": scroll.get("gesture", ""), "scroll_draw_fps": scroll.get("draw_fps", ""), "scroll_raf_fps": scroll.get("raf_fps", ""),
 "scroll_presented_pct": scroll.get("scroll_presented_pct", ""), "scroll_dropped": scroll.get("dropped_frames", ""),
 "scroll_renderer_pct": pc(cpu, "renderer"), "scroll_gpu_pct": pc(cpu, "GPU"), "scroll_browser_pct": pc(cpu, "browser"),
 "scroll_comp_pct": sc_comp, "scroll_sys_pct": sc_sys,
 "idle_sys_pct": id_sys, "idle_comp_pct": id_comp, "idle_renderer_pct": pc(idle, "renderer"), "idle_gpu_pct": pc(idle, "GPU"),
 "kiosk_pss_mib": pss, "memavail_mib": avail,
 "temp_c": round(int(i1.get("temp_mC", 0) or 0) / 1000, 1), "governor": i1.get("governor", ""),
 "freq_mhz": int(i1.get("freq_kHz", 0) or 0) // 1000, "duration_s": int(time.time() - int(start)),
}
json.dump({"row": row, "conf": rd("conf"), "load": load, "cards": cards, "scroll": scroll, "idle": idle,
           "snap": {"s0": s0, "s1": s1, "i0": i0, "i1": i1}, "mem": mem}, open(jpath, "w"), indent=1)
new = not os.path.exists(csv)
with open(csv, "a") as f:
    if new: f.write(",".join(row) + "\n")
    f.write(",".join(str(v).replace(",", ";") for v in row.values()) + "\n")
print(",".join(f"{k}={v}" for k, v in row.items() if k in ("cfg", "compositing", "load_fcp_ms", "cards_fcp_ms", "scroll_draw_fps",
      "scroll_presented_pct", "scroll_renderer_pct", "scroll_gpu_pct", "scroll_sys_pct", "idle_sys_pct", "kiosk_pss_mib", "gpu_crashes_during_run")))
PY
rm -rf "$T"
