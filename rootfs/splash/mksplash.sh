#!/bin/sh
# Render the boot splash for every supported panel size into OUTDIR:
#   splash-1280x800.{png,ppm}   TSW-1060 / TSS-10
#   splash-1024x600.{png,ppm}   TSW-760
#   splash-800x1280, splash-600x1024  the same upright for a panel that hangs
#                               in portrait (tsx-splash turns the frame onto
#                               the landscape LCD; docs/rootfs.md "Orientation")
#   font-16.psf, font-24.psf    Terminus console fonts for the status line
# The .ppm files and fonts go into the initramfs (tsx-splash draws them on
# /dev/fb0), the .png files into the rootfs (the compositor background).
# Runs INSIDE an Alpine container (the initramfs and rootfs builds); installs
# its own tools there (rsvg-convert, py3-pillow, font-terminus, and
# font-jetbrains-mono for the word mark), never into the image being built.
#   mksplash.sh OUTDIR
set -eu
OUT=$1; HERE=$(cd "$(dirname "$0")" && pwd)
apk add -q --no-cache rsvg-convert py3-pillow font-terminus font-jetbrains-mono fontconfig >/dev/null
# the word mark is text: refuse to render it in a fallback font
fc-match -f '%{file}\n' 'JetBrains Mono:bold' | grep -q 'JetBrainsMono-Bold\.ttf$' ||
	{ echo "mksplash.sh: JetBrains Mono Bold not found by fontconfig" >&2; exit 1; }
mkdir -p "$OUT"; T=$(mktemp -d)
# W H TUX_SCALE MARK_WIDTH
for s in "1280 800 2 560" "1024 600 2 448" "800 1280 2 560" "600 1024 2 448"; do
	set -- $s
	rsvg-convert -w "$4" "$HERE/tsx-linux-mark.svg" -o "$T/mark.png"
	python3 "$HERE/compose.py" "$1" "$2" "$3" "$T/mark.png" "$HERE/tux-80.png" "$OUT/splash-$1x$2"
done
# Terminus (SIL OFL 1.1), ISO 8859-1 code page: ASCII maps 1:1 to glyphs
zcat /usr/share/consolefonts/ter-116n.psf.gz > "$OUT/font-16.psf"
zcat /usr/share/consolefonts/ter-124n.psf.gz > "$OUT/font-24.psf"
rm -rf "$T"
ls -l "$OUT"
