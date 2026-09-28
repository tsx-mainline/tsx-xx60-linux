#!/bin/bash
# Layer the v2 splash/status screen onto an already-built rescue image
# (installer/rescue/mkrescue.sh's own output, UNCHANGED -- this script does
# not modify or re-implement anything under installer/rescue/, it only adds
# one more cpio archive on top, the same layering trick mkrescue.sh itself
# uses for the rescue overlay: the kernel unpacks concatenated cpio archives
# in order, so a later file wins).
#
# Adds:
#   /usr/sbin/tsx-rescue-status   splash + live status screen (see its own header)
#   /etc/tsx/rescue-version       "v2 <date> <flavor>", shown on the screen
#   /etc/inittab                  BASE rescue's inittab, with the one-shot
#                                 "tsx-rescue banner" line replaced by a
#                                 respawning "tsx-rescue-status loop" (same
#                                 banner information, redrawn live instead of
#                                 printed once)
#
#   installer/rescue-v2/mkrescue-v2.sh --base RESCUE_IMG [--flavor lts|stable] [--out IMG]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); INSTALLER_DIR=$(cd "$HERE/.." && pwd)
BASE= FLAVOR=unknown OUT=
while [ $# -gt 0 ]; do case $1 in --base) BASE=$2; shift;; --flavor) FLAVOR=$2; shift;; --out) OUT=$2; shift;; *) sed -n '2,20p' "$0"; exit 2;; esac; shift; done
[ -n "$BASE" ] && [ -f "$BASE" ] || { echo "mkrescue-v2.sh: --base RESCUE_IMG required (installer/rescue/mkrescue.sh output)" >&2; exit 2; }
OUT=${OUT:-$HERE/out/tsx-rescue-v2-$(basename "${BASE%.img}").img}
mkdir -p "$(dirname "$OUT")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

python3 - "$BASE" "$W/base-rd.gz" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(); h = struct.unpack_from('<8s10I', d, 0); assert h[0] == b'ANDROID!'
ks, rs, ps = h[1], h[3], h[8]; pad = lambda n: (n + ps - 1) // ps * ps
open(sys.argv[2], 'wb').write(d[ps + pad(ks): ps + pad(ks) + rs])
PY
# NOTE: BASE (a rescue image) is itself two concatenated cpio archives (the
# kiosk switch_root initramfs + the rescue overlay, see installer/rescue/mkrescue.sh);
# a plain `cpio -id` from userspace only unpacks the FIRST one it finds (it stops
# at that archive's own TRAILER entry) -- only the KERNEL's own initramfs unpacker
# walks past a trailer to the next embedded archive. So this extracts the
# kiosk's plain inittab (sysinit/rcS + gettys + ctrlaltdel + shutdown, no
# rescue-specific lines at all), which is exactly the right starting point here:
# our own archive is appended LAST and therefore wins wholesale at boot, so its
# inittab is the ONLY one that matters for the final result, and it should
# start from the plain base, not try to reconstruct the rescue overlay's own
# (independently correct) version of it.
mkdir -p "$W/base"; (cd "$W/base" && zcat "$W/base-rd.gz" | cpio -id --quiet etc/inittab 2>/dev/null) || true
[ -f "$W/base/etc/inittab" ] || { echo "mkrescue-v2.sh: $BASE's initramfs has no etc/inittab (not a rescue image built by mkrescue.sh?)"; exit 1; }

R=$W/ov; mkdir -p "$R/usr/sbin" "$R/etc/tsx"
install -D -m 755 "$HERE/overlay/usr/sbin/tsx-rescue-status" "$R/usr/sbin/tsx-rescue-status"
echo "v2 $(date -Iseconds 2>/dev/null || date) flavor=$FLAVOR" > "$R/etc/tsx/rescue-version"
cp "$W/base/etc/inittab" "$R/etc/inittab"
echo "::respawn:/usr/sbin/tsx-rescue-status loop" >> "$R/etc/inittab"

(cd "$R" && find . -mindepth 1 | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > "$W/ov.gz"
python3 - "$BASE" "$W/ov.gz" "$W/rd-extra.gz" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(); h = struct.unpack_from('<8s10I', d, 0)
ks, rs, ps = h[1], h[3], h[8]; pad = lambda n: (n + ps - 1) // ps * ps
rd = d[ps + pad(ks): ps + pad(ks) + rs]
open(sys.argv[3], 'wb').write(rd + open(sys.argv[2], 'rb').read())
PY
python3 "$INSTALLER_DIR/initramfs/repack-bootimg.py" "$BASE" "$W/rd-extra.gz" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" && cat "$(basename "$OUT").sha256")
echo "mkrescue-v2.sh: v2 overlay added on top of $BASE: $(cd "$R" && find . -type f | sort | tr '\n' ' ')"
