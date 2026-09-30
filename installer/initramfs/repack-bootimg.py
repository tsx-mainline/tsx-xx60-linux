#!/usr/bin/env python3
"""repack-bootimg.py BASE.img RAMDISK.cpio.gz OUT.img

Replace only the ramdisk of an Android v0 boot image (xx60 format, see
kernel/mkimage.sh). The script copies the kernel (legacy uImage) and the second
payload (DTB) byte for byte. The header keeps every field except ramdisk_size
and the id (SHA1 over kernel, ramdisk, second and the sizes, as mkimage.sh
computes it). Afterwards the script checks that kernel and DTB are identical to
BASE. Use it to add installer stage 2 to the current p1 image without a kernel
rebuild."""
import hashlib, struct, sys

base, rdf, out = sys.argv[1:4]
d = open(base, 'rb').read()
FMT = '<8s10I16s512s32s'
h = list(struct.unpack_from(FMT, d, 0))
assert h[0] == b'ANDROID!', 'not an Android boot image'
ks, ka, rs, ra, ss, sa, ta, ps = h[1:9]
pad_n = lambda n: (n + ps - 1) // ps * ps
k = d[ps:ps + ks]
s = d[ps + pad_n(ks) + pad_n(rs): ps + pad_n(ks) + pad_n(rs) + ss]
assert k[:4] == bytes.fromhex('27051956'), 'kernel is not a legacy uImage'
r = open(rdf, 'rb').read()
assert r[:2] == b'\x1f\x8b', 'ramdisk is not gzip'
sha = hashlib.sha1()
for b in (k, r, s):
    sha.update(b); sha.update(struct.pack('<I', len(b)))
h[3] = len(r)
h[13] = sha.digest()
pad = lambda b: b + b'\0' * (-len(b) % ps)
img = pad(struct.pack(FMT, *h)) + pad(k) + pad(r) + (pad(s) if s else b'')
open(out, 'wb').write(img)
# verify
e = open(out, 'rb').read(); g = struct.unpack_from(FMT, e, 0)
assert e[ps:ps + g[1]] == k
assert e[ps + pad_n(g[1]):ps + pad_n(g[1]) + g[3]] == r
assert e[ps + pad_n(g[1]) + pad_n(g[3]):ps + pad_n(g[1]) + pad_n(g[3]) + g[5]] == s
assert [x for i, x in enumerate(g) if i not in (3, 13)] == [x for i, x in enumerate(struct.unpack_from(FMT, d, 0)) if i not in (3, 13)], 'header changed'
print('%s: kernel %d (sha256 %s, = base), ramdisk %d (new), second/DTB %d (sha256 %s, = base), cmdline %r' % (
    out, len(k), hashlib.sha256(k).hexdigest()[:12], len(r), len(s), hashlib.sha256(s).hexdigest()[:12],
    g[12].rstrip(b'\0').decode()))
