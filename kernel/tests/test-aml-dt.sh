#!/bin/bash
# Tests for aml-dt.py (Amlogic "AML_" multi-DTB container pack/unpack) and the
# mkimage.sh --dtbs integration. Host-only, no panel/serial/tftp involved.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KDIR=$(cd "$HERE/.." && pwd)
STOCK_SECOND=$KDIR/stock/second
TSW1060_DTB=$KDIR/out/meson8m2-crestron-tsw1060.dtb
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- Test 1: unpack the stock container -----------------------------------
if python3 "$KDIR/aml-dt.py" unpack "$STOCK_SECOND" "$TMP/unpacked" >"$TMP/unpack.log" 2>&1; then
  ok "aml-dt.py unpack runs on stock/second"
else
  bad "aml-dt.py unpack on stock/second (see $TMP/unpack.log)"
fi

COUNT=$(ls "$TMP/unpacked"/*.dtb 2>/dev/null | wc -l)
if [ "$COUNT" = 6 ]; then
  ok "unpack produced 6 dtb files"
else
  bad "unpack produced $COUNT dtb files, expected 6"
fi

EXPECTED_NAMES="yushan_one_10inch yushan_one_5inch yushan_one_7inch yushan_one_old10inch yushan_one_old5inch yushan_one_old7inch"
MISSING=0
for n in $EXPECTED_NAMES; do
  [ -f "$TMP/unpacked/$n.dtb" ] || MISSING=$((MISSING+1))
done
if [ "$MISSING" = 0 ]; then
  ok "all 6 expected entry names present ($EXPECTED_NAMES)"
else
  bad "$MISSING expected entry name(s) missing from unpack output"
fi

# --- Test 2: repack the same entries in the same order, compare byte-for-byte
python3 "$KDIR/aml-dt.py" pack \
  --entry yushan_one_10inch="$TMP/unpacked/yushan_one_10inch.dtb" \
  --entry yushan_one_5inch="$TMP/unpacked/yushan_one_5inch.dtb" \
  --entry yushan_one_7inch="$TMP/unpacked/yushan_one_7inch.dtb" \
  --entry yushan_one_old10inch="$TMP/unpacked/yushan_one_old10inch.dtb" \
  --entry yushan_one_old5inch="$TMP/unpacked/yushan_one_old5inch.dtb" \
  --entry yushan_one_old7inch="$TMP/unpacked/yushan_one_old7inch.dtb" \
  "$TMP/repacked.img" >"$TMP/pack.log" 2>&1

if cmp -s "$STOCK_SECOND" "$TMP/repacked.img"; then
  ok "repacked container is byte-identical to stock/second"
else
  bad "repacked container differs from stock/second (see $TMP/pack.log, cmp output below)"
  cmp "$STOCK_SECOND" "$TMP/repacked.img" || true
fi

# --- Test 3: aml-dt.py list sanity -----------------------------------------
if python3 "$KDIR/aml-dt.py" list "$STOCK_SECOND" | grep -q "6 entries"; then
  ok "aml-dt.py list reports 6 entries"
else
  bad "aml-dt.py list did not report 6 entries"
fi

# --- Test 4: mkimage.sh --selftest (stock repack + --dtbs container roundtrip)
if [ -f "$TSW1060_DTB" ]; then
  if SELFTEST_OUT=$(bash "$KDIR/mkimage.sh" --selftest 2>&1); then
    echo "$SELFTEST_OUT" | sed 's/^/  mkimage.sh: /'
    if echo "$SELFTEST_OUT" | grep -q "repacked stock boot.img is byte-identical"; then
      ok "mkimage.sh --selftest: stock boot.img repack"
    else
      bad "mkimage.sh --selftest: stock boot.img repack line missing"
    fi
    if echo "$SELFTEST_OUT" | grep -q "dtbs container (yushan_one_10inch + yushan_one_7inch) round-trips intact"; then
      ok "mkimage.sh --selftest: --dtbs container round-trip"
    else
      bad "mkimage.sh --selftest: --dtbs container round-trip line missing"
    fi
  else
    bad "mkimage.sh --selftest exited non-zero: $SELFTEST_OUT"
  fi
else
  echo "SKIP: $TSW1060_DTB not found, skipping mkimage.sh --dtbs selftest"
fi

# --- Test 5: --dtb and --dtbs are mutually exclusive ------------------------
if bash "$KDIR/mkimage.sh" --dtb "$TSW1060_DTB" --dtbs "yushan_one_10inch=$TSW1060_DTB" \
     --uimage "$KDIR/stock/kernel.uImage" --out "$TMP/should-fail.img" >/dev/null 2>&1; then
  bad "mkimage.sh accepted --dtb and --dtbs together (should have failed)"
else
  ok "mkimage.sh rejects --dtb and --dtbs together"
fi

# --- Test 6: --board-dtbs (one boot image for the TSW-1060 and the TSW-760) ---
# Two small valid FDT headers stand in for the board DTBs (aml-dt.py only reads
# the FDT totalsize); the kernel is a dummy blob.
python3 - "$TMP/board" <<'PYF'
import os, struct, sys
d = sys.argv[1]; os.makedirs(d, exist_ok=True)
for name, tag in (('meson8m2-crestron-tsw1060.dtb', b'10'), ('meson8m2-crestron-tsw760.dtb', b'7')):
    body = tag * 60
    hdr = struct.pack('>2I', 0xd00dfeed, 8 + len(body))
    open(os.path.join(d, name), 'wb').write(hdr + body)
open(os.path.join(d, 'zImage'), 'wb').write(os.urandom(4096))
PYF
second_of() {  # boot.img -> its second payload (Android boot image v0, page 2048)
  python3 - "$1" "$2" <<'PYS'
import struct, sys
b = open(sys.argv[1], 'rb').read()
ks, rs, ss, ps = (struct.unpack_from('<I', b, o)[0] for o in (8, 16, 24, 36))
up = lambda n: (n + ps - 1) // ps * ps
o = ps + up(ks) + up(rs)
open(sys.argv[2], 'wb').write(b[o:o + ss])
PYS
}
if command -v mkimage >/dev/null; then
  if bash "$KDIR/mkimage.sh" --kernel "$TMP/board/zImage" --board-dtbs "$TMP/board" --out "$TMP/board.img" >/dev/null 2>&1; then
    second_of "$TMP/board.img" "$TMP/board-second.img"
    python3 "$KDIR/aml-dt.py" unpack "$TMP/board-second.img" "$TMP/board-out" >/dev/null 2>&1
    B=$TMP/board R=$TMP/board-out
    if cmp -s "$B/meson8m2-crestron-tsw1060.dtb" "$R/yushan_one_10inch.dtb" && cmp -s "$B/meson8m2-crestron-tsw760.dtb" "$R/yushan_one_7inch.dtb" \
       && cmp -s "$B/meson8m2-crestron-tsw1060.dtb" "$R/yushan_one_old10inch.dtb" && cmp -s "$B/meson8m2-crestron-tsw760.dtb" "$R/yushan_one_old7inch.dtb" \
       && [ "$(ls "$R" | wc -l)" = 4 ]; then
      ok "--board-dtbs: container with 10inch/7inch (+ old variants) -> TSW-1060/TSW-760 DTBs"
    else
      bad "--board-dtbs: container entries do not map to the right DTBs ($(ls "$R" 2>/dev/null | tr '\n' ' '))"
    fi
  else
    bad "mkimage.sh --board-dtbs failed"
  fi
  rm "$TMP/board/meson8m2-crestron-tsw760.dtb"
  if bash "$KDIR/mkimage.sh" --kernel "$TMP/board/zImage" --board-dtbs "$TMP/board" --out "$TMP/board1.img" >/dev/null 2>&1; then
    second_of "$TMP/board1.img" "$TMP/board1-second.img"
    cmp -s "$TMP/board1-second.img" "$TMP/board/meson8m2-crestron-tsw1060.dtb" && ok "--board-dtbs without a TSW-760 DTB: plain TSW-1060 FDT" \
      || bad "--board-dtbs without a TSW-760 DTB: second is not the plain TSW-1060 FDT"
  else
    bad "mkimage.sh --board-dtbs (no TSW-760 DTB) failed"
  fi
  if bash "$KDIR/mkimage.sh" --kernel "$TMP/board/zImage" --board-dtbs "$TMP/board" --dtb "$TMP/board/meson8m2-crestron-tsw1060.dtb" --out "$TMP/x.img" >/dev/null 2>&1; then
    bad "mkimage.sh accepted --board-dtbs with --dtb"
  else
    ok "mkimage.sh rejects --board-dtbs with --dtb"
  fi
else
  echo "SKIP: no mkimage (u-boot-tools), skipping the --board-dtbs tests"
fi

echo
echo "===== $PASS passed, $FAIL failed ====="
[ "$FAIL" = 0 ]
