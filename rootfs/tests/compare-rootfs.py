#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare two rootfs tarballs file by file (docs/rootfs.md "Compare two builds").

  compare-rootfs.py OLD.tar.gz NEW.tar.gz [--expect FILE] [--list]
  compare-rootfs.py OLD.cpio.gz NEW.cpio.gz [--expect FILE] [--list]

A name that ends in .cpio.gz is read as a gzip-compressed cpio archive (the
initramfs). Any other name is read as a tar archive. For each path the script compares the type, the mode, the owner (numeric) and
the SHA-256 of the content (or the link target). It prints one line for each
difference:

  only-old PATH          the old image has it, the new one has not
  only-new PATH          the new image has it, the old one has not
  differ PATH what       what is one or more of type, mode, owner, content, target

Times are not compared. FILE holds one rule for each line: a regular
expression, then optional spaces and a reason. A difference whose path matches
a rule is "expected" and shows with the reason. The script prints the
unexpected differences first, then a count for each rule. The exit status is 1
when any difference is unexpected, and 0 otherwise. --list prints every
difference, also the expected ones.
"""
import gzip
import hashlib
import re
import stat
import sys
import tarfile


def index_cpio(path):
    """Read a gzip-compressed cpio archive (newc) as the initramfs has it."""
    out = {}
    data = gzip.open(path, "rb").read()
    pos = 0
    while True:
        if data[pos:pos + 6] != b"070701":
            raise ValueError("%s: not a newc cpio archive at %d" % (path, pos))
        h = [int(data[pos + 6 + 8 * i:pos + 14 + 8 * i], 16) for i in range(13)]
        ino, mode, uid, gid, nlink, mtime, size = h[:7]
        namesize = h[11]
        name = data[pos + 110:pos + 110 + namesize - 1].decode()
        pos = (pos + 110 + namesize + 3) & ~3
        body = data[pos:pos + size]
        pos = (pos + size + 3) & ~3
        if name == "TRAILER!!!":
            break
        name = name[2:] if name.startswith("./") else name
        if name in ("", "."):
            continue
        if stat.S_ISREG(mode):
            kind, content = "f", hashlib.sha256(body).hexdigest()
        elif stat.S_ISLNK(mode):
            kind, content = "l", body.decode()
        elif stat.S_ISDIR(mode):
            kind, content = "d", ""
        else:
            kind, content = "o", ""
        out[name] = (kind, mode & 0o7777, uid, gid, content)
    return out


def index(path):
    if path.endswith(".cpio.gz"):
        return index_cpio(path)
    out = {}
    with tarfile.open(path, "r|*") as tf:
        for m in tf:
            name = m.name[2:] if m.name.startswith("./") else m.name
            if name in ("", "."):
                continue
            if m.isreg():
                h = hashlib.sha256()
                f = tf.extractfile(m)
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    h.update(b)
                content = h.hexdigest()
            elif m.issym() or m.islnk():
                content = m.linkname
            else:
                content = ""
            kind = "f" if m.isreg() else "l" if m.issym() else "h" if m.islnk() else "d" if m.isdir() else "o"
            out[name] = (kind, m.mode & 0o7777, m.uid, m.gid, content)
    return out


def main():
    args = sys.argv[1:]
    expect = None
    show_all = False
    if "--expect" in args:
        i = args.index("--expect")
        expect = args[i + 1]
        del args[i:i + 2]
    if "--list" in args:
        args.remove("--list")
        show_all = True
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    rules = []
    if expect:
        for line in open(expect):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            pat, _, why = line.partition("  ")
            rules.append((re.compile(pat.strip()), why.strip() or pat.strip()))
    a, b = index(args[0]), index(args[1])
    diffs = []
    for p in sorted(set(a) | set(b)):
        if p not in b:
            diffs.append((p, "only-old", ""))
        elif p not in a:
            diffs.append((p, "only-new", ""))
        else:
            x, y = a[p], b[p]
            w = []
            if x[0] != y[0]:
                w.append("type")
            if x[1] != y[1]:
                w.append("mode %o>%o" % (x[1], y[1]))
            if (x[2], x[3]) != (y[2], y[3]):
                w.append("owner %d:%d>%d:%d" % (x[2], x[3], y[2], y[3]))
            if x[4] != y[4]:
                w.append("target" if x[0] == "l" else "content")
            if w:
                diffs.append((p, "differ", ",".join(w)))
    counts = {}
    unexpected = 0
    for p, k, w in diffs:
        why = None
        for rx, reason in rules:
            if rx.search(p):
                why = reason
                break
        if why is None:
            unexpected += 1
            print("UNEXPECTED %s %s %s" % (k, p, w))
        else:
            counts[why] = counts.get(why, 0) + 1
            if show_all:
                print("expected   %s %s %s  (%s)" % (k, p, w, why))
    print("files: old %d, new %d" % (len(a), len(b)))
    print("differences: %d, unexpected: %d" % (len(diffs), unexpected))
    for why, n in sorted(counts.items(), key=lambda t: -t[1]):
        print("  %5d  %s" % (n, why))
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
