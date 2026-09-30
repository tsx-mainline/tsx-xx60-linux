#!/bin/bash
# Build an Android boot image that the xx60 vendor U-Boot (Amlogic 2011, Crestron 1.00.12) boots.
#
# What U-Boot requires (common/cmd_bootm.c, arch/arm/lib/bootm.c, common/aml_dt.c):
#   - An Android boot image v0 with page size 2048. bootm hardcodes the 0x800 header skip.
#   - The "kernel" payload must be a legacy uImage. bootm reads type, comp, load
#     and entry from the uImage header at +0x800. It rejects a raw zImage.
#   - U-Boot passes the ramdisk to Linux through the FDT (/chosen linux,initrd-*).
#   - The "second" payload is the device tree. It is a plain FDT or an Amlogic
#     "AML_" multi-DTB container (selected by env aml_dt). U-Boot relocates it,
#     writes /chosen bootargs, the memory node and initrd, and jumps with r2 = FDT.
#   - bootm ignores the load addresses in the header. This script keeps them
#     equal to stock for clarity.
#
# Usage:
#   mkimage.sh --kernel zImage --dtb board.dtb [--initrd initrd.cpio.gz] [--cmdline ".."] \
#              [--append-dtb] --out boot.img
#   mkimage.sh --kernel zImage --dtbs name=path.dtb[,name=path.dtb...] [...] --out boot.img
#   mkimage.sh --kernel zImage --board-dtbs DIR [...] --out boot.img
#   mkimage.sh --uimage uImage [--second second.bin] [--initrd ramdisk] --out boot.img
#   mkimage.sh --selftest        (repack the stock boot.img and compare byte for byte,
#                                  plus a multi-DTB "AML_" container round-trip check)
#
# --dtbs packs an Amlogic "AML_" multi-DTB container (with aml-dt.py) and uses
# it as the second payload instead of a plain FDT. One boot.img can then serve
# several board variants. The env aml_dt of the vendor U-Boot selects the
# variant at runtime (see aml_dt.c and the header comment of aml-dt.py).
# Each name is "soc_platform_variant", for example yushan_one_10inch.
# --dtbs excludes --dtb. It also does not work with --append-dtb, which needs
# a single flat FDT.
#
# --board-dtbs DIR makes the one xx60 boot image for every panel size. The
# container comes from DIR/meson8m2-crestron-tsw1060.dtb and
# DIR/meson8m2-crestron-tsw760.dtb, with one entry for each aml_dt value that
# U-Boot can hold (board_dtbs below). U-Boot boots nothing when no entry
# matches its aml_dt (aml_dt.c returns the container itself). So the "old"
# variants of the vendor container get the DTB of their panel size, the same
# DTB that a plain FDT gave them before. If DIR has no TSW-760 DTB (a kernel
# older than the TSW-760 DTS), the script makes the plain TSW-1060 FDT, as before.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOADADDR=0x00208000          # = Meson TEXT_OFFSET, same as stock uImage
KERNEL= DTB= DTBS= UIMAGE= SECOND= INITRD= OUT= CMDLINE= APPEND=0 SELFTEST=0 BOARD_DIR=

while [ $# -gt 0 ]; do
  case $1 in
    --kernel) KERNEL=$2; shift;;
    --dtb) DTB=$2; shift;;
    --dtbs) DTBS=$2; shift;;
    --board-dtbs) BOARD_DIR=$2; shift;;
    --uimage) UIMAGE=$2; shift;;
    --second) SECOND=$2; shift;;
    --initrd) INITRD=$2; shift;;
    --cmdline) CMDLINE=$2; shift;;
    --append-dtb) APPEND=1;;
    --out) OUT=$2; shift;;
    --selftest) SELFTEST=1;;
    *) echo "unknown arg $1" >&2; exit 1;;
  esac; shift
done

# board_dtbs DIR: the --dtbs list for the xx60 panels (aml_dt variant -> DTB)
board_dtbs() {
  local d10=$1/meson8m2-crestron-tsw1060.dtb d7=$1/meson8m2-crestron-tsw760.dtb
  echo "yushan_one_10inch=$d10,yushan_one_7inch=$d7,yushan_one_old10inch=$d10,yushan_one_old7inch=$d7"
}
if [ -n "$BOARD_DIR" ]; then
  [ -z "$DTB" ] && [ -z "$DTBS" ] || { echo "--board-dtbs excludes --dtb and --dtbs" >&2; exit 1; }
  [ -f "$BOARD_DIR/meson8m2-crestron-tsw1060.dtb" ] || { echo "--board-dtbs: no $BOARD_DIR/meson8m2-crestron-tsw1060.dtb" >&2; exit 1; }
  if [ -f "$BOARD_DIR/meson8m2-crestron-tsw760.dtb" ]; then
    DTBS=$(board_dtbs "$BOARD_DIR")
  else
    echo "mkimage.sh: no TSW-760 DTB in $BOARD_DIR: plain TSW-1060 FDT" >&2
    DTB=$BOARD_DIR/meson8m2-crestron-tsw1060.dtb
  fi
fi
if [ -n "$DTB" ] && [ -n "$DTBS" ]; then
  echo "--dtb and --dtbs are mutually exclusive" >&2; exit 1
fi
if [ -n "$DTBS" ] && [ $APPEND = 1 ]; then
  echo "--append-dtb is incompatible with --dtbs (no single flat FDT to append)" >&2; exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkbootimg() { # kernel ramdisk second cmdline out
  python3 - "$@" <<'PY'
import sys, struct, hashlib
kf, rf, sf, cmd, out = sys.argv[1:6]
rd = lambda f: open(f, 'rb').read() if f else b''
k, r, s = rd(kf), rd(rf), rd(sf)
PAGE = 2048
sha = hashlib.sha1()
for b in (k, r, s):
    sha.update(b); sha.update(struct.pack('<I', len(b)))
hdr = struct.pack('<8s10I16s512s32s', b'ANDROID!',
                  len(k), 0x10008000, len(r), 0x11000000, len(s), 0x10f00000,
                  0x10000100, PAGE, 0, 0, b'', cmd.encode()[:511], sha.digest())
pad = lambda b: b + b'\0' * (-len(b) % PAGE)
img = pad(hdr) + pad(k) + pad(r) + (pad(s) if s else b'')
open(out, 'wb').write(img)
print(f"{out}: kernel {len(k)} ramdisk {len(r)} second {len(s)} total {len(img)}")
PY
}

if [ $SELFTEST = 1 ]; then
  STOCK=$HERE/../../../tsw-xx60_3.002.1061.001/tsx-xx60_3.002.1061/image_3.002.1061_r542678/boot.img
  mkbootimg "$HERE/stock/kernel.uImage" "$HERE/stock/ramdisk.img" "$HERE/stock/second" "" "$TMP/re.img" >/dev/null
  cmp "$STOCK" "$TMP/re.img" && echo "selftest OK: repacked stock boot.img is byte-identical"

  # Multi-DTB container path (--dtbs): pack the TSW-1060 and TSW-760 DTBs.
  # If out/ has no TSW-760 DTB, pack the TSW-1060 DTB twice. Then unpack the
  # container and confirm that both entries round-trip intact.
  TSW1060_DTB=$HERE/out/meson8m2-crestron-tsw1060.dtb TSW760_DTB=$HERE/out/meson8m2-crestron-tsw760.dtb
  [ -f "$TSW760_DTB" ] || TSW760_DTB=$TSW1060_DTB
  if [ -f "$TSW1060_DTB" ]; then
    python3 "$HERE/aml-dt.py" pack \
      --entry yushan_one_10inch="$TSW1060_DTB" \
      --entry yushan_one_7inch="$TSW760_DTB" \
      "$TMP/dtbs.img" >/dev/null
    python3 "$HERE/aml-dt.py" unpack "$TMP/dtbs.img" "$TMP/dtbs-out" >/dev/null
    cmp -s "$TSW1060_DTB" "$TMP/dtbs-out/yushan_one_10inch.dtb" && cmp -s "$TSW760_DTB" "$TMP/dtbs-out/yushan_one_7inch.dtb" || {
      echo "selftest FAILED: --dtbs container round-trip mismatch" >&2; exit 1; }
    echo "selftest OK: --dtbs container (yushan_one_10inch + yushan_one_7inch) round-trips intact"
  else
    echo "selftest SKIPPED: --dtbs check ($TSW1060_DTB not found)" >&2
  fi
  exit
fi

[ -n "$OUT" ] || { echo "--out required" >&2; exit 1; }

if [ -n "$DTBS" ]; then
  IFS=',' read -ra DTB_PAIRS <<< "$DTBS"
  ENTRY_ARGS=()
  for p in "${DTB_PAIRS[@]}"; do ENTRY_ARGS+=(--entry "$p"); done
  python3 "$HERE/aml-dt.py" pack "${ENTRY_ARGS[@]}" "$TMP/dtbs.img" >/dev/null
  SECOND=$TMP/dtbs.img
fi

if [ -n "$KERNEL" ]; then
  [ -n "$DTB" ] || [ -n "$DTBS" ] || { echo "--dtb or --dtbs required with --kernel" >&2; exit 1; }
  cp "$KERNEL" "$TMP/zImage"
  if [ -n "$DTBS" ]; then
    : # SECOND already built above as the multi-DTB container
  elif [ $APPEND = 1 ]; then
    # fallback: DTB appended to zImage (needs CONFIG_ARM_APPENDED_DTB). Second stays empty
    cat "$DTB" >> "$TMP/zImage"
  else
    SECOND=$DTB
  fi
  # -C none: U-Boot copies the zImage to LOADADDR. The zImage decompressor then
  # places the kernel at (pc & 0xf8000000) + TEXT_OFFSET = 0x00208000.
  mkimage -A arm -O linux -T kernel -C none -a $LOADADDR -e $LOADADDR \
          -n "Linux-mainline" -d "$TMP/zImage" "$TMP/uImage" >/dev/null
  UIMAGE=$TMP/uImage
fi

[ -n "$UIMAGE" ] || { echo "--kernel or --uimage required" >&2; exit 1; }
mkbootimg "$UIMAGE" "$INITRD" "$SECOND" "$CMDLINE" "$OUT"
