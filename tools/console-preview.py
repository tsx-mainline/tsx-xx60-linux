#!/usr/bin/env python3
"""console-preview.py: render text the way the Linux framebuffer console draws it.

Reads a kernel bitmap font straight from the kernel source (lib/fonts/font_*.c),
or a PSF console font file (PSF1 or PSF2, optionally gzipped, e.g. Alpine's
font-terminus /usr/share/consolefonts/ter-132b.psf.gz, what tsx-confont loads
with setfont), and draws the text gray-on-black, one glyph per character cell,
into a PNG. A PSF font's Unicode table is used to map characters to glyphs,
like the console does after setfont.

  console-preview.py KERNEL_DIR FONT OUT.png [TEXTFILE]    (text from stdin if no file)
  console-preview.py FONT.psf[.gz] OUT.png [TEXTFILE]
  FONT: 8x16 (the default VGA font), ter16x32, ter10x18, sun12x22, 10x18, ...
  --screen WxH (first argument): draw on a canvas of the LCD size (text top-left,
  like the panel shows it) and report the console size in cells.

Example (the rescue banner, as the rescue screen prints it):
  sh -c "$(sed -n '/^splash() {/,/^}/p' rootfs/initramfs/overlay/usr/sbin/tsx-rescue-status); splash" |
    tools/console-preview.py /path/to/linux 8x16 rescue-8x16.png
"""
import gzip
import re
import struct
import sys

from PIL import Image


def load_font(kdir, name):
    src = open(f"{kdir}/lib/fonts/font_{name.lower()}.c").read()
    w, h = (int(x) for x in re.search(r"(\d+)x(\d+)", name).groups())
    body = re.sub(r"/\*.*?\*/", "", src[src.index("fontdata_"):], flags=re.S)  # comments hold 0x.. too
    data = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})\b", body)]
    stride = (w + 7) // 8 * h
    if len(data) < 256 * stride:
        sys.exit(f"font_{name}.c: parsed {len(data)} bytes, need {256 * stride}")
    return w, h, stride, data, None


def load_psf(path):
    """PSF1 / PSF2 (gzip ok): width, height, bytes per glyph, glyph data, {codepoint: glyph}"""
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    umap = {}
    if raw[:2] == b"\x36\x04":                                  # PSF1
        mode, h = raw[2], raw[3]
        w, stride, n, off = 8, h, 512 if mode & 1 else 256, 4
        data = list(raw[off:off + n * stride])
        if mode & 2:                                              # u16 table, 0xFFFF ends a glyph
            tab, g, i = raw[off + n * stride:], 0, 0
            while g < n and i + 1 < len(tab):
                u = tab[i] | tab[i + 1] << 8; i += 2
                if u == 0xFFFF: g += 1
                elif u != 0xFFFE: umap.setdefault(u, g)
    elif raw[:4] == b"\x72\xb5\x4a\x86":                          # PSF2
        _, _, off, flags, n, stride, h, w = struct.unpack_from("<8I", raw)
        data = list(raw[off:off + n * stride])
        if flags & 1:                                             # UTF-8 table, 0xFF ends a glyph
            for g, entry in enumerate(raw[off + n * stride:].split(b"\xff")[:n]):
                for seq in entry.split(b"\xfe")[:1]:             # single code points only
                    for ch in seq.decode("utf-8", "replace"):
                        umap.setdefault(ord(ch), g)
    else:
        sys.exit(f"{path}: not a PSF1/PSF2 font")
    return w, h, stride, data, umap or None


def main():
    args = sys.argv[1:]
    screen = None
    if args and args[0] == "--screen":
        screen = tuple(int(x) for x in args[1].split("x")); args = args[2:]
    if len(args) >= 2 and re.search(r"\.psf(\.gz)?$", args[0]):
        font, out, rest = args[0], args[1], args[2:]
        w, h, stride, data, umap = load_psf(font)
    elif len(args) >= 3:
        kdir, font, out, rest = args[0], args[1], args[2], args[3:]
        w, h, stride, data, umap = load_font(kdir, font)
    else:
        sys.exit(__doc__)
    text = open(rest[0]).read() if rest else sys.stdin.read()
    rowbytes = (w + 7) // 8
    lines = text.rstrip("\n").split("\n")
    cols = max(len(l) for l in lines)
    if screen:
        img = Image.new("RGB", screen, (0, 0, 0))
        ox = oy = 0
        ccols, crows = screen[0] // w, screen[1] // h
        print(f"console {ccols}x{crows} cells on {screen[0]}x{screen[1]}. Text {cols}x{len(lines)}")
        if cols > ccols:
            print(f"WARNING: lines longer than {ccols} columns wrap (as on the console)")
            lines = [l[i:i + ccols] for l in lines for i in range(0, max(len(l), 1), ccols)]
        if len(lines) > crows:
            print(f"WARNING: {len(lines)} rows do not fit in {crows} (the console would scroll)")
    else:
        img = Image.new("RGB", (cols * w + 16, len(lines) * h + 16), (0, 0, 0))
        ox = oy = 8
    px = img.load()
    for r, line in enumerate(lines):
        for c, ch in enumerate(line):
            gi = umap.get(ord(ch), umap.get(0xFFFD, ord("?"))) if umap else ord(ch) & 0xFF
            g = data[gi * stride:][:stride]
            for y in range(h):
                for x in range(w):
                    if g[y * rowbytes + x // 8] & (0x80 >> (x % 8)):
                        X, Y = ox + c * w + x, oy + r * h + y
                        if X < img.size[0] and Y < img.size[1]:
                            px[X, Y] = (170, 170, 170)
    img.save(out)
    print(f"{out}: {cols}x{len(lines)} cells, font {w}x{h}, {img.size[0]}x{img.size[1]} px")
    return 0


main()
