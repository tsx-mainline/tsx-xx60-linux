#!/usr/bin/env python3
# Compose the full-screen boot splash for one panel size: Tux (the kernel's
# own 80x80 logo, scaled by a whole number with nearest-neighbour so the
# pixels stay sharp) above the TSX-XX60 word mark (rendered from
# tsx-xx60-mark.svg by rsvg-convert, see mksplash.sh), centred a little above
# the middle of a black screen; the lower part stays black for the status
# line and progress bar that tsx-splash draws at 70 % of the height.
#   compose.py W H TUX_SCALE MARK.png TUX.png OUT_BASENAME  -> OUT.png, OUT.ppm
import sys
from PIL import Image

w, h, scale = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
mark = Image.open(sys.argv[4]).convert('RGBA')
tux = Image.open(sys.argv[5]).convert('RGB')
out = sys.argv[6]

tux = tux.resize((tux.width * scale, tux.height * scale), Image.NEAREST)
gap = h * 45 // 1000                       # 36 px on 800 lines, 21 on 480
total = tux.height + gap + mark.height
top = h * 42 // 100 - total // 2           # group centred at 42 % of the height

img = Image.new('RGB', (w, h), (0, 0, 0))
img.paste(tux, ((w - tux.width) // 2, top))
img.paste(mark, ((w - mark.width) // 2, top + tux.height + gap), mark)
assert top + total < h * 70 // 100, 'artwork runs into the status band'
img.save(out + '.png', optimize=True)
img.save(out + '.ppm')
