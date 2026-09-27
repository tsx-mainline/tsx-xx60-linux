#!/usr/bin/env python3
"""tsx-env.py: read, check, merge and write the xx60 U-Boot env block.

The env U-Boot 1.00.x reads and saves lives on the SD card (mmcblk0) at byte
0x100000, 64 KiB, one copy: 4-byte CRC32 (little endian) over the next 65532
bytes, then "name=value\\0" entries, a terminating "\\0", zero padding
(work/rootfs proved the location; all three known blocks are laid out like this).

Usage (SRC/DST = a block device, a card image, or a bare 64 KiB env file;
a file of exactly 65536 bytes is taken as a bare env block, anything else is
read at --offset, default 0x100000):
  tsx-env.py show SRC [NAME...]
  tsx-env.py check SRC                      CRC + "this is a xx60 env" (exit 1 if not)
  tsx-env.py unit SRC                       the per-unit variables (PER_UNIT below)
  tsx-env.py merge SRC OUT [--guard fallback|nogolden] [--no-defuse-golden]
            [--set NAME=VALUE ...] [--unset NAME ...]
      OUT = SRC's env with ONLY the hook variables changed: tsx_boot and
      switch_bootmode set (byte-identical to the hook on the TSW-1060),
      boot_retry=0, golden_boot_retry=0, DataRecoveryDone=1 (the Crestron golden
      image then does not format p5/p7; --no-defuse-golden
      leaves it as it is). Every
      other variable keeps its exact bytes and its position; new ones are
      appended (fw_setenv does the same). OUT is a bare 64 KiB block.
  tsx-env.py generic SRC OUT --model tsw1060|tsw760 [--guard ..] [--no-defuse-golden]
      for a card image that is not made for one unit: SRC's env (a donor unit)
      with the per-unit identity removed (see NEUTRAL) + the hook.
  tsx-env.py unhook SRC OUT
      factory state for Crestron's Android (factory/puf-tool.sh): stock
      switch_bootmode, tsx_boot deleted, boot_retry/golden_boot_retry 0, fwUpgrade 0,
      reformat* 0, DataRecoveryDone 0. Identity and everything else unchanged.
  tsx-env.py write BLOCK DST                write a bare 64 KiB block at DST+offset
  tsx-env.py diff A B                       variable-level diff of two env blocks
"""
import argparse, os, struct, sys, zlib

ENV_OFF = 0x100000
ENV_SIZE = 0x10000

STOCK_SWITCH = 'usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;'
TSX_BOOT = ('mmcinfo; if fatexist mmc 0 tsxboot.off; then echo tsx: mainline disabled; else '
            'if fatexist mmc 0 tsxboot.img; then echo tsx: booting tsxboot.img; '
            'fatload mmc 0 ${loadaddr} tsxboot.img; bootm; fi; fi')
GUARDS = {
    'fallback': STOCK_SWITCH + 'if itest ${boot_retry} -lt 6; then run tsx_boot; fi',
    'nogolden': STOCK_SWITCH + 'if itest ${boot_retry} -lt 6 || itest ${boot_retry} -gt 9; then run tsx_boot; fi',
}
KNOWN_SWITCH = {STOCK_SWITCH: 'stock', STOCK_SWITCH + 'run tsx_boot': 'plain',
                GUARDS['fallback']: 'fallback', GUARDS['nogolden']: 'nogolden'}

# Per-unit variables. Derived by diffing three real env blocks (TSW-1060 A
# ethaddr ..:b8:30, TSW-1060 B ..:b8:37, TSW-760 C from xx60-FACTORY.img)
# against the built-in default env of the running U-Boot (results/env-per-unit.txt).
#   identity: set in the Crestron/Jabil factory, nothing recreates them
#   hw:       re-detected by U-Boot at every boot on 2 GB units
#             (select_m8m2_dtd: aml_dt, lcmsupplier; "lcd dpck": lcdsize,
#             display_*, fb_*), but kept anyway
#   state:    Crestron runtime/config state kept by Android scripts
PER_UNIT = {
    'identity': ['ethaddr', 'tsid', 'product_name', 'lan_hostname', 'updater_version', 'updater_build'],
    'hw': ['aml_dt', 'lcmsupplier', 'lcdsize', 'display_width', 'display_height', 'fb_width', 'fb_height', 'orientation'],
    'state': ['forced_auth_mode', 'standaloneapp', 'government', 'stealth', 'crestron_fastboot',
              'first_boot', 'firstboot', 'gscreen_reset_count', 'txrx_mode', 'apk_fail_recover',
              'manual_reboot', 'reboot_reason', 'softreboot', 'update_golden_version',
              'DataRecoveryDone', 'reformatDataPartition', 'reformatExtendedPartition', 'fwUpgrade',
              'boot_complete_recover'],
}
# generic image: identity removed / neutral (U-Boot then uses what it has:
# efuse MAC if burned (common/main.c), else no MAC in the env)
NEUTRAL = {'tsid': 'FFFFFFFF', 'standaloneapp': '0', 'forced_auth_mode': 'true'}
MODEL_HW = {
    'tsw1060': {'lcdsize': '10inch', 'aml_dt': 'yushan_one_10inch', 'display_width': '1280',
                'display_height': '800', 'fb_width': '1280', 'fb_height': '800'},
    'tsw760': {'lcdsize': '7inch', 'aml_dt': 'yushan_one_7inch', 'display_width': '1024',
               'display_height': '600', 'fb_width': '1024', 'fb_height': '600'},
}


class Env:
    def __init__(self, block):
        if len(block) != ENV_SIZE:
            raise ValueError('env block must be 64 KiB')
        self.crc_stored = struct.unpack_from('<I', block, 0)[0]
        self.data = block[4:]
        self.crc_ok = zlib.crc32(self.data) & 0xffffffff == self.crc_stored
        end = self.data.find(b'\0\0')
        self.entries = []          # list of [name(bytes), raw entry bytes]
        if end >= 0:
            for raw in self.data[:end].split(b'\0'):
                if b'=' in raw:
                    self.entries.append([raw.split(b'=', 1)[0], raw])

    def get(self, name):
        n = name.encode()
        for k, raw in self.entries:
            if k == n:
                return raw.split(b'=', 1)[1].decode('latin1')
        return None

    def names(self):
        return [k.decode('latin1') for k, _ in self.entries]

    def set(self, name, value):
        n = name.encode()
        raw = n + b'=' + value.encode('latin1')
        for e in self.entries:
            if e[0] == n:
                e[1] = raw
                return
        self.entries.append([n, raw])

    def unset(self, name):
        n = name.encode()
        self.entries = [e for e in self.entries if e[0] != n]

    def pack(self):
        body = b''.join(raw + b'\0' for _, raw in self.entries) + b'\0'
        if len(body) > ENV_SIZE - 4:
            raise ValueError('env too large')
        body += b'\0' * (ENV_SIZE - 4 - len(body))
        return struct.pack('<I', zlib.crc32(body) & 0xffffffff) + body

    def problems(self):
        p = []
        if not self.crc_ok:
            p.append('CRC mismatch (U-Boot would use its built-in default env)')
        aml = self.get('aml_dt') or ''
        if not (aml.startsxith('yushan_one') or aml.startsxith('m8m2_n200')):
            p.append('aml_dt=%r is not a xx60 value' % aml)
        if not self.get('crestron_uboot_version'):
            p.append('no crestron_uboot_version')
        if 'run switch_bootmode' not in (self.get('preboot') or ''):
            p.append('preboot does not run switch_bootmode')
        sw = self.get('switch_bootmode')
        if sw not in KNOWN_SWITCH:
            p.append('switch_bootmode has unknown content: %r' % sw)
        return p

    def hook_state(self):
        return KNOWN_SWITCH.get(self.get('switch_bootmode'), 'foreign')


def read_block(path, offset):
    size = os.path.getsize(path) if os.path.isfile(path) else None
    with open(path, 'rb') as f:
        if size == ENV_SIZE:
            return f.read(ENV_SIZE)
        f.seek(offset)
        b = f.read(ENV_SIZE)
    if len(b) != ENV_SIZE:
        raise ValueError('%s: short read at %#x' % (path, offset))
    return b


def apply_hook(env, guard, defuse):
    env.set('tsx_boot', TSX_BOOT)
    env.set('switch_bootmode', GUARDS[guard])
    env.set('boot_retry', '0')
    env.set('golden_boot_retry', '0')
    if defuse:
        env.set('DataRecoveryDone', '1')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['show', 'check', 'unit', 'merge', 'generic', 'unhook', 'write', 'diff'])
    ap.add_argument('args', nargs='*')
    ap.add_argument('--offset', type=lambda s: int(s, 0), default=ENV_OFF)
    ap.add_argument('--guard', choices=list(GUARDS), default='fallback')
    ap.add_argument('--defuse-golden', dest='defuse_golden', action='store_true', default=True,
                    help='set DataRecoveryDone=1 (default)')
    ap.add_argument('--no-defuse-golden', dest='defuse_golden', action='store_false')
    ap.add_argument('--model', choices=list(MODEL_HW))
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--unset', action='append', default=[])
    ap.add_argument('--force', action='store_true', help='merge even if the source env has problems (never for a unit)')
    a = ap.parse_args()
    A = a.args

    if a.cmd == 'write':
        blk = open(A[0], 'rb').read()
        e = Env(blk)
        if not e.crc_ok or e.problems():
            sys.exit('refusing to write: %s' % '; '.join(e.problems()))
        with open(A[1], 'r+b') as f:
            f.seek(a.offset)
            f.write(blk)
            f.flush()
            os.fsync(f.fileno())
        with open(A[1], 'rb') as f:
            f.seek(a.offset)
            if f.read(ENV_SIZE) != blk:
                sys.exit('readback differs after the write')
        print('env written at %s+%#x (hook: %s)' % (A[1], a.offset, e.hook_state()))
        return

    env = Env(read_block(A[0], a.offset))
    if a.cmd == 'show':
        if not A[1:]:
            for k, raw in env.entries:
                print(raw.decode('latin1'))
        for n in A[1:]:
            v = env.get(n)
            print('%s=%s' % (n, v) if v is not None else '## %s not set' % n)
        return
    if a.cmd == 'check':
        p = env.problems()
        print('env: %d variables, CRC %s, hook %s, model %s/%s, unit %s' % (
            len(env.entries), 'ok' if env.crc_ok else 'BAD', env.hook_state(), env.get('lcdsize'),
            env.get('aml_dt'), env.get('ethaddr')))
        for x in p:
            print('PROBLEM: ' + x)
        sys.exit(1 if p else 0)
    if a.cmd == 'unit':
        for grp, names in PER_UNIT.items():
            for n in names:
                v = env.get(n)
                if v is not None:
                    print('%-8s %s=%s' % (grp, n, v))
        return
    if a.cmd == 'diff':
        other = Env(read_block(A[1], a.offset))
        for n in sorted(set(env.names()) | set(other.names())):
            if env.get(n) != other.get(n):
                print('%s: %r -> %r' % (n, env.get(n), other.get(n)))
        return
    if a.cmd == 'unhook':
        if not env.crc_ok or (env.get('aml_dt') or '')[:10] not in ('yushan_one', 'm8m2_n200_'):
            sys.exit('source env not usable (CRC or not a xx60 env)')
        env.set('switch_bootmode', STOCK_SWITCH)
        env.unset('tsx_boot')
        for n, v in (('boot_retry', '0'), ('golden_boot_retry', '0'), ('fwUpgrade', '0'), ('reformatDataPartition', '0'),
                     ('reformatExtendedPartition', '0'), ('DataRecoveryDone', '0')):
            if env.get(n) is not None or n in ('boot_retry', 'golden_boot_retry'):
                env.set(n, v)
        out = env.pack(); chk = Env(out)
        assert chk.crc_ok and not chk.problems(), chk.problems()
        open(A[1], 'wb').write(out)
        print('unhook env -> %s: %d variables, hook %s' % (A[1], len(chk.entries), chk.hook_state()))
        return
    p = env.problems()
    if p and not a.force:
        sys.exit('source env not usable: %s' % '; '.join(p))
    if a.cmd == 'generic':
        if not a.model:
            sys.exit('generic needs --model')
        for n in PER_UNIT['identity']:
            env.unset(n)
        for n, v in NEUTRAL.items():
            env.set(n, v)
        for n, v in MODEL_HW[a.model].items():
            env.set(n, v)
        for n in ('reboot_reason', 'gscreen_reset_count', 'manual_reboot'):
            env.set(n, '0' if n != 'reboot_reason' else 'poweron')
        env.set('DataRecoveryDone', '0')
        env.set('fwUpgrade', '0')
    apply_hook(env, a.guard, a.defuse_golden)
    for s in a.set:
        n, v = s.split('=', 1)
        env.set(n, v)
    for n in a.unset:
        env.unset(n)
    out = env.pack()
    chk = Env(out)
    assert chk.crc_ok and not chk.problems(), chk.problems()
    open(A[1], 'wb').write(out)
    print('%s env -> %s: %d variables, hook %s, boot_retry %s' % (
        a.cmd, A[1], len(chk.entries), chk.hook_state(), chk.get('boot_retry')))


if __name__ == '__main__':
    main()
