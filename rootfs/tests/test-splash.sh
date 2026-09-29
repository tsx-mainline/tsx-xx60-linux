#!/bin/sh
# Host test for rootfs/src/tsx-splash.c (no framebuffer needed): builds it
# with the host compiler, renders frames with "png -g WxH" from a synthetic
# splash dir (a PPM with a white square, a PSF2 font whose glyphs are solid
# blocks) and checks the pixels: the image centred on black, the status text
# where the panel shows it (70 % of the height), the progress bar fill and
# track, the fallback to a smaller image centred on a bigger screen, no bar
# with -p -1, and a missing font (bar only). CC (default gcc).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

${CC:-gcc} -O2 -Wall -Wextra -Werror -o "$W/tsx-splash" "$HERE/../src/tsx-splash.c"
mkdir -p "$W/d"
python3 - "$W/d" <<'PY'
import struct, sys
d = sys.argv[1]
w, h = 1024, 600
px = bytearray(w * h * 3)
for y in range(295, 305):
    for x in range(507, 517):
        px[(y * w + x) * 3:(y * w + x) * 3 + 3] = b'\xff\xff\xff'
open(d + '/splash-1024x600.ppm', 'wb').write(b'P6\n# test\n1024 600\n255\n' + bytes(px))
# PSF2, 256 glyphs of 8x16, every pixel set
open(d + '/font-16.psf', 'wb').write(struct.pack('<8I', 0x864ab572, 0, 32, 0, 256, 16, 16, 8) + b'\xff' * 16 * 256)
PY

# pixel FILE X Y -> rrggbb
pixel() {
	python3 - "$@" <<'PY'
import struct, sys, zlib
b = open(sys.argv[1], 'rb').read()
assert b[:8] == b'\x89PNG\r\n\x1a\n'
o, idat, w = 8, b'', 0
while o < len(b):
    n, t = struct.unpack('>I4s', b[o:o + 8])
    c = b[o + 8:o + 8 + n]
    assert zlib.crc32(t + c) & 0xffffffff == struct.unpack('>I', b[o + 8 + n:o + 12 + n])[0], 'crc'
    if t == b'IHDR': w, h = struct.unpack('>II', c[:8])
    if t == b'IDAT': idat += c
    o += 12 + n
raw = zlib.decompress(idat)
x, y = int(sys.argv[2]), int(sys.argv[3])
row = raw[y * (w * 3 + 1):(y + 1) * (w * 3 + 1)]
assert row[0] == 0
print(row[1 + x * 3:4 + x * 3].hex())
PY
}
expect() {  # FILE X Y RRGGBB WHAT
	got=$(pixel "$1" "$2" "$3") || { bad "$5: PNG did not decode"; return; }
	[ "$got" = "$4" ] && ok "$5" || bad "$5: ($2,$3) is $got, want $4"
}

echo "== 1024x600, image + status + 50 % =="
"$W/tsx-splash" -d "$W/d" -g 1024x600 -s AB -p 50 png "$W/a.png"
expect "$W/a.png" 0 0 000000 "background black"
expect "$W/a.png" 512 300 ffffff "image centred"
expect "$W/a.png" 505 425 9aa3ad "status text at 70 % (text centred, 2 glyphs of 8)"
expect "$W/a.png" 500 425 000000 "left of the text is black"
expect "$W/a.png" 400 445 3fa7e0 "bar: filled part"
expect "$W/a.png" 600 445 1c2329 "bar: track past 50 %"
expect "$W/a.png" 320 445 000000 "bar: 36 % wide, centred"
[ "$("$W/tsx-splash" -g 1024x600 size)" = 1024x600 ] && ok "size -g" || bad "size -g"

echo "== no bar (-p -1) =="
"$W/tsx-splash" -d "$W/d" -g 1024x600 -s AB -p -1 png "$W/b.png"
expect "$W/b.png" 400 445 000000 "no bar"

echo "== 1280x800: the 1024x600 image centred, no font-24 (bar only) =="
"$W/tsx-splash" -d "$W/d" -g 1280x800 -s AB -p 100 png "$W/c.png"
expect "$W/c.png" 640 400 ffffff "smaller image centred"
expect "$W/c.png" 127 400 000000 "outside the smaller image is black"
expect "$W/c.png" 640 565 000000 "no font: no text"
expect "$W/c.png" 869 598 3fa7e0 "bar full at 100 %"

echo "== bad usage =="
"$W/tsx-splash" -g 0x0 png "$W/x.png" 2>/dev/null && bad "-g 0x0 accepted" || ok "-g 0x0 rejected"
"$W/tsx-splash" frobnicate 2>/dev/null && bad "unknown command accepted" || ok "unknown command rejected"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-splash || echo FAIL test-splash
exit $F
