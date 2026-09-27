#!/usr/bin/env python3
"""gentone.py FREQ DBFS SECONDS OUT.wav [both|left|right]
48 kHz S16_LE stereo sine burst with 10 ms raised-cosine fades."""
import math, struct, sys, wave
f, db, sec, out = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
ch = sys.argv[5] if len(sys.argv) > 5 else "both"
rate = 48000; n = int(rate * sec); fade = int(0.010 * rate)
amp = 32767 * 10 ** (db / 20.0)
buf = bytearray()
for i in range(n):
    g = 1.0
    if i < fade: g = 0.5 - 0.5 * math.cos(math.pi * i / fade)
    elif i >= n - fade: g = 0.5 - 0.5 * math.cos(math.pi * (n - 1 - i) / fade)
    s = int(round(amp * g * math.sin(2 * math.pi * f * i / rate)))
    l = s if ch in ("both", "left") else 0
    r = s if ch in ("both", "right") else 0
    buf += struct.pack("<hh", l, r)
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(buf))
