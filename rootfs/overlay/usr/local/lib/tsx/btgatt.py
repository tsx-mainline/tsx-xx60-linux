# SPDX-License-Identifier: GPL-2.0-or-later
"""tsx-btscan, active connections: BLE links and a GATT client over ATT.

btscan.py imports this module when Home Assistant uses the panel as an
active Bluetooth proxy (panel.conf BT_ACTIVE=on). The docstring of btscan.py
describes the socket protocol to the ESPHome front ends. This module holds
the link and ATT logic, with no socket server of its own.

One BLE link = one kernel L2CAP socket on the ATT fixed channel (CID 4).
connect() of that socket makes the kernel scan for the device and send
LE Create Connection. No bluetoothd runs, so this module is the GATT client:
MTU exchange, service discovery, read (with Read Blob for long values),
write (Prepare/Execute Write for long values), write without response,
notifications and indications (with the confirmation). The client writes
the CCCD itself (ESPHome REMOTE_CACHING): "notify" here only selects which
notifications go to the front end. ATT requests from the peer get "Request
Not Supported", except the MTU exchange.

The kernel runs its own scan while it connects, and it stops every scan
when the connection is up or has failed. Links therefore ask the scanner to
pause the passive scan before connect() and to start it again after.

Test hook: TSX_BTSCAN_FAKE_L2CAP=<path of a SOCK_SEQPACKET Unix socket>
replaces the L2CAP socket (rootfs/tests/bt-gatt-peer.py fake): the link
sends "ADDRESS TYPE" and waits for "OK HANDLE" or "FAIL CODE" (hex).
"""

import collections
import errno
import logging
import os
import socket
import struct
import time

_LOGGER = logging.getLogger("tsx-btscan")

ATT_CID = 4
SOL_L2CAP = 6
L2CAP_CONNINFO = 2
MY_MTU = 517                # the ATT MTU that the panel offers
# Home Assistant gives up after 30 s. TSX_BT_CONNECT_TIMEOUT: a test hook.
CONNECT_TIMEOUT = float(os.environ.get("TSX_BT_CONNECT_TIMEOUT", "20"))
ATT_TIMEOUT = 20.0          # one ATT request (the ATT limit is 30 s)
CLOSE_TIMEOUT = 5.0         # HCI Disconnect -> Disconnection Complete
DOWN_GRACE = 0.5            # socket error -> wait for the HCI reason
MAX_LONG = 512              # the longest attribute value

OP_ERROR = 0x01
OP_MTU_REQ, OP_MTU_RSP = 0x02, 0x03
OP_FIND_INFO, OP_FIND_INFO_RSP = 0x04, 0x05
OP_READ_TYPE, OP_READ_TYPE_RSP = 0x08, 0x09
OP_READ, OP_READ_RSP = 0x0A, 0x0B
OP_READ_BLOB, OP_READ_BLOB_RSP = 0x0C, 0x0D
OP_READ_GROUP, OP_READ_GROUP_RSP = 0x10, 0x11
OP_WRITE, OP_WRITE_RSP = 0x12, 0x13
OP_PREPARE, OP_PREPARE_RSP = 0x16, 0x17
OP_EXECUTE, OP_EXECUTE_RSP = 0x18, 0x19
OP_NOTIFY, OP_INDICATE, OP_CONFIRM = 0x1B, 0x1D, 0x1E
OP_WRITE_CMD = 0x52
RESPONSES = {0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x17, 0x19}

ERR_NOT_FOUND = 0x0A
ERR_NOT_LONG = 0x0B
ERR_INVALID_OFFSET = 0x07
ERR_NOT_SUPPORTED = 0x06
ERR_UNLIKELY = 0x0E
ERR_NOT_CONNECTED = -1      # ESPHome: "Not connected"
ERR_TIMEOUT = 0x85          # ESPHome: "Error"
CONN_FAIL = 0x3E            # HCI: connection failed to be established
CONN_TIMEOUT = 0x08         # HCI: connection timeout
CONN_LOCAL = 0x16           # HCI: connection terminated by local host
CONN_REMOTE = 0x13          # HCI: remote user terminated connection


class AttError(Exception):
    def __init__(self, code, handle=0):
        super().__init__(f"ATT error 0x{code & 0xFF:02x} on handle {handle}")
        self.code = code
        self.handle = handle


def u16(value):
    return struct.pack("<H", value)


def addr_text(addr):
    return ":".join(f"{(addr >> s) & 0xFF:02X}" for s in range(40, -8, -8))


def uuid_text(raw):
    """An ATT UUID (2, 4 or 16 bytes, little-endian) as a 128-bit string."""
    if len(raw) in (2, 4):
        return f"{int.from_bytes(raw, 'little'):08x}-0000-1000-8000-00805f9b34fb"
    h = raw[::-1].hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def check(rsp, want, handle=0):
    if rsp[0] == OP_ERROR and len(rsp) >= 5:
        raise AttError(rsp[4], struct.unpack_from("<H", rsp, 2)[0])
    if rsp[0] != want:
        raise AttError(ERR_UNLIKELY, handle)


# ---- ATT procedures: generators that yield a request PDU and get the
# ---- response PDU back. The return value is the result.
def proc_mtu():
    rsp = yield bytes((OP_MTU_REQ,)) + u16(MY_MTU)
    if rsp[0] == OP_ERROR:
        return 23
    check(rsp, OP_MTU_RSP)
    return max(23, min(MY_MTU, struct.unpack_from("<H", rsp, 1)[0]))


def proc_services():
    services = []
    start = 1
    while start <= 0xFFFF:
        rsp = yield bytes((OP_READ_GROUP,)) + u16(start) + u16(0xFFFF) + u16(0x2800)
        if rsp[0] == OP_ERROR and rsp[4] == ERR_NOT_FOUND:
            break
        check(rsp, OP_READ_GROUP_RSP)
        ln = rsp[1]
        last = start
        for pos in range(2, len(rsp) - ln + 1, ln):
            s, e = struct.unpack_from("<HH", rsp, pos)
            services.append({"uuid": uuid_text(rsp[pos + 4:pos + ln]), "handle": s, "end": e, "chars": []})
            last = e
        if ln < 6 or last >= 0xFFFF or last < start:
            break
        start = last + 1
    for svc in services:
        start = svc["handle"]
        while start <= svc["end"]:
            rsp = yield bytes((OP_READ_TYPE,)) + u16(start) + u16(svc["end"]) + u16(0x2803)
            if rsp[0] == OP_ERROR and rsp[4] == ERR_NOT_FOUND:
                break
            check(rsp, OP_READ_TYPE_RSP)
            ln = rsp[1]
            last = start
            for pos in range(2, len(rsp) - ln + 1, ln):
                decl, props, value = struct.unpack_from("<HBH", rsp, pos)
                svc["chars"].append({"uuid": uuid_text(rsp[pos + 5:pos + ln]), "handle": value,
                                     "props": props, "decl": decl, "descs": []})
                last = decl
            if ln < 7 or last < start:
                break
            start = last + 1
        chars = svc["chars"]
        for i, ch in enumerate(chars):
            end = chars[i + 1]["decl"] - 1 if i + 1 < len(chars) else svc["end"]
            start = ch["handle"] + 1
            while start <= end:
                rsp = yield bytes((OP_FIND_INFO,)) + u16(start) + u16(end)
                if rsp[0] == OP_ERROR and rsp[4] == ERR_NOT_FOUND:
                    break
                check(rsp, OP_FIND_INFO_RSP)
                ln = 4 if rsp[1] == 1 else 18
                last = start
                for pos in range(2, len(rsp) - ln + 1, ln):
                    h = struct.unpack_from("<H", rsp, pos)[0]
                    ch["descs"].append({"uuid": uuid_text(rsp[pos + 2:pos + ln]), "handle": h})
                    last = h
                if last < start:
                    break
                start = last + 1
            del ch["decl"]
    return services


def proc_read(link, handle):
    rsp = yield bytes((OP_READ,)) + u16(handle)
    check(rsp, OP_READ_RSP, handle)
    value = bytes(rsp[1:])
    part = len(value)
    while part == link.mtu - 1 and len(value) < MAX_LONG:
        rsp = yield bytes((OP_READ_BLOB,)) + u16(handle) + u16(len(value))
        if rsp[0] == OP_ERROR and rsp[4] in (ERR_NOT_LONG, ERR_INVALID_OFFSET):
            break
        check(rsp, OP_READ_BLOB_RSP, handle)
        part = len(rsp) - 1
        value += rsp[1:]
    return value


def proc_write(link, handle, data):
    if len(data) <= link.mtu - 3:
        rsp = yield bytes((OP_WRITE,)) + u16(handle) + data
        check(rsp, OP_WRITE_RSP, handle)
        return None
    off = 0
    try:
        while off < len(data):
            part = data[off:off + link.mtu - 5]
            rsp = yield bytes((OP_PREPARE,)) + u16(handle) + u16(off) + part
            check(rsp, OP_PREPARE_RSP, handle)
            off += len(part)
    except AttError:
        yield bytes((OP_EXECUTE, 0))  # cancel the queued parts
        raise
    rsp = yield bytes((OP_EXECUTE, 1))
    check(rsp, OP_EXECUTE_RSP, handle)
    return None


# ---- bearers: how a link reaches the peer -----------------------------------
class L2capBearer:
    """The ATT fixed channel of the kernel. connect() runs in the background:
    the socket turns writable when the link is up, or reports an error."""

    fake = False

    def __init__(self, addr, atype):
        self.sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
        self.sock.setblocking(False)
        self.sock.bind((socket.BDADDR_ANY, 0, ATT_CID, socket.BDADDR_LE_PUBLIC))
        kind = socket.BDADDR_LE_RANDOM if atype else socket.BDADDR_LE_PUBLIC
        rc = self.sock.connect_ex((addr_text(addr), 0, ATT_CID, kind))
        if rc not in (0, errno.EINPROGRESS, errno.EAGAIN):
            self.sock.close()
            raise OSError(rc, os.strerror(rc))

    def want_write(self):
        return True

    def poll_up(self, readable):
        """While connecting: ("up", handle), ("fail", reason) or None."""
        err = self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if err:
            return ("fail", CONN_FAIL, os.strerror(err))
        try:
            info = self.sock.getsockopt(SOL_L2CAP, L2CAP_CONNINFO, 8)
        except OSError:
            return None  # not connected yet
        return ("up", struct.unpack_from("<H", info)[0], "")


class FakeBearer:
    fake = True

    def __init__(self, addr, atype, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.sock.connect(path)
        self.sock.setblocking(False)
        self.sock.send(f"{addr_text(addr)} {atype}".encode())

    def want_write(self):
        return False

    def poll_up(self, readable):
        if not readable:
            return None
        try:
            msg = self.sock.recv(64).decode()
        except BlockingIOError:
            return None
        except OSError as err:
            return ("fail", CONN_FAIL, str(err))
        word = msg.split()
        if len(word) == 2 and word[0] == "OK":
            return ("up", int(word[1]), "")
        return ("fail", int(word[1], 16) if len(word) == 2 else CONN_FAIL, msg or "closed")


# ---- one link ----------------------------------------------------------------
class Link:
    def __init__(self, addr, atype, owner):
        self.addr = addr
        self.atype = atype
        self.owner = owner
        self.state = "queued"    # queued, connecting, mtu, connected, closing, down
        self.bearer = None
        self.handle = None
        self.mtu = 23
        self.notify = set()
        self.queue = collections.deque()
        self.cur = None          # [generator, on_done, deadline, first handle]
        self.deadline = 0.0
        self.reason = None       # the HCI reason of the disconnection
        self.requested = False   # the front end asked for the disconnection
        self.again = None        # (owner, atype) of a connect that waits for this link to go down
        self.t0 = 0.0
        self.error_text = ""

    @property
    def name(self):
        return addr_text(self.addr)


class Links:
    """All BLE links of the daemon. The scanner calls it from its main loop.

    emit(client, msg): send one message (a dict) to a front end.
    slots_changed(): the slot count changed (the scanner sends it to all).
    scan_pause() / scan_resume(): stop the passive scan before a connect,
      start it again after.
    hci_send(opcode, params): send an HCI command, do not wait.
    le_enable(): make sure that the kernel has LE enabled (HCI_LE_ENABLED).
    """

    def __init__(self, limit, emit, slots_changed, scan_pause, scan_resume, hci_send, le_enable):
        self.limit = limit
        self.links = {}
        self.emit = emit
        self.slots_changed = slots_changed
        self.scan_pause = scan_pause
        self.scan_resume = scan_resume
        self.hci_send = hci_send
        self.le_enable = le_enable
        self.fake = os.environ.get("TSX_BTSCAN_FAKE_L2CAP")
        self.stats = collections.Counter()

    # ---- state for the front ends ------------------------------------------
    def slots(self):
        return {"ev": "slots", "limit": self.limit, "free": max(0, self.limit - len(self.links)),
                "allocated": list(self.links)}

    def connecting(self):
        return any(link.state in ("connecting", "mtu") for link in self.links.values())

    def sockets(self):
        """(readable, writable) lists for select()."""
        rd, wr = [], []
        for link in self.links.values():
            if link.bearer is None:
                continue
            rd.append(link.bearer.sock)
            if link.state == "connecting" and link.bearer.want_write():
                wr.append(link.bearer.sock)
        return rd, wr

    def by_sock(self, sock):
        for link in self.links.values():
            if link.bearer is not None and link.bearer.sock is sock:
                return link
        return None

    # ---- requests from a front end ---------------------------------------------
    def request(self, client, msg):
        op = msg.get("op")
        addr = int(msg.get("addr", 0))
        link = self.links.get(addr)
        if op == "connect":
            self.connect(client, addr, int(msg.get("atype", 0)))
            return
        if op == "disconnect":
            if link is None:
                self.emit(client, {"ev": "conn", "addr": addr, "connected": False, "mtu": 0, "error": 0})
            else:
                link.owner = client
                link.again = None  # a disconnect cancels a connect that waits
                self.close(link, "requested")
            return
        handle = int(msg.get("handle", 0))
        if link is None or link.state != "connected":
            self.emit(client, {"ev": "error", "addr": addr, "handle": handle, "error": ERR_NOT_CONNECTED})
            return
        if op == "services":
            self.enqueue(link, proc_services(), self.done_services, 0)
        elif op in ("read", "read_desc"):
            self.enqueue(link, proc_read(link, handle), self.done_read, handle)
        elif op in ("write", "write_desc"):
            data = bytes.fromhex(msg.get("data", ""))
            if op == "write" and not msg.get("response", True):
                if len(data) > link.mtu - 3:
                    _LOGGER.warning("%s: write without response of %d bytes, MTU %d: cut", link.name, len(data), link.mtu)
                self.send_pdu(link, bytes((OP_WRITE_CMD,)) + u16(handle) + data[:link.mtu - 3])
                return
            self.enqueue(link, proc_write(link, handle, data), self.done_write, handle)
        elif op == "notify":
            if msg.get("enable"):
                link.notify.add(handle)
            else:
                link.notify.discard(handle)
            self.emit(link.owner, {"ev": "notify", "addr": addr, "handle": handle})
        else:
            _LOGGER.warning("unknown request %r", op)

    def connect(self, client, addr, atype):
        link = self.links.get(addr)
        if link is not None:
            if link.state == "closing":
                # the old link is still on its way down: connect again after
                link.again = (client, atype)
                return
            link.owner = client
            if link.state == "connected":
                self.emit(client, {"ev": "conn", "addr": addr, "connected": True, "mtu": link.mtu, "error": 0})
            return
        if len(self.links) >= self.limit:
            _LOGGER.warning("%s: no free connection slot (%d in use)", addr_text(addr), len(self.links))
            self.emit(client, {"ev": "conn", "addr": addr, "connected": False, "mtu": 0, "error": 0})
            return
        self.links[addr] = Link(addr, atype, client)
        self.slots_changed()

    def drop_client(self, client):
        for link in list(self.links.values()):
            if link.again is not None and link.again[0] is client:
                link.again = None
            if link.owner is client:
                link.owner = None
                self.close(link, "the front end went away")

    # ---- link life cycle -----------------------------------------------------------
    def start(self, link, now):
        self.scan_pause()
        self.le_enable()
        link.state = "connecting"
        link.deadline = now + CONNECT_TIMEOUT
        link.t0 = now
        try:
            link.bearer = FakeBearer(link.addr, link.atype, self.fake) if self.fake else L2capBearer(link.addr, link.atype)
        except OSError as err:
            _LOGGER.warning("%s: connect: %s", link.name, err)
            self.finish(link, False, CONN_FAIL)
            return
        _LOGGER.info("%s: connecting (%s address)", link.name, "random" if link.atype else "public")

    def link_up(self, link, handle, now):
        link.handle = handle
        link.state = "mtu"
        self.enqueue(link, proc_mtu(), self.done_mtu, 0, front=True)

    def done_mtu(self, link, ok, value, _handle):
        if link.state != "mtu":
            return
        if not ok:
            if isinstance(value, AttError) and value.code == ERR_NOT_CONNECTED:
                return  # the link went down during the MTU exchange: finish() reports it
            _LOGGER.warning("%s: no answer to the MTU exchange (%s)", link.name, value)
            self.close(link, "no ATT answer")
            return
        link.mtu = value
        link.state = "connected"
        self.stats["connect"] += 1
        _LOGGER.info("%s: connected (handle 0x%03x, MTU %d, %.2f s)", link.name, link.handle, link.mtu,
                     time.monotonic() - link.t0)
        self.emit(link.owner, {"ev": "conn", "addr": link.addr, "connected": True, "mtu": link.mtu, "error": 0})
        self.scan_resume()

    def close(self, link, why):
        """Take a link down on request."""
        if link.state in ("closing", "down"):
            return
        if link.state == "queued":
            self.finish(link, False, 0)
            return
        if link.state == "connecting" or link.handle is None:
            _LOGGER.info("%s: connect cancelled (%s)", link.name, why)
            self.finish(link, False, 0)
            return
        _LOGGER.info("%s: disconnecting (%s)", link.name, why)
        link.requested = True
        link.state = "closing"
        link.deadline = time.monotonic() + CLOSE_TIMEOUT
        self.fail_ops(link)
        self.hci_send(0x0406, u16(link.handle) + bytes((CONN_REMOTE,)))

    def finish(self, link, was_up, reason):
        """The link is gone: tell the owner, free the slot."""
        if self.links.get(link.addr) is not link:
            return
        was_connecting = link.state in ("connecting", "mtu")
        link.state = "down"
        self.fail_ops(link)
        if link.bearer is not None:
            try:
                link.bearer.sock.close()
            except OSError:
                pass
            link.bearer = None
        del self.links[link.addr]
        if link.again is not None:
            # a new connect for this address waits: no "down" for it, the
            # slot stays taken
            self.links[link.addr] = Link(link.addr, link.again[1], link.again[0])
        elif link.owner is not None:
            self.emit(link.owner, {"ev": "conn", "addr": link.addr, "connected": False, "mtu": 0,
                                   "error": reason or 0})
        if link.again is None:
            self.slots_changed()
        if was_up:
            _LOGGER.info("%s: disconnected (reason 0x%02x)", link.name, reason or 0)
        elif reason:
            _LOGGER.info("%s: connect failed (0x%02x%s)", link.name, reason,
                         f", {link.error_text}" if link.error_text else "")
        if was_connecting:
            self.scan_resume()

    def fail_ops(self, link):
        cur, link.cur = link.cur, None
        pending = ([cur] if cur else []) + [[None, done, 0, h] for _, done, h in link.queue]
        link.queue.clear()
        for item in pending:
            item[1](link, False, AttError(ERR_NOT_CONNECTED, item[3]), item[3])

    # ---- ATT transactions -------------------------------------------------------------
    def enqueue(self, link, gen, on_done, handle, front=False):
        item = (gen, on_done, handle)
        if front:
            link.queue.appendleft(item)
        else:
            link.queue.append(item)
        self.next_op(link)

    def next_op(self, link):
        while link.cur is None and link.queue and link.bearer is not None:
            gen, on_done, handle = link.queue.popleft()
            link.cur = [gen, on_done, 0.0, handle]
            self.step(link, None)

    def step(self, link, rsp):
        cur = link.cur
        try:
            pdu = next(cur[0]) if rsp is None else cur[0].send(rsp)
        except StopIteration as stop:
            link.cur = None
            cur[1](link, True, stop.value, cur[3])
            self.next_op(link)
            return
        except AttError as err:
            if err.code == ERR_UNLIKELY and rsp is not None:
                _LOGGER.warning("%s: unexpected ATT answer %s", link.name, rsp.hex())
            link.cur = None
            cur[1](link, False, err, cur[3])
            self.next_op(link)
            return
        cur[2] = time.monotonic() + ATT_TIMEOUT
        self.send_pdu(link, pdu)

    def send_pdu(self, link, pdu):
        try:
            link.bearer.sock.send(pdu)
        except OSError as err:
            _LOGGER.warning("%s: ATT send: %s", link.name, err)
            self.lost(link, str(err))

    def done_services(self, link, ok, value, handle):
        if not ok:
            self.op_error(link, value, handle)
            return
        for svc in value:
            self.emit(link.owner, {"ev": "services", "addr": link.addr, "services": [svc]})
        self.emit(link.owner, {"ev": "services_done", "addr": link.addr})

    def done_read(self, link, ok, value, handle):
        if not ok:
            self.op_error(link, value, handle)
            return
        self.emit(link.owner, {"ev": "read", "addr": link.addr, "handle": handle, "data": value.hex()})

    def done_write(self, link, ok, value, handle):
        if not ok:
            self.op_error(link, value, handle)
            return
        self.emit(link.owner, {"ev": "write", "addr": link.addr, "handle": handle})

    def op_error(self, link, err, handle):
        if link.owner is None:
            return
        code = err.code if isinstance(err, AttError) else ERR_UNLIKELY
        self.emit(link.owner, {"ev": "error", "addr": link.addr, "handle": handle, "error": code})

    # ---- socket events ---------------------------------------------------------------
    def on_writable(self, sock, now):
        link = self.by_sock(sock)
        if link is not None and link.state == "connecting":
            self.poll_connect(link, now, False)

    def on_readable(self, sock, now):
        link = self.by_sock(sock)
        if link is None:
            return
        if link.state == "connecting":
            self.poll_connect(link, now, True)
            return
        try:
            pdu = sock.recv(1024)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as err:
            self.lost(link, str(err))
            return
        if not pdu:
            self.lost(link, "closed")
            return
        self.att_in(link, pdu)

    def poll_connect(self, link, now, readable):
        res = link.bearer.poll_up(readable)
        if res is None:
            return
        if res[0] == "up":
            self.link_up(link, res[1], now)
        else:
            link.error_text = res[2]
            self.finish(link, False, res[1])

    def att_in(self, link, pdu):
        op = pdu[0]
        if op in (OP_NOTIFY, OP_INDICATE) and len(pdu) >= 3:
            if op == OP_INDICATE:
                self.send_pdu(link, bytes((OP_CONFIRM,)))
            handle = struct.unpack_from("<H", pdu, 1)[0]
            if handle in link.notify and link.owner is not None:
                self.stats["notify"] += 1
                self.emit(link.owner, {"ev": "notify_data", "addr": link.addr, "handle": handle,
                                       "data": pdu[3:].hex()})
            return
        if op == OP_MTU_REQ and len(pdu) >= 3:
            peer = struct.unpack_from("<H", pdu, 1)[0]
            self.send_pdu(link, bytes((OP_MTU_RSP,)) + u16(MY_MTU))
            link.mtu = max(23, min(MY_MTU, peer, link.mtu if link.state == "connected" else MY_MTU))
            return
        if op in RESPONSES:
            if link.cur is not None:
                self.step(link, pdu)
            return
        if not op & 0x40 and op != OP_CONFIRM:
            # a request from the peer: the panel has no GATT server
            self.send_pdu(link, bytes((OP_ERROR, op, 0, 0, ERR_NOT_SUPPORTED)))

    def lost(self, link, why):
        """The bearer failed. Wait a moment for the HCI reason."""
        if link.state == "down":
            return
        if link.bearer is not None:
            try:
                link.bearer.sock.close()
            except OSError:
                pass
            link.bearer = None
        if not link.requested:
            _LOGGER.info("%s: link lost (%s)", link.name, why)
        grace = time.monotonic() + DOWN_GRACE
        if link.state != "closing":
            link.state = "closing"
            link.deadline = grace
            self.fail_ops(link)
        else:
            link.deadline = min(link.deadline, grace)

    def on_disconnect(self, handle, reason):
        """HCI Disconnection Complete (from the raw HCI socket)."""
        for link in list(self.links.values()):
            if link.handle == handle:
                link.reason = reason
                if link.state != "closing":
                    self.fail_ops(link)
                self.finish(link, True, reason)
                return

    def tick(self, now):
        for link in list(self.links.values()):
            if link.state == "connecting" and now >= link.deadline:
                _LOGGER.warning("%s: no connection after %d s", link.name, int(CONNECT_TIMEOUT))
                self.finish(link, False, CONN_TIMEOUT)
            elif link.state == "closing" and now >= link.deadline:
                default = CONN_LOCAL if link.requested else CONN_REMOTE
                self.finish(link, True, link.reason if link.reason is not None else default)
            elif link.cur is not None and link.cur[2] and now >= link.cur[2]:
                _LOGGER.warning("%s: no ATT answer in %d s: disconnecting", link.name, int(ATT_TIMEOUT))
                cur, link.cur = link.cur, None
                cur[1](link, False, AttError(ERR_TIMEOUT, cur[3]), cur[3])
                self.close(link, "ATT timeout")
        if not self.connecting():
            for link in self.links.values():
                if link.state == "queued":
                    self.start(link, now)
                    break
