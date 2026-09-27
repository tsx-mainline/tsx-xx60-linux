#!/usr/bin/env python3
"""levels.py REC.wav [FREQ] [WIN_S]: per-window rms and FREQ (Goertzel) level in dBFS
of the left channel, plus a list of bursts (windows > floor + 10 dB)."""
import math, struct, sys, wave
fn = sys.argv[1]; f = float(sys.argv[2]) if len(sys.argv) > 2 else 1000.0
win_s = float(sys.argv[3]) if len(sys.argv) > 3 else 0.25
w = wave.open(fn); rate = w.getframerate(); ch = w.getnchannels(); sw = w.getsampwidth()
raw = w.readframes(w.getnframes())
fmt = {2: 'h', 4: 'i'}[sw]; full = 32768.0 if sw == 2 else 2147483648.0
x = struct.unpack('<%d%s' % (len(raw) // sw, fmt), raw)[0::ch]
n = int(win_s * rate); k = 2 * math.cos(2 * math.pi * f / rate)
rows = []
for i in range(0, len(x) - n + 1, n):
    seg = x[i:i + n]
    rms = math.sqrt(sum(v * v for v in seg) / n) / full
    s1 = s2 = 0.0
    for v in seg:
        s0 = v + k * s1 - s2; s2 = s1; s1 = s0
    p = s1 * s1 + s2 * s2 - k * s1 * s2
    a = 2 * math.sqrt(max(p, 0)) / n / full / math.sqrt(2)   # rms of the tone
    pk = max(abs(v) for v in seg) / full
    db = lambda v: 20 * math.log10(v) if v > 0 else -150
    rows.append((i / rate, db(rms), db(a), db(pk)))
for t, r, a, p in rows:
    print('%7.2f s  rms %7.1f  %gHz %7.1f  peak %7.1f dBFS' % (t, r, f, a, p))
fl = sorted(a for _, _, a, _ in rows)[len(rows) // 4]
print('# floor (25th pct) of %g Hz: %.1f dBFS' % (f, fl))
