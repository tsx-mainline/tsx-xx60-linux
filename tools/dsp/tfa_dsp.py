#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""TFA9890 (NXP "TFA1" family, CoolFlux DSP) container parser and loader.

Reimplements, for the TFA9890 only, what the vendor Android library
(libjbl_acoustic.so + NXP nxpTfaHost "climax 3.1") does on the TSW-1060:
parse the NXP container (stereo.cnt, "PM1_00"), then per amplifier:
I2C reset, container bitfields, power on, wait for the DSP subsystem,
ROM check + patch, soft mute, config / speaker / preset / EQ messages,
SBSL=1 ("configured"), calibration check, and finally unmute.

The register/xmem/RPC sequence is verified byte for byte against a trace of
the vendor climax_hostsw run under qemu against NXP's own TFA9890 simulator
("-d dummy90"), see tests/test_tfa_dsp.py and golden/*.trace.

Protocol facts are taken from the vendor trace and the GPL-2.0 NXP tfa98xx
driver headers (github.com/nxpsw/tfa98xx: tfa98xx_parameters.h,
tfa1_tfafieldnames.h, tfa9890_tfafieldnames.h).

Runs on the panel (Alpine armv7, python3 stdlib only; I2C via /dev/i2c-N
with the I2C_RDWR ioctl, which also works on addresses bound to the
tfa989x kernel driver) and on the host (parse, plan, dry-run).

Usage:
  tfa_dsp.py info  CNT
  tfa_dsp.py plan  CNT [--profile N] [--vstep N] [--dev 0x34]   (simulated, no I2C)
  tfa_dsp.py start CNT --bus 1 [--profile N] [--vstep N] [--dry-run] [--yes]
  tfa_dsp.py stop  --bus 1
  tfa_dsp.py status --bus 1 [--state]
  tfa_dsp.py vstep CNT N --bus 1 [--profile N]
  tfa_dsp.py bypass --bus 1           (mainline-driver equivalent bypass, fallback)
  tfa_dsp.py spkcmp CNT... --dump FILE (compare a 423-byte speaker model read-back)
"""

import argparse
import struct
import sys
import time
import zlib

# ---------------------------------------------------------------- registers
REG_STATUS, REG_BATV, REG_TEMP, REG_REV, REG_I2S, REG_BATPROT = 0, 1, 2, 3, 4, 5
REG_AUDIO, REG_DCDC, REG_SPKCAL, REG_SYS, REG_I2SSEL = 6, 7, 8, 9, 0x0a
REG_KEY, REG_PLL59, REG_MTP0, REG_MTP84 = 0x40, 0x59, 0x80, 0x84
REG_CF_CTRL, REG_CF_MAD, REG_CF_MEM, REG_CF_STATUS = 0x70, 0x71, 0x72, 0x73

TFA9890_REV = 0x80

# status register 0x00 bits (tfa1_tfafieldnames.h)
STATUS_BITS = ["VDDS", "PLLS", "OTDS", "OVDS", "UVDS", "OCDS", "CLKS", "CLIPS",
               "MTPB", "NOCLK", "SPKS", "ACS", "SWS", "WDS", "AMPS", "AREFS"]
ST_CLKS, ST_ACS, ST_AMPS, ST_AREFS, ST_MTPB = 1 << 6, 1 << 11, 1 << 14, 1 << 15, 1 << 8
# system control 0x09
SYS_BITS = {0: "PWDN", 1: "I2CR", 2: "CFE", 3: "AMPE", 4: "DCA", 5: "SBSL",
            6: "AMPC", 7: "DCDIS", 8: "PSDR", 11: "CCFD", 14: "IPLL"}
SYS_PWDN, SYS_I2CR, SYS_CFE, SYS_AMPE, SYS_DCA, SYS_SBSL, SYS_AMPC = \
    1, 2, 4, 8, 16, 32, 64
AUDIO_CFSM = 1 << 5          # 0x650 soft mute in CoolFlux
# CF_CONTROLS 0x70 fields
CF_RST, CF_DMEM_SHIFT, CF_AIF, CF_INT, CF_REQCMD = 1, 1, 1 << 3, 1 << 4, 1 << 8
DMEM_PMEM, DMEM_XMEM, DMEM_YMEM, DMEM_IOMEM = 0, 1, 2, 3
CF_ACKCMD = 1 << 8           # 0x7380

# DSP module / parameter ids (TFA1 SpeakerBoost firmware)
MODULE_SPEAKERBOOST, MODULE_BIQUAD = 1, 2
SB_PARAM_SET_LSMODEL, SB_PARAM_SET_PRESET, SB_PARAM_SET_CONFIG = 0x06, 0x0d, 0x0e
SB_PARAM_GET_CONFIG, SB_PARAM_GET_LSMODEL, SB_PARAM_GET_STATE = 0x80, 0x86, 0xc0
XMEM_CAL_DONE = 0xe7          # read by the vendor after SBSL (calibration done)
XMEM_ROM_CHECK_DEFAULT = 0x20c6

RPC_STATUS = {0: "Ok", 1: "busy", 2: "invalid module id", 3: "invalid param id",
              4: "invalid channel config", 5: "invalid sequence",
              6: "invalid parameter", 7: "buffer overflow",
              8: "calibration busy", 9: "calibration failed"}

# bitfield ids used by the container (datasheet names, tfa1 + tfa9890 tables)
BF_NAMES = {
    0x0991: "DCCV", 0x0431: "CHS12", 0x0a02: "DOLS", 0x0a32: "DORS",
    0x0450: "CHS3", 0x07b0: "DCSR", 0x07a0: "DCIE", 0x0733: "DCMCC",
    0x0702: "DCVO", 0x0940: "DCA", 0x0a91: "SPKR", 0x04c3: "I2SSR",
    0x0461: "CHSA", 0x0687: "VOL", 0x0650: "CFSM", 0x0900: "PWDN",
    0x0930: "AMPE", 0x0950: "SBSL", 0x0920: "CFE", 0x0960: "AMPC",
}


def bf_split(bf):
    """bitfield id 0xRRPL: register RR, bit position P, length L+1"""
    return (bf >> 8) & 0xff, (bf >> 4) & 0xf, (bf & 0xf) + 1


def bf_set(regval, bf, value):
    _, pos, ln = bf_split(bf)
    mask = ((1 << ln) - 1) << pos
    return (regval & ~mask) | ((value << pos) & mask)


def bf_get(regval, bf):
    _, pos, ln = bf_split(bf)
    return (regval >> pos) & ((1 << ln) - 1)


# ---------------------------------------------------------------- container
DSC = ["device", "profile", "register", "string", "file", "patch", "marker",
       "mode", "set_input_select", "set_output_select", "set_program_config",
       "set_lag_w", "set_gains", "set_vbat_factors", "set_senses_cal",
       "set_senses_delay", "bit_field", "default", "livedata",
       "livedata_string", "group", "cmd", "set_mb_drc", "filter", "no_init",
       "features", "cf_mem", "set_fw_use_case", "set_vddp_config"]
DSC_DEVICE, DSC_PROFILE, DSC_STRING, DSC_FILE, DSC_PATCH, DSC_MARKER = 0, 1, 3, 4, 5, 6
PROFID = 0x1234


class CntError(Exception):
    pass


def cstr(b):
    return b.split(b"\0", 1)[0].decode("latin-1")


class NxpFile:
    """NXP tuning file with the 36-byte tfa_header (patch/config/speaker/vstep)"""
    HDR = struct.Struct("<2s2s2sHI8s8s8s")   # 36 bytes

    def __init__(self, name, data):
        if len(data) < self.HDR.size:
            raise CntError("%s: too short" % name)
        (self.id, self.version, self.subversion, self.size, self.crc,
         cust, app, typ) = self.HDR.unpack_from(data)
        self.id = self.id.decode("latin-1")
        self.version = self.version.decode("latin-1")
        self.subversion = self.subversion.decode("latin-1")
        self.customer, self.application, self.type = cstr(cust), cstr(app), cstr(typ)
        self.name = name
        self.raw = bytes(data)
        # VP2 volume-step files carry size 0 in the vendor drop: CRC covers the file
        if self.size not in (0, len(data)):
            raise CntError("%s: header size %d != file size %d" % (name, self.size, len(data)))
        crc = zlib.crc32(self.raw[12:]) & 0xffffffff
        self.crc_ok = crc == self.crc
        if not self.crc_ok:
            raise CntError("%s: CRC mismatch (hdr %08x calc %08x)" % (name, self.crc, crc))
        self.body = self.raw[self.HDR.size:]
        self.kind = {"PA": "patch", "CO": "config", "SP": "speaker", "VP": "vstep",
                     "PR": "preset", "EQ": "eq", "DR": "drc", "MG": "msg"}.get(self.id, "?")
        self._parse()

    def _parse(self):
        b = self.body
        if self.kind == "patch":
            if len(b) < 6:
                raise CntError("patch header missing")
            self.patch_rev = b[0]
            self.rom_addr = (b[1] << 8) | b[2]
            self.rom_value = (b[3] << 16) | (b[4] << 8) | b[5]
            self.chunks = []
            i = 6
            while i < len(b):
                if i + 2 > len(b):
                    raise CntError("patch: truncated chunk length at %d" % i)
                n = b[i] | (b[i + 1] << 8)
                i += 2
                if n == 0 or i + n > len(b):
                    raise CntError("patch: chunk of %d bytes at %d exceeds file" % (n, i))
                self.chunks.append(b[i:i + n])
                i += n
        elif self.kind == "config":
            if len(b) % 3:
                raise CntError("config not a multiple of 24-bit words")
            self.payload = b
        elif self.kind == "speaker":
            (nick, vendor, typ, h, w, d, ohm1, ohm2) = struct.unpack_from("<8s16s8sBBBBB", b)
            self.spk_name, self.spk_vendor, self.spk_type = cstr(nick), cstr(vendor), cstr(typ)
            self.dims = (h, w, d)
            self.ohm = (ohm1, ohm2)
            self.payload = b[37:]
            if len(self.payload) != 423:
                raise CntError("speaker payload %d != 423 bytes" % len(self.payload))
        elif self.kind == "vstep":
            if self.version != "2_":
                raise CntError("only VP2 volume step files supported (got %s)" % self.version)
            nsteps, self.samplerate = b[0], b[1]
            step = 4 + 87 + 10 * 32
            if 2 + nsteps * step != len(b):
                raise CntError("vstep size %d != 2 + %d*%d" % (len(b), nsteps, step))
            self.steps = []
            for s in range(nsteps):
                o = 2 + s * step
                att = struct.unpack_from("<f", b, o)[0]
                preset = b[o + 4:o + 91]
                filters = []
                for f in range(10):
                    fo = o + 91 + f * 32
                    bq = b[fo:fo + 18]
                    en, ftype = b[fo + 18], b[fo + 19]
                    freq, q, gain = struct.unpack_from("<fff", b, fo + 20)
                    filters.append(dict(biquad=bq, enabled=en, type=ftype,
                                        freq=freq, q=q, gain=gain))
                self.steps.append(dict(att=att, preset=preset, filters=filters))


class Container:
    HDR = struct.Struct("<2s2s2sIIH8s8s8sHH")   # 44 bytes (PM1_00: no nlivedata)

    def __init__(self, data, name="container"):
        self.raw = bytes(data)
        (idb, ver, sub, self.size, self.crc, self.rev, cust, app, typ,
         self.ndev, self.nprof) = self.HDR.unpack_from(self.raw)
        if idb != b"PM":
            raise CntError("%s: not an NXP container (id %r)" % (name, idb))
        self.version = (ver + sub).decode("latin-1")
        self.customer, self.application, self.type = cstr(cust), cstr(app), cstr(typ)
        if self.size != len(self.raw):
            raise CntError("%s: size field %d != file size %d" % (name, self.size, len(self.raw)))
        calc = zlib.crc32(self.raw[14:self.size]) & 0xffffffff
        self.crc_ok = calc == self.crc
        if not self.crc_ok:
            raise CntError("%s: container CRC mismatch (hdr %08x calc %08x)" % (name, self.crc, calc))
        self.index_off = self.HDR.size
        self.devices = [self._device(i) for i in range(self.ndev)]
        self.profiles = self._profiles()

    def u32(self, off):
        return struct.unpack_from("<I", self.raw, off)[0]

    def dsc(self, off):
        v = self.u32(off)
        return v & 0xffffff, v >> 24

    def string(self, off):
        end = self.raw.index(b"\0", off)
        return self.raw[off:end].decode("latin-1")

    def file_at(self, off):
        noff, ntype = self.dsc(off)
        name = self.string(noff) if ntype == DSC_STRING else "?"
        size = self.u32(off + 4)
        return NxpFile(name, self.raw[off + 8:off + 8 + size])

    def _items(self, off, count):
        items = []
        for k in range(count):
            v = self.u32(off + 4 * k)
            typ = v >> 24
            if typ & 0x80:          # bitfield: value u16, field u16 (| 0x8000)
                items.append(("bitfield", (v >> 16) & 0x7fff, v & 0xffff))
                continue
            o = v & 0xffffff
            if typ == DSC_FILE:
                items.append(("file", self.file_at(o)))
            elif typ == DSC_PATCH:
                items.append(("patch", self.file_at(o)))
            elif typ == DSC_PROFILE:
                items.append(("profile", o))
            elif typ == DSC_STRING:
                items.append(("string", self.string(o)))
            else:
                items.append((DSC[typ] if typ < len(DSC) else "type%d" % typ, o))
        return items

    def _device(self, i):
        off, typ = self.dsc(self.index_off + 4 * i)
        if typ != DSC_DEVICE:
            raise CntError("index %d is not a device list (type %d)" % (i, typ))
        length, bus, dev, func = struct.unpack_from("<BBBB", self.raw, off)
        devid = self.u32(off + 4)
        noff, _ = self.dsc(off + 8)
        d = dict(off=off, length=length, bus=bus, addr=dev, func=func, devid=devid,
                 name=self.string(noff), items=self._items(off + 12, length))
        d["end"] = off + 12 + 4 * length
        d["bitfields"] = [(f, v) for k, f, v in (x for x in d["items"] if x[0] == "bitfield")]
        d["patch"] = next((x[1] for x in d["items"] if x[0] == "patch"), None)
        d["files"] = [x[1] for x in d["items"] if x[0] == "file"]
        d["profile_offs"] = [x[1] for x in d["items"] if x[0] == "profile"]
        return d

    def _profiles(self):
        profs = {}
        off = self.devices[-1]["end"]           # 1st profile follows last device list
        while off + 8 <= len(self.raw):
            v = self.u32(off)
            length, pid = v & 0xff, v >> 8
            if pid != PROFID:
                break
            noff, _ = self.dsc(off + 4)
            items = self._items(off + 8, length - 1)
            profs[off] = dict(off=off, name=self.string(noff), items=items,
                              bitfields=[(x[1], x[2]) for x in items if x[0] == "bitfield"],
                              files=[x[1] for x in items if x[0] == "file"])
            off += 8 + 4 * (length - 1)
        return profs

    def device(self, addr):
        for d in self.devices:
            if d["addr"] == addr:
                return d
        raise CntError("no device 0x%02x in container" % addr)

    def dev_profile(self, dev, idx):
        return self.profiles[dev["profile_offs"][idx]]

    def dev_file(self, dev, kind):
        for f in dev["files"]:
            if f.kind == kind:
                return f
        return None


# ---------------------------------------------------------------- I2C layers
class I2CDev:
    """/dev/i2c-N via I2C_RDWR (works on addresses bound to a kernel driver)."""
    I2C_RDWR, I2C_M_RD = 0x0707, 0x0001

    def __init__(self, bus):
        import ctypes
        import fcntl
        import os
        self.ct, self.fcntl = ctypes, fcntl
        self.fd = os.open("/dev/i2c-%d" % bus, os.O_RDWR)

        class Msg(ctypes.Structure):
            _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                        ("len", ctypes.c_uint16), ("buf", ctypes.c_void_p)]

        class RdWr(ctypes.Structure):
            _fields_ = [("msgs", ctypes.POINTER(Msg)), ("nmsgs", ctypes.c_uint32)]
        self.Msg, self.RdWr = Msg, RdWr
        self.log = None

    def _xfer(self, msgs):
        ct = self.ct
        arr = (self.Msg * len(msgs))()
        bufs = []
        for i, (addr, rd, data) in enumerate(msgs):
            b = ct.create_string_buffer(bytes(data), len(data)) if not rd else ct.create_string_buffer(data)
            bufs.append(b)
            arr[i].addr, arr[i].flags, arr[i].len = addr, self.I2C_M_RD if rd else 0, len(b) if not rd else data
            arr[i].buf = ct.cast(b, ct.c_void_p)
        req = self.RdWr(arr, len(msgs))
        self.fcntl.ioctl(self.fd, self.I2C_RDWR, req)
        return [bytes(b.raw[:m[2]]) if m[1] else None for b, m in zip(bufs, msgs)]

    def write(self, addr, data):
        if self.log:
            self.log.append(("w", addr, bytes(data)))
        self._xfer([(addr, False, bytes(data))])

    def read(self, addr, reg, n):
        r = self._xfer([(addr, False, bytes([reg])), (addr, True, n)])[1]
        if self.log is not None:
            self.log.append(("r", addr, bytes([reg]), n, r))
        return r


class DryRun:
    """Prints writes, performs reads for real (or not at all with --no-read)."""

    def __init__(self, inner=None, out=sys.stdout):
        self.inner, self.out, self.writes = inner, out, 0

    def write(self, addr, data):
        self.writes += 1
        self.out.write("DRY W 0x%02x [%3d] %s\n" % (addr, len(data), " ".join("%02x" % x for x in data[:24])
                                                     + (" ..." if len(data) > 24 else "")))

    def read(self, addr, reg, n):
        if self.inner is None:
            raise CntError("dry-run without device cannot read")
        return self.inner.read(addr, reg, n)


class FakeTfa9890:
    """Minimal TFA9890 model with the same power-on values and replies as NXP's
    climax "dummy90" simulator, so plans can be compared with golden traces."""
    DEFAULTS = {0x00: 0x0a5d, 0x03: 0x0080, 0x04: 0x888b, 0x06: 0x001f, 0x07: 0x8fe6,
                0x09: 0x825d, 0x0a: 0x3ec3, 0x59: 0x0000, 0x70: 0x0000, 0x80: 0x0002,
                0x84: 0x1234}

    def __init__(self, addrs=(0x34, 0x36)):
        self.regs = {a: dict(self.DEFAULTS) for a in addrs}
        self.xmem = {a: {XMEM_ROM_CHECK_DEFAULT: 0x000031, XMEM_CAL_DONE: 0x010000} for a in addrs}
        self.mad = {a: 0 for a in addrs}
        self.ops = []                     # ("w", addr, bytes) / ("r", addr, reg, n)

    def write(self, addr, data):
        self.ops.append(("w", addr, bytes(data)))
        r = self.regs[addr]
        reg = data[0]
        payload = data[1:]
        while payload:
            if reg == REG_CF_MEM:          # streaming into DSP memory
                for i in range(0, len(payload) - 2, 3):
                    self.xmem[addr][self.mad[addr]] = int.from_bytes(payload[i:i + 3], "big")
                    self.mad[addr] += 1
                return
            v = (payload[0] << 8) | payload[1]
            payload = payload[2:]
            if reg == REG_SYS and v & SYS_I2CR:
                self.regs[addr] = dict(self.DEFAULTS)
                self.regs[addr][0x00] = 0x0a5d
                r = self.regs[addr]
            else:
                r[reg] = v
            if reg == REG_SYS:
                r[0] = (r[0] | 0x8002) if not v & SYS_PWDN else r[0]
                if v & SYS_SBSL:
                    r[0] &= ~ST_ACS
            if reg == REG_CF_MAD:
                self.mad[addr] = v
            reg += 1

    def read(self, addr, reg, n):
        self.ops.append(("r", addr, reg, n))
        if reg == REG_CF_MEM:
            out = b""
            for _ in range(n // 3):
                out += self.xmem[addr].get(self.mad[addr], 0).to_bytes(3, "big")
                self.mad[addr] += 1
            return out
        if reg == REG_CF_STATUS:
            return b"\x03\x00"
        v = self.regs[addr].get(reg, 0)
        return bytes([v >> 8, v & 0xff])


# ---------------------------------------------------------------- device ops
class Tfa:
    def __init__(self, bus, addr, verbose=False, log=None):
        self.bus, self.addr, self.verbose = bus, addr, verbose
        self.log = log if log is not None else (lambda s: None)

    def rd(self, reg):
        b = self.bus.read(self.addr, reg, 2)
        return (b[0] << 8) | b[1]

    def wr(self, reg, val):
        self.bus.write(self.addr, bytes([reg, (val >> 8) & 0xff, val & 0xff]))

    def set_bf(self, bf, value):
        reg = bf_split(bf)[0]
        self.wr(reg, bf_set(self.rd(reg), bf, value))

    def mem_read(self, dmem, addr, nwords):
        ctl = self.rd(REG_CF_CTRL)
        ctl = (ctl & ~(3 << CF_DMEM_SHIFT) & ~CF_AIF) | (dmem << CF_DMEM_SHIFT)
        self.wr(REG_CF_CTRL, ctl)
        self.wr(REG_CF_MAD, addr)
        return self.bus.read(self.addr, REG_CF_MEM, 3 * nwords)

    def system_stable(self):
        """tfa9890_dsp_system_stable(): AMPS, or AREFS+CLKS, MTPB clear, MTP 0x84 != 0"""
        st = self.rd(REG_STATUS)
        if st & ST_AMPS:
            return True
        if not (st & ST_AREFS and st & ST_CLKS):
            return False
        if self.rd(REG_STATUS) & ST_MTPB:
            return False
        return self.rd(REG_MTP84) != 0

    def wait_stable(self, tries=50, delay=0.01):
        for _ in range(tries):
            if self.system_stable():
                return True
            time.sleep(delay)
        return False

    def dsp_msg(self, module, param, payload=b"", chunk=252):
        """RPC: cmd at xmem[1..], payload streamed, REQCMD+CFINT, ACK, status xmem[0]"""
        # one burst: CF_CTRL = XMEM (autoincrement), CF_MAD = 1, CF_MEM = cmd id
        self.bus.write(self.addr, bytes([REG_CF_CTRL, 0x00, DMEM_XMEM << CF_DMEM_SHIFT,
                                         0x00, 0x01, 0x00, 0x80 | module, param]))
        for i in range(0, len(payload), chunk):
            self.bus.write(self.addr, bytes([REG_CF_MEM]) + payload[i:i + chunk])
        self.wr(REG_CF_CTRL, CF_REQCMD | CF_INT | (DMEM_XMEM << CF_DMEM_SHIFT))
        for _ in range(20):
            ack = self.rd(REG_CF_STATUS)
            if ack & CF_ACKCMD:
                break
            time.sleep(0.001)
        else:
            raise CntError("0x%02x: DSP did not ACK message %02x/%02x (CF_STATUS %04x)"
                           % (self.addr, module, param, ack))
        self.bus.write(self.addr, bytes([REG_CF_CTRL, 0x00, DMEM_XMEM << CF_DMEM_SHIFT, 0x00, 0x00]))
        st = int.from_bytes(self.bus.read(self.addr, REG_CF_MEM, 3), "big")
        if st != 0:
            raise CntError("0x%02x: DSP message %02x/%02x RPC status %d (%s)"
                           % (self.addr, module, param, st, RPC_STATUS.get(st, "?")))
        return st

    def dsp_get(self, module, param, nbytes, chunk=252):
        self.dsp_msg(module, param)
        self.wr(REG_CF_MAD, 2)
        out = b""
        while len(out) < nbytes:
            out += self.bus.read(self.addr, REG_CF_MEM, min(chunk, nbytes - len(out)))
        return out


def eq_payload(flt):
    return bytes(flt["biquad"]) if flt["enabled"] else b"\x80" + bytes(17)


def vol_from_att(att):
    """vendor: VOL field = attenuation in 0.5 dB steps (vstep 5: -8.5 dB -> 17)"""
    return max(0, min(255, int(round(-att * 2))))


def write_vstep(t, step):
    """VOL register + preset + 10 EQ biquads (same order as climax)"""
    t.set_bf(0x0687, vol_from_att(step["att"]))
    t.dsp_msg(MODULE_SPEAKERBOOST, SB_PARAM_SET_PRESET, step["preset"])
    for i, flt in enumerate(step["filters"]):
        t.dsp_msg(MODULE_BIQUAD, i + 1, eq_payload(flt))


def cold_start(cnt, t, profile=0, vstep=0, say=print):
    """Everything up to SBSL=1 for one amplifier (amp stays soft-muted)."""
    dev = cnt.device(t.addr)
    rev = t.rd(REG_REV)
    if rev & 0xff != TFA9890_REV:
        raise CntError("0x%02x: revision 0x%04x is not a TFA9890" % (t.addr, rev))
    st = t.rd(REG_STATUS)
    st = t.rd(REG_STATUS)
    say("0x%02x: status %04x (%s)" % (t.addr, st, decode_status(st)))
    # I2C register reset + TFA9890 PLL fix (tfa9890_specific)
    t.wr(REG_SYS, SYS_I2CR)
    t.wr(REG_KEY, 0x5a6b)
    t.wr(REG_PLL59, t.rd(REG_PLL59) | 0x3)
    t.wr(REG_KEY, 0x0000)
    # device list bitfields, then the profile's bitfields
    for field, value in dev["bitfields"]:
        t.set_bf(field, value)
    prof = cnt.dev_profile(dev, profile)
    for field, value in prof["bitfields"]:
        t.set_bf(field, value)
    # power on and wait for the DSP subsystem (needs I2S clocks)
    t.set_bf(0x0900, 0)
    if not t.wait_stable():
        raise CntError("0x%02x: DSP subsystem not stable (no I2S clock? status %04x)"
                       % (t.addr, t.rd(REG_STATUS)))
    # patch: ROM check, then raw writes
    p = dev["patch"]
    if p.patch_rev != 0xff and p.patch_rev != rev & 0xff:
        raise CntError("patch is for revision 0x%02x" % p.patch_rev)
    if p.rom_addr != 0xffff:
        if not t.wait_stable():
            raise CntError("0x%02x: not stable before ROM check" % t.addr)
        rom = int.from_bytes(t.mem_read(DMEM_XMEM, p.rom_addr, 1), "big")
        if rom != p.rom_value:
            raise CntError("0x%02x: ROM check xmem[0x%04x]=0x%06x, patch wants 0x%06x"
                           % (t.addr, p.rom_addr, rom, p.rom_value))
    for c in p.chunks:
        t.bus.write(t.addr, c)
    # soft mute while loading (CFSM=1, AMPE=1, DCA=0 per tfa98xx_set_mute DIGITAL)
    audio, sysc = t.rd(REG_AUDIO), t.rd(REG_SYS)
    t.wr(REG_AUDIO, audio | AUDIO_CFSM)
    t.wr(REG_SYS, (sysc | SYS_AMPE) & ~SYS_DCA)
    cfg, spk = cnt.dev_file(dev, "config"), cnt.dev_file(dev, "speaker")
    t.dsp_msg(MODULE_SPEAKERBOOST, SB_PARAM_SET_CONFIG, cfg.payload)
    t.dsp_msg(MODULE_SPEAKERBOOST, SB_PARAM_SET_LSMODEL, spk.payload)
    vs = prof["files"][0]
    write_vstep(t, vs.steps[vstep])
    # "configured": SBSL=1 lets the DSP start; the vendor then checks MTPEX + cal-done
    t.set_bf(0x0950, 1)
    mtp = t.rd(REG_MTP0)
    cal = int.from_bytes(t.mem_read(DMEM_XMEM, XMEM_CAL_DONE, 1), "big")
    say("0x%02x: configured (MTP0 %04x MTPEX=%d, xmem[0xe7]=0x%06x)" % (t.addr, mtp, (mtp >> 1) & 1, cal))
    return dict(mtp=mtp, cal=cal)


def unmute(t):
    audio, sysc = t.rd(REG_AUDIO), t.rd(REG_SYS)
    t.wr(REG_AUDIO, audio & ~AUDIO_CFSM)
    t.wr(REG_SYS, sysc | SYS_AMPE)


def stop(t):
    """vendor --stop: CFSM off, AMPE=0 DCA=0 PWDN=1 (DSP keeps its config).
    The vendor also sets CHSA=0 (left); not done here: the kernel mux owns CHSA."""
    audio, sysc = t.rd(REG_AUDIO), t.rd(REG_SYS)
    t.wr(REG_AUDIO, audio & ~AUDIO_CFSM)
    t.wr(REG_SYS, (sysc & ~SYS_AMPE & ~SYS_DCA) | SYS_PWDN)


def bypass(t):
    """same end state as mainline tfa989x_dsp_bypass(), per-channel CHSA"""
    chs12 = bf_get(t.rd(REG_I2S), 0x0431)
    t.set_bf(0x0461, 1 if chs12 == 2 else 0)
    v = t.rd(REG_I2SSEL)
    t.wr(REG_I2SSEL, (v & ~(0xf << 11)) | (3 << 9))
    t.wr(REG_SYS, t.rd(REG_SYS) & ~(SYS_DCA | SYS_CFE | SYS_AMPC))


def decode_status(st):
    return " ".join(n for i, n in enumerate(STATUS_BITS) if st >> i & 1)


def decode_sys(v):
    s = [n for b, n in SYS_BITS.items() if v >> b & 1]
    return " ".join(s) + " DCCV=%d" % ((v >> 9) & 3)


def state_info(t):
    """SpeakerBoost state (param 0xC0), 9 words; scaling as in NXP Tfa98xx.c
    (SPKRBST_HEADROOM 7, AGCGAIN_EXP 7, LIMGAIN_EXP 4). Re/X1/X2 (exp 9)
    verified plausible on hardware (unit A). T (temperature) is NOT exp 9:
    that decoded a constant 98.9 C from raw 0x18b8ad on both amps at
    15:38-15:45 on 2026-09-26 (see the DSP bring-up notes ("Hardware bring-up"));
    exp 8 gives 49.4 C, matching the IC's measured 47-50 C, so T uses exp 8."""
    raw = t.dsp_get(MODULE_SPEAKERBOOST, SB_PARAM_GET_STATE, 27)
    w = [int.from_bytes(raw[i:i + 3], "big", signed=True) for i in range(0, 27, 3)]
    f = lambda v, e: v / float(1 << (23 - e))
    return dict(agcGain=f(w[0], 7), limGain=f(w[1], 4), sMax=f(w[2], 7), T=f(w[3], 8),
                statusFlag=w[4], X1=f(w[5], 7), X2=f(w[6], 7), Re=f(w[7], 9),
                shortOnMips=w[8], raw=raw.hex())


# ---------------------------------------------------------------- CLI
def cmd_info(a):
    cnt = Container(open(a.cnt, "rb").read(), a.cnt)
    print("container %s: v%s customer=%s app=%s type=%s size=%d crc=%08x OK ndev=%d nprof=%d"
          % (a.cnt, cnt.version, cnt.customer, cnt.application, cnt.type, cnt.size, cnt.crc,
             cnt.ndev, cnt.nprof))
    for d in cnt.devices:
        print(" device %s bus %d addr 0x%02x" % (d["name"], d["bus"], d["addr"]))
        for f, v in d["bitfields"]:
            print("   bf %-6s (0x%04x) = %d" % (BF_NAMES.get(f, "?"), f, v))
        p = d["patch"]
        print("   patch %s %s%s rev 0x%02x rom xmem[0x%04x]==0x%06x, %d chunks, %d bytes, crc OK"
              % (p.name, p.id, p.version + p.subversion, p.patch_rev, p.rom_addr, p.rom_value,
                 len(p.chunks), sum(len(c) for c in p.chunks)))
        for f in d["files"]:
            extra = ""
            if f.kind == "speaker":
                extra = " name=%r vendor=%r type=%r dims=%s ohm=%s" % (
                    f.spk_name, f.spk_vendor, f.spk_type, f.dims, f.ohm)
            print("   %s %s %d payload bytes, crc OK%s" % (f.kind, f.name, len(f.payload), extra))
        for i, po in enumerate(d["profile_offs"]):
            pr = cnt.profiles[po]
            print("   profile %d %s: %s" % (i, pr["name"], ", ".join(
                "%s=%d" % (BF_NAMES.get(f, hex(f)), v) for f, v in pr["bitfields"])))
            for vs in pr["files"]:
                print("     vstep %s: %d steps, att dB = %s" % (vs.name, len(vs.steps), " ".join(
                    "%.1f" % s["att"] for s in vs.steps)))
    return 0


def open_bus(a):
    if a.dry_run and a.no_read:
        return None
    return I2CDev(a.bus)


def cmd_plan(a):
    cnt = Container(open(a.cnt, "rb").read(), a.cnt)
    fake = FakeTfa9890()
    addrs = [a.dev] if a.dev else [d["addr"] for d in cnt.devices]
    tfas = [Tfa(fake, x) for x in addrs]
    for t in tfas:
        cold_start(cnt, t, a.profile, a.vstep, say=lambda s: print("#", s))
    for t in tfas:
        unmute(t)
    for op in fake.ops:
        if op[0] == "w":
            print("W 0x%02x [%3d] %s" % (op[1], len(op[2]), op[2].hex(" ")))
        else:
            print("R 0x%02x reg 0x%02x n=%d" % (op[1], op[2], op[3]))
    print("# %d transactions" % len(fake.ops))
    return 0


def cmd_start(a):
    cnt = Container(open(a.cnt, "rb").read(), a.cnt)
    dev = I2CDev(a.bus)
    bus = DryRun(dev) if a.dry_run else dev
    if not a.dry_run and not a.yes:
        print("refusing to write without --yes (use --dry-run to print)", file=sys.stderr)
        return 2
    addrs = [a.dev] if a.dev else [d["addr"] for d in cnt.devices]
    tfas = [Tfa(bus, x) for x in addrs]
    if a.dry_run:
        print("# dry run: reads are real, writes are printed only; RMW values and"
              " DSP replies below assume nothing was written")
        for t in tfas:
            try:
                cold_start(cnt, t, a.profile, a.vstep)
            except CntError as e:
                print("# dry run stopped at: %s" % e)
        print("# %d writes printed" % bus.writes)
        return 0
    ok = []
    for t in tfas:
        try:
            cold_start(cnt, t, a.profile, a.vstep)
            ok.append(t)
        except (CntError, OSError) as e:
            print("0x%02x: FAILED: %s -> leaving it in bypass" % (t.addr, e), file=sys.stderr)
            try:
                bypass(t)
            except OSError:
                pass
    if len(ok) != len(tfas):
        for t in ok:            # never run one amp with DSP and the other without
            bypass(t)
        return 1
    for t in tfas:
        unmute(t)
    for t in tfas:
        print("0x%02x: running, status %04x (%s), sys %04x (%s)" % (
            t.addr, t.rd(REG_STATUS), decode_status(t.rd(REG_STATUS)), t.rd(REG_SYS),
            decode_sys(t.rd(REG_SYS))))
    return 0


def cmd_status(a):
    dev = I2CDev(a.bus)
    rc = 0
    for addr in (0x34, 0x36):
        t = Tfa(dev, addr)
        regs = {r: t.rd(r) for r in (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0a, 0x47, 0x80)}
        st, sysc = regs[0], regs[9]
        print("0x%02x: %s" % (addr, " ".join("%02x=%04x" % kv for kv in sorted(regs.items()))))
        print("  status  %s" % decode_status(st))
        print("  sys     %s" % decode_sys(sysc))
        print("  i2s     CHS12=%d CHS3=%d CHSA=%d I2SSR=%d; VOL=%d (-%.1f dB) CFSM=%d"
              % (bf_get(regs[4], 0x0431), bf_get(regs[4], 0x0450), bf_get(regs[4], 0x0461),
                 bf_get(regs[4], 0x04c3), bf_get(regs[6], 0x0687), bf_get(regs[6], 0x0687) / 2.0,
                 bf_get(regs[6], 0x0650)))
        print("  vbat    %.3f V, IC temp %d C, MTPEX=%d" % (regs[1] * 5.5 / 1024, regs[2] & 0x1ff,
                                                       (regs[0x80] >> 1) & 1))
        dsp = (not st & ST_ACS) and sysc & SYS_SBSL and sysc & SYS_CFE
        print("  DSP     %s" % ("CONFIGURED (ACS=0, SBSL=1, CFE=1)" if dsp else
                               "not configured (bypass or cold)"))
        if dsp and a.state:
            try:
                print("  state   %s" % state_info(t))
            except CntError as e:
                print("  state   %s" % e)
                rc = 1
    return rc


def cmd_simple(a, fn):
    dev = I2CDev(a.bus)
    if not a.yes:
        print("refusing to write without --yes", file=sys.stderr)
        return 2
    for addr in (0x34, 0x36):
        fn(Tfa(dev, addr))
    return 0


def cmd_vstep(a):
    cnt = Container(open(a.cnt, "rb").read(), a.cnt)
    if not a.yes:
        print("refusing to write without --yes", file=sys.stderr)
        return 2
    dev = I2CDev(a.bus)
    for d in cnt.devices:
        t = Tfa(dev, d["addr"])
        st, sysc = t.rd(REG_STATUS), t.rd(REG_SYS)
        if st & ST_ACS or not sysc & SYS_SBSL:
            raise CntError("0x%02x: DSP not configured, run start first" % t.addr)
        write_vstep(t, cnt.dev_profile(d, a.profile)["files"][0].steps[a.step])
    return 0


def cmd_spkcmp(a):
    dump = open(a.dump, "rb").read()
    if len(dump) != 423:
        print("dump must be the 423-byte speaker model (param 0x86)", file=sys.stderr)
        return 2
    for c in a.cnt:
        cnt = Container(open(c, "rb").read(), c)
        spk = cnt.dev_file(cnt.devices[0], "speaker")
        same = sum(1 for i in range(0, 423, 3) if spk.payload[i:i + 3] == dump[i:i + 3])
        print("%s: %s %d/141 words identical" % (c, spk.name, same))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("info"); p.add_argument("cnt")
    p = sp.add_parser("plan"); p.add_argument("cnt")
    p.add_argument("--profile", type=int, default=0); p.add_argument("--vstep", type=int, default=0)
    p.add_argument("--dev", type=lambda s: int(s, 0))
    p = sp.add_parser("start"); p.add_argument("cnt"); p.add_argument("--bus", type=int, default=1)
    p.add_argument("--profile", type=int, default=0); p.add_argument("--vstep", type=int, default=0)
    p.add_argument("--dev", type=lambda s: int(s, 0)); p.add_argument("--dry-run", action="store_true")
    p.add_argument("--yes", action="store_true")
    p = sp.add_parser("status"); p.add_argument("--bus", type=int, default=1)
    p.add_argument("--state", action="store_true", help="also query DSP state (writes a GET message)")
    for name in ("stop", "bypass"):
        p = sp.add_parser(name); p.add_argument("--bus", type=int, default=1); p.add_argument("--yes", action="store_true")
    p = sp.add_parser("vstep"); p.add_argument("cnt"); p.add_argument("step", type=int)
    p.add_argument("--profile", type=int, default=0); p.add_argument("--bus", type=int, default=1)
    p.add_argument("--yes", action="store_true")
    p = sp.add_parser("spkcmp"); p.add_argument("cnt", nargs="+"); p.add_argument("--dump", required=True)
    a = ap.parse_args(argv)
    try:
        return {"info": cmd_info, "plan": cmd_plan, "start": cmd_start, "status": cmd_status,
                "stop": lambda a: cmd_simple(a, stop), "bypass": lambda a: cmd_simple(a, bypass),
                "vstep": cmd_vstep, "spkcmp": cmd_spkcmp}[a.cmd](a)
    except CntError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
