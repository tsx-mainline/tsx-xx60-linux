#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Daemon-side check of the active Bluetooth proxy for rootfs/tests/test-bt.sh.
It talks to the GATT socket of tsx-btscan (btscan.py, btgatt.py) the way the
ESPHome front end does (the JSON messages in the docstring of btscan.py).
The peers are the fakes of bt-gatt-peer.py behind TSX_BTSCAN_FAKE_L2CAP.

  bt-gatt-check.py GATT-SOCKET PEER-LOG

Prints one "ok:" or "FAIL:" line per check. Exit status = the failures.
"""
import json
import socket
import sys
import time

A1 = 0xC0FFEE000001    # a normal peer
A2 = 0xC0FFEE000002    # a normal peer with ATT MTU 23
A3 = 0xC0FFEE000003
A_SILENT = 0xC0FFEE0000EE
A_FAIL = 0xC0FFEE0000EF
LONG = (b"hello tsx " * 10)[:100]

FAILS = []


def ok(cond, text):
    print(("  ok: " if cond else "  FAIL: ") + text)
    if not cond:
        FAILS.append(text)


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.sock.connect(path)
        self.sock.settimeout(0.2)
        self.backlog = []

    def send(self, **msg):
        self.sock.send(json.dumps(msg).encode())

    def wait(self, pred, timeout=5.0):
        """The first message that matches pred (earlier ones stay queued)."""
        for i, msg in enumerate(self.backlog):
            if pred(msg):
                return self.backlog.pop(i)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                msg = json.loads(self.sock.recv(65536))
            except socket.timeout:
                continue
            if pred(msg):
                return msg
            self.backlog.append(msg)
        return None

    def ev(self, ev, addr=None, timeout=5.0, **kw):
        def pred(m):
            if m.get("ev") != ev or (addr is not None and m.get("addr") != addr):
                return False
            return all(m.get(k) == v for k, v in kw.items())
        return self.wait(pred, timeout)


def main():
    path, peer_log = sys.argv[1], sys.argv[2]
    c = Client(path)
    hello = c.ev("slots")
    ok(hello == {"ev": "slots", "limit": 2, "free": 2, "allocated": []},
       f"a new client gets the slot count first: {hello}")

    # ---- connect, MTU, slots
    t0 = time.monotonic()
    c.send(op="connect", addr=A1, atype=1)
    s1 = c.ev("slots", free=1)
    conn = c.ev("conn", A1)
    ok(s1 is not None and s1["allocated"] == [A1], f"the slot is taken at the request: {s1}")
    ok(conn == {"ev": "conn", "addr": A1, "connected": True, "mtu": 185, "error": 0},
       f"connect: connected, MTU 185 (the smaller of 517 and the peer), {time.monotonic() - t0:.2f} s: {conn}")
    c.send(op="connect", addr=A1, atype=1)
    again = c.ev("conn", A1)
    ok(again is not None and again["connected"] and again["mtu"] == 185, "a second connect to a linked device: connected again")

    # ---- services
    c.send(op="services", addr=A1)
    svcs = []
    while True:
        m = c.wait(lambda m: m.get("ev") in ("services", "services_done", "error") and m.get("addr") == A1)
        if m is None or m["ev"] != "services":
            break
        svcs += m["services"]
    ok(m is not None and m["ev"] == "services_done", "services end with services_done")
    got = [(s["uuid"][4:8], s["handle"], s["end"]) for s in svcs]
    ok(got == [("1800", 1, 3), ("fff0", 4, 15)], f"two primary services with their handle ranges: {got}")
    chars = {ch["uuid"]: ch for s in svcs for ch in s["chars"]}
    want = {"00002a00-0000-1000-8000-00805f9b34fb": (3, 0x02, []),
            "0000fff1-0000-1000-8000-00805f9b34fb": (6, 0x02, []),
            "7e570001-0000-4000-8000-747378746573": (8, 0x0E, []),
            "0000fff3-0000-1000-8000-00805f9b34fb": (10, 0x12, [("00002902-0000-1000-8000-00805f9b34fb", 11)]),
            "0000fff4-0000-1000-8000-00805f9b34fb": (13, 0x08, []),
            "0000fff5-0000-1000-8000-00805f9b34fb": (15, 0x02, [])}
    have = {u: (ch["handle"], ch["props"], [(d["uuid"], d["handle"]) for d in ch["descs"]]) for u, ch in chars.items()}
    ok(have == want, "characteristics: value handles, properties, the 128-bit UUID and the CCCD descriptor")

    # ---- read, write
    c.send(op="read", addr=A1, handle=6)
    r = c.ev("read", A1, handle=6)
    ok(r is not None and bytes.fromhex(r["data"]) == LONG, "read: 100 bytes in one Read at MTU 185")
    c.send(op="write", addr=A1, handle=8, data=b"panel".hex(), response=True)
    ok(c.ev("write", A1, handle=8) is not None, "write with response: answered")
    c.send(op="write", addr=A1, handle=8, data=b"quick".hex(), response=False)
    ok(c.ev("write", A1, timeout=0.5) is None, "write without response: no answer")
    c.send(op="read", addr=A1, handle=8)
    r = c.ev("read", A1, handle=8)
    ok(r is not None and bytes.fromhex(r["data"]) == b"quick", "the peer has the value of the write without response")
    c.send(op="read_desc", addr=A1, handle=11)
    r = c.ev("read", A1, handle=11)
    ok(r is not None and r["data"] == "0000", "read descriptor: the CCCD")
    c.send(op="read", addr=A1, handle=15)
    e = c.ev("error", A1, handle=15)
    ok(e is not None and e["error"] == 2, f"a read the peer refuses: ATT error 2 (read not permitted): {e}")

    # ---- notifications
    c.send(op="notify", addr=A1, handle=10, enable=True)
    ok(c.ev("notify", A1, handle=10) is not None, "notify on: answered")
    c.send(op="write_desc", addr=A1, handle=11, data="0100")
    ok(c.ev("write", A1, handle=11) is not None, "the client writes the CCCD itself: answered")
    vals = []
    end = time.monotonic() + 1.0
    while time.monotonic() < end:
        n = c.ev("notify_data", A1, timeout=0.3)
        if n:
            vals.append(int.from_bytes(bytes.fromhex(n["data"]), "little"))
    ok(len(vals) >= 5 and vals == sorted(vals), f"notifications arrive in order ({len(vals)} in 1 s)")
    c.send(op="notify", addr=A1, handle=10, enable=False)
    c.ev("notify", A1, handle=10)
    c.backlog = [m for m in c.backlog if m.get("ev") != "notify_data"]
    time.sleep(0.3)
    c.backlog = [m for m in c.backlog if m.get("ev") != "notify_data"]
    ok(c.ev("notify_data", A1, timeout=0.5) is None, "notify off: no more notifications for the front end")

    # ---- long values at MTU 23, a second link, the slot limit
    c.send(op="connect", addr=A2, atype=0)
    conn = c.ev("conn", A2)
    ok(conn is not None and conn["connected"] and conn["mtu"] == 23, f"a second link at the same time (MTU 23): {conn}")
    free = c.ev("slots", free=0)
    ok(free is not None and sorted(free["allocated"]) == [A1, A2], f"slots: 0 free, both addresses allocated: {free}")
    c.send(op="read", addr=A2, handle=6)
    r = c.ev("read", A2, handle=6)
    ok(r is not None and bytes.fromhex(r["data"]) == LONG, "long read at MTU 23: Read + Read Blob give all 100 bytes")
    c.send(op="write", addr=A2, handle=8, data=LONG[::-1].hex(), response=True)
    w = c.ev("write", A2, handle=8)
    c.send(op="read", addr=A2, handle=8)
    r = c.ev("read", A2, handle=8)
    ok(w is not None and r is not None and bytes.fromhex(r["data"]) == LONG[::-1],
       "long write at MTU 23: Prepare Write + Execute Write, the peer has all 100 bytes")
    c.send(op="connect", addr=A3, atype=0)
    full = c.ev("conn", A3, timeout=2)
    ok(full is not None and not full["connected"] and full["error"] == 0x80,
       f"a third link with 2 slots: refused at once with error 0x80 (no resources): {full}")

    # ---- disconnect on request, a drop by the peer
    t0 = time.monotonic()
    c.send(op="disconnect", addr=A2)
    d = c.ev("conn", A2)
    ok(d == {"ev": "conn", "addr": A2, "connected": False, "mtu": 0, "error": 0x16},
       f"disconnect: HCI Disconnect, then connected=false with reason 0x16 ({time.monotonic() - t0:.2f} s): {d}")
    ok(c.ev("slots", free=1) is not None, "the slot is free again")
    c.send(op="write", addr=A1, handle=13, data="01", response=True)
    d = c.ev("conn", A1, timeout=3)
    ok(d is not None and not d["connected"] and d["error"] == 0x13,
       f"the peer drops the link: connected=false, reason 0x13 (remote): {d}")
    c.send(op="read", addr=A1, handle=6)
    e = c.ev("error", A1, handle=6)
    ok(e is not None and e["error"] == -1, "a request on a link that is down: error -1 (not connected)")
    c.send(op="connect", addr=A1, atype=1)
    conn = c.ev("conn", A1)
    ok(conn is not None and conn["connected"], "a reconnect after the drop works")

    # ---- a slow answer does not block other links. A failed and a silent peer
    c.send(op="write", addr=A1, handle=13, data="02", response=True)
    c.ev("write", A1, handle=13)
    c.send(op="read", addr=A1, handle=8)
    c.send(op="connect", addr=A_FAIL, atype=0)
    f = c.ev("conn", A_FAIL)
    ok(f is not None and not f["connected"] and f["error"] == 0x3E, f"a link that does not come up: error 0x3E: {f}")
    r = c.ev("read", A1, handle=8, timeout=5)
    ok(r is not None, "a slow read (3 s) still gets its answer")
    t0 = time.monotonic()
    c.send(op="connect", addr=A_SILENT, atype=0)
    f = c.ev("conn", A_SILENT, timeout=10)
    dt = time.monotonic() - t0
    ok(f is not None and not f["connected"] and f["error"] == 0x08 and 1.5 < dt < 4,
       f"a silent peer: connect timeout (hook 2 s), error 0x08 after {dt:.1f} s: {f}")
    c.send(op="connect", addr=A_SILENT, atype=0)
    time.sleep(0.3)
    c.send(op="disconnect", addr=A_SILENT)
    f = c.ev("conn", A_SILENT, timeout=2)
    ok(f is not None and not f["connected"], "a disconnect while the link comes up cancels the connect at once")

    # ---- the front end goes away: its links go down
    c.sock.close()
    time.sleep(1.0)
    log = open(peer_log, encoding="ascii").read()
    ok(log.count("link closed by the proxy") >= 2, "a closed front end socket takes its links down")
    c2 = Client(path)
    hello = c2.ev("slots")
    ok(hello is not None and hello["free"] == 2 and hello["allocated"] == [], f"after that all slots are free: {hello}")
    c2.sock.close()
    return len(FAILS)


if __name__ == "__main__":
    sys.exit(main())
