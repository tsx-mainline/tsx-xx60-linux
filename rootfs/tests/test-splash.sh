#!/bin/sh
# Host test for rootfs/src/tsx-splash.c (no framebuffer needed). The test
# builds it with the host compiler. It renders frames with "png -g WxH" from a
# synthetic splash dir: a PPM with a white square, and a PSF2 font whose
# glyphs are solid blocks. It checks the pixels for these cases:
#  - the image centered on black
#  - the status text where the panel shows it (70 % of the height)
#  - the fill and the track of the progress bar
#  - a smaller image, centered on a bigger screen (the fallback)
#  - no bar with -p -1
#  - a missing font (bar only)
# CC selects the compiler (default gcc).
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
expect "$W/a.png" 512 300 ffffff "image centered"
expect "$W/a.png" 505 425 9aa3ad "status text at 70 % (text centered, 2 glyphs of 8)"
expect "$W/a.png" 500 425 000000 "left of the text is black"
expect "$W/a.png" 400 445 3fa7e0 "bar: filled part"
expect "$W/a.png" 600 445 1c2329 "bar: track past 50 %"
expect "$W/a.png" 320 445 000000 "bar: 36 % wide, centered"
[ "$("$W/tsx-splash" -g 1024x600 size)" = 1024x600 ] && ok "size -g" || bad "size -g"

echo "== no bar (-p -1) =="
"$W/tsx-splash" -d "$W/d" -g 1024x600 -s AB -p -1 png "$W/b.png"
expect "$W/b.png" 400 445 000000 "no bar"

echo "== 1280x800: the 1024x600 image centered, no font-24 (bar only) =="
"$W/tsx-splash" -d "$W/d" -g 1280x800 -s AB -p 100 png "$W/c.png"
expect "$W/c.png" 640 400 ffffff "smaller image centered"
expect "$W/c.png" 127 400 000000 "outside the smaller image is black"
expect "$W/c.png" 640 565 000000 "no font: no text"
expect "$W/c.png" 869 598 3fa7e0 "bar full at 100 %"

echo "== orientation: the frame upright, turned onto the framebuffer =="
mkdir -p "$W/d2"
python3 - "$W/d2" <<'PY'
import struct, sys
d = sys.argv[1]
for w, h, cx, cy in ((1024, 600, 512, 300), (600, 1024, 300, 512)):
    px = bytearray(w * h * 3)
    for y in range(cy - 5, cy + 5):
        for x in range(cx - 5, cx + 5):
            px[(y * w + x) * 3:(y * w + x) * 3 + 3] = b'\xff\xff\xff'
    open('%s/splash-%dx%d.ppm' % (d, w, h), 'wb').write(b'P6\n%d %d\n255\n' % (w, h) + bytes(px))
for n, gw, gh in ((16, 8, 16), (24, 12, 24)):
    open('%s/font-%d.psf' % (d, n), 'wb').write(struct.pack('<8I', 0x864ab572, 0, 32, 0, 256, gh * ((gw + 7) // 8), gh, gw) + b'\xff' * gh * ((gw + 7) // 8) * 256)
PY
[ "$("$W/tsx-splash" -g 1024x600 -o portrait size)" = 600x1024 ] && ok "size: portrait frame 600x1024" || bad "size -o portrait"
echo portrait-flipped > "$W/orient"
[ "$(TSX_ORIENTATION_FILE="$W/orient" "$W/tsx-splash" -g 1280x800 size)" = 800x1280 ] && ok "orientation from TSX_ORIENTATION_FILE" || bad "orientation file not read"
echo junk > "$W/orient"
[ "$(TSX_ORIENTATION_FILE="$W/orient" "$W/tsx-splash" -g 1280x800 size)" = 1280x800 ] && ok "junk orientation file: landscape" || bad "junk orientation file"
"$W/tsx-splash" -d "$W/d2" -g 1024x600 -o portrait -s AB -p 50 png "$W/p.png"
expect "$W/p.png" 300 512 ffffff "portrait png: the 600x1024 frame, image centered"
expect "$W/p.png" 295 720 9aa3ad "portrait png: status text (24 px font) at 70 % of 1024"
expect "$W/p.png" 250 754 3fa7e0 "portrait png: bar filled"
expect "$W/p.png" 350 754 1c2329 "portrait png: bar track"
"$W/tsx-splash" -d "$W/d2" -g 1024x600 -o portrait -s AB -p 50 fbpng "$W/pf.png"
expect "$W/pf.png" 512 299 ffffff "portrait on the LCD: image (3 quarter turns clockwise)"
expect "$W/pf.png" 720 304 9aa3ad "portrait on the LCD: text"
expect "$W/pf.png" 754 349 3fa7e0 "portrait on the LCD: bar"
"$W/tsx-splash" -d "$W/d2" -g 1024x600 -o portrait-flipped -s AB -p 50 fbpng "$W/qf.png"
expect "$W/qf.png" 303 295 9aa3ad "portrait-flipped on the LCD: text (1 quarter turn)"
expect "$W/qf.png" 269 250 3fa7e0 "portrait-flipped on the LCD: bar"
"$W/tsx-splash" -d "$W/d" -g 1024x600 -o landscape-flipped -s AB -p 50 fbpng "$W/lf.png"
expect "$W/lf.png" 518 174 9aa3ad "landscape-flipped on the LCD: text (half a turn)"
expect "$W/lf.png" 623 154 3fa7e0 "landscape-flipped on the LCD: bar filled part"
"$W/tsx-splash" -d "$W/d" -g 1024x600 -o landscape -s AB -p 50 fbpng "$W/l.png"
cmp -s "$W/l.png" "$W/a.png" && ok "landscape fbpng == png (no turn)" || bad "landscape fbpng differs from png"
"$W/tsx-splash" -o sideways -g 1024x600 size 2>/dev/null && bad "-o sideways accepted" || ok "-o sideways rejected"

echo "== bad usage =="
"$W/tsx-splash" -g 0x0 png "$W/x.png" 2>/dev/null && bad "-g 0x0 accepted" || ok "-g 0x0 rejected"
"$W/tsx-splash" frobnicate 2>/dev/null && bad "unknown command accepted" || ok "unknown command rejected"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-splash || echo FAIL test-splash
exit $F
