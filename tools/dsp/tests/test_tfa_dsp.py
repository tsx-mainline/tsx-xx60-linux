#!/usr/bin/env python3
"""Host tests for tools/tfa_dsp.py.

1. Container/file integrity for every vendor variant (CRCs, sizes, message
   boundaries: config 55 words, speaker 141 words, preset 29 words, EQ 6 words).
2. Transaction-exact comparison of our cold start + unmute plan with the
   vendor climax_hostsx 3.1 trace against NXP's TFA9890 simulator
   (golden/start-<variant>.trace, produced by tools/climax.sh -d dummy90).
Run: python3 tests/test_tfa_dsp.py
"""
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
P16 = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(P16, "tools"))
import tfa_dsp as T  # noqa: E402

VENDOR = os.path.join(P16, "..", "..", "..", "android-crestron", "device_amlogic_common",
                      "audio", "tfa9890")
VARIANTS = ["settings_yushan", "settings_yushan_2nd", "settings_yushan_3rd"]


def load(v):
    with open(os.path.join(VENDOR, v, "stereo.cnt"), "rb") as fh:
        return T.Container(fh.read(), v)


def golden_ops(path):
    """parse climax -t output into [("w", addr, bytes) | ("r", addr, reg, n)]"""
    ops, pending = [], None
    rx = re.compile(r"^I2C ([wWR]) \[\s*(\d+)\]: (.*)$")
    with open(path) as fh:
        lines = fh.read().splitlines()
    for line in lines:
        m = rx.match(line.strip())
        if not m:
            continue
        kind, n, data = m.group(1), int(m.group(2)), [int(x, 16) for x in m.group(3).split()]
        assert len(data) == n, line
        addr = data[0] >> 1
        if kind == "w":
            ops.append(("w", addr, bytes(data[1:])))
        elif kind == "W":            # register pointer for the following read
            pending = (addr, data[1])
        else:
            assert pending and pending[0] == addr, line
            ops.append(("r", addr, pending[1], n - 1))
            pending = None
    return ops


class ContainerTests(unittest.TestCase):
    def test_variants(self):
        for v in VARIANTS:
            with self.subTest(v=v):
                c = load(v)
                self.assertTrue(c.crc_ok)
                self.assertEqual([d["addr"] for d in c.devices], [0x34, 0x36])
                for d in c.devices:
                    p = d["patch"]
                    self.assertEqual(p.patch_rev, 0x80)
                    self.assertEqual((p.rom_addr, p.rom_value), (0x20c6, 0x000031))
                    self.assertEqual(len(p.chunks), 22)
                    self.assertEqual(2 * len(p.chunks) + sum(len(x) for x in p.chunks) + 6,
                                     len(p.body))
                    self.assertEqual(p.chunks[-1], bytes([0x70, 0x00, 0x00]))  # DSP reset release
                    self.assertEqual(len(c.dev_file(d, "config").payload), 55 * 3)
                    self.assertEqual(len(c.dev_file(d, "speaker").payload), 141 * 3)
                    self.assertEqual(len(d["profile_offs"]), 2)
                    for i in range(2):
                        vs = c.dev_profile(d, i)["files"][0]
                        self.assertEqual(len(vs.steps), 11)
                        for s in vs.steps:
                            self.assertEqual(len(s["preset"]), 87)
                            self.assertEqual(len(s["filters"]), 10)
                            for f in s["filters"]:
                                self.assertEqual(len(T.eq_payload(f)), 18)
                chs = [dict(d["bitfields"])[0x0431] for d in c.devices]
                self.assertEqual(chs, [1, 2])       # left amp = I2S left, right = right

    def test_files_match_loose_copies(self):
        """the container embeds the same patch/config/speaker as the loose files"""
        for v in VARIANTS:
            c = load(v)
            d = c.devices[0]
            for f in [d["patch"]] + d["files"]:
                with open(os.path.join(VENDOR, v, f.name), "rb") as fh:
                    loose = fh.read()
                self.assertEqual(f.raw, loose, "%s %s" % (v, f.name))

    def test_variants_differ_only_in_speaker_and_vstep(self):
        cs = [load(v) for v in VARIANTS]
        for d in range(2):
            p = [c.devices[d]["patch"].raw for c in cs]
            cfg = [c.dev_file(c.devices[d], "config").raw for c in cs]
            spk = [c.dev_file(c.devices[d], "speaker").payload for c in cs]
            self.assertEqual(len(set(p)), 1)
            self.assertEqual(len(set(cfg)), 1)
            self.assertEqual(len(set(spk)), 3)

    def test_bitfield_math(self):
        self.assertEqual(T.bf_set(0x888b, 0x0450, 1), 0x88ab)      # CHS3
        self.assertEqual(T.bf_set(0x825d, 0x0940, 0), 0x824d)      # DCA
        self.assertEqual(T.bf_set(0x3ec3, 0x0a02, 1), 0x3ec1)      # DOLS
        self.assertEqual(T.bf_set(0x83e6, 0x0733, 8), 0x83c6)      # DCMCC
        self.assertEqual(T.vol_from_att(-8.5), 17)


class I2CDevTests(unittest.TestCase):
    def test_rdwr_marshalling(self):
        """I2C_RDWR message building, with the ioctl mocked (no /dev/i2c)"""
        import ctypes
        import types
        dev = T.I2CDev.__new__(T.I2CDev)
        T.I2CDev.__init__.__globals__  # noqa
        # build the ctypes types the same way __init__ does, without opening a bus
        class Msg(ctypes.Structure):
            _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                        ("len", ctypes.c_uint16), ("buf", ctypes.c_void_p)]

        class RdWr(ctypes.Structure):
            _fields_ = [("msgs", ctypes.POINTER(Msg)), ("nmsgs", ctypes.c_uint32)]
        seen = []

        def ioctl(fd, req, arg):
            self.assertEqual(req, 0x0707)
            for i in range(arg.nmsgs):
                m = arg.msgs[i]
                if m.flags & 1:
                    ctypes.memmove(m.buf, bytes(range(1, m.len + 1)), m.len)
                    seen.append(("r", m.addr, m.len))
                else:
                    seen.append(("w", m.addr, ctypes.string_at(m.buf, m.len)))
        dev.ct, dev.fcntl, dev.fd, dev.Msg, dev.RdWr, dev.log = (
            ctypes, types.SimpleNamespace(ioctl=ioctl), -1, Msg, RdWr, None)
        dev.write(0x34, b"\x09\x82\x6c")
        self.assertEqual(dev.read(0x36, 0x00, 2), b"\x01\x02")
        self.assertEqual(seen, [("w", 0x34, b"\x09\x82\x6c"), ("w", 0x36, b"\x00"), ("r", 0x36, 2)])


class GoldenTraceTests(unittest.TestCase):
    def compare(self, variant, trace, profile=0, vstep=0):
        c = load(variant)
        fake = T.FakeTfa9890()
        tfas = [T.Tfa(fake, a) for a in (0x34, 0x36)]
        for t in tfas:
            T.cold_start(c, t, profile, vstep, say=lambda s: None)
        for t in tfas:
            T.unmute(t)
        gold = golden_ops(os.path.join(P16, "golden", trace))
        self.assertEqual(len(fake.ops), len(gold), "transaction count")
        for i, (a, b) in enumerate(zip(fake.ops, gold)):
            self.assertEqual(a, b, "transaction %d differs" % i)
        return len(gold), sum(len(o[2]) for o in gold if o[0] == "w")

    def test_start_traces(self):
        for v in VARIANTS:
            with self.subTest(v=v):
                n, nb = self.compare(v, "start-%s.trace" % v)
                pass
            with self.subTest(v=v):
                print("\n  %s: %d transactions identical to vendor trace (%d bytes written)"
                      % (v, n, nb), end="")


    def test_vstep5_trace(self):
        n, _ = self.compare("settings_yushan", "op_v_5.trace", vstep=5)
        print("\n  settings_yushan vstep 5 (-8.5 dB): %d transactions identical" % n, end="")


if __name__ == "__main__":
    unittest.main(verbosity=2)
