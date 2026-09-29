#!/bin/sh
# Host test for the screen orientation (panel.conf ORIENTATION, docs/rootfs.md
# "Orientation"), no panel needed:
#   - tsx-orientation: the four names, the table (sway transform, touch
#     matrix, fbcon rotation, slide direction), the configured name from the
#     file (missing / junk = landscape), the sway lines, and `apply` (swaymsg
#     on every sway socket of the kiosk user, a stale one is skipped);
#   - touch agrees with the picture: tsx-splash draws a marker at a frame
#     position, turned onto the LCD (fbpng), and a touch on the LCD where the
#     marker shows maps back to that frame position through the touch matrix
#     and then the output transform, the way wlroots applies it to a touch
#     device mapped to an output (measured on a TSS-10 with injected touches);
#   - kiosk-session puts the sway lines into the session config, the
#     initramfs gets the same tsx-orientation;
#   - tsx-overlay's layout (tsx-overlay-layout.h) on the four outputs
#     (1280x800, 1024x600 and both turned): unchanged in landscape, no higher
#     than the 10-inch landscape overlay in portrait, and everything inside.
# The last two parts compile C with CC (default gcc); busybox and python3
# are needed for the rest.
set -eu
HERE=$(cd "$(dirname "$0")/../.." && pwd)
ORI=$HERE/rootfs/overlay/usr/local/bin/tsx-orientation
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
o() { TSX_ORIENTATION_FILE=$T/none busybox sh "$ORI" "$@"; }

echo "== the table =="
busybox sh -n "$ORI" && ok "busybox sh -n" || bad "busybox sh -n"
for row in "landscape 0 normal 1_0_0_0_1_0 0" "portrait 3 270 1_0_0_0_1_0 0" \
	"landscape-flipped 2 180 1_0_0_0_1_0 1" "portrait-flipped 1 90 1_0_0_0_1_0 1"; do
	set -- $row
	got=$(o info "$1" | tr '\n' ' ')
	want="ORIENTATION=$1 ROTATE=$2 SWAY_TRANSFORM=$3 TOUCH_MATRIX=\"$(echo "$4" | tr _ ' ')\" FBCON_ROTATE=$2 SLIDE_INVERT=$5 "
	[ "$got" = "$want" ] && ok "$1: rotate $2, sway $3, matrix $4, slide inverted $5" || bad "$1: got '$got'"
done
o info sideways >/dev/null 2>&1 && bad "info sideways accepted" || ok "info: unknown name refused (exit 2)"
for v in landscape portrait landscape-flipped portrait-flipped; do o check "$v" || bad "check $v"; done
if o check "" || o check Portrait || o check "portrait x"; then bad "check accepted a bad name"; else ok "check: only the four names"; fi

echo "== the configured name =="
[ "$(o get)" = landscape ] && ok "no file: landscape" || bad "no file: $(o get)"
echo portrait-flipped > "$T/o1"
[ "$(busybox sh "$ORI" -f "$T/o1" get)" = portrait-flipped ] && ok "-f FILE: portrait-flipped" || bad "-f FILE"
[ "$(TSX_ORIENTATION_FILE=$T/o1 busybox sh "$ORI" get)" = portrait-flipped ] && ok "TSX_ORIENTATION_FILE" || bad "env file"
printf 'upside-down\n' > "$T/o2"; : > "$T/o3"
[ "$(busybox sh "$ORI" -f "$T/o2" get)/$(busybox sh "$ORI" -f "$T/o3" get)" = landscape/landscape ] && ok "junk or empty file: landscape" || bad "junk file"
[ "$(busybox sh "$ORI" -f "$T/o1" sway)" = "output * transform 90
input type:touch calibration_matrix 1 0 0 0 1 0" ] && ok "sway lines for the configured name" || bad "sway: $(busybox sh "$ORI" -f "$T/o1" sway)"

echo "== apply: every sway socket of the kiosk user =="
me=$(id -un); uid=$(id -u)
mkdir -p "$T/run/user/$uid" "$T/bin"
python3 -c 'import socket,sys
for p in sys.argv[1:]:
    socket.socket(socket.AF_UNIX).bind(p)' "$T/run/user/$uid/sway-ipc.$uid.100.sock" "$T/run/user/$uid/sway-ipc.$uid.99-stale.sock"
cat > "$T/bin/swaymsg" <<EOF
#!/bin/sh
case "\$SWAYSOCK" in *stale*) exit 1;; esac
echo "\${SWAYSOCK##*/} \$*" >> "$T/swaymsg.log"
EOF
chmod 755 "$T/bin/swaymsg"
ap() { TSX_ORIENTATION_FILE=$1 TSX_SWAYMSG=$T/bin/swaymsg TSX_RUN_USER_DIR=$T/run/user TSX_KIOSK_USER=$me busybox sh "$ORI" apply 2>&1; }
echo portrait > "$T/o4"
msg=$(ap "$T/o4")
[ "$(cat "$T/swaymsg.log")" = "sway-ipc.$uid.100.sock output * transform 270
sway-ipc.$uid.100.sock input type:touch calibration_matrix 1 0 0 0 1 0" ] && ok "portrait: transform 270 + identity touch matrix on the live socket, the stale one skipped" || bad "swaymsg: $(cat "$T/swaymsg.log")"
case "$msg" in *"turned to portrait"*) ok "says so";; *) bad "message: $msg";; esac
: > "$T/swaymsg.log"; ap "$T/none" >/dev/null
grep -q 'transform normal' "$T/swaymsg.log" && grep -q 'calibration_matrix 1 0 0 0 1 0' "$T/swaymsg.log" && ok "back to landscape: explicit normal + identity" || bad "landscape: $(cat "$T/swaymsg.log")"
rm -f "$T/run/user/$uid"/*.sock
msg=$(ap "$T/o4"); case "$msg" in *"no running sway kiosk"*) ok "no sway: exit 0, applies at the next kiosk start";; *) bad "no sway: $msg";; esac

echo "== kiosk-session and the initramfs use it =="
KS=$HERE/rootfs/overlay/usr/local/bin/kiosk-session
grep -q 'orient_cfg=$(/usr/local/bin/tsx-orientation sway)' "$KS" && grep -q '^\$orient_cfg$' "$KS" && ok "kiosk-session: sway lines in the session config" || bad "kiosk-session does not use tsx-orientation sway"
grep -q 'overlay/usr/local/bin/tsx-orientation" \$R/usr/sbin/tsx-orientation' "$HERE/rootfs/initramfs/mkinitramfs-switchroot.sh" && ok "initramfs ships the same tsx-orientation" || bad "initramfs lacks tsx-orientation"
grep -q 'tsx-orientation -f /newroot/etc/tsx/orientation info' "$HERE/rootfs/initramfs/overlay/init" && ok "/init reads the orientation from the mounted root" || bad "/init does not read the orientation"

CC=${CC:-gcc}
echo "== touch (matrix + output transform) vs the turned splash (CC=$CC) =="
$CC -O2 -Wall -Wextra -Werror -o "$T/tsx-splash" "$HERE/rootfs/src/tsx-splash.c"
mkdir -p "$T/d"
# frames with an 11x11 white marker centred on (105, 205), upright
python3 - "$T/d" <<'PY'
import sys
d = sys.argv[1]
for w, h in ((1280, 800), (800, 1280)):
    px = bytearray(w * h * 3)
    for y in range(200, 211):
        for x in range(100, 111):
            px[(y * w + x) * 3:(y * w + x) * 3 + 3] = b'\xff\xff\xff'
    open('%s/splash-%dx%d.ppm' % (d, w, h), 'wb').write(b'P6\n%d %d\n255\n' % (w, h) + bytes(px))
PY
for v in landscape portrait landscape-flipped portrait-flipped; do
	"$T/tsx-splash" -d "$T/d" -g 1280x800 -o "$v" -p -1 fbpng "$T/fb-$v.png"
	m=$(o info "$v" | sed -n 's/^TOUCH_MATRIX="\(.*\)"$/\1/p')
	tr=$(o info "$v" | sed -n 's/^SWAY_TRANSFORM=//p')
	res=$(python3 - "$T/fb-$v.png" "$m" "$tr" <<'PY'
import struct, sys, zlib
b = open(sys.argv[1], 'rb').read()
o, idat = 8, b''
while o < len(b):
    n, t = struct.unpack('>I4s', b[o:o + 8]); c = b[o + 8:o + 8 + n]
    if t == b'IHDR': w, h = struct.unpack('>II', c[:8])
    if t == b'IDAT': idat += c
    o += 12 + n
raw = zlib.decompress(idat)
pts = [(x, y) for y in range(h) for x in range(w)
       if raw[y * (w * 3 + 1) + 1 + x * 3] == 255]
cx = sum(p[0] for p in pts) / len(pts) + 0.5; cy = sum(p[1] for p in pts) / len(pts) + 0.5
a, bb, c, d, e, f = map(float, sys.argv[2].split())
x, y = cx / w, cy / h                    # the touch where the marker shows, raw 0..1
lx, ly = a * x + bb * y + c, d * x + e * y + f   # libinput calibration
# wlroots then turns the touch by the output transform (sway maps the
# touchscreen to the built-in output); measured on the panel:
lx, ly = {'normal': (lx, ly), '90': (ly, 1 - lx), '180': (1 - lx, 1 - ly), '270': (1 - ly, lx)}[sys.argv[3]]
turned = sys.argv[3] in ('90', '270')    # a quarter turn: the frame is 800x1280
fw, fh = (h, w) if turned else (w, h)
print('%dx%d %d %.1f %.1f' % (w, h, len(pts), lx * fw, ly * fh))
PY
)
	set -- $res
	if [ "$1" = 1280x800 ] && [ "$2" = 121 ] && python3 -c "import sys; sys.exit(not (abs($3 - 105.5) < 1 and abs($4 - 205.5) < 1))"; then
		ok "$v: the marker (frame 105,205) lands where a touch maps back to frame $3,$4"
	else
		bad "$v: fb $1, $2 marker pixels, touch maps to $3,$4 (want 105.5,205.5)"
	fi
done

echo "== tsx-overlay layout on the four outputs (CC=$CC) =="
cat > "$T/ov.c" <<'C'
#include <stdio.h>
#include "tsx-overlay-layout.h"
int main(void)
{
	static const int out[][2] = { { 1280, 800 }, { 1024, 600 }, { 800, 1280 }, { 600, 1024 } };
	int fails = 0;
	for (int i = 0; i < 4; i++)
		for (int full = 0; full <= 1; full++) {
			int ow = out[i][0], oh = out[i][1], mv = overlay_margin_v(full, oh), h = oh - 2 * mv;
			int w = full ? FULL_W : SLIDER_W, max_h = full ? FULL_MAX_H : SLIDER_MAX_H;
			struct rect t, b[NBTN];
			overlay_layout(full, h, &t, b);
			int bad = h <= 0 || h > max_h || w + MARGIN_R > ow
				|| (oh <= 800 && mv != (full ? FULL_MARGIN_V : SLIDER_MARGIN_V))   /* landscape: as before */
				|| t.y < 60 || t.y + t.h + 66 + 12 > h || t.x + t.w > w;      /* sun above, level text below */
			for (int k = B_AUTO; full && k < NBTN; k++)
				bad |= b[k].y < 0 || b[k].y + b[k].h > h || b[k].x < t.x + t.w || b[k].x + b[k].w > w || b[k].h < 60;
			printf("%s %dx%d: %s surface %dx%d, margin %d%s\n", bad ? "FAIL" : "ok", ow, oh,
			       full ? "full" : "slider", w, h, mv, bad ? " (does not fit)" : "");
			fails += bad;
		}
	return fails != 0;
}
C
if $CC -O2 -Wall -Wextra -Werror -I"$HERE/rootfs/src" -o "$T/ov" "$T/ov.c" && "$T/ov" > "$T/ov.out"; then
	ok "all eight layouts fit"; sed 's/^/      /' "$T/ov.out"
else
	bad "overlay layout"; cat "$T/ov.out" 2>/dev/null
fi

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-orientation || echo FAIL test-orientation
exit $F
