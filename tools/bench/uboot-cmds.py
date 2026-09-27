#!/usr/bin/env python3
"""List the U-Boot command table of a decompressed Amlogic U-Boot image.
Usage: uboot-cmds.py u-boot-decompressed.bin [base=0x10000000]
Decompress first: the image in mmcblk0's first MiB has a UCL stream at 0x8000
(tools/ucl/uclpack -d, built from the vendor U-Boot source (tools/ucl))."""
import struct, sys
d = open(sys.argv[1], 'rb').read()
base = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x10000000
n = len(d)
def s(p):
    o = p - base
    if not 0 <= o < n: return None
    e = d.find(b'\0', o)
    if e < 0 or e - o > 400: return None
    t = d[o:e]
    try: t = t.decode()
    except: return None
    return t if t and all(32 <= ord(c) < 127 or c in '\n\t' for c in t) else None
out = {}
for off in range(0, n - 28, 4):
    w = struct.unpack_from('<7I', d, off)
    name = s(w[0])
    if not name or ' ' in name or len(name) > 20: continue
    if not (0 < w[1] <= 64 and w[2] in (0, 1)): continue
    if not (base <= w[3] < base + n): continue
    usage = s(w[4])
    if usage is None: continue
    out.setdefault(name, usage.strip().split('\n')[0])
for k in sorted(out): print(f"{k:14s} {out[k]}")
