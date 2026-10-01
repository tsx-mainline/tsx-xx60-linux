#!/usr/bin/env python3
"""Find U-Boot environment blocks in a raw disk image (read only).

Usage: find-uboot-env.py IMAGE [--size 0x10000] [--step 512] [--max-mib 64] [--show]

A block is reported when crc32(data[4:size]) == le32(data[0:4]) and the data
starts with printable "key=value" strings. Prints the byte offset and a few
variables (bootcmd, boot_retry, aml_dt). Use the offset in
/etc/tsx/uboot-env.conf (ENV_OFFSET) after confirming it on the panel with
fw_printenv -c (see docs/boot.md).
"""
import argparse, sys, zlib

ap = argparse.ArgumentParser()
ap.add_argument("image")
ap.add_argument("--size", type=lambda s: int(s, 0), default=0x10000)
ap.add_argument("--step", type=lambda s: int(s, 0), default=512)
ap.add_argument("--max-mib", type=int, default=64)
ap.add_argument("--show", action="store_true", help="print all variables of each hit")
a = ap.parse_args()

limit = a.max_mib * 1024 * 1024
with open(a.image, "rb") as f:
    buf = f.read(limit + a.size)
hits = 0
for off in range(0, max(0, min(limit, len(buf) - a.size)) + 1, a.step):
    d = buf[off + 4: off + a.size]
    # cheap pre-filter: must start with an ASCII identifier and contain '='
    if not (65 <= d[0] <= 122) or b"=" not in d[:64]:
        continue
    if zlib.crc32(d) & 0xffffffff != int.from_bytes(buf[off:off + 4], "little"):
        continue
    hits += 1
    env = {}
    for kv in d.split(b"\0"):
        if not kv:
            break
        k, _, v = kv.partition(b"=")
        env[k.decode("latin1")] = v.decode("latin1")
    print(f"env block at offset 0x{off:x} ({off} bytes, sector {off // 512}), {len(env)} vars")
    for k in ("bootcmd", "boot_retry", "golden_boot_retry", "aml_dt", "upgrade_step"):
        if k in env:
            print(f"    {k}={env[k][:100]}")
    if a.show:
        for k, v in env.items():
            print(f"      {k}={v}")
if not hits:
    print(f"no env block with a valid CRC in the first {a.max_mib} MiB (size 0x{a.size:x})")
    sys.exit(1)
