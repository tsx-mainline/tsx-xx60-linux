#!/usr/bin/env python3
"""Diff a mainline register dump against the vendor capture.

The dump comes from tools/regs/regsnap.sh (static regdump through
/dev/mem, same format as captures/tsw-1060/regs-live.txt).

usage: regdiff.py regs-mainline.txt [../../../captures/tsw-1060/regs-live.txt]

Prints every register whose value differs, grouped as
  OWNED   - written by the LVDS encoder or the clock chain it drives (must match,
            except the known write-only/unowned bits listed in hosttest/compare.py)
  OTHER   - everything else (VIU/VPP/OSD, pinmux, other clocks): review by hand
Registers the vendor capture read twice with different values are skipped.
"""
import re
import sys

mine = sys.argv[1]
import os
live = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "../../../captures/tsw-1060/regs-live.txt")

OWNED_V = set(range(0x1400, 0x1460)) | set(range(0x14c0, 0x1500)) | \
    set(range(0x1c90, 0x1ce0)) | {0x271a, 0x1b6e}
OWNED_C = {0x104a, 0x104b, 0x104c, 0x1065, 0x109c, 0x10d1, 0x10d2, 0x10d9,
           0x10da, 0x10db, 0x10de} | set(range(0x10e0, 0x10e5))
KNOWN = {("VCBUS", 0x14e1), ("VCBUS", 0x14e2), ("VCBUS", 0x14e5), ("VCBUS", 0x1cc2),
         ("CBUS", 0x104a), ("CBUS", 0x1065), ("CBUS", 0x10d2)}
# HHI_LVDS_TX_PHY_CNTL1 (0x10df): not written by the driver. Bit 25 changes
# between boots without writes , so it is never compared.
SKIP = {("CBUS", 0x10df)}


def load(path):
    d, multi = {}, {}
    for line in open(path):
        m = re.match(r"(AOBUS|V?CBUS)\[0x([0-9a-f]+)\]=(0x[0-9a-f]+|ERR)", line)
        if not m:
            continue
        k = (m.group(1), int(m.group(2), 16))
        v = m.group(3)
        v = None if v == "ERR" else int(v, 16)
        multi.setdefault(k, set()).add(v)
        d.setdefault(k, v)
    return d, {k for k, s in multi.items() if len(s) > 1}


a, _ = load(mine)
b, vol = load(live)
owned, other = [], []
for k in sorted(b):
    if k in vol or k in SKIP or k not in a or a[k] == b[k]:
        continue
    bus, reg = k
    own = (bus == "VCBUS" and reg in OWNED_V) or (bus == "CBUS" and reg in OWNED_C)
    fmt = lambda v: "ERR" if v is None else f"0x{v:08x}"
    line = f"{bus}[0x{reg:04x}] vendor {fmt(b[k])} mainline {fmt(a[k])}"
    if k in KNOWN:
        line += "  (known, see BRINGUP.md step 2)"
    (owned if own else other).append(line)

print(f"OWNED differences ({len(owned)}):")
print("\n".join("  " + x for x in owned) or "  none")
print(f"OTHER differences ({len(other)}):")
print("\n".join("  " + x for x in other) or "  none")
print("skipped volatile:", ", ".join(f"{b_}[0x{r:04x}]" for b_, r in sorted(vol)))
