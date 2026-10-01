#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A small BLE peripheral with a GATT server, for the tests of the active
Bluetooth proxy (rootfs/overlay/usr/local/lib/tsx/btgatt.py).

  bt-gatt-peer.py fake SOCKET LOG [--mtu N]
  bt-gatt-peer.py hw LOG [--hci 0] [--name tsx-test-peer]

fake: a fake L2CAP peer for the host tests (TSX_BTSCAN_FAKE_L2CAP=SOCKET).
  It listens on SOCKET (SOCK_SEQPACKET). tsx-btscan connects once for each
  BLE link and sends one hello message: "ADDRESS ADDRESS-TYPE" (text). The
  peer answers with "OK HANDLE" and then serves ATT on the same socket (one
  ATT PDU per message), like the ATT socket of the kernel. The address
  picks the behavior:
    ...:01 .. ...:0F   a normal peripheral (...:02 with ATT MTU 23)
    ...:EE             never answers the hello (a connect timeout)
    ...:EF             answers "FAIL 3E" (the link does not come up)
  --mtu sets the ATT MTU of the peer (default 185). With MTU 23, reads and
  writes of the 100-byte characteristic need Read Blob and Prepare Write.

hw: a real peripheral on a panel (root, hci0 up, no bluetoothd). It
  advertises (ADV_IND, 100 ms, the name), listens on the ATT fixed channel
  (L2CAP CID 4) and serves the same GATT database. After a link drops, it
  advertises again. Stop it with SIGTERM: it stops the advertising.

The GATT database (handles):
  1-3    GAP service 0x1800: 0x2A00 device name (read)
  4-15   service 0xFFF0:
    6    0xFFF1 read: "hello tsx " repeated to 100 bytes
    8    7e570001-0000-4000-8000-747378746573 read, write, write without
         response: the last value written (starts as "init")
    10   0xFFF3 read, notify: a 4-byte counter. With its CCCD (11) = 01 00,
         the peer notifies every 0.2 s
    13   0xFFF4 write: 01 = drop the link, 02 = read the next value slowly
         (after 3 s)
    15   0xFFF5 read: returns ATT error 0x02 (read not permitted)
LOG gets one line per ATT request and per link event. The data is made up.
"""
import argparse
import os
import select
import signal
import socket
import struct
import sys
import time

GAP_NAME = b"tsx-test-peer"
LONG = (b"hello tsx " * 10)[:100]
WRITABLE_UUID = bytes.fromhex("7e570001000040008000747378746573")[::-1]


def u16(v):
    return struct.pack("<H", v)


class Db:
    """The attribute table: handle -> [type uuid (bytes, LE), value, read_error]."""

    def __init__(self, name):
        self.attrs = {}
        a = self.attrs
        a[1] = [u16(0x2800), u16(0x1800), 0]
        a[2] = [u16(0x2803), bytes((0x02,)) + u16(3) + u16(0x2A00), 0]
        a[3] = [u16(0x2A00), name, 0]
        a[4] = [u16(0x2800), u16(0xFFF0), 0]
        a[5] = [u16(0x2803), bytes((0x02,)) + u16(6) + u16(0xFFF1), 0]
        a[6] = [u16(0xFFF1), LONG, 0]
        a[7] = [u16(0x2803), bytes((0x0E,)) + u16(8) + WRITABLE_UUID, 0]
        a[8] = [WRITABLE_UUID, b"init", 0]
        a[9] = [u16(0x2803), bytes((0x12,)) + u16(10) + u16(0xFFF3), 0]
        a[10] = [u16(0xFFF3), struct.pack("<I", 0), 0]
        a[11] = [u16(0x2902), b"\x00\x00", 0]
        a[12] = [u16(0x2803), bytes((0x08,)) + u16(13) + u16(0xFFF4), 0]
        a[13] = [u16(0xFFF4), b"", 0]
        a[14] = [u16(0x2803), bytes((0x02,)) + u16(15) + u16(0xFFF5), 0]
        a[15] = [u16(0xFFF5), b"secret", 0x02]
        self.groups = [(1, 3), (4, 15)]


def err(op, handle, code):
    return bytes((0x01, op)) + u16(handle) + bytes((code,))


class AttServer:
    """The ATT server of one link. send(pdu) sends one PDU on the link."""

    def __init__(self, db, mtu, send, log, drop):
        self.db = db
        self.my_mtu = mtu
        self.mtu = 23
        self.send = send
        self.log = log
        self.drop = drop
        self.queue = []
        self.counter = 0
        self.next_notify = 0.0
        self.slow_read = False
        self.pending = None  # (time, pdu) of a slow answer

    def notifying(self):
        return self.db.attrs[11][1][0] & 1

    def tick(self, now, period):
        if self.pending and now >= self.pending[0]:
            self.send(self.pending[1])
            self.pending = None
        if self.notifying() and now >= self.next_notify:
            self.next_notify = now + period
            self.counter += 1
            val = struct.pack("<I", self.counter)
            self.db.attrs[10][1] = val
            self.send(bytes((0x1B,)) + u16(10) + val[: self.mtu - 3])

    def handle(self, pdu):
        op = pdu[0]
        a = self.db.attrs
        if op == 0x02:
            client = struct.unpack_from("<H", pdu, 1)[0]
            self.mtu = max(23, min(client, self.my_mtu))
            self.log(f"mtu client={client} use={self.mtu}")
            return bytes((0x03,)) + u16(self.my_mtu)
        if op == 0x10:  # Read By Group Type
            start, end = struct.unpack_from("<HH", pdu, 1)
            self.log(f"read_by_group {start:04x}-{end:04x}")
            out = [(s, e) for s, e in self.db.groups if start <= s <= end]
            if not out:
                return err(op, start, 0x0A)
            return bytes((0x11, 6)) + b"".join(u16(s) + u16(e) + a[s][1] for s, e in out if len(a[s][1]) == 2)
        if op == 0x08:  # Read By Type
            start, end = struct.unpack_from("<HH", pdu, 1)
            typ = pdu[5:]
            self.log(f"read_by_type {start:04x}-{end:04x} {typ[::-1].hex()}")
            hits = [h for h in sorted(a) if start <= h <= end and a[h][0] == typ]
            if not hits:
                return err(op, start, 0x0A)
            # one response holds entries of one length only: it stops at
            # the first attribute of another length
            ln = len(a[hits[0]][1])
            body = b""
            for h in hits:
                if len(a[h][1]) != ln:
                    break
                ent = u16(h) + a[h][1]
                if 2 + len(body) + len(ent) > self.mtu:
                    break
                body += ent
            return bytes((0x09, ln + 2)) + body
        if op == 0x04:  # Find Information
            start, end = struct.unpack_from("<HH", pdu, 1)
            self.log(f"find_info {start:04x}-{end:04x}")
            hits = [h for h in sorted(a) if start <= h <= end]
            if not hits:
                return err(op, start, 0x0A)
            fmt = 1 if len(a[hits[0]][0]) == 2 else 2
            body = b""
            for h in hits:
                if (len(a[h][0]) == 2) != (fmt == 1):
                    break
                ent = u16(h) + a[h][0]
                if 2 + len(body) + len(ent) > self.mtu:
                    break
                body += ent
            return bytes((0x05, fmt)) + body
        if op in (0x0A, 0x0C):  # Read, Read Blob
            h = struct.unpack_from("<H", pdu, 1)[0]
            off = struct.unpack_from("<H", pdu, 3)[0] if op == 0x0C else 0
            self.log(f"{'read' if op == 0x0A else 'read_blob'} {h} {off}")
            if h not in a:
                return err(op, h, 0x01)
            if a[h][2]:
                return err(op, h, a[h][2])
            val = a[h][1]
            if off > len(val):
                return err(op, h, 0x07)
            rsp = bytes((op + 1,)) + val[off:off + self.mtu - 1]
            if self.slow_read and op == 0x0A:
                self.slow_read = False
                self.pending = (time.monotonic() + 3.0, rsp)
                return None
            return rsp
        if op in (0x12, 0x52):  # Write Request, Write Command
            h = struct.unpack_from("<H", pdu, 1)[0]
            val = pdu[3:]
            self.log(f"{'write' if op == 0x12 else 'write_cmd'} {h} {val.hex()}")
            if h not in (8, 11, 13):
                return err(op, h, 0x03) if op == 0x12 else None
            self.store(h, val)
            return b"\x13" if op == 0x12 else None
        if op == 0x16:  # Prepare Write
            h, off = struct.unpack_from("<HH", pdu, 1)
            self.log(f"prepare {h} {off} {len(pdu) - 5}")
            self.queue.append((h, off, pdu[5:]))
            return bytes((0x17,)) + pdu[1:]
        if op == 0x18:  # Execute Write
            self.log(f"execute {pdu[1]}")
            if pdu[1] == 1 and self.queue:
                h = self.queue[0][0]
                val = bytearray()
                for _, off, part in self.queue:
                    val[off:off + len(part)] = part
                self.store(h, bytes(val))
            self.queue = []
            return b"\x19"
        if op == 0x1E:  # Handle Value Confirmation
            return None
        if op & 0x40:  # a command: no answer
            return None
        self.log(f"unsupported 0x{op:02x}")
        return err(op, 0, 0x06)

    def store(self, h, val):
        if h == 13:
            if val[:1] == b"\x01":
                self.log("drop requested")
                self.drop()
            elif val[:1] == b"\x02":
                self.slow_read = True
            return
        self.db.attrs[h][1] = val
        if h == 11:
            self.log(f"cccd {val.hex()}")


def open_log(path):
    fobj = open(path, "a", buffering=1, encoding="ascii")
    return lambda text: fobj.write(f"{time.monotonic():.3f} {text}\n")


# ---- fake mode -------------------------------------------------------------
def run_fake(args):
    log = open_log(args.log)
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    srv.bind(args.socket)
    srv.listen(8)
    links = {}  # socket -> AttServer or None (before the hello)
    handles = iter(range(0x40, 0x0FFF))
    while True:
        r, _, _ = select.select([srv] + list(links), [], [], 0.05)
        now = time.monotonic()
        if srv in r:
            conn, _ = srv.accept()
            links[conn] = None
        for conn in [c for c in r if c is not srv]:
            try:
                pdu = conn.recv(1024)
            except OSError:
                pdu = b""
            if not pdu:
                log("link closed by the proxy")
                links.pop(conn, None)
                conn.close()
                continue
            if links[conn] is None:
                addr, atype = pdu.decode().split()
                last = int(addr.split(":")[-1], 16)
                log(f"connect {addr} {atype}")
                if last == 0xEE:
                    links[conn] = "silent"
                    continue
                if last == 0xEF:
                    conn.send(b"FAIL 3E")
                    links.pop(conn)
                    conn.close()
                    continue

                def drop(c=conn):
                    log("link dropped by the peer")
                    links.pop(c, None)
                    c.close()

                mtu = 23 if last == 0x02 else args.mtu
                links[conn] = AttServer(Db(GAP_NAME), mtu, conn.send, log, drop)
                conn.send(f"OK {next(handles)}".encode())
                continue
            if links[conn] == "silent":
                continue
            rsp = links[conn].handle(pdu)
            if rsp and conn in links:
                conn.send(rsp)
        for conn, att in list(links.items()):
            if isinstance(att, AttServer):
                try:
                    att.tick(now, 0.1)
                except OSError:
                    links.pop(conn, None)


# ---- hardware mode -----------------------------------------------------------
def hci_cmd(sock, ogf, ocf, params=b""):
    op = (ogf << 10) | ocf
    sock.send(struct.pack("<BHB", 1, op, len(params)) + params)
    end = time.monotonic() + 2
    while time.monotonic() < end:
        r, _, _ = select.select([sock], [], [], 0.2)
        if not r:
            continue
        p = sock.recv(300)
        if p[1] == 0x0E and struct.unpack_from("<H", p, 4)[0] == op:
            return p[6]
        if p[1] == 0x0F and struct.unpack_from("<H", p, 5)[0] == op:
            return p[3]
    return None


def advertise(hci, name, on):
    if not on:
        return hci_cmd(hci, 0x08, 0x000A, b"\x00")
    params = struct.pack("<HHBBB6sBB", 0xA0, 0xA0, 0, 0, 0, b"\x00" * 6, 7, 0)
    st = hci_cmd(hci, 0x08, 0x0006, params)
    ad = b"\x02\x01\x06" + bytes((len(name) + 1, 0x09)) + name
    st2 = hci_cmd(hci, 0x08, 0x0008, bytes((len(ad),)) + ad.ljust(31, b"\x00"))
    st3 = hci_cmd(hci, 0x08, 0x000A, b"\x01")
    return (st, st2, st3)


def run_hw(args):
    log = open_log(args.log)
    name = args.name.encode()
    hci = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    hci.setsockopt(socket.SOL_HCI, socket.HCI_FILTER,
                   struct.pack("<IIIHxx", 1 << 4, (1 << 0x0E) | (1 << 0x0F), 0, 0))
    hci.bind((args.hci,))
    # LE host support: the kernel then takes LE links (no bluetoothd here)
    st = hci_cmd(hci, 0x03, 0x006D, bytes((1, 0)))
    log(f"le host support: status {st}")
    srv = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    srv.bind((socket.BDADDR_ANY, 0, 4, socket.BDADDR_LE_PUBLIC))
    srv.listen(1)
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    log(f"advertising {args.name}: status {advertise(hci, name, True)}")
    conn = None
    att = None
    while not stop:
        rl = [srv] + ([conn] if conn else [])
        try:
            r, _, _ = select.select(rl, [], [], 0.05)
        except InterruptedError:
            continue
        if srv in r:
            c, peer = srv.accept()
            if conn:
                c.close()
            else:
                conn = c
                cinfo = conn.getsockopt(6, 2, 8)  # SOL_L2CAP, L2CAP_CONNINFO
                handle = struct.unpack_from("<H", cinfo)[0]
                log(f"link up from {peer[0]} handle {handle}")

                def drop(h=handle):
                    log("drop requested: HCI Disconnect")
                    hci.send(struct.pack("<BHB", 1, 0x0406, 3) + u16(h) + b"\x13")

                att = AttServer(Db(GAP_NAME), 517, conn.send, log, drop)
        if conn and conn in r:
            try:
                pdu = conn.recv(1024)
            except OSError as e:
                pdu = b""
                log(f"link error {e}")
            if not pdu:
                log("link down")
                conn.close()
                conn = att = None
                time.sleep(0.2)
                log(f"advertising again: status {advertise(hci, name, True)}")
                continue
            rsp = att.handle(pdu)
            if rsp:
                conn.send(rsp)
        if att:
            try:
                att.tick(time.monotonic(), 0.2)
            except OSError:
                pass
    advertise(hci, name, False)
    if conn:
        conn.close()
    log("stopped")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    f = sub.add_parser("fake")
    f.add_argument("socket")
    f.add_argument("log")
    f.add_argument("--mtu", type=int, default=185)
    h = sub.add_parser("hw")
    h.add_argument("log")
    h.add_argument("--hci", type=int, default=0)
    h.add_argument("--name", default="tsx-test-peer")
    args = ap.parse_args()
    if args.mode == "fake":
        run_fake(args)
    else:
        run_hw(args)


if __name__ == "__main__":
    sys.exit(main())
