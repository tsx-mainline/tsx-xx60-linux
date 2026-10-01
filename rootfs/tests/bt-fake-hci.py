#!/usr/bin/env python3
"""A fake Bluetooth controller for the host tests of tsx-btscan
(rootfs/overlay/usr/local/lib/tsx/btscan.py, TSX_BTSCAN_FAKE_HCI).

  bt-fake-hci.py SOCKET LOG

It listens on SOCKET (SOCK_SEQPACKET) and serves one tsx-btscan at a time.
Each HCI command gets a Command Complete with status 0, except "LE Set Scan
Enable (disable)" while no scan runs: that gets status 0x0C (Command
Disallowed), as a real controller answers. While the scan is on, the fake
sends the ADVERTS below every 0.2 s: one LE Advertising Report event with
two reports, then one with a single report. HCI Disconnect (0x0406) gets a
Command Status and a Disconnection Complete (reason 0x16) for the handle.
LOG gets one line per command: "cmd OPCODE PARAMS-HEX". The advertisement
data is made up.
"""
import os
import select
import socket
import struct
import sys
import time

# (address as printed, HCI address type, rssi, event type, data)
ADVERTS = [
    ("C0:FF:EE:00:00:01", 1, -60, 0, bytes.fromhex("0201060aff4c001005031c000001")),
    ("12:34:56:78:9A:BC", 0, -75, 3, bytes.fromhex("0303aafe1116aafe10f403676f6f676c6507")),
    ("00:11:22:33:44:55", 3, -90, 0, b""),
]


def addr_bytes(text):
    return bytes(int(x, 16) for x in reversed(text.split(":")))


def report(entries):
    body = bytes((0x02, len(entries)))
    for text, atype, rssi, etype, data in entries:
        body += bytes((etype, atype)) + addr_bytes(text) + bytes((len(data),)) + data + struct.pack("b", rssi)
    return bytes((0x04, 0x3E, len(body))) + body


def main():
    path, logpath = sys.argv[1], sys.argv[2]
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    srv.bind(path)
    srv.listen(1)
    log = open(logpath, "a", buffering=1, encoding="ascii")
    conn = None
    scanning = False
    next_adv = 0.0
    while True:
        rlist = [srv] + ([conn] if conn else [])
        r, _, _ = select.select(rlist, [], [], 0.05)
        if srv in r:
            if conn:
                conn.close()
            conn, _ = srv.accept()
            scanning = False
            log.write("connect\n")
        if conn and conn in r:
            pkt = conn.recv(300)
            if not pkt:
                conn.close()
                conn = None
                scanning = False
                log.write("disconnect\n")
                continue
            if pkt[0] != 0x01 or len(pkt) < 4:
                continue
            opcode = struct.unpack_from("<H", pkt, 1)[0]
            params = pkt[4:4 + pkt[3]]
            log.write(f"cmd {opcode:04x} {params.hex()}\n")
            status = 0
            if opcode == 0x0406:
                try:
                    conn.send(bytes((0x04, 0x0F, 4, 0, 1)) + struct.pack("<H", opcode))
                    conn.send(bytes((0x04, 0x05, 4, 0)) + params[:2] + bytes((0x16,)))
                except OSError:
                    pass
                continue
            if opcode == 0x200C:
                if params[0] == 0 and not scanning:
                    status = 0x0C
                elif params[0] == 1 and scanning:
                    status = 0x0C
                else:
                    scanning = params[0] == 1
            try:
                conn.send(bytes((0x04, 0x0E, 4, 1)) + struct.pack("<H", opcode) + bytes((status,)))
            except OSError:
                conn.close()
                conn = None
                continue
        if conn and scanning and time.monotonic() >= next_adv:
            next_adv = time.monotonic() + 0.2
            try:
                conn.send(report(ADVERTS[:2]))
                conn.send(report(ADVERTS[2:]))
            except OSError:
                conn.close()
                conn = None


if __name__ == "__main__":
    main()
