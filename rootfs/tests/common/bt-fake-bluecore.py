#!/usr/bin/env python3
"""A fake CSR BlueCore on a pseudo terminal, for the host test of the PSR
loader (rootfs/overlay/usr/local/lib/tsx/csr_psload.py). The test
test-bt-csr8811.sh runs it.

  bt-fake-bluecore.py MODE RESULT -- COMMAND...

The script opens a pty, runs COMMAND with every "@TTY@" replaced by the
slave path, and plays the chip on the master side until COMMAND exits. It
writes what it received as JSON to RESULT: the PS keys in order
([key, stores, [words]]), the warm reset, the exit status of COMMAND.

MODE:
  ok        answer every BCCMD with status 0
  refuse    answer the third PS key with status 3 (a bad key)
  lossy     ignore the first copy of every reliable packet (the loader
            must send it again)
  silent    never answer (the loader must time out)
  csr8811   the link establishment of the real CSR8811 on unit B
            (2026-09-30): it answers a SYNC with its own SYNC, never sends a
            SYNC-RESP, sends CONF after our SYNC-RESP, and restarts the link
            establishment on a SYNC after that. Its packets carry a CRC.

The chip side of the protocol follows the BCSP specification: it sends its
own SYNC first, answers SYNC and CONF, acknowledges reliable packets with
the ack field and answers each BCCMD with a reliable vendor event 0xFF on
channel 5. It sends its packets without a CRC, so the loader must accept
both forms.
"""
import json
import os
import pty
import select
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "overlay", "usr", "local", "lib", "tsx"))
import csr_psload as c  # noqa: E402


def main():
    mode, result = sys.argv[1], sys.argv[2]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    master, slave = pty.openpty()
    tty = os.ttyname(slave)
    proc = subprocess.Popen([a.replace("@TTY@", tty) for a in cmd])
    reader = c.SlipReader()
    keys, resets, drops = [], 0, set()
    expect = 0      # the next seq we accept from the loader
    my_seq = 0
    out = {"link": False, "keys": keys, "resets": 0, "resent": 0}

    def send(chan, payload, reliable=False):
        nonlocal my_seq
        seq = my_seq
        if reliable:
            my_seq = (my_seq + 1) & 7
        os.write(master, c.make_packet(chan, payload, reliable=reliable, seq=seq, ack=expect, crc=(mode == "csr8811")))

    if mode != "silent":
        send(c.CHAN_LE, c.LE_SYNC)
    deadline = time.monotonic() + 30
    while proc.poll() is None and time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.05)
        if not r:
            continue
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        for frame in reader.feed(data):
            pkt = c.parse_packet(frame)
            if pkt is None or mode == "silent":
                continue
            if pkt.chan == c.CHAN_LE and mode == "csr8811":
                if pkt.payload == c.LE_SYNC:
                    out["link"] = False
                    send(c.CHAN_LE, c.LE_SYNC)
                elif pkt.payload == c.LE_SYNC_RESP:
                    send(c.CHAN_LE, c.LE_CONF)
                elif pkt.payload == c.LE_CONF:
                    send(c.CHAN_LE, c.LE_CONF_RESP)
                    out["link"] = True
                continue
            if pkt.chan == c.CHAN_LE:
                if pkt.payload == c.LE_SYNC:
                    send(c.CHAN_LE, c.LE_SYNC_RESP)
                elif pkt.payload == c.LE_CONF:
                    send(c.CHAN_LE, c.LE_CONF_RESP)
                    out["link"] = True
                continue
            if not pkt.reliable:
                continue
            if pkt.seq != expect:
                out["resent"] += 1
                send(c.CHAN_ACK, b"")   # a copy we already have: ack again
                continue
            if mode == "lossy" and (pkt.seq, len(keys), resets) not in drops:
                drops.add((pkt.seq, len(keys), resets))
                continue
            expect = (expect + 1) & 7
            p = pkt.payload
            if len(p) < 14 or p[:2] != b"\x00\xfc" or p[3] != c.BCCMD_DESCRIPTOR:
                send(c.CHAN_ACK, b"")
                continue
            command, size, seqnum, varid, _st = struct.unpack_from("<HHHHH", p, 4)
            value = p[14:]
            if varid == c.VARID_WARM_RESET:
                resets += 1
                send(c.CHAN_ACK, b"")
                send(c.CHAN_LE, c.LE_SYNC)   # the chip restarts
                continue
            key, length, stores = struct.unpack_from("<HHH", value, 0)
            words = list(struct.unpack_from("<%dH" % length, value, 6))
            keys.append([key, stores, words])
            status = 3 if (mode == "refuse" and len(keys) == 3) else 0
            resp = struct.pack("<HHHHH", c.BCCMD_GETRESP, size, seqnum, varid, status) + value
            params = bytes((c.BCCMD_DESCRIPTOR,)) + resp
            send(c.CHAN_HCI, bytes((0xFF, len(params))) + params, reliable=True)
    try:
        rc = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        rc = "killed"
    out["resets"] = resets
    out["rc"] = rc
    with open(result, "w", encoding="ascii") as fobj:
        json.dump(out, fobj)


if __name__ == "__main__":
    main()
