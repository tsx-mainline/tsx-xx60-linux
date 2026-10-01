#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""tsx-btscan: BLE scanner and BLE links for the Bluetooth proxy of the panel.

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

A client can also send two bytes: "m" and the scan mode (0 passive, 1
active). The daemon scans actively only if a client asks for it and bt.conf
says ACTIVE="on". Otherwise the scan stays passive: nothing goes over the
air. The daemon sends each client a three-byte state message when the state
or the mode changes:

  1 byte   "S"
  1 byte   scanner state (ESPHome: 2 running, 3 failed, 1 starting, 5 stopped)
  1 byte   scan mode now in use (0 passive, 1 active)

A record is at least 9 bytes long, so a front end tells the two apart by the
length.

The scan runs only while at least one client is connected. The ESPHome front
end connects when Home Assistant subscribes to advertisements and
disconnects when it unsubscribes, so the radio idles without Home Assistant.

The kernel keeps hci0 (the daemon uses the raw channel, not the user
channel), so hciconfig and btmgmt keep working. If no report arrives for
WATCHDOG seconds while clients are connected, the daemon sends the scan
commands again. This covers a controller reset and a kernel that turned the
scan off.

Active connections (panel.conf BT_ACTIVE=on, docs/ha.md "Bluetooth
proxy"): the daemon also holds the BLE links that Home Assistant asks for
and runs GATT over them (btgatt.py). The front ends reach it on a second
socket, because GATT answers must never get lost the way a report to a slow
client does:

  /run/tsx/bt-gatt.sock  SOCK_SEQPACKET, mode 0660, group kiosk

One message is one JSON object. Addresses are 48-bit integers, as in the
ESPHome API. Data is hex. A front end sends requests:

  {"op": "connect", "addr": A, "atype": 0|1}     (0 public, 1 random)
  {"op": "disconnect", "addr": A}
  {"op": "services", "addr": A}
  {"op": "read" | "read_desc", "addr": A, "handle": H}
  {"op": "write", "addr": A, "handle": H, "data": D, "response": true|false}
  {"op": "write_desc", "addr": A, "handle": H, "data": D}
  {"op": "notify", "addr": A, "handle": H, "enable": true|false}

and gets events (the ESPHome message that each one becomes in brackets):

  {"ev": "slots", "limit": N, "free": F, "allocated": [A, ...]}
      at the start and on each change (BluetoothConnectionsFreeResponse)
  {"ev": "conn", "addr": A, "connected": B, "mtu": M, "error": E}
      (BluetoothDeviceConnectionResponse). E is an HCI reason
      (0x08 timeout, 0x13 remote, 0x16 local, 0x3E failed), 0x80 (all
      connection slots are in use), or 0.
  {"ev": "services", "addr": A, "services": [{"uuid": U, "handle": H,
      "end": H2, "chars": [{"uuid": U, "handle": H, "props": P,
      "descs": [{"uuid": U, "handle": H}]}]}]}   one service each
      (BluetoothGATTGetServicesResponse), then {"ev": "services_done"}
  {"ev": "read", "addr": A, "handle": H, "data": D}
  {"ev": "write", "addr": A, "handle": H}
  {"ev": "notify", "addr": A, "handle": H}        (the answer to "notify")
  {"ev": "notify_data", "addr": A, "handle": H, "data": D}
  {"ev": "error", "addr": A, "handle": H, "error": E}
      E is the ATT error code, or -1 when the link is not up
      (BluetoothGATTErrorResponse).

A link belongs to the front end that asked for it. When that front end
closes its socket, the daemon takes its links down. The daemon connects
only while bt.conf says ACTIVE="on", and one link at a time. The passive
scan pauses while a link comes up, because the kernel scans for the device
itself then. The kernel stops every scan when a link comes up or goes down,
so the daemon starts the passive scan again after those events.

  btscan.py [--hci hci0] [--socket /run/tsx/bt-adv.sock] [--group kiosk]
            [--gatt-socket PATH] [--max-connections 3]
  Test hooks: TSX_BTSCAN_FAKE_HCI=<path of a SOCK_SEQPACKET Unix socket>
  replaces the HCI socket. The test acts as the controller on that socket.
  TSX_BTSCAN_FAKE_L2CAP (btgatt.py) replaces the L2CAP sockets.
  TSX_BT_CONF replaces /run/tsx/bt.conf. TSX_BT_MAC_FILE replaces
  /run/tsx/bt.mac.

  btscan.py --hci hci0 --up    bring the device up (HCIDEVUP) and exit.
  TSX_BTSCAN_FAKE_UP_ERRNO=<number> makes it fail with that errno (a test hook).

When bt.mac is missing or empty, the daemon reads the address of the
controller (Read BD_ADDR) and writes it there. A board that loads its own
address (the xx60: tsx-bt) has bt.mac already. If the controller reports
another address than bt.mac, the daemon logs a warning.
"""

import argparse
import errno
import fcntl
import grp
import json
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
EVT_DISCONN_COMPLETE = 0x05
EVT_CMD_COMPLETE = 0x0E
EVT_CMD_STATUS = 0x0F
EVT_LE_META = 0x3E
LE_ADV_REPORT = 0x02
LE_CONN_COMPLETE = (0x01, 0x0A)

OP_INQUIRY_CANCEL = 0x0402
OP_READ_BD_ADDR = 0x1009
OP_LE_SET_SCAN_PARAMS = 0x200B
OP_LE_SET_SCAN_ENABLE = 0x200C
OP_WRITE_LE_HOST_SUPPORTED = 0x0C6D

HCIDEVUP = 0x400448C9    # _IOW('H', 201, int)
# ESPHome BluetoothScannerState
STATE_STARTING, STATE_RUNNING, STATE_FAILED, STATE_STOPPED = 1, 2, 3, 5
MODE_PASSIVE, MODE_ACTIVE = 0, 1

SCAN_INTERVAL = 0x00A0  # 100 ms (0.625 ms units)
SCAN_WINDOW = 0x00A0    # the same: listen all the time
WATCHDOG = 60.0
# After a link event the kernel updates its own scan state (it sends LE Set
# Scan Enable itself, within about 0.2 s on the CSR8811). Start the passive
# scan again only after that, or the commands of both collide ("Command
# Disallowed").
SCAN_RESUME_DELAY = 0.5
STATS_EVERY = 600.0

_LOGGER = logging.getLogger("tsx-btscan")


def hci_filter():
    """struct hci_filter: HCI event packets, only the events we read."""
    type_mask = 1 << HCI_EVENT_PKT
    events = 0
    for ev in (EVT_DISCONN_COMPLETE, EVT_CMD_COMPLETE, EVT_CMD_STATUS, EVT_LE_META):
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


def hci_up(dev):
    """HCIDEVUP on hci<dev>. Return None on success (or if the device is
    up already), else an error text. With TSX_BTSCAN_FAKE_HCI the call does
    nothing and TSX_BTSCAN_FAKE_UP_ERRNO gives the error to return."""
    if os.environ.get("TSX_BTSCAN_FAKE_HCI") or os.environ.get("TSX_BTSCAN_FAKE_UP_ERRNO"):
        code = int(os.environ.get("TSX_BTSCAN_FAKE_UP_ERRNO", "0") or 0)
        return None if code in (0, errno.EALREADY) else os.strerror(code)
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    try:
        fcntl.ioctl(sock.fileno(), HCIDEVUP, dev)
    except OSError as err:
        if err.errno == errno.EALREADY:
            return None
        return os.strerror(err.errno) + (" (blocked by rfkill?)" if err.errno == errno.ERFKILL else "")
    finally:
        sock.close()
    return None


def conf_value(path, key):
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            for line in fobj:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


class Scanner:
    def __init__(self, hci_name, sock_path, group, gatt_path=None, max_conn=3):
        self.hci_name = hci_name
        self.sock_path = sock_path
        self.group = group
        self.gatt_path = gatt_path
        self.gatt_server = None
        self.gatt_clients = []
        self.links = None
        self.max_conn = max_conn
        self.conf_path = os.environ.get("TSX_BT_CONF", "/run/tsx/bt.conf")
        self.mac_path = os.environ.get("TSX_BT_MAC_FILE", "/run/tsx/bt.mac")
        self.paused = False
        self.le_enabled = False
        self.client_modes = {}   # adv client -> the scan mode it asked for
        self.scan_mode = MODE_PASSIVE   # the mode of the scan that runs
        self.scan_failed = False
        self.discovery_dirty = False  # an active scan ran: the kernel thinks discovery runs
        self.sent_state = {}     # adv client -> the last state message sent
        self.cc_params = {}      # opcode -> return parameters of the last Command Complete
        self.link_event_at = -100.0  # a link came up or went down (retry the scan sooner)
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
            err = hci_up(dev)
            if err:
                raise OSError(errno.EIO, f"HCIDEVUP on {self.hci_name}: {err}")
            sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
            sock.setsockopt(socket.SOL_HCI, socket.HCI_FILTER, hci_filter())
            sock.bind((dev,))
        sock.setblocking(False)
        self.hci = sock
        self.hci_error_logged = False
        self.le_enabled = False
        # An earlier tsx-btscan can have left an active scan behind.
        self.discovery_dirty = True
        _LOGGER.info("HCI socket open on %s", "the fake controller" if fake else self.hci_name)
        self.publish_address()

    def publish_address(self):
        """Read the address of the controller. Write it to bt.mac if the file
        is missing or empty. Warn if it differs from the file."""
        try:
            st = self.send_cmd(OP_READ_BD_ADDR)
        except OSError as err:
            self.hci_fail("HCI command", err)
            return
        data = self.cc_params.pop(OP_READ_BD_ADDR, b"")
        if st != 0 or len(data) < 7:
            _LOGGER.warning("Read BD_ADDR: %s", "no answer" if st is None else f"status 0x{st:02x}")
            return
        mac = ":".join(f"{b:02X}" for b in reversed(data[1:7]))
        if mac == "00:00:00:00:00:00":
            _LOGGER.warning("the controller reports the address %s: not used", mac)
            return
        try:
            with open(self.mac_path, "r", encoding="utf-8") as fobj:
                have = fobj.read().strip().upper()
        except OSError:
            have = ""
        if have:
            if have != mac:
                _LOGGER.warning("the controller reports address %s, not %s of %s", mac, have, self.mac_path)
            return
        try:
            tmp = self.mac_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fobj:
                fobj.write(mac + "\n")
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.mac_path)
            _LOGGER.info("Bluetooth address %s from the controller, written to %s", mac, self.mac_path)
        except OSError as err:
            _LOGGER.warning("cannot write %s: %s", self.mac_path, err)

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

    def wanted_mode(self):
        """Active only if a client asked for it and BT_ACTIVE is on."""
        if MODE_ACTIVE in self.client_modes.values() and conf_value(self.conf_path, "ACTIVE") == "on":
            return MODE_ACTIVE
        return MODE_PASSIVE

    def scan_state(self):
        if self.scanning or self.paused:
            return STATE_RUNNING
        if self.scan_failed:
            return STATE_FAILED
        return STATE_STARTING if self.clients else STATE_STOPPED

    def send_state(self, conn=None, force=False):
        """Tell the clients the scanner state and mode (when it changed)."""
        msg = bytes((ord("S"), self.scan_state(), self.wanted_mode()))
        for client in ([conn] if conn is not None else list(self.clients)):
            if not force and self.sent_state.get(client) == msg:
                continue
            self.sent_state[client] = msg
            try:
                client.send(msg)
            except BlockingIOError:
                self.sent_state.pop(client, None)  # try again at the next change
            except OSError:
                self.drop(client)

    def set_scan(self, enable):
        """Start or stop the scan (passive, or active by wanted_mode()).
        Return True on success."""
        if self.hci is None:
            return False
        try:
            if enable:
                # Stop a scan that may still run (from us or from the kernel):
                # the controller refuses new parameters while it scans.
                self.send_cmd(OP_LE_SET_SCAN_ENABLE, bytes((0, 0)))
                self.reset_discovery()
                mode = self.wanted_mode()
                params = struct.pack("<BHHBB", mode, SCAN_INTERVAL, SCAN_WINDOW, 0, 0)
                st = self.send_cmd(OP_LE_SET_SCAN_PARAMS, params)
                if st != 0:
                    _LOGGER.warning("LE Set Scan Parameters: %s", "no answer" if st is None else f"status 0x{st:02x}")
                    return False
                st = self.send_cmd(OP_LE_SET_SCAN_ENABLE, bytes((1, 0)))
                if st != 0:
                    _LOGGER.warning("LE Set Scan Enable: %s", "no answer" if st is None else f"status 0x{st:02x}")
                    return False
                self.scanning = True
                self.scan_failed = False
                self.scan_mode = mode
                if mode == MODE_ACTIVE:
                    self.discovery_dirty = True
                self.last_report = time.monotonic()
                _LOGGER.info("%s scan on (interval %d ms, window %d ms)", "active" if mode else "passive",
                             SCAN_INTERVAL * 625 // 1000, SCAN_WINDOW * 625 // 1000)
            else:
                self.send_cmd(OP_LE_SET_SCAN_ENABLE, bytes((0, 0)))
                self.scanning = False
                self.reset_discovery()
                _LOGGER.info("scan off (%s)", "a link comes up" if self.paused else "no clients")
            return True
        except OSError as err:
            self.hci_fail("HCI command", err)
            return False

    def reset_discovery(self):
        """Set the discovery state of the kernel back to stopped.

        The kernel tracks the scan commands on the raw socket. When an active
        scan starts, it sets its discovery state to "finding", and only a
        stop of its own discovery sets it back. While the state is not
        "stopped", the kernel does not start the scan for a pending LE link,
        and every connect() runs into the 20 s timeout. The Command Complete
        of Inquiry Cancel sets the state to "stopped" when no active scan
        runs. The CSR8811 answers "Command Disallowed" (no inquiry runs), and
        the kernel takes that answer as success. Call this with the scan off.
        """
        if not self.discovery_dirty or self.hci is None:
            return
        st = self.send_cmd(OP_INQUIRY_CANCEL)
        if st in (0x00, 0x0C):
            self.discovery_dirty = False
        else:
            _LOGGER.warning("Inquiry Cancel: %s", "no answer" if st is None else f"status 0x{st:02x}")

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
                self.cc_params[opcode] = bytes(params[3:])
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
        elif evt == EVT_LE_META and params and params[0] in LE_CONN_COMPLETE:
            self.kernel_stopped_scan()
        elif evt == EVT_DISCONN_COMPLETE and len(params) >= 4 and params[0] == 0:
            handle, reason = struct.unpack_from("<HB", params, 1)
            if self.links is not None:
                self.links.on_disconnect(handle & 0x0FFF, reason)
            self.kernel_stopped_scan()

    def kernel_stopped_scan(self):
        """A link came up or went down. The kernel then stops the scan (it
        knows about our scan: it tracks the scan commands on the raw
        socket too). Send the scan commands again soon."""
        self.link_event_at = time.monotonic()
        if self.scanning and not self.paused:
            self.scanning = False
            self.scan_retry_at = time.monotonic() + SCAN_RESUME_DELAY

    def hci_send(self, opcode, params):
        if self.hci is not None:
            try:
                self.hci.send(command(opcode, params))
            except OSError as err:
                self.hci_fail("HCI command", err)

    def le_enable(self):
        """Set LE Host Supported, so that the kernel sets HCI_LE_ENABLED and
        takes LE connections. With no bluetoothd, nothing else does it."""
        if self.le_enabled or self.hci is None:
            return
        try:
            st = self.send_cmd(OP_WRITE_LE_HOST_SUPPORTED, bytes((1, 0)))
        except OSError as err:
            self.hci_fail("HCI command", err)
            return
        if st == 0:
            self.le_enabled = True
        else:
            _LOGGER.warning("Write LE Host Supported: %s", "no answer" if st is None else f"status 0x{st:02x}")

    def scan_pause(self):
        self.paused = True
        if self.scanning:
            self.set_scan(False)
        else:
            # The kernel stopped the scan: it can still be in discovery
            try:
                self.reset_discovery()
            except OSError as err:
                self.hci_fail("HCI command", err)

    def scan_resume(self):
        if self.paused:
            self.paused = False
            self.scanning = False
            self.link_event_at = time.monotonic()
            self.scan_retry_at = time.monotonic() + SCAN_RESUME_DELAY

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
        self.send_state(conn, force=True)

    def drop(self, conn):
        self.client_modes.pop(conn, None)
        self.sent_state.pop(conn, None)
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

    # ---- GATT side (active connections, btgatt.py) ------------------------------
    def open_gatt_server(self):
        import btgatt  # noqa: WPS433 - only with active connections

        try:
            os.unlink(self.gatt_path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        old = os.umask(0o117)
        try:
            srv.bind(self.gatt_path)
        finally:
            os.umask(old)
        if self.group:
            try:
                os.chown(self.gatt_path, -1, grp.getgrnam(self.group).gr_gid)
            except (KeyError, PermissionError) as err:
                _LOGGER.warning("cannot give group %s access to %s: %s", self.group, self.gatt_path, err)
        os.chmod(self.gatt_path, 0o660)
        srv.listen(4)
        srv.setblocking(False)
        self.gatt_server = srv
        self.links = btgatt.Links(self.max_conn, self.gatt_emit, self.gatt_slots, self.scan_pause,
                                  self.scan_resume, self.hci_send, self.le_enable)
        _LOGGER.info("listening on %s (up to %d BLE links)", self.gatt_path, self.max_conn)

    def gatt_emit(self, conn, msg):
        if conn not in self.gatt_clients:
            return
        try:
            conn.send(json.dumps(msg, separators=(",", ":")).encode())
        except OSError as err:
            _LOGGER.warning("GATT client: %s", err)
            self.gatt_drop(conn)

    def gatt_slots(self):
        msg = self.links.slots()
        for conn in list(self.gatt_clients):
            self.gatt_emit(conn, msg)

    def gatt_accept(self):
        try:
            conn, _ = self.gatt_server.accept()
        except (BlockingIOError, InterruptedError):
            return
        conn.settimeout(2.0)  # answers must not get lost: wait for a slow client
        self.gatt_clients.append(conn)
        _LOGGER.info("GATT client connected (%d)", len(self.gatt_clients))
        self.gatt_emit(conn, self.links.slots())

    def gatt_drop(self, conn):
        if conn in self.gatt_clients:
            self.gatt_clients.remove(conn)
            try:
                conn.close()
            except OSError:
                pass
            _LOGGER.info("GATT client disconnected (%d left)", len(self.gatt_clients))
            self.links.drop_client(conn)

    def gatt_read(self, conn):
        try:
            data = conn.recv(65536)
        except (BlockingIOError, InterruptedError, socket.timeout):
            return
        except OSError:
            data = b""
        if not data:
            self.gatt_drop(conn)
            return
        try:
            msg = json.loads(data)
        except ValueError:
            _LOGGER.warning("GATT client: not JSON: %r", data[:80])
            return
        if msg.get("op") == "connect" and conf_value(self.conf_path, "ACTIVE") != "on":
            _LOGGER.warning("connect refused: BT_ACTIVE is off (%s)", self.conf_path)
            self.gatt_emit(conn, {"ev": "conn", "addr": msg.get("addr", 0), "connected": False, "mtu": 0, "error": 0})
            return
        self.links.request(conn, msg)

    # ---- main loop ---------------------------------------------------------
    def stats(self, now):
        if now - self.last_stats >= STATS_EVERY:
            links = ""
            if self.links is not None:
                st = self.links.stats
                links = f", {st['connect']} link(s) up, {st['notify']} notification(s), {len(self.links.links)} link(s) now"
                st.clear()
            _LOGGER.info("%d reports from %d addresses in the last %d s, %d client(s)%s",
                         self.n_reports, len(self.addrs), int(now - self.last_stats), len(self.clients), links)
            self.n_reports = 0
            self.addrs = set()
            self.last_stats = now

    def run(self, stop):
        self.open_server()
        if self.gatt_path:
            try:
                self.open_gatt_server()
            except OSError as err:
                _LOGGER.warning("no active connections: %s: %s", self.gatt_path, err)
                self.links = self.gatt_server = None
        while not stop():
            now = time.monotonic()
            if self.links is not None:
                self.links.tick(now)
            if self.hci is None and now - self.last_try >= 5.0:
                self.last_try = now
                try:
                    self.open_hci()
                except OSError as err:
                    self.hci_fail(f"HCI socket on {self.hci_name}", err)
            want = bool(self.clients) and not self.paused
            if self.hci is not None and not self.paused:
                if want and not self.scanning and now >= self.scan_retry_at:
                    if not self.set_scan(True):
                        self.scan_failed = True
                        self.scan_retry_at = now + (1.0 if now - self.link_event_at < 10 else 5.0)
                elif not want and self.scanning:
                    self.set_scan(False)
                elif want and self.scanning and self.scan_mode != self.wanted_mode():
                    _LOGGER.info("scan mode change: %s", "active" if self.wanted_mode() else "passive")
                    if not self.set_scan(True):
                        self.scan_failed = True
                        self.scan_retry_at = now + (1.0 if now - self.link_event_at < 10 else 5.0)
                elif want and self.scanning and now - self.last_report > WATCHDOG:
                    _LOGGER.warning("no advertising report for %d s: sending the scan commands again", int(WATCHDOG))
                    self.scanning = False
                    if not self.set_scan(True):
                        self.scan_failed = True
                        self.scan_retry_at = now + (1.0 if now - self.link_event_at < 10 else 5.0)
            if self.hci is None and self.clients:
                self.scan_failed = True
            if not self.clients:
                self.scan_failed = False
            self.send_state()
            self.stats(now)
            rlist = [self.server] + self.clients + ([self.hci] if self.hci is not None else [])
            wlist = []
            if self.links is not None:
                lr, wlist = self.links.sockets()
                rlist += [self.gatt_server] + self.gatt_clients + lr
            timeout = 0.2 if self.links is not None and self.links.links else 1.0
            if self.scan_retry_at > now:
                timeout = min(timeout, max(0.05, self.scan_retry_at - now))
            try:
                r, w, _ = select.select(rlist, wlist, [], timeout)
            except InterruptedError:
                continue
            now = time.monotonic()
            for sock in w:
                self.links.on_writable(sock, now)
            for sock in r:
                if sock is self.server:
                    self.accept()
                elif sock is self.hci:
                    self.read_hci()
                elif sock is self.gatt_server:
                    self.gatt_accept()
                elif sock in self.gatt_clients:
                    self.gatt_read(sock)
                elif sock not in self.clients:
                    self.links.on_readable(sock, now)
                else:
                    try:
                        data = sock.recv(64)
                    except (BlockingIOError, InterruptedError):
                        continue
                    except OSError:
                        data = b""
                    if not data:
                        self.drop(sock)
                    elif data[:1] == b"m" and len(data) >= 2:
                        self.client_modes[sock] = MODE_ACTIVE if data[1] == MODE_ACTIVE else MODE_PASSIVE
                        _LOGGER.info("client asks for the %s scan", "active" if data[1] == MODE_ACTIVE else "passive")
        if self.links is not None:
            for conn in list(self.gatt_clients):
                self.gatt_drop(conn)
            end = time.monotonic() + 2.0
            while self.links.links and time.monotonic() < end and self.hci is not None:
                r, _, _ = select.select([self.hci], [], [], 0.1)
                if r:
                    self.read_hci()
                self.links.tick(time.monotonic())
            try:
                os.unlink(self.gatt_path)
            except OSError:
                pass
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
    ap.add_argument("--gatt-socket", help="the socket for active connections "
                    "(default: bt-gatt.sock next to --socket, '' = none)")
    ap.add_argument("--max-connections", type=int, default=3)
    ap.add_argument("--up", action="store_true", help="bring the device up (HCIDEVUP) and exit")
    args = ap.parse_args(argv)
    if args.up:
        err = hci_up(int(args.hci.replace("hci", "") or 0))
        if err:
            print(f"HCIDEVUP on {args.hci}: {err}", file=sys.stderr)
            return 1
        return 0
    logging.basicConfig(level=logging.INFO, format="%(asctime)s tsx-btscan: %(message)s", stream=sys.stdout)

    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(1))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(1))
    gatt = args.gatt_socket
    if gatt is None:
        gatt = os.path.join(os.path.dirname(args.socket) or ".", "bt-gatt.sock")
    scanner = Scanner(args.hci, args.socket, args.group, gatt or None, args.max_connections)
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
