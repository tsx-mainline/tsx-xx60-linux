#!/usr/bin/env python3
"""Check the kernel packages inside a rootfs against the kernel pins.

  check-boot-images.py ROOT [PIN_DIR]

ROOT is the rootfs tree. PIN_DIR holds KERNEL_REV.lts and KERNEL_REV.stable
(default: ../kernel next to this script). For each flavor the script reads
ROOT/boot/tsxboot-emmc-<flavor>.img, an Android boot image. Two things must
be true:

1. The kernel release in the image ends with -g<first 12 digits of the pin>.
   The release in ROOT/usr/share/tsx/kernel-<flavor>.release and the
   directory ROOT/lib/modules/<release> must be the same release.
2. The initramfs in the image has the stamp of this checkout. The stamp is
   the file usr/share/tsx/initramfs.stamp. initramfs-stamp.sh prints the
   stamp of the sources. An image without a stamp, or with another one, has
   an older initramfs.

A failure stops the build with exit status 1. This keeps a payload from
booting an old kernel or an old rescue login when tsx-kernel-flavor runs on
the panel.
"""
import gzip
import os
import re
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
STAMP_PATH = "usr/share/tsx/initramfs.stamp"
failed = False


def bad(msg):
    global failed
    print("check-boot-images: " + msg, file=sys.stderr)
    failed = True


def split_image(data):
    """Return (kernel, ramdisk) of an Android boot image v0."""
    if data[:8] != b"ANDROID!":
        raise ValueError("not an Android boot image")
    ksize, _, rsize, _, _, _, _, page = struct.unpack("<8I", data[8:40])
    if page == 0 or ksize == 0:
        raise ValueError("bad boot image header")
    kernel = data[page:page + ksize]
    roff = page + (ksize + page - 1) // page * page
    ramdisk = data[roff:roff + rsize]
    if len(kernel) != ksize or len(ramdisk) != rsize:
        raise ValueError("boot image is shorter than its header says")
    return kernel, ramdisk


def kernel_release(kernel):
    """The release string inside the gzip stream of the kernel."""
    pos = kernel.find(b"\x1f\x8b\x08")
    while pos >= 0:
        try:
            out = zlib.decompressobj(31).decompress(kernel[pos:])
        except zlib.error:
            out = b""
        m = re.search(rb"Linux version ([^ \n]+)", out)
        if m:
            return m.group(1).decode()
        pos = kernel.find(b"\x1f\x8b\x08", pos + 1)
    return ""


def cpio_file(blob, want):
    """Content of one file in a newc cpio archive, or None."""
    off = 0
    while off + 110 <= len(blob) and blob[off:off + 6] == b"070701":
        f = [int(blob[off + 6 + 8 * i:off + 14 + 8 * i], 16) for i in range(13)]
        size, namesize = f[6], f[11]
        name = blob[off + 110:off + 110 + namesize - 1].decode(errors="replace")
        data_off = (off + 110 + namesize + 3) & ~3
        if name == "TRAILER!!!":
            return None
        if os.path.normpath(name) == want:
            return blob[data_off:data_off + size]
        off = (data_off + size + 3) & ~3
    return None


def main():
    if len(sys.argv) < 2:
        print("usage: check-boot-images.py ROOT [PIN_DIR]", file=sys.stderr)
        return 2
    root = sys.argv[1]
    pins = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "kernel")
    want_stamp = subprocess.run(["sh", os.path.join(HERE, "initramfs-stamp.sh")],
                                check=True, capture_output=True, text=True).stdout.strip()
    for fl in ("lts", "stable"):
        pin = os.path.join(pins, "KERNEL_REV." + fl)
        if not os.path.isfile(pin):
            bad("no " + pin)
            continue
        lines = [l.strip() for l in open(pin) if not l.startswith("#") and l.strip()]
        rev = lines[0] if lines else ""
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            bad("%s has no 40 digit revision" % pin)
            continue
        short = rev[:12]
        img = os.path.join(root, "boot", "tsxboot-emmc-%s.img" % fl)
        if not os.path.isfile(img):
            bad("%s: no /boot/tsxboot-emmc-%s.img in the rootfs" % (fl, fl))
            continue
        try:
            kernel, ramdisk = split_image(open(img, "rb").read())
        except ValueError as e:
            bad("%s: %s" % (fl, e))
            continue
        rel = kernel_release(kernel)
        if not rel:
            bad("%s: no kernel release found in the boot image" % fl)
            continue
        if not rel.endswith("-g" + short):
            bad("%s: the boot image has kernel %s, the pin is %s (rebuild the tsx-xx60-kernel-%s package)"
                % (fl, rel, rev, fl))
            continue
        rf = os.path.join(root, "usr/share/tsx/kernel-%s.release" % fl)
        have = open(rf).read().strip() if os.path.isfile(rf) else ""
        if have != rel:
            bad("%s: kernel-%s.release is '%s', the boot image has %s" % (fl, fl, have, rel))
            continue
        if not os.path.isdir(os.path.join(root, "lib/modules", rel)):
            bad("%s: no /lib/modules/%s in the rootfs" % (fl, rel))
            continue
        try:
            cpio = gzip.decompress(ramdisk)
        except (OSError, EOFError, zlib.error):
            bad("%s: the initramfs in the boot image is not gzip data" % fl)
            continue
        got = cpio_file(cpio, STAMP_PATH)
        got = got.decode().strip() if got is not None else ""
        if not got:
            bad("%s: the initramfs has no %s, so it is older than this checkout (rebuild the tsx-xx60-kernel-%s package)"
                % (fl, STAMP_PATH, fl))
            continue
        if got != want_stamp:
            bad("%s: the initramfs stamp is %s, this checkout has %s (rebuild the tsx-xx60-kernel-%s package)"
                % (fl, got[:12], want_stamp[:12], fl))
            continue
        print("check-boot-images: %s %s matches %s, initramfs %s" % (fl, rel, short, got[:12]))
    return 1 if failed else 0


sys.exit(main())
