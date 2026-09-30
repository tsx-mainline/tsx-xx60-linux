#!/usr/bin/env python3
# Test pattern for the TSW-1060 simple-framebuffer (1280x800, r8g8b8 = bytes B,G,R in memory).
# Writes pattern.raw (for /dev/fb0) and pattern.png (what the panel should look like).
# Top 2/3: 8 color bars (white yellow cyan green magenta red blue black).
# Bottom 1/3: 4 ramps (red, green, blue, gray), dark on the left.
# Red square top-left, green top-right, blue bottom-left, white bottom-right. 2 px white border.
import struct, zlib
W, H = 1280, 800
bars = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(0,0,0)]
def px(x, y):
    if x < 2 or y < 2 or x >= W-2 or y >= H-2: return (255,255,255)
    if x < 80 and y < 80: return (255,0,0)
    if x >= W-80 and y < 80: return (0,255,0)
    if x < 80 and y >= H-80: return (0,0,255)
    if x >= W-80 and y >= H-80: return (255,255,255)
    if y < H*2//3: return bars[x*8//W]
    band = (y - H*2//3) * 4 // (H - H*2//3); v = x*255//(W-1)
    return [(v,0,0),(0,v,0),(0,0,v),(v,v,v)][band]
rows = [[px(x, y) for x in range(W)] for y in range(H)]
with open('pattern.raw', 'wb') as f:
    for r in rows: f.write(bytes(c for p in r for c in (p[2], p[1], p[0])))
raw = b''.join(b'\0' + bytes(c for p in r for c in p) for r in rows)
chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
open('pattern.png', 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
