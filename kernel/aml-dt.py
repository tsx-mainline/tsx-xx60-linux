#!/usr/bin/env python3
"""aml-dt.py - pack/unpack Amlogic "AML_" multi-DTB containers.

This is the container the xx60 vendor U-Boot accepts as the boot image's
"second" payload when it wants to pick a DTB by board variant instead of
booting a single flat FDT. Format reverse-engineered from the vendor U-Boot
source (common/aml_dt.c, get_multi_dt_entry) and cross-checked against the
real container extracted from the stock boot.img's "second" payload.

Container layout (tool "version 2" - the only version aml_dt.c still fully
supports and the one the stock image uses):

  offset 0   magic     4 bytes, literal ASCII "AML_"
  offset 4   version   u32 LE, = 2
  offset 8   count     u32 LE, number of dtb entries (N)
  offset 12  entries   N * 56-byte records:
               +0  soc       16 bytes, see STRING ENCODING below
               +16 platform  16 bytes
               +32 variant   16 bytes
               +48 offset    u32 LE, absolute byte offset from container start
               +52 size      u32 LE, bytes reserved for this dtb
  then the raw dtb blobs, each at its recorded offset.

STRING ENCODING: each 16-byte identifier field holds the string right-padded
with spaces (0x20) to 16 bytes, with every 4-byte group byte-reversed. U-Boot
undoes this with a readl() (little-endian load) whose bytes it then
reassembles MSB-first - the same transform, so it is its own inverse and one
swap4() helper both encodes and decodes it.

U-Boot's env `aml_dt` (e.g. "yushan_one_10inch") is split into exactly 3
tokens on "_" (aml_dt.c does 3x strsep) and compared against soc/platform/
variant of each entry in turn; the first exact match wins. Only `offset` is
read to relocate the DTB - `size` is written but never consulted by U-Boot,
it is just bookkeeping.

Verified against the stock boot.img's "second" payload: the header occupies bytes
[0, 12+56*N), rounded up to the next 2048-byte page for the first entry's
payload (2048 is also the Android boot image page size mkimage.sh uses
elsewhere); the stock tool then reserved a fixed 32768-byte slot per dtb
(all 6 stock dtbs fit under that). This tool does not force that fixed slot
for new containers it packs - it lays out each supplied blob at its actual
length, 4-byte aligned, which U-Boot accepts fine since it addresses each
dtb purely through the FDT's own totalsize field. Repacking the *stock*
entries (extracted verbatim, padding included) reproduces the exact
original bytes because the extracted blobs already carry the original size.
"""
import sys
import os
import struct

MAGIC = b'AML_'
VERSION = 2
ID_LEN = 16
IDS_PER_ENTRY = 3
ENTRY_SIZE = 8 + ID_LEN * IDS_PER_ENTRY  # 56
FIRST_ENTRY_OFF = 12
PAGE = 2048  # header area is page-rounded, matching the stock container/boot.img


def swap4(b: bytes) -> bytes:
    assert len(b) % 4 == 0
    return b''.join(bytes(b[i:i + 4][::-1]) for i in range(0, len(b), 4))


def encode_id(s: str) -> bytes:
    raw = s.encode('ascii')
    if len(raw) > ID_LEN:
        raise ValueError(f"identifier {s!r} longer than {ID_LEN} bytes")
    return swap4(raw.ljust(ID_LEN, b' '))


def decode_id(b: bytes) -> str:
    return swap4(b).rstrip(b' \x00').decode('ascii', 'replace')


def round_up(n, a):
    return (n + a - 1) // a * a


def fdt_totalsize(blob: bytes):
    if len(blob) >= 8 and blob[0:4] == b'\xd0\x0d\xfe\xed':
        return struct.unpack_from('>I', blob, 4)[0]
    return None


def parse(data: bytes):
    if data[0:4] != MAGIC:
        raise ValueError(f"bad magic {data[0:4]!r}, expected {MAGIC!r}")
    version, count = struct.unpack_from('<II', data, 4)
    if version != VERSION:
        raise ValueError(
            f"unsupported aml_dt tool version {version} (only v{VERSION} implemented)")
    entries = []
    for i in range(count):
        base = FIRST_ENTRY_OFF + i * ENTRY_SIZE
        soc = decode_id(data[base:base + 16])
        plat = decode_id(data[base + 16:base + 32])
        vari = decode_id(data[base + 32:base + 48])
        off, size = struct.unpack_from('<II', data, base + 48)
        entries.append(dict(soc=soc, platform=plat, variant=vari, offset=off, size=size))
    return version, entries


def name_of(e):
    return f"{e['soc']}_{e['platform']}_{e['variant']}"


def do_list(container):
    data = open(container, 'rb').read()
    version, entries = parse(data)
    print(f"{container}: AML_ v{version}, {len(entries)} entries, {len(data)} bytes total")
    for i, e in enumerate(entries):
        blob = data[e['offset']:e['offset'] + e['size']]
        real = fdt_totalsize(blob)
        print(f"  [{i}] {name_of(e):32s} off=0x{e['offset']:06x} slot={e['size']:6d} "
              f"fdt_totalsize={real}")


def do_unpack(container, outdir):
    data = open(container, 'rb').read()
    version, entries = parse(data)
    os.makedirs(outdir, exist_ok=True)
    for i, e in enumerate(entries):
        blob = data[e['offset']:e['offset'] + e['size']]
        path = os.path.join(outdir, name_of(e) + '.dtb')
        open(path, 'wb').write(blob)
        real = fdt_totalsize(blob)
        print(f"  [{i}] {name_of(e)} -> {path} ({e['size']} bytes, fdt_totalsize={real})")
    print(f"unpacked {len(entries)} entries from {container} into {outdir}")


def do_pack(argv):
    entry_specs = []
    out = None
    i = 0
    while i < len(argv):
        if argv[i] == '--entry':
            entry_specs.append(argv[i + 1])
            i += 2
        else:
            out = argv[i]
            i += 1
    if out is None or not entry_specs:
        sys.exit("usage: aml-dt.py pack --entry NAME=PATH [--entry NAME=PATH ...] OUT")

    parsed = []
    for spec in entry_specs:
        if '=' not in spec:
            sys.exit(f"--entry {spec!r} must be NAME=PATH")
        name, path = spec.split('=', 1)
        parts = name.split('_', 2)
        if len(parts) != 3:
            sys.exit(f"--entry name {name!r} must be soc_platform_variant "
                      f"(3 underscore-separated fields)")
        soc, plat, vari = parts
        blob = open(path, 'rb').read()
        parsed.append((soc, plat, vari, blob))

    count = len(parsed)
    header_size = FIRST_ENTRY_OFF + count * ENTRY_SIZE
    header = bytearray(header_size)
    header[0:4] = MAGIC
    struct.pack_into('<II', header, 4, VERSION, count)

    cur = round_up(header_size, PAGE)
    pad_before = cur - header_size
    payload = bytearray()
    for idx, (soc, plat, vari, blob) in enumerate(parsed):
        base = FIRST_ENTRY_OFF + idx * ENTRY_SIZE
        header[base:base + 16] = encode_id(soc)
        header[base + 16:base + 32] = encode_id(plat)
        header[base + 32:base + 48] = encode_id(vari)
        struct.pack_into('<II', header, base + 48, cur, len(blob))
        payload += blob
        nxt = round_up(cur + len(blob), 4)
        payload += b'\0' * (nxt - (cur + len(blob)))
        cur = nxt

    img = bytes(header) + b'\0' * pad_before + bytes(payload)
    open(out, 'wb').write(img)
    print(f"packed {count} entries into {out} ({len(img)} bytes)")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == 'list':
        if len(rest) != 1:
            sys.exit("usage: aml-dt.py list CONTAINER")
        do_list(rest[0])
    elif cmd == 'unpack':
        if len(rest) != 2:
            sys.exit("usage: aml-dt.py unpack CONTAINER OUTDIR")
        do_unpack(rest[0], rest[1])
    elif cmd == 'pack':
        do_pack(rest)
    else:
        sys.exit(f"unknown command {cmd!r}\n\n{__doc__}")


if __name__ == '__main__':
    main()
