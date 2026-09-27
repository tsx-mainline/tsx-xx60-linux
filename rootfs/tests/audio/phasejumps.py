#!/usr/bin/env python3
"""phasejumps.py REC.wav T0 T1 [FREQ]: 1 ms blocks, report 1 kHz phase jumps > 0.3 rad
(sample slips / dropouts) between T0 and T1 in the left channel."""
import math, struct, sys, wave
w = wave.open(sys.argv[1]); r = w.getframerate(); raw = w.readframes(w.getnframes())
x = struct.unpack('<%dh' % (len(raw) // 2), raw)[0::w.getnchannels()]
f = float(sys.argv[4]) if len(sys.argv) > 4 else 1000.0; N = r // 1000; prev = None; j = []
for b in range(int(float(sys.argv[2]) * r) // N, int(float(sys.argv[3]) * r) // N):
    s = x[b * N:(b + 1) * N]
    c = sum(v * math.cos(2 * math.pi * f * (b * N + i) / r) for i, v in enumerate(s))
    d = sum(v * math.sin(2 * math.pi * f * (b * N + i) / r) for i, v in enumerate(s))
    ph = math.atan2(d, c)
    if prev is not None:
        dp = (ph - prev + math.pi) % (2 * math.pi) - math.pi
        if abs(dp) > 0.3: j.append('%.3f' % (b * N / r))
    prev = ph
print(len(j), 'phase jumps:', ' '.join(j[:30]))
