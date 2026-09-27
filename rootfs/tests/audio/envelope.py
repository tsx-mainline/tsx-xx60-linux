#!/usr/bin/env python3
"""envelope.py REC.wav T0 DUR [WIN_MS]: rms envelope (dBFS) of the left channel in
WIN_MS windows from T0 for DUR s, one character per window (dropout finder):
'#' within 3 dB of the median, '+' 3-10 dB below, '-' 10-20 dB below, '.' >20 dB below."""
import math, struct, sys, wave
w = wave.open(sys.argv[1]); r = w.getframerate(); ch = w.getnchannels()
raw = w.readframes(w.getnframes()); x = struct.unpack('<%dh' % (len(raw) // 2), raw)[0::ch]
t0, dur = float(sys.argv[2]), float(sys.argv[3]); win = int(r * (float(sys.argv[4]) if len(sys.argv) > 4 else 5) / 1000)
e = []
for i in range(int(t0 * r), int((t0 + dur) * r) - win, win):
    s = x[i:i + win]; v = math.sqrt(sum(a * a for a in s) / win) / 32768
    e.append(20 * math.log10(v) if v > 0 else -150)
m = sorted(e)[len(e) // 2]
out = ''.join('#' if v > m - 3 else '+' if v > m - 10 else '-' if v > m - 20 else '.' for v in e)
print('median %.1f dBFS, min %.1f, max %.1f, windows %d' % (m, min(e), max(e), len(e)))
for i in range(0, len(out), 100): print(out[i:i + 100])
