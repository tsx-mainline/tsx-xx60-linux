#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""tsx-btscan: passive BLE scanner for the Bluetooth proxy of the panel.

The daemon runs as root under /etc/init.d/tsx-bt, after tsx-bt has brought
hci0 up. It opens a raw HCI socket on the controller and runs a passive LE
scan: the controller only listens and sends nothing over the air. It hands
each LE advertising report to the ESPHome front ends of the panel
(tsx-esphome, or the voice satellite, which runs as the kiosk user and cannot
open an HCI socket itself) over a Unix socket:

  /run/tsx/bt-adv.sock   SOCK_SEQPACKET, mode 0660, group kiosk

One message is one advertising report:

  6 bytes  device address, HCI byte order (least significant byte first)
  1 byte   address type (0 public, 1 random, 2/3 resolved public/random)
  1 byte   RSSI in dBm, signed (127 = not available)
  1 byte   advertising event type (0 ADV_IND ... 4 SCAN_RSP)
  N bytes  advertising data (0..31 bytes)

The scan runs only while at least one client is connected. The ESPHome front
end connects when Home Assistant subscribes to advertisements and
disconnects when it unsubscribes, so the radio idles without Home Assistant.

The kernel keeps hci0 (the daemon uses the raw channel, not the user
channel), so hciconfig and btmgmt keep working. If no report arrives for
WATCHDOG seconds while clients are connected, the daemon sends the scan
commands again. This covers a controller reset and a kernel that turned the
scan off.

  btscan.py [--hci hci0] [--socket /run/tsx/bt-adv.sock] [--group kiosk]
  Test hook: TSX_BTSCAN_FAKE_HCI=<path of a SOCK_SEQPACKET Unix socket>
  replaces the HCI socket. The test acts as the controller on that socket.
"""

import argparse
import errno
import grp
import logging
import os
import select
import signal
import socket
import struct
import sys
import time

HCI_COMMAND_PKT = 0x01
HCI_EVENT_PKT = 0x04
EVT_CMD_COMPLETE = 0x0E
EVT_CMD_STATUS = 0x0F
EVT_LE_META = 0x3E
LE_ADV_REPORT = 0x02

OP_LE_SET_SCAN_PARAMS = 0x200B
OP_LE_SET_SCAN_ENABLE = 0x200C

SCAN_INTERVAL = 0x00A0  # 100 ms (0.625 ms units)
SCAN_WINDOW = 0x00A0    # the same: listen all the time
WATCHDOG = 60.0
STATS_EVERY = 600.0

_LOGGER = logging.getLogger("tsx-btscan")


def hci_filter():
    """struct hci_filter: HCI event packets, only the events we read."""
    type_mask = 1 << HCI_EVENT_PKT
    events = 0
    for ev in (EVT_CMD_COMPLETE, EVT_CMD_STATUS, EVT_LE_META):
        events |= 1 << ev
    # struct hci_ufilter is 14 bytes plus 2 bytes of padding. The kernel
    # refuses a shorter option with EINVAL.
    return struct.pack("<IIIHxx", type_mask, events & 0xFFFFFFFF, events >> 32, 0)


def command(opcode, params=b""):
    return struct.pack("<BHB", HCI_COMMAND_PKT, opcode, len(params)) + params


def parse_adv_reports(params):
    """Parse the parameters of an LE Advertising Report subevent (after the
    subevent code). Return a list of (addr6, addr_type, rssi, evt_type,
    data). The layout follows the kernel: the reports come one after the
    other, and each one ends with its RSSI byte."""
    out = []
    if not params:
        return out
    num = params[0]
    pos = 1
    for _ in range(num):
        if pos + 9 > len(params):
            break
        evt_type, addr_type = params[pos], params[pos + 1]
        addr = params[pos + 2:pos + 8]
        dlen = params[pos + 8]
        end = pos + 9 + dlen
        if dlen > 31 or end + 1 > len(params):
            break
        data = params[pos + 9:end]
        rssi = struct.unpack_from("b", params, end)[0]
        out.append((bytes(addr), addr_type, rssi, evt_type, bytes(data)))
        pos = end + 1
    return out


def pack_record(addr, addr_type, rssi, evt_type, data):
    return bytes(addr) + struct.pack("BbB", addr_type, rssi, evt_type) + bytes(data)


class Scanner:
    def __init__(self, hci_name, sock_path, group):
        self.hci_name = hci_name
        self.sock_path = sock_path
        self.group = group
        self.hci = None
        self.server = None
        self.clients = []
        self.scanning = False
        self.want_scan = False
        self.last_report = 0.0
        self.last_try = 0.0
        self.scan_retry_at = 0.0  # after a failed scan start, wait before the next try
        self.pending = {}   # opcode -> status (None while waiting)
        self.n_reports = 0
        self.addrs = set()
        self.last_stats = time.monotonic()
        self.hci_error_logged = False

    # ---- HCI side ----------------------------------------------------------
    def open_hci(self):
        fake = os.environ.get("TSX_BTSCAN_FAKE_HCI")
        if fake:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            sock.connect(fake)
        else:
            dev = int(self.hci_name.replace("hci", "") or 0)
            sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
            sock.setsockopt(socket.SOL_HCI, socket.HCI_FILTER, hci_filter())
            sock.bind((dev,))
        sock.setblocking(False)
        self.hci = sock
        self.hci_error_logged = False
        _LOGGER.info("HCI socket open on %s", "the fake controller" if fake else self.hci_name)

    def close_hci(self):
        if self.hci is not None:
            try:
                self.hci.close()
            except OSError:
                pass
        self.hci = None
        self.scanning = False

    def hci_fail(self, what, err):
        if not self.hci_error_logged:
            _LOGGER.warning("%s: %s. Retrying every 5 s", what, err)
            self.hci_error_logged = True
        self.close_hci()

    def send_cmd(self, opcode, params=b"", timeout=2.0):
        """Send one HCI command and wait for its Command Complete or Command
        Status. Return the status byte, or None on a timeout."""
        self.pending[opcode] = None
        self.hci.send(command(opcode, params))
        deadline = time.monotonic() + timeout
        while self.pending.get(opcode) is None:
            left = deadline - time.monotonic()
            if left <= 0:
                self.pending.pop(opcode, None)
                return None
            r, _, _ = select.select([self.hci], [], [], left)
            if r:
                self.read_hci()
            if self.hci is None:
                raise OSError(errno.EIO, "the HCI socket closed")
        return self.pending.pop(opcode)

    def set_scan(self, enable):
        """Start or stop the passive scan. Return True on success."""
        if self.hci is None:
            return False
        try:
            if enable:
                # Stop a scan that may still run (from us or from the kernel):
                # the controller refuses new parameters while it scans.
                self.send_cmd(OP_LE_SET_SCAN_ENABLE, bytes((0, 0)))
                params = struct.pack("<BHHBB", 0, SCAN_INTERVAL, SCAN_WINDOW, 0, 0)
                st = self.send_cmd(OP_LE_SET_SCAN_PARAMS, params)
                if st != 0:
                    _LOGGER.warning("LE Set Scan Parameters: %s", "no answer" if st is None else f"status 0x{st:02x}")
                    return False
                st = self.send_cmd(OP_LE_SET_SCAN_ENABLE, bytes((1, 0)))
                if st != 0:
                    _LOGGER.warning("LE Set Scan Enable: %s", "no answer" if st is None else f"status 0x{st:02x}")
                    return False
                self.scanning = True
                self.last_report = time.monotonic()
                _LOGGER.info("passive scan on (interval %d ms, window %d ms)",
                             SCAN_INTERVAL * 625 // 1000, SCAN_WINDOW * 625 // 1000)
            else:
                self.send_cmd(OP_LE_SET_SCAN_ENABLE, bytes((0, 0)))
                self.scanning = False
                _LOGGER.info("passive scan off (no clients)")
            return True
        except OSError as err:
            self.hci_fail("HCI command", err)
            return False

    def read_hci(self):
        try:
            pkt = self.hci.recv(1024)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as err:
            self.hci_fail("HCI read", err)
            return
        if not pkt:
            self.hci_fail("HCI read", "end of stream")
            return
        if len(pkt) < 3 or pkt[0] != HCI_EVENT_PKT:
            return
        evt, params = pkt[1], pkt[3:3 + pkt[2]]
        if evt == EVT_CMD_COMPLETE and len(params) >= 4:
            opcode = struct.unpack_from("<H", params, 1)[0]
            if opcode in self.pending:
                self.pending[opcode] = params[3]
        elif evt == EVT_CMD_STATUS and len(params) >= 4:
            opcode = struct.unpack_from("<H", params, 2)[0]
            if opcode in self.pending and params[0] != 0:
                self.pending[opcode] = params[0]
        elif evt == EVT_LE_META and params and params[0] == LE_ADV_REPORT:
            for rep in parse_adv_reports(params[1:]):
                self.last_report = time.monotonic()
                self.n_reports += 1
                self.addrs.add(rep[0])
                self.forward(pack_record(*rep))

    # ---- client side -------------------------------------------------------
    def open_server(self):
        try:
            os.unlink(self.sock_path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        old = os.umask(0o117)
        try:
            srv.bind(self.sock_path)
        finally:
            os.umask(old)
        if self.group:
            try:
                os.chown(self.sock_path, -1, grp.getgrnam(self.group).gr_gid)
            except (KeyError, PermissionError) as err:
                _LOGGER.warning("cannot give group %s access to %s: %s", self.group, self.sock_path, err)
        os.chmod(self.sock_path, 0o660)
        srv.listen(4)
        srv.setblocking(False)
        self.server = srv
        _LOGGER.info("listening on %s", self.sock_path)

    def accept(self):
        try:
            conn, _ = self.server.accept()
        except (BlockingIOError, InterruptedError):
            return
        conn.setblocking(False)
        self.clients.append(conn)
        _LOGGER.info("client connected (%d)", len(self.clients))

    def drop(self, conn):
        if conn in self.clients:
            self.clients.remove(conn)
            try:
                conn.close()
            except OSError:
                pass
            _LOGGER.info("client disconnected (%d left)", len(self.clients))

    def forward(self, record):
        for conn in list(self.clients):
            try:
                conn.send(record)
            except BlockingIOError:
                pass  # a slow client loses this report, the scan goes on
            except OSError:
                self.drop(conn)

    # ---- main loop ---------------------------------------------------------
    def stats(self, now):
        if now - self.last_stats >= STATS_EVERY:
            _LOGGER.info("%d reports from %d addresses in the last %d s, %d client(s)",
                         self.n_reports, len(self.addrs), int(now - self.last_stats), len(self.clients))
            self.n_reports = 0
            self.addrs = set()
            self.last_stats = now

    def run(self, stop):
        self.open_server()
        while not stop():
            now = time.monotonic()
            if self.hci is None and now - self.last_try >= 5.0:
                self.last_try = now
                try:
                    self.open_hci()
                except OSError as err:
                    self.hci_fail(f"HCI socket on {self.hci_name}", err)
            want = bool(self.clients)
            if self.hci is not None:
                if want and not self.scanning and now >= self.scan_retry_at:
                    if not self.set_scan(True):
                        self.scan_retry_at = now + 5.0
                elif not want and self.scanning:
                    self.set_scan(False)
                elif want and self.scanning and now - self.last_report > WATCHDOG:
                    _LOGGER.warning("no advertising report for %d s: sending the scan commands again", int(WATCHDOG))
                    self.scanning = False
                    if not self.set_scan(True):
                        self.scan_retry_at = now + 5.0
            self.stats(now)
            rlist = [self.server] + self.clients + ([self.hci] if self.hci is not None else [])
            try:
                r, _, _ = select.select(rlist, [], [], 1.0)
            except InterruptedError:
                continue
            for sock in r:
                if sock is self.server:
                    self.accept()
                elif sock is self.hci:
                    self.read_hci()
                else:
                    try:
                        data = sock.recv(64)
                    except (BlockingIOError, InterruptedError):
                        continue
                    except OSError:
                        data = b""
                    if not data:
                        self.drop(sock)
        if self.scanning:
            self.set_scan(False)
        for conn in list(self.clients):
            self.drop(conn)
        self.close_hci()
        try:
            os.unlink(self.sock_path)
        except OSError:
            pass


def main(argv=None):
    ap = argparse.ArgumentParser(description="Passive BLE scanner for the ESPHome Bluetooth proxy of the panel.")
    ap.add_argument("--hci", default="hci0")
    ap.add_argument("--socket", default="/run/tsx/bt-adv.sock")
    ap.add_argument("--group", default="kiosk")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s tsx-btscan: %(message)s", stream=sys.stdout)

    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(1))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(1))
    scanner = Scanner(args.hci, args.socket, args.group)
    try:
        scanner.run(lambda: bool(stopping))
    except OSError as err:
        if err.errno in (errno.EACCES, errno.EPERM):
            _LOGGER.error("%s (tsx-btscan must run as root)", err)
        else:
            _LOGGER.error("%s", err)
        return 1
    _LOGGER.info("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
