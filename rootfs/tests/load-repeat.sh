#!/bin/bash
# Page-load repeat: N loads each of the HA dashboard and cards.html, median/min/max
# of FCP and load event (ms). Usage: load-repeat.sh CFG [N]  -> results/load-CFG.txt
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../results; CFG=$1; N=${2:-5}
CDP="python3 $HERE/../../rootfs/tests/cdp.py 9222"
URL=${LOAD_URL:-https://ha.example.org/tsx-default/0}
{
echo "### load-repeat $CFG $(date) N=$N"
for u in "$URL" file:///tmp/tsx-perf/cards.html; do
	for i in $(seq $N); do $CDP nav "$u"; sleep 4; done > /tmp/load-$$.json
	python3 - "$u" /tmp/load-$$.json <<'PY'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[2]) if l.strip().startswith("{")]
for k in ("fcp", "load", "dcl"):
    v = [r[k] for r in rows if r.get(k)]
    print(f"{sys.argv[1][:50]:50s} {k:5s} median {statistics.median(v):6.0f}  min {min(v):6.0f}  max {max(v):6.0f}  n={len(v)}  {v}")
PY
done
$CDP nav "$URL" >/dev/null
} | tee "$R/load-$CFG.txt"
rm -f /tmp/load-$$.json
