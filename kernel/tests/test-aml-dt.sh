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

echo
echo "===== $PASS passed, $FAIL failed ====="
[ "$FAIL" = 0 ]
