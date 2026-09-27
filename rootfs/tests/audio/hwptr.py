#!/usr/bin/env python3
# hwptr.py SECONDS: sample /proc/asound/TSW1060/pcm0p/sub0/status as fast as possible,
# print state changes and hw_ptr steps that are not small forward steps
import sys, time
end = time.time() + float(sys.argv[1]); last = None; n = 0; rows = []
while time.time() < end:
    try: s = open('/proc/asound/TSW1060/pcm0p/sub0/status').read()
    except OSError: continue
    d = dict((k.strip(), v) for k, v in (l.split(':', 1) for l in s.splitlines() if ':' in l))
    st = d.get('state', ' closed').strip(); hw = int(d.get('hw_ptr', '0').strip() or 0); ap = int(d.get('appl_ptr', '0').strip() or 0)
    t = time.monotonic(); n += 1
    rows.append((t, st, hw, ap))
t0 = rows[0][0]; prev = None
for t, st, hw, ap in rows:
    if prev and (st != prev[1] or hw - prev[2] > 1200 or hw < prev[2]):
        print('%8.4f %-9s hw %8d (+%d) appl %8d avail %d' % (t - t0, st, hw, hw - prev[2], ap, ap - hw))
    prev = (t, st, hw, ap)
print('samples', n, 'first/last', rows[0][1:], rows[-1][1:])
good = [(t, hw) for t, st, hw, ap in rows if st == 'RUNNING']
if len(good) > 2: print('mean rate %.1f frames/s' % ((good[-1][1] - good[0][1]) / (good[-1][0] - good[0][0])))
