#!/usr/bin/env python3
"""Re-enable Chromium's OpenGL ES 3.0 -> 2.0 context fallback on Linux .

Chromium 146+ on Linux never lets the GPU info collector fall back from an ES 3.0
to an ES 2.0 context (ui/gl/gl_features.cc ShouldFallbackToSWIfGLES3NotSupported()
returns true unconditionally on Linux), so on a GLES 2.0-only GPU such as the
Mali-450 (lima) the GPU process logs

  eglCreateContext ES 3.0 failed with error EGL_BAD_ATTRIBUTE. ES version fallback is disabled.

(ui/gl/gl_context_egl.cc, GLContextEGL::InitializeImpl) and GPU init aborts.
The source is

  if (context_) return true;
  else if (!attribs.allow_es_version_fallback) {   // <- ldrb; cmp #0; beq LOG
    LOG(ERROR) << ... << ". ES version fallback is disabled.";
    return false;
  }
  ... fallback 3.1 -> 3.0 -> 2.0 ...

This tool replaces the "branch if allow_es_version_fallback == 0" with NOPs, so
the fallback path always runs. Nothing else changes.

Usage:
  patch-chromium.py [--sidecar F] [--dry-run] BINARY   patch (known builds only)
  patch-chromium.py --check  BINARY                    0 patched, 1 patchable, 2 unknown
  patch-chromium.py --revert [--sidecar F] BINARY      restore the original bytes
  patch-chromium.py --derive BINARY [--add]            find the site in a NEW build
                                                        (host only, needs numpy)

Safety: a build is patched only when the sha256 of the whole file is listed in
sigs.json (next to this script) AND the bytes around the site match the
recorded instruction signature. After patching, the sha256 must equal the
recorded patched hash. Anything else: exit 2, file untouched.
"""
import argparse, hashlib, json, os, shutil, struct, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
SIGS = os.path.join(HERE, "sigs.json")
ANCHOR = b". ES version fallback is disabled."


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_sigs():
    try:
        with open(SIGS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def read_at(path, off, n):
    with open(path, "rb") as f:
        f.seek(off)
        return f.read(n)


def write_at(path, off, data):
    with open(path, "r+b") as f:
        f.seek(off)
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def site_state(path, e):
    """'orig' | 'patched' | None, from the bytes at the site (context included)."""
    off = int(e["offset"], 16)
    ctx = bytes.fromhex(e["context_before"])
    n = len(bytes.fromhex(e["orig"]))
    got = read_at(path, off - len(ctx), len(ctx) + n)
    if got[:len(ctx)] != ctx:
        return None
    if got[len(ctx):] == bytes.fromhex(e["orig"]):
        return "orig"
    if got[len(ctx):] == bytes.fromhex(e["patched"]):
        return "patched"
    return None


def identify(path, sigs, digest=None):
    digest = digest or sha256(path)
    for key, e in sigs.items():
        if digest == e["sha256_orig"]:
            return key, e, "orig", digest
        if digest == e.get("sha256_patched"):
            return key, e, "patched", digest
    return None, None, None, digest


def sidecar_text(e, key, path):
    """Shell-sourceable KEY='value' lines (kiosk-session and tsx-chromium-es2 read them)."""
    rows = [("BINARY", path), ("BUILD", key), ("PACKAGE", e.get("package", "")),
            ("OFFSET", e["offset"]), ("VADDR", e.get("vaddr", "")),
            ("ORIG", e["orig"]), ("PATCHED", e["patched"]), ("CONTEXT", e["context_before"]),
            ("SHA256_ORIG", e["sha256_orig"]), ("SHA256_PATCHED", e["sha256_patched"]),
            ("DATE", time.strftime("%Y-%m-%dT%H:%M:%S%z"))]
    return "# written by patch-chromium.py : Chromium ES3->ES2 fallback patch\n" + \
        "".join("%s='%s'\n" % (k, str(v).replace("'", "")) for k, v in rows)


def cmd_patch(a, sigs):
    key, e, state, digest = identify(a.binary, sigs)
    if e is None:
        print(f"patch-chromium: UNKNOWN build (sha256 {digest}); not patched. "
              f"Derive the site on the host: patch-chromium.py --derive {a.binary} --add", file=sys.stderr)
        return 2
    if site_state(a.binary, e) != state:
        print("patch-chromium: sha256 known but the site bytes do not match; not patched", file=sys.stderr)
        return 2
    if state == "patched":
        print(f"patch-chromium: already patched ({key})")
    else:
        if a.dry_run:
            print(f"patch-chromium: would patch {a.binary} at {e['offset']}: {e['orig']} -> {e['patched']} ({key})")
            return 0
        write_at(a.binary, int(e["offset"], 16), bytes.fromhex(e["patched"]))
        new = sha256(a.binary)
        if new != e["sha256_patched"]:
            write_at(a.binary, int(e["offset"], 16), bytes.fromhex(e["orig"]))
            print(f"patch-chromium: patched sha256 {new} != expected; reverted", file=sys.stderr)
            return 2
        print(f"patch-chromium: patched {a.binary} at {e['offset']} ({e['orig']} -> {e['patched']}), "
              f"sha256 {e['sha256_orig'][:12]}.. -> {new[:12]}.. ({key})")
    sc = a.sidecar or a.binary + ".es2-patch"
    if not a.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(sc)), exist_ok=True)
        with open(sc, "w") as f:
            f.write(sidecar_text(e, key, a.target_path or a.binary))
        print(f"patch-chromium: sidecar {sc}")
    return 0


def cmd_check(a, sigs):
    key, e, state, digest = identify(a.binary, sigs)
    if e is None:
        print(f"unknown build, sha256 {digest}")
        return 2
    if site_state(a.binary, e) != state:
        print(f"{key}: sha256 {state} but site bytes differ (?)")
        return 2
    print(f"{key}: {'PATCHED (ES2 fallback enabled)' if state == 'patched' else 'unpatched, patchable'}"
          f" sha256 {digest}")
    return 0 if state == "patched" else 1


def cmd_revert(a, sigs):
    key, e, state, digest = identify(a.binary, sigs)
    if e is None:
        print(f"patch-chromium: unknown build (sha256 {digest}); refusing. Reinstall the package "
              "instead: apk fix chromium", file=sys.stderr)
        return 2
    if state == "patched":
        if site_state(a.binary, e) != "patched":
            print("patch-chromium: site bytes differ; refusing", file=sys.stderr)
            return 2
        write_at(a.binary, int(e["offset"], 16), bytes.fromhex(e["orig"]))
        if sha256(a.binary) != e["sha256_orig"]:
            print("patch-chromium: sha256 after revert does not match the original!", file=sys.stderr)
            return 2
        print(f"patch-chromium: reverted {a.binary} to the original ({key})")
    else:
        print(f"patch-chromium: {a.binary} is already the original ({key})")
    sc = a.sidecar or a.binary + ".es2-patch"
    if os.path.exists(sc):
        os.remove(sc)
        print(f"patch-chromium: removed {sc}")
    return 0


# ---------------------------------------------------------------- derivation
def elf_maps(data):
    """(vaddr, offset, filesz) of PT_LOAD segments and the .text section."""
    assert data[:4] == b"\x7fELF" and data[4] == 1 and data[5] == 1, "need ELF32 LE"
    e_phoff, e_shoff = struct.unpack_from("<II", data, 28)
    e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHHHH", data, 42)
    loads = []
    for i in range(e_phnum):
        p_type, p_off, p_vaddr, _, p_filesz = struct.unpack_from("<IIIII", data, e_phoff + i * e_phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_off, p_filesz))
    shs = [struct.unpack_from("<IIIIII", data, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    stroff = shs[e_shstrndx][4]
    text = None
    for sh in shs:
        name = data[stroff + sh[0]: data.index(b"\0", stroff + sh[0])]
        if name == b".text":
            text = (sh[3], sh[4], sh[5])  # addr, offset, size
    return loads, text


def off2va(loads, off):
    for va, fo, sz in loads:
        if fo <= off < fo + sz:
            return va + off - fo
    raise ValueError(hex(off))


def thumb_cond_branch_zero(hw1, hw2, addr):
    """If the instruction at addr is beq / beq.w / cbz, return (target, length)."""
    if (hw1 & 0xFF00) == 0xD000:                      # beq T1
        imm = hw1 & 0xFF
        imm = imm - 0x100 if imm & 0x80 else imm
        return addr + 4 + imm * 2, 2
    if (hw1 & 0xF500) == 0xB100:                      # cbz (not cbnz: bit 11 = 0)
        i = (hw1 >> 9) & 1
        imm5 = (hw1 >> 3) & 0x1F
        return addr + 4 + ((i << 6) | (imm5 << 1)), 2
    if (hw1 & 0xFBC0) == 0xF000 and (hw2 & 0xD000) == 0x8000:   # b<cond>.w T3
        cond = (hw1 >> 6) & 0xF
        if cond != 0:
            return None
        s = (hw1 >> 10) & 1
        imm6 = hw1 & 0x3F
        j1 = (hw2 >> 13) & 1
        j2 = (hw2 >> 11) & 1
        imm11 = hw2 & 0x7FF
        imm = (s << 20) | (j2 << 19) | (j1 << 18) | (imm6 << 12) | (imm11 << 1)
        if s:
            imm -= 1 << 21
        return addr + 4 + imm, 4
    return None


def cmd_derive(a, sigs):
    import numpy as np
    data = open(a.binary, "rb").read()
    loads, (TV, TO, TS) = elf_maps(data)
    hits = []
    i = data.find(ANCHOR)
    while i >= 0:
        hits.append(i)
        i = data.find(ANCHOR, i + 1)
    if len(hits) != 1:
        print(f"derive: anchor string found {len(hits)} times, need exactly 1", file=sys.stderr)
        return 2
    S = off2va(loads, hits[0])
    print(f"anchor {ANCHOR!r} at file {hits[0]:#x} vaddr {S:#x}")
    # Thumb PIC string reference: ldr rN, [pc, #imm] ... add rN, pc
    text = np.frombuffer(data, dtype=np.uint8, count=TS, offset=TO)
    h = text[:TS // 2 * 2].view("<u2")
    adds = np.nonzero((h & 0xFF78) == 0x4478)[0]            # add r0-r7, pc
    A = TV + adds.astype(np.int64) * 2
    need = (S - (A + 4)) & 0xFFFFFFFF
    xrefs = []
    for idx, a_va, n in zip(adds, A, need):
        reg = int(h[idx]) & 7
        # the matching ldr rN,[pc,#imm8*4] (T1: 0x4800 | rN<<8) within 16 halfwords before
        for k in range(1, 17):
            j = int(idx) - k
            if j < 0:
                break
            hw = int(h[j])
            if (hw & 0xFF00) == (0x4800 | (reg << 8)):
                pc = (TV + j * 2 + 4) & ~3
                lit = pc + (hw & 0xFF) * 4
                lo = lit - TV
                if 0 <= lo and lo + 4 <= TS and struct.unpack_from("<I", data, TO + lo)[0] == int(n):
                    xrefs.append(int(a_va))
                break
    print("string references:", [hex(x) for x in xrefs])
    cands = []
    for x in xrefs:
        # LOG(ERROR) block: starts with "movs r0, #2" (severity ERROR) somewhere
        # within 0x100 bytes before the reference; the gate branches to it.
        for va in range(x - 0x600, x, 2):
            o = TO + va - TV
            hw1, hw2 = struct.unpack_from("<HH", data, o)
            br = thumb_cond_branch_zero(hw1, hw2, va)
            if not br:
                continue
            tgt, ln = br
            if not (x - 0x100 <= tgt < x):
                continue
            if struct.unpack_from("<H", data, TO + tgt - TV)[0] != 0x2002:   # movs r0, #2
                continue
            before = data[o - 6:o]
            b_hw = struct.unpack_from("<HHH", before)
            # expect: ldrb.w rX, [rY, #imm] ; cmp rX, #0 ; beq   (or cbz rX)
            ldrb = (b_hw[0] & 0xFFF0) == 0xF890
            cmp0 = (b_hw[2] & 0xF8FF) == 0x2800
            kind = "beq" if ln == 2 and (hw1 & 0xFF00) == 0xD000 else ("cbz" if ln == 2 else "beq.w")
            cands.append(dict(vaddr=va, offset=o, len=ln, target=tgt, kind=kind,
                              orig=data[o:o + ln].hex(), before=before.hex(), ldrb=ldrb, cmp0=cmp0))
    for c in cands:
        print(f"candidate {c['kind']} at vaddr {c['vaddr']:#x} file {c['offset']:#x} -> {c['target']:#x} "
              f"bytes {c['orig']} (before {c['before']}, ldrb.w={c['ldrb']} cmp#0={c['cmp0']})")
    good = [c for c in cands if (c["kind"] == "cbz") or (c["ldrb"] and c["cmp0"])]
    if len(good) != 1:
        print(f"derive: {len(good)} candidates with the expected shape, need exactly 1: do it by hand "
              "(objdump, see README.md)", file=sys.stderr)
        return 2
    c = good[0]
    nop = "00bf" * (c["len"] // 2)
    ctx = c["before"] if c["kind"] != "cbz" else data[c["offset"] - 4:c["offset"]].hex()
    orig_sha = hashlib.sha256(data).hexdigest()
    pdata = bytearray(data)
    pdata[c["offset"]:c["offset"] + c["len"]] = bytes.fromhex(nop)
    patched_sha = hashlib.sha256(pdata).hexdigest()
    od = shutil.which("arm-linux-gnueabihf-objdump") or shutil.which("arm-none-eabi-objdump") or shutil.which("llvm-objdump")
    if od:
        lo, hi = c["vaddr"] - 8, c["target"] + 0x70
        out = subprocess.run([od, "-d", "-M", "force-thumb", f"--start-address={lo:#x}", f"--stop-address={hi:#x}", a.binary]
                             if "llvm" not in od else
                             [od, "-d", "--triple=thumbv7a", f"--start-address={lo:#x}", f"--stop-address={hi:#x}", a.binary],
                             capture_output=True, text=True).stdout
        print(f"--- {os.path.basename(od)} around the site:")
        print("\n".join(l for l in out.splitlines() if l.strip().startswith(tuple("0123456789abcdef")) and ":" in l))
    key = a.name or f"chromium-{orig_sha[:12]}"
    entry = {"package": a.package or "", "sha256_orig": orig_sha, "sha256_patched": patched_sha,
             "offset": hex(c["offset"]), "vaddr": hex(c["vaddr"]), "kind": c["kind"],
             "target": hex(c["target"]), "context_before": ctx, "orig": c["orig"], "patched": nop}
    print(json.dumps({key: entry}, indent=2))
    if a.add:
        sigs[key] = entry
        with open(SIGS, "w") as f:
            json.dump(sigs, f, indent=2)
            f.write("\n")
        print(f"added {key} to {SIGS}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("binary")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true")
    g.add_argument("--revert", action="store_true")
    g.add_argument("--derive", action="store_true")
    p.add_argument("--sidecar", help="sidecar file (default BINARY.es2-patch)")
    p.add_argument("--target-path", help="path of BINARY on the target, written to the sidecar")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--add", action="store_true", help="--derive: store the entry in sigs.json")
    p.add_argument("--name", help="--derive: key for sigs.json, e.g. alpine-v3.24-armv7-chromium-152.0.7977.82-r0")
    p.add_argument("--package", help="--derive: package description")
    a = p.parse_args()
    if not os.path.isfile(a.binary):
        print(f"patch-chromium: no such file {a.binary}", file=sys.stderr)
        return 2
    sigs = load_sigs()
    if a.check:
        return cmd_check(a, sigs)
    if a.revert:
        return cmd_revert(a, sigs)
    if a.derive:
        return cmd_derive(a, sigs)
    return cmd_patch(a, sigs)


if __name__ == "__main__":
    sys.exit(main())
