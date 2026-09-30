#!/bin/bash
# Stamp a built rescue image (the own output of installer/rescue/mkrescue.sh,
# UNCHANGED, because this script does not modify anything under
# installer/rescue/) with its version line. It appends one more cpio archive on
# top. This is the same layering trick that mkrescue.sh uses for the rescue
# overlay. The kernel unpacks concatenated cpio archives in order, so a later
# file wins.
#
# The rescue screen itself (/usr/sbin/tsx-rescue-status, started on tty1 by the
# inittab of the base initramfs) now ships in the base initramfs, so the own
# rescue of the initramfs shows it too. This script adds only:
#   /etc/tsx/rescue-version   "built <date>, kernel <flavor>", shown on the screen
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
# kiosk switch_root initramfs + the rescue overlay, see installer/rescue/mkrescue.sh).
# A plain `cpio -id` from userspace unpacks only the FIRST archive that it finds.
# That is the base initramfs, and it must carry the screen.
mkdir -p "$W/base"; (cd "$W/base" && zcat "$W/base-rd.gz" | cpio -id --quiet etc/inittab usr/sbin/tsx-rescue-status 2>/dev/null) || true
[ -x "$W/base/usr/sbin/tsx-rescue-status" ] && grep -q 'tsx-rescue-status loop' "$W/base/etc/inittab" || { echo "mkrescue-v2.sh: $BASE's initramfs has no rescue screen (usr/sbin/tsx-rescue-status + its inittab line): rebuild the initramfs"; exit 1; }

R=$W/ov; mkdir -p "$R/etc/tsx"
echo "built $(date +%F 2>/dev/null), kernel flavor $FLAVOR" > "$R/etc/tsx/rescue-version"

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
