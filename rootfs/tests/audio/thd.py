#!/usr/bin/env python3
"""thd.py REC.wav T0 [T0...]: for 0.5 s windows starting at T0+0.3 s, print the
1 kHz level and the 2nd..5th harmonic levels (dB relative to 1 kHz) of the left channel."""
import math, struct, sys, wave
w = wave.open(sys.argv[1]); rate = w.getframerate(); ch = w.getnchannels()
raw = w.readframes(w.getnframes()); x = struct.unpack('<%dh' % (len(raw) // 2), raw)[0::ch]
def g(seg, f):
    k = 2 * math.cos(2 * math.pi * f / rate); s1 = s2 = 0.0
    for v in seg:
        s0 = v + k * s1 - s2; s2 = s1; s1 = s0
    return 2 * math.sqrt(max(s1 * s1 + s2 * s2 - k * s1 * s2, 1e-9)) / len(seg) / 32768 / math.sqrt(2)
for t0 in map(float, sys.argv[2:]):
    i = int((t0 + 0.3) * rate); seg = x[i:i + rate // 2]
    a = [g(seg, 1000 * h) for h in range(1, 6)]
    thd = math.sqrt(sum(v * v for v in a[1:])) / a[0]
    pk = max(abs(v) for v in seg) / 32768
    print('t=%5.2f  1k %6.1f dBFS  peak %6.1f  H2..H5 %s dBc  THD %.2f %%' % (t0, 20 * math.log10(a[0]), 20 * math.log10(pk),
          ' '.join('%6.1f' % (20 * math.log10(v / a[0])) for v in a[1:]), 100 * thd))
