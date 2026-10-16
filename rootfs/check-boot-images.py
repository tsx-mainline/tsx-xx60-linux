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

TSX_STAMP_OLDER (environment) lists stamps of older commits of this checkout,
as "<stamp>:<commit>" words (rootfs/initramfs-stamp-history.sh,
build-rootfs.sh with TSX_STAMP_OLDER_OK=1). An initramfs with one of these
stamps comes from an older version of the same initramfs sources. Only the
initramfs sources differ, so the script prints a warning with both stamps and
does not fail. This is the state between a change of the initramfs sources and
the kernel packages of the next release. Every other difference still fails.

  check-boot-images.py --image FLAVOR IMG [PIN_DIR]

checks one boot image (for example rootfs/out/tsxboot.img of a release
build): the kernel release must end with the pin of FLAVOR, and the initramfs
must have the stamp of this checkout. TSX_STAMP_OLDER does not apply.
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


def read_pin(pins, fl):
    """The 40 digit revision of KERNEL_REV.<fl>, or None after bad()."""
    pin = os.path.join(pins, "KERNEL_REV." + fl)
    if not os.path.isfile(pin):
        bad("no " + pin)
        return None
    lines = [l.strip() for l in open(pin) if not l.startswith("#") and l.strip()]
    rev = lines[0] if lines else ""
    if not re.fullmatch(r"[0-9a-f]{40}", rev):
        bad("%s has no 40 digit revision" % pin)
        return None
    return rev


def image_parts(fl, img, rev):
    """(release, stamp) of the boot image IMG, or None after bad()."""
    try:
        kernel, ramdisk = split_image(open(img, "rb").read())
    except ValueError as e:
        bad("%s: %s" % (fl, e))
        return None
    rel = kernel_release(kernel)
    if not rel:
        bad("%s: no kernel release found in the boot image" % fl)
        return None
    if not rel.endswith("-g" + rev[:12]):
        bad("%s: the boot image has kernel %s, the pin is %s (rebuild the tsx-xx60-kernel-%s package)"
            % (fl, rel, rev, fl))
        return None
    try:
        cpio = gzip.decompress(ramdisk)
    except (OSError, EOFError, zlib.error):
        bad("%s: the initramfs in the boot image is not gzip data" % fl)
        return None
    got = cpio_file(cpio, STAMP_PATH)
    return rel, (got.decode().strip() if got is not None else "")


def older_stamps():
    """{stamp: commit} from TSX_STAMP_OLDER."""
    out = {}
    for word in os.environ.get("TSX_STAMP_OLDER", "").split():
        stamp, _, commit = word.partition(":")
        if re.fullmatch(r"[0-9a-f]{64}", stamp):
            out[stamp] = commit
    return out


def check_image(argv):
    if len(argv) < 2 or argv[0] not in ("lts", "stable"):
        print("usage: check-boot-images.py --image lts|stable IMG [PIN_DIR]", file=sys.stderr)
        return 2
    fl, img = argv[0], argv[1]
    pins = argv[2] if len(argv) > 2 else os.path.join(HERE, "..", "kernel")
    want_stamp = this_stamp()
    rev = read_pin(pins, fl)
    parts = image_parts(fl, img, rev) if rev else None
    if parts:
        rel, got = parts
        if got != want_stamp:
            bad("%s: the initramfs stamp of %s is '%s', this checkout has %s"
                % (fl, img, got[:12], want_stamp[:12]))
        else:
            print("check-boot-images: %s %s matches %s, initramfs %s" % (fl, rel, rev[:12], got[:12]))
    return 1 if failed else 0


def this_stamp():
    return subprocess.run(["sh", os.path.join(HERE, "initramfs-stamp.sh")],
                          check=True, capture_output=True, text=True).stdout.strip()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--image":
        return check_image(sys.argv[2:])
    if len(sys.argv) < 2:
        print("usage: check-boot-images.py ROOT [PIN_DIR]", file=sys.stderr)
        return 2
    root = sys.argv[1]
    pins = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "kernel")
    want_stamp = this_stamp()
    older = older_stamps()
    for fl in ("lts", "stable"):
        rev = read_pin(pins, fl)
        if not rev:
            continue
        img = os.path.join(root, "boot", "tsxboot-emmc-%s.img" % fl)
        if not os.path.isfile(img):
            bad("%s: no /boot/tsxboot-emmc-%s.img in the rootfs" % (fl, fl))
            continue
        parts = image_parts(fl, img, rev)
        if not parts:
            continue
        rel, got = parts
        rf = os.path.join(root, "usr/share/tsx/kernel-%s.release" % fl)
        have = open(rf).read().strip() if os.path.isfile(rf) else ""
        if have != rel:
            bad("%s: kernel-%s.release is '%s', the boot image has %s" % (fl, fl, have, rel))
            continue
        if not os.path.isdir(os.path.join(root, "lib/modules", rel)):
            bad("%s: no /lib/modules/%s in the rootfs" % (fl, rel))
            continue
        if not got:
            bad("%s: the initramfs has no %s, so it is older than this checkout (rebuild the tsx-xx60-kernel-%s package)"
                % (fl, STAMP_PATH, fl))
            continue
        if got != want_stamp and got in older:
            # A workflow command: GitHub shows the line as a warning of the run.
            print("::warning title=initramfs stamp (%s)::the kernel package tsx-xx60-kernel-%s has the initramfs stamp %s "
                  "of the older commit %s. This checkout has the stamp %s. Only the initramfs sources differ "
                  "(rootfs/initramfs, install.sh, tsx-disk.sh, packages.pin). The kernel packages of the next "
                  "release carry the new stamp." % (fl, fl, got, older[got][:12], want_stamp))
            print("check-boot-images: %s %s matches %s, initramfs %s is OLDER than this checkout (%s)"
                  % (fl, rel, rev[:12], got[:12], want_stamp[:12]))
            continue
        if got != want_stamp:
            bad("%s: the initramfs stamp is %s, this checkout has %s (rebuild the tsx-xx60-kernel-%s package)"
                % (fl, got[:12], want_stamp[:12], fl))
            continue
        print("check-boot-images: %s %s matches %s, initramfs %s" % (fl, rel, rev[:12], got[:12]))
    return 1 if failed else 0


sys.exit(main())
