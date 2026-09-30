#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Upload a PSR (persistent store) file into a CSR BlueCore chip over BCSP.

This is the "bccmd -t bcsp -d TTY -b 115200 psload -r FILE" step of the
vendor Bluetooth start script, for the CSR8811 on UART A of the xx60 panels.
BlueZ removed bccmd in version 5.66, and Alpine does not ship it. This file
does the same work with the Python standard library only.

What goes over the wire (the same as bccmd with its BCSP transport):
  - The serial line runs at 115200 baud, 8 data bits, even parity, one stop
    bit, no flow control (the BCSP defaults of the chip).
  - BCSP link establishment on channel 1: SYNC, SYNC-RESP, CONF, CONF-RESP.
  - For each "&KEY = WORD WORD ..." line of the PSR file, in file order: one
    reliable BCSP packet on channel 5 (HCI command/event). The packet is the
    vendor HCI command 0xFC00 with a BCCMD SETREQ for varid 0x7003 (PS). The
    store is 0x0008 (PSRAM), so the values last until the next cold reset.
  - The chip answers each command with vendor event 0xFF (a BCCMD GETRESP).
    A status other than 0 stops the upload.
  - Last, a BCCMD SETREQ for varid 0x4002 (warm reset). The chip restarts
    with the new values. After that, hciattach can attach the chip.

The BCSP framing: SLIP (0xC0 frames, 0xDB escapes), a 4-byte header (seq,
ack, CRC flag, reliable flag, channel, 12-bit length, header checksum), the
payload and a 16-bit CRC (the CRC-CCITT of BCSP, bit-reversed). Every packet
that this file sends carries the CRC, like the uBCSP code that bccmd used.

  csr_psload.py --device /dev/ttyAML1 [--baud 115200] [--no-reset] PSR [PSR...]
  csr_psload.py --check PSR [PSR...]      parse only, print the keys

Several PSR files load in the order given. A later value for the same key
wins, because the chip keeps the last write. Exit status: 0 = all keys
loaded, 1 = the chip did not answer or refused a key, 2 = bad arguments or
a bad PSR file.
"""

import argparse
import os
import re
import select
import struct
import sys
import termios
import time

SLIP_END = 0xC0
SLIP_ESC = 0xDB
SLIP_ESC_END = 0xDC
SLIP_ESC_ESC = 0xDD

CHAN_ACK = 0
CHAN_LE = 1
CHAN_HCI = 5

LE_SYNC = bytes((0xDA, 0xDC, 0xED, 0xED))
LE_SYNC_RESP = bytes((0xAC, 0xAF, 0xEF, 0xEE))
LE_CONF = bytes((0xAD, 0xEF, 0xAC, 0xED))
LE_CONF_RESP = bytes((0xDE, 0xAD, 0xD0, 0xD0))

BCCMD_GETREQ = 0x0000
BCCMD_GETRESP = 0x0001
BCCMD_SETREQ = 0x0002
VARID_PS = 0x7003
VARID_WARM_RESET = 0x4002
STORES_PSRAM = 0x0008
HCI_VENDOR_OPCODE = 0xFC00
BCCMD_DESCRIPTOR = 0xC2  # first + last fragment, channel 2 (BCCMD)

PSR_LINE = re.compile(r"^&([0-9A-Fa-f]{1,4})\s*=\s*((?:[0-9A-Fa-f]{1,4}\s*)*)$")


class PsloadError(Exception):
    """The chip did not answer, or it refused a key."""


# ---- PSR file -------------------------------------------------------------
def parse_psr(text):
    """Return a list of (key, [words]) in file order.

    The format is the one of bccmd: a line that starts with '&' holds
    "&KEY = WORD WORD ..." in hex. Other lines (comments with //, blank
    lines, commented-out keys) are ignored. A line that starts with '&' and
    does not match raises ValueError: a broken line must not load half a key.
    """
    out = []
    for num, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line.startswith("&"):
            continue
        m = PSR_LINE.match(line)
        if not m:
            raise ValueError(f"line {num}: not '&KEY = WORD ...': {line[:60]!r}")
        words = [int(w, 16) for w in m.group(2).split()]
        if not words:
            raise ValueError(f"line {num}: key &{m.group(1)} has no value")
        if len(words) > 120:
            raise ValueError(f"line {num}: key &{m.group(1)} has {len(words)} words (too long for one BCCMD)")
        out.append((int(m.group(1), 16), words))
    return out


def bdaddr_psr_line(mac):
    """The PSR line for PSKEY_BDADDR (&0001) of MAC "m1:m2:m3:m4:m5:m6".

    The same layout as the bt_getprop_mac.sh script of the vendor:
    "&0001 = 00m4 m5m6 00m3 m1m2" (LAP high, LAP low, UAP, NAP).
    """
    parts = mac.split(":")
    if len(parts) != 6 or not all(re.fullmatch(r"[0-9A-Fa-f]{2}", p) for p in parts):
        raise ValueError(f"not a MAC address: {mac!r}")
    m = [p.lower() for p in parts]
    return f"&0001 = 00{m[3]} {m[4]}{m[5]} 00{m[2]} {m[0]}{m[1]}"


# ---- BCSP packet layer ----------------------------------------------------
def crc_ccitt_bcsp(data, crc=0xFFFF):
    """The BCSP CRC: CRC-CCITT computed LSB first, then bit-reversed."""
    for byte in data:
        for _ in range(8):
            if (crc ^ byte) & 1:
                crc = (crc >> 1) ^ 0x8408
            else:
                crc >>= 1
            byte >>= 1
    rev = 0
    for _ in range(16):
        rev = (rev << 1) | (crc & 1)
        crc >>= 1
    return rev


def slip(data):
    out = bytearray((SLIP_END,))
    for byte in data:
        if byte == SLIP_END:
            out += bytes((SLIP_ESC, SLIP_ESC_END))
        elif byte == SLIP_ESC:
            out += bytes((SLIP_ESC, SLIP_ESC_ESC))
        else:
            out.append(byte)
    out.append(SLIP_END)
    return bytes(out)


def make_packet(chan, payload, reliable=False, seq=0, ack=0, crc=True):
    """One framed BCSP packet (SLIP included)."""
    length = len(payload)
    b0 = (0x80 if reliable else 0) | (0x40 if crc else 0) | ((ack & 7) << 3) | (seq & 7)
    b1 = (chan & 0x0F) | ((length & 0x0F) << 4)
    b2 = (length >> 4) & 0xFF
    hdr = bytes((b0, b1, b2, (~(b0 + b1 + b2)) & 0xFF))
    body = hdr + bytes(payload)
    if crc:
        c = crc_ccitt_bcsp(body)
        body += bytes((c >> 8, c & 0xFF))
    return slip(body)


class Packet:
    __slots__ = ("reliable", "seq", "ack", "chan", "payload")

    def __init__(self, reliable, seq, ack, chan, payload):
        self.reliable, self.seq, self.ack, self.chan, self.payload = reliable, seq, ack, chan, payload


def parse_packet(frame):
    """Decode one de-SLIPped frame. Return a Packet, or None if it is broken."""
    if len(frame) < 4 or (sum(frame[:4]) & 0xFF) != 0xFF:
        return None
    b0, b1, b2 = frame[0], frame[1], frame[2]
    length = ((b1 >> 4) & 0x0F) | (b2 << 4)
    has_crc = bool(b0 & 0x40)
    body = frame[4:]
    if has_crc:
        if len(body) != length + 2:
            return None
        c = crc_ccitt_bcsp(frame[:4 + length])
        if body[length:] != bytes((c >> 8, c & 0xFF)):
            return None
        body = body[:length]
    elif len(body) != length:
        return None
    return Packet(bool(b0 & 0x80), b0 & 7, (b0 >> 3) & 7, b1 & 0x0F, bytes(body))


class SlipReader:
    """Collect bytes, return complete de-SLIPped frames."""

    def __init__(self):
        self.buf = bytearray()
        self.esc = False
        self.inframe = False

    def feed(self, data):
        frames = []
        for byte in data:
            if byte == SLIP_END:
                if self.inframe and self.buf:
                    frames.append(bytes(self.buf))
                self.buf = bytearray()
                self.inframe = True
                self.esc = False
            elif not self.inframe:
                continue
            elif self.esc:
                self.buf.append(SLIP_END if byte == SLIP_ESC_END else SLIP_ESC if byte == SLIP_ESC_ESC else byte)
                self.esc = False
            elif byte == SLIP_ESC:
                self.esc = True
            else:
                self.buf.append(byte)
        return frames


# ---- BCCMD ------------------------------------------------------------------
def bccmd_hci_command(command, seqnum, varid, value=b""):
    """The HCI command packet (opcode 0xFC00) that carries one BCCMD message,
    exactly as bccmd builds it: the size in words is at least 9."""
    length = len(value)
    size = 9 if length < 8 else (length + 1) // 2 + 5
    msg = struct.pack("<HHHHH", command, size, seqnum, varid, 0) + bytes(value)
    msg = msg.ljust(size * 2, b"\0")
    params = bytes((BCCMD_DESCRIPTOR,)) + msg
    return struct.pack("<HB", HCI_VENDOR_OPCODE, len(params)) + params


def ps_value(key, words, stores=STORES_PSRAM):
    return struct.pack("<HHH", key, len(words), stores) + b"".join(struct.pack("<H", w) for w in words)


def parse_bccmd_event(payload):
    """Return (command, seqnum, varid, status) of a vendor event that holds a
    BCCMD answer, or None if the payload is something else."""
    if len(payload) < 13 or payload[0] != 0xFF or payload[2] != BCCMD_DESCRIPTOR:
        return None
    command, _size, seqnum, varid, status = struct.unpack_from("<HHHHH", payload, 3)
    return command, seqnum, varid, status


# ---- the link -----------------------------------------------------------------
class BcspLink:
    """A minimal BCSP peer with a window of one packet, like uBCSP."""

    def __init__(self, fd, log=None, retry=0.25):
        self.fd = fd
        self.log = log or (lambda msg: None)
        self.retry = retry
        self.reader = SlipReader()
        self.seq = 0      # the seq of our next reliable packet
        self.ack = 0      # the seq that we expect next from the chip
        self.active = False
        self.inbox = []   # reliable/unreliable payloads on channel 5

    # -- I/O
    def _write(self, data):
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.fd, view)
            except BlockingIOError:
                select.select([], [self.fd], [], 1.0)
                continue
            view = view[n:]

    def _read_frames(self, timeout):
        r, _, _ = select.select([self.fd], [], [], max(0.0, timeout))
        if not r:
            return []
        try:
            data = os.read(self.fd, 4096)
        except (BlockingIOError, InterruptedError):
            return []
        return self.reader.feed(data)

    def _send_ack(self):
        self._write(make_packet(CHAN_ACK, b"", reliable=False, ack=self.ack))

    # -- receive handling; returns the packets that the caller may want
    def _handle(self, pkt):
        if pkt.chan == CHAN_LE:
            body = pkt.payload[:4]
            if body == LE_SYNC:
                if self.active:
                    raise PsloadError("the chip reset during the upload (BCSP SYNC while the link was up)")
                self._write(make_packet(CHAN_LE, LE_SYNC_RESP))
            elif body == LE_CONF:
                self._write(make_packet(CHAN_LE, LE_CONF_RESP))
            return pkt
        if pkt.reliable:
            if pkt.seq == self.ack:
                self.ack = (self.ack + 1) & 7
                self._send_ack()
                if pkt.chan == CHAN_HCI:
                    self.inbox.append(pkt.payload)
            else:
                self._send_ack()  # a resend of a packet that we already have
        elif pkt.chan == CHAN_HCI:
            self.inbox.append(pkt.payload)
        return pkt

    def establish(self, timeout=5.0):
        """Run the link establishment. Raise PsloadError on a timeout."""
        deadline = time.monotonic() + timeout
        state = "sync"
        next_send = 0.0
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_send:
                self._write(make_packet(CHAN_LE, LE_SYNC if state == "sync" else LE_CONF))
                next_send = now + self.retry
            for frame in self._read_frames(min(self.retry, deadline - now)):
                pkt = parse_packet(frame)
                if pkt is None:
                    continue
                self._handle(pkt)
                if pkt.chan != CHAN_LE:
                    continue
                if pkt.payload[:4] == LE_SYNC_RESP and state == "sync":
                    state = "conf"
                    next_send = 0.0
                elif pkt.payload[:4] == LE_CONF and state == "sync":
                    # The CSR8811 on the panel answers our SYNC with its own
                    # SYNC. It then gets our SYNC-RESP and sends CONF, but it
                    # never sends a SYNC-RESP. A CONF shows that the chip has
                    # our SYNC-RESP, so go on with our CONF. Another SYNC from
                    # us would restart the link establishment of the chip.
                    state = "conf"
                    next_send = 0.0
                elif pkt.payload[:4] == LE_CONF_RESP and state == "conf":
                    self.active = True
                    self.log("BCSP link up")
                    return
        raise PsloadError("no BCSP answer from the chip (%s stage). Check the reset line, the UART and the parity"
                          % ("SYNC" if state == "sync" else "CONF"))

    def send_reliable(self, payload, timeout=3.0, want_ack=True):
        """Send one reliable packet on channel 5 and wait for its ack.

        Return True when the chip acknowledged the packet. With
        want_ack=False, a missing ack is not an error (the warm reset)."""
        seq = self.seq
        deadline = time.monotonic() + timeout
        next_send = 0.0
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_send:
                self._write(make_packet(CHAN_HCI, payload, reliable=True, seq=seq, ack=self.ack))
                next_send = now + self.retry
            for frame in self._read_frames(min(self.retry, deadline - now)):
                pkt = parse_packet(frame)
                if pkt is None:
                    continue
                self._handle(pkt)
                if pkt.chan != CHAN_LE and pkt.ack == ((seq + 1) & 7):
                    self.seq = (seq + 1) & 7
                    return True
        if want_ack:
            raise PsloadError("the chip did not acknowledge a BCSP packet")
        return False

    def wait_event(self, match, timeout=3.0):
        """Wait for a channel-5 payload for which match(payload) is true."""
        deadline = time.monotonic() + timeout
        while True:
            for i, payload in enumerate(self.inbox):
                if match(payload):
                    del self.inbox[i]
                    return payload
            now = time.monotonic()
            if now >= deadline:
                raise PsloadError("no BCCMD answer from the chip")
            for frame in self._read_frames(min(self.retry, deadline - now)):
                pkt = parse_packet(frame)
                if pkt is not None:
                    self._handle(pkt)


def open_tty(path, baud):
    speeds = {9600: termios.B9600, 38400: termios.B38400, 57600: termios.B57600,
              115200: termios.B115200, 230400: termios.B230400}
    if baud not in speeds:
        raise ValueError(f"unsupported baud rate {baud}")
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag = 0, 0, attrs[2], 0
    cflag &= ~(termios.CSIZE | termios.CSTOPB | termios.PARODD | getattr(termios, "CRTSCTS", 0))
    cflag |= termios.CS8 | termios.PARENB | termios.CLOCAL | termios.CREAD
    cc = attrs[6]
    cc[termios.VMIN] = 1
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speeds[baud], speeds[baud], cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def psload(fd, keys, reset=True, log=print, link_timeout=5.0):
    """Load the keys over an open, configured tty. Raise PsloadError."""
    link = BcspLink(fd, log=log)
    link.establish(timeout=link_timeout)
    seqnum = 0
    for key, words in keys:
        link.send_reliable(bccmd_hci_command(BCCMD_SETREQ, seqnum, VARID_PS, ps_value(key, words)))
        want = seqnum

        def match(payload, want=want):
            ev = parse_bccmd_event(payload)
            return ev is not None and ev[1] == want

        ev = parse_bccmd_event(link.wait_event(match))
        if ev[0] != BCCMD_GETRESP or ev[3] != 0:
            raise PsloadError(f"the chip refused PS key 0x{key:04x} (BCCMD status {ev[3]})")
        log(f"loaded PS key 0x{key:04x} ({len(words)} words)")
        seqnum += 1
    if reset:
        # bccmd ignores the result of this step: the chip can restart before
        # it acknowledges the packet, and then it sends a SYNC.
        try:
            acked = link.send_reliable(bccmd_hci_command(BCCMD_SETREQ, seqnum, VARID_WARM_RESET),
                                       timeout=1.0, want_ack=False)
        except PsloadError:
            acked = False
        log("warm reset sent" + ("" if acked else " (no ack: the chip restarted first)"))
    return len(keys)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Upload a PSR file into a CSR BlueCore chip over BCSP (bccmd psload).")
    ap.add_argument("psr", nargs="+", help="PSR file(s), loaded in this order")
    ap.add_argument("--device", default="/dev/ttyAML1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-reset", action="store_true", help="do not warm-reset the chip after the upload")
    ap.add_argument("--timeout", type=float, default=5.0, help="seconds to wait for the BCSP link (default 5)")
    ap.add_argument("--check", action="store_true", help="parse the files and print the keys, do not open the device")
    args = ap.parse_args(argv)

    keys = []
    for path in args.psr:
        try:
            with open(path, "r", encoding="ascii") as fobj:
                keys += parse_psr(fobj.read())
        except (OSError, UnicodeDecodeError, ValueError) as err:
            print(f"csr_psload: {path}: {err}", file=sys.stderr)
            return 2
    if not keys:
        print("csr_psload: no PS keys in the given files", file=sys.stderr)
        return 2
    if args.check:
        for key, words in keys:
            print(f"0x{key:04x} {len(words)} words")
        return 0

    def log(msg):
        print(f"csr_psload: {msg}", flush=True)

    try:
        fd = open_tty(args.device, args.baud)
    except (OSError, ValueError, termios.error) as err:
        print(f"csr_psload: {args.device}: {err}", file=sys.stderr)
        return 1
    try:
        n = psload(fd, keys, reset=not args.no_reset, log=log, link_timeout=args.timeout)
    except PsloadError as err:
        print(f"csr_psload: {err}", file=sys.stderr)
        return 1
    finally:
        os.close(fd)
    log(f"done: {n} PS keys loaded from {len(args.psr)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
