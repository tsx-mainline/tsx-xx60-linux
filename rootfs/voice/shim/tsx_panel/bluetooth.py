"""Bluetooth proxy for the ESPHome device of the panel.

Home Assistant uses an ESPHome device as a remote Bluetooth adapter when the
DeviceInfoResponse announces Bluetooth proxy feature flags. This module
serves that protocol (aioesphomeapi 46.2.0, bleak-esphome 4.1).

Passive part (BT_PROXY=on):

  DeviceInfoResponse
      bluetooth_proxy_feature_flags = PASSIVE_SCAN | RAW_ADVERTISEMENTS |
                                      STATE_AND_MODE (97)
      bluetooth_mac_address         = the address that tsx-bt loaded
  SubscribeBluetoothLEAdvertisementsRequest (flags RAW_ADVERTISEMENTS)
      -> BluetoothLERawAdvertisementsResponse messages, up to 16
         advertisements each, at most every 100 ms
  UnsubscribeBluetoothLEAdvertisementsRequest, or a closed connection
      -> no more advertisements for that connection

  BluetoothScannerStateResponse (state, mode, configured_mode)
      after a subscription, a mode request, and each change of the scanner
  BluetoothScannerSetModeRequest
      -> the mode is active only with BT_ACTIVE=on. Otherwise the scan stays
         passive and the response says so (mode passive, configured_mode as
         asked).

Active part (BT_PROXY=on and BT_ACTIVE=on): the flags add
ACTIVE_CONNECTIONS | REMOTE_CACHING | CACHE_CLEARING (119 in total), and
Home Assistant can connect to BLE devices through the panel:

  SubscribeBluetoothConnectionsFreeRequest
      -> BluetoothConnectionsFreeResponse (free, limit, allocated) now and
         on each change
  BluetoothDeviceRequest CONNECT_V3_WITH_CACHE / _WITHOUT_CACHE
      -> BluetoothDeviceConnectionResponse connected=true with the ATT
         MTU, or connected=false with an HCI reason. The link comes up
         within 20 s or fails.
  BluetoothDeviceRequest DISCONNECT
      -> BluetoothDeviceConnectionResponse connected=false
  BluetoothDeviceRequest CLEAR_CACHE
      -> BluetoothDeviceClearCacheResponse success (the panel keeps no
         GATT cache: Home Assistant keeps it, REMOTE_CACHING)
  BluetoothGATTGetServicesRequest
      -> one BluetoothGATTGetServicesResponse for each primary service,
         then BluetoothGATTGetServicesDoneResponse
  BluetoothGATTReadRequest, BluetoothGATTReadDescriptorRequest
      -> BluetoothGATTReadResponse
  BluetoothGATTWriteRequest, BluetoothGATTWriteDescriptorRequest
      -> BluetoothGATTWriteResponse (none for a write without response)
  BluetoothGATTNotifyRequest
      -> BluetoothGATTNotifyResponse, then BluetoothGATTNotifyDataResponse
         for each notification or indication. Home Assistant writes the
         CCCD itself (REMOTE_CACHING).
  A GATT request that fails -> BluetoothGATTErrorResponse with the ATT
  error code, or -1 when the link is down.
  A closed Home Assistant connection takes its links down.

No pairing. PAIR and UNPAIR get a negative answer, and so does
BluetoothSetConnectionParamsRequest (the controller keeps the parameters of the
kernel).

The advertisements come from tsx-btscan (/usr/local/lib/tsx/btscan.py, run
as root by /etc/init.d/tsx-bt) over a SOCK_SEQPACKET Unix socket. The
format of one message is in the docstring of btscan.py. This module connects
only while at least one Home Assistant connection is subscribed, and
tsx-btscan scans only while a client is connected.

The links and GATT run in tsx-btscan too (btgatt.py). This module talks
to it over a second socket, bt-gatt.sock, with the JSON messages in the
docstring of btscan.py. A reader thread turns the answers into ESPHome
messages for the Home Assistant connection that owns the link.

The proxy is on when $TSX_RUN_DIR/bt.conf (written by tsx-config apply from
panel.conf BT_PROXY and BT_ACTIVE) says PROXY="on". The active part also
needs ACTIVE="on". On a panel without a Bluetooth module (BT=no in
hw.conf, government=1: hw.py) the proxy is always off. Both front ends use one module-level instance (PROXY):
tsx-esphome (esphome_server.py) and the voice satellite (tsx_lva). The voice
satellite runs as the kiosk user. It can read bt.conf and bt.mac (mode 644)
and connect to both sockets (group kiosk).
Test hooks: TSX_RUN_DIR, TSX_BT_CONF, TSX_BT_MAC_FILE, TSX_BT_ADV_SOCKET,
TSX_BT_GATT_SOCKET, TSX_HW_CONF.
"""

import json
import logging
import os
import socket
import struct
import threading
import time

from . import hw

_LOGGER = logging.getLogger("tsx_panel.bluetooth")

FEATURE_PASSIVE_SCAN = 1
FEATURE_ACTIVE_CONNECTIONS = 2
FEATURE_REMOTE_CACHING = 4
FEATURE_CACHE_CLEARING = 16
FEATURE_RAW_ADVERTISEMENTS = 32
FEATURE_STATE_AND_MODE = 64
FEATURES = FEATURE_PASSIVE_SCAN | FEATURE_RAW_ADVERTISEMENTS | FEATURE_STATE_AND_MODE
ACTIVE_FEATURES = FEATURE_ACTIVE_CONNECTIONS | FEATURE_REMOTE_CACHING | FEATURE_CACHE_CLEARING
# BluetoothDeviceRequestType
REQ_CONNECT, REQ_DISCONNECT, REQ_PAIR, REQ_UNPAIR = 0, 1, 2, 3
REQ_CONNECT_V3_WITH_CACHE, REQ_CONNECT_V3_WITHOUT_CACHE, REQ_CLEAR_CACHE = 4, 5, 6
ERR_NOT_CONNECTED = -1
ERR_NOT_SUPPORTED = 6
ERR_GENERIC = 0x85          # the status of the ESP32 stack for "GATT error"
MODE_PASSIVE, MODE_ACTIVE = 0, 1
SUBSCRIPTION_FLAG_RAW = 1
BATCH_MAX = 16
QUEUE_MAX = 512             # advertisements that wait for the event loop
BATCHES_PER_TICK = 8        # messages for each flush interval (128 advertisements)
FLUSH_INTERVAL = 0.1
RECONNECT_DELAY = 2.0


def _conf_value(path, key):
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            for line in fobj:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


def parse_record(msg):
    """One message from tsx-btscan -> (address as int, address_type, rssi,
    data), or None if the message is too short. ESPHome sends the address
    as a 48-bit integer with the first MAC octet as the most significant
    byte. HCI sends the octets in the reverse order, so this is a
    little-endian read. ESPHome uses 0 (public) and 1 (random) as the
    address type. HCI types 2 and 3 are resolved identities of those two."""
    if len(msg) < 9:
        return None
    address = int.from_bytes(msg[0:6], "little")
    addr_type, rssi, _evt = struct.unpack_from("BbB", msg, 6)
    return address, addr_type & 1, rssi, bytes(msg[9:9 + 62])


class AdvQueue:
    """The advertisements that wait to go to Home Assistant. Beyond QUEUE_MAX
    the oldest ones are dropped, so a slow event loop or a busy radio never
    makes the queue grow. Each flush sends at most BATCHES_PER_TICK messages
    of BATCH_MAX advertisements."""

    def __init__(self, limit=QUEUE_MAX):
        self.limit = limit
        self.items = []
        self.dropped = 0

    def push(self, rec):
        self.items.append(rec)
        if len(self.items) > self.limit:
            over = len(self.items) - self.limit
            del self.items[:over]
            self.dropped += over

    def full_batch(self):
        return len(self.items) >= BATCH_MAX

    def pop_batches(self, limit=BATCHES_PER_TICK):
        """Up to limit batches (lists of at most BATCH_MAX records)."""
        out = []
        while self.items and len(out) < limit:
            out.append(self.items[:BATCH_MAX])
            del self.items[:BATCH_MAX]
        return out

    def __len__(self):
        return len(self.items)


class BtProxy:
    def __init__(self, run_dir=None):
        run = run_dir or os.environ.get("TSX_RUN_DIR", "/run/tsx")
        self.conf_path = os.environ.get("TSX_BT_CONF", os.path.join(run, "bt.conf"))
        self.hw_path = os.environ.get("TSX_HW_CONF", os.path.join(run, "hw.conf"))
        self.mac_path = os.environ.get("TSX_BT_MAC_FILE", os.path.join(run, "bt.mac"))
        self.state_path = os.environ.get("TSX_BT_STATE", os.path.join(run, "bt.state"))
        self.sock_path = os.environ.get("TSX_BT_ADV_SOCKET", os.path.join(run, "bt-adv.sock"))
        self.gatt = GattBridge(os.environ.get("TSX_BT_GATT_SOCKET", os.path.join(run, "bt-gatt.sock")))
        self._lock = threading.Lock()
        self._subscribers = []
        self._thread = None
        self._wake = threading.Event()
        self._modes = {}            # connection -> the mode it asked for
        self._mode_sent = None      # the mode that the scanner got
        self._scanner = None        # the last state message of the scanner: (state, mode)

    # ---- configuration ---------------------------------------------------
    def enabled(self):
        """On when panel.conf says so, the board has a module and tsx-bt did
        not find the kernel without Bluetooth (bt.state says "absent")."""
        return (hw.present("BT", self.hw_path) and _conf_value(self.conf_path, "PROXY") == "on"
                and _conf_value(self.state_path, "state") != "absent")

    def active(self):
        return self.enabled() and _conf_value(self.conf_path, "ACTIVE") == "on"

    def mac(self):
        try:
            with open(self.mac_path, "r", encoding="utf-8") as fobj:
                return fobj.read().strip().upper()
        except OSError:
            return ""

    def device_info_fields(self):
        """The DeviceInfoResponse fields of the proxy ({} when it is off)."""
        if not self.enabled():
            return {}
        flags = FEATURES | (ACTIVE_FEATURES if self.active() else 0)
        fields = {"bluetooth_proxy_feature_flags": flags}
        mac = self.mac()
        if mac:
            fields["bluetooth_mac_address"] = mac
        return fields

    def apply_device_info(self, response):
        for key, value in self.device_info_fields().items():
            setattr(response, key, value)
        return response

    # ---- subscriptions -----------------------------------------------------
    def subscribe(self, conn, flags):
        if not self.enabled():
            _LOGGER.info("advertisement subscription ignored: BT_PROXY is off")
            return
        if not flags & SUBSCRIPTION_FLAG_RAW:
            # Home Assistant asks for raw advertisements when the device
            # announces RAW_ADVERTISEMENTS. The parsed form is not served.
            _LOGGER.warning("advertisement subscription without the raw flag (flags %d): not served", flags)
            return
        with self._lock:
            if conn not in self._subscribers:
                self._subscribers.append(conn)
            _LOGGER.info("Bluetooth advertisements: %d subscriber(s)", len(self._subscribers))
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="tsx-bt-proxy", daemon=True)
                self._thread.start()
        self._wake.set()
        self._send_state([conn])

    def unsubscribe(self, conn):
        with self._lock:
            if conn in self._subscribers:
                self._subscribers.remove(conn)
                _LOGGER.info("Bluetooth advertisements: %d subscriber(s)", len(self._subscribers))
        self._wake.set()

    # ---- scanner state and mode (feature flag 64) ------------------------------
    def set_mode(self, conn, mode):
        """BluetoothScannerSetModeRequest: remember the mode of this
        connection. The scanner uses the active mode if any connection asks
        for it (and BT_ACTIVE is on)."""
        if not self.enabled():
            return
        with self._lock:
            self._modes[conn] = MODE_ACTIVE if mode == MODE_ACTIVE else MODE_PASSIVE
        self._wake.set()
        self._send_state([conn])

    def _wanted_mode(self):
        with self._lock:
            subs = set(self._subscribers)
            return MODE_ACTIVE if any(m == MODE_ACTIVE for c, m in self._modes.items() if c in subs) else MODE_PASSIVE

    def _send_state(self, conns=None):
        from aioesphomeapi.api_pb2 import BluetoothScannerStateResponse  # pylint: disable=no-name-in-module

        if self._scanner is None:
            return
        state, mode = self._scanner
        for conn in (conns if conns is not None else self._targets()):
            with self._lock:
                configured = self._modes.get(conn, MODE_PASSIVE)
            try:
                conn.send_messages([BluetoothScannerStateResponse(state=state, mode=mode, configured_mode=configured)])
            except Exception:  # noqa: BLE001 - one bad connection must not stop the others
                _LOGGER.debug("state message to a subscriber failed", exc_info=True)

    def _targets(self):
        with self._lock:
            return list(self._subscribers)

    def connection_lost(self, conn):
        """A Home Assistant connection closed: no advertisements, and its
        BLE links go down."""
        self.unsubscribe(conn)
        with self._lock:
            self._modes.pop(conn, None)
        self.gatt.release(conn)

    # ---- the reader thread ---------------------------------------------------
    def _send(self, batch):
        from aioesphomeapi.api_pb2 import (  # pylint: disable=no-name-in-module
            BluetoothLERawAdvertisement,
            BluetoothLERawAdvertisementsResponse,
        )

        msg = BluetoothLERawAdvertisementsResponse(advertisements=[
            BluetoothLERawAdvertisement(address=a, address_type=t, rssi=r, data=d) for a, t, r, d in batch])
        for conn in self._targets():
            try:
                conn.send_messages([msg])
            except Exception:  # noqa: BLE001 - one bad connection must not stop the others
                _LOGGER.debug("send to a subscriber failed", exc_info=True)

    def _run(self):
        logged = False
        while True:
            if not self._targets():
                with self._lock:
                    if not self._subscribers:
                        self._thread = None
                        return
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                sock.connect(self.sock_path)
            except OSError as err:
                if not logged:
                    _LOGGER.warning("no advertisements: cannot connect to %s (%s). Is tsx-bt running? Retrying",
                                    self.sock_path, err)
                    logged = True
                sock.close()
                self._wake.wait(RECONNECT_DELAY)
                self._wake.clear()
                continue
            logged = False
            _LOGGER.info("connected to the scanner (%s)", self.sock_path)
            try:
                self._pump(sock)
            finally:
                sock.close()

    def _pump(self, sock):
        sock.settimeout(FLUSH_INTERVAL)
        queue = AdvQueue()
        self._mode_sent = None
        self._scanner = None
        next_flush = time.monotonic() + FLUSH_INTERVAL
        while self._targets():
            mode = self._wanted_mode()
            if mode != self._mode_sent:
                try:
                    sock.send(b"m" + bytes((mode,)))
                    self._mode_sent = mode
                except OSError as err:
                    _LOGGER.warning("scanner connection: %s", err)
                    break
            try:
                msg = sock.recv(128)
                if not msg:
                    _LOGGER.warning("the scanner closed the connection")
                    break
                if len(msg) == 3 and msg[:1] == b"S":
                    scanner = (msg[1], msg[2])
                    if scanner != self._scanner:
                        self._scanner = scanner
                        self._send_state()
                else:
                    rec = parse_record(msg)
                    if rec is not None:
                        queue.push(rec)
            except socket.timeout:
                pass
            except OSError as err:
                _LOGGER.warning("scanner connection: %s", err)
                break
            now = time.monotonic()
            if queue and (queue.full_batch() or now >= next_flush):
                for batch in queue.pop_batches():
                    self._send(batch)
            if now >= next_flush:
                next_flush = now + FLUSH_INTERVAL
                if queue.dropped:
                    _LOGGER.warning("advertisements dropped: %d (the queue holds at most %d)", queue.dropped, QUEUE_MAX)
                    queue.dropped = 0
        if queue and self._targets():
            for batch in queue.pop_batches(limit=QUEUE_MAX):
                self._send(batch)
        self._scanner = None


def _uuid_words(text):
    """A 128-bit UUID string -> [high 64 bits, low 64 bits] (ESPHome)."""
    value = int(text.replace("-", ""), 16)
    return [value >> 64, value & 0xFFFFFFFFFFFFFFFF]


class GattBridge:
    """Active connections: the requests of Home Assistant go to tsx-btscan
    over bt-gatt.sock. A reader thread turns the answers into ESPHome
    messages. Each link belongs to the Home Assistant connection that asked
    for it (ESPHome allows one at a time, and so does this bridge)."""

    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()
        self._sock = None
        self._thread = None
        self._subscribers = []     # connections that want the slot count
        self._owners = {}          # address -> connection
        self._slots = None         # the last "slots" event

    # ---- the socket to tsx-btscan ------------------------------------------
    def _connect(self, quiet=False):
        """Open the socket if it is closed. Return it, or None."""
        with self._lock:
            if self._sock is not None:
                return self._sock
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            try:
                sock.connect(self.path)
            except OSError as err:
                sock.close()
                if not quiet:
                    _LOGGER.warning("active connections: cannot connect to %s (%s). Is tsx-bt running?", self.path, err)
                return None
            self._sock = sock
            self._thread = threading.Thread(target=self._reader, args=(sock,), name="tsx-bt-gatt", daemon=True)
            self._thread.start()
            _LOGGER.info("active connections: connected to %s", self.path)
            return sock

    def _send(self, **msg):
        sock = self._connect()
        if sock is None:
            return False
        try:
            sock.send(json.dumps(msg, separators=(",", ":")).encode())
            return True
        except OSError as err:
            _LOGGER.warning("active connections: send: %s", err)
            self._lost(sock)
            return False

    def _lost(self, sock):
        with self._lock:
            if self._sock is not sock:
                return
            self._sock = None
            owners, self._owners = self._owners, {}
            self._slots = None
            subs = list(self._subscribers)
        try:
            sock.close()
        except OSError:
            pass
        _LOGGER.warning("active connections: tsx-btscan closed the socket")
        from aioesphomeapi.api_pb2 import (  # pylint: disable=no-name-in-module
            BluetoothConnectionsFreeResponse,
            BluetoothDeviceConnectionResponse,
        )

        for addr, conn in owners.items():
            conn.send_messages([BluetoothDeviceConnectionResponse(address=addr, connected=False, error=0x16)])
        for conn in subs:
            conn.send_messages([BluetoothConnectionsFreeResponse(free=0, limit=0)])
        if subs:
            threading.Thread(target=self._reconnect, name="tsx-bt-gatt-retry", daemon=True).start()

    def _reconnect(self):
        """tsx-btscan went away (a restart of tsx-bt). Home Assistant still
        waits for free slots: connect again as soon as it is back."""
        while True:
            time.sleep(RECONNECT_DELAY)
            with self._lock:
                if not self._subscribers or self._sock is not None:
                    return
            if self._connect(quiet=True) is not None:
                return

    def _reader(self, sock):
        while True:
            try:
                data = sock.recv(65536)
            except OSError:
                data = b""
            if not data:
                self._lost(sock)
                return
            try:
                self._dispatch(json.loads(data))
            except Exception:  # noqa: BLE001 - one bad message must not stop the reader
                _LOGGER.warning("active connections: bad message %r", data[:120], exc_info=True)

    # ---- tsx-btscan -> Home Assistant ---------------------------------------
    def _dispatch(self, ev):
        from aioesphomeapi import api_pb2 as pb  # pylint: disable=no-name-in-module

        kind = ev.get("ev")
        if kind == "slots":
            with self._lock:
                self._slots = ev
                subs = list(self._subscribers)
            msg = pb.BluetoothConnectionsFreeResponse(free=ev["free"], limit=ev["limit"], allocated=ev["allocated"])
            for conn in subs:
                conn.send_messages([msg])
            return
        addr = ev.get("addr", 0)
        with self._lock:
            conn = self._owners.get(addr)
            if kind == "conn" and not ev.get("connected"):
                self._owners.pop(addr, None)
        if conn is None:
            _LOGGER.debug("active connections: %s for %x with no owner", kind, addr)
            return
        if kind == "conn":
            msg = pb.BluetoothDeviceConnectionResponse(address=addr, connected=ev["connected"], mtu=ev["mtu"],
                                                       error=ev["error"])
        elif kind == "services":
            msg = pb.BluetoothGATTGetServicesResponse(address=addr, services=[
                pb.BluetoothGATTService(uuid=_uuid_words(svc["uuid"]), handle=svc["handle"], characteristics=[
                    pb.BluetoothGATTCharacteristic(uuid=_uuid_words(ch["uuid"]), handle=ch["handle"],
                                                   properties=ch["props"], descriptors=[
                        pb.BluetoothGATTDescriptor(uuid=_uuid_words(d["uuid"]), handle=d["handle"])
                        for d in ch["descs"]])
                    for ch in svc["chars"]])
                for svc in ev["services"]])
        elif kind == "services_done":
            msg = pb.BluetoothGATTGetServicesDoneResponse(address=addr)
        elif kind == "read":
            msg = pb.BluetoothGATTReadResponse(address=addr, handle=ev["handle"], data=bytes.fromhex(ev["data"]))
        elif kind == "write":
            msg = pb.BluetoothGATTWriteResponse(address=addr, handle=ev["handle"])
        elif kind == "notify":
            msg = pb.BluetoothGATTNotifyResponse(address=addr, handle=ev["handle"])
        elif kind == "notify_data":
            msg = pb.BluetoothGATTNotifyDataResponse(address=addr, handle=ev["handle"], data=bytes.fromhex(ev["data"]))
        elif kind == "error":
            msg = pb.BluetoothGATTErrorResponse(address=addr, handle=ev["handle"], error=ev["error"])
        else:
            _LOGGER.debug("active connections: unknown event %r", kind)
            return
        conn.send_messages([msg])

    # ---- Home Assistant -> tsx-btscan ---------------------------------------
    def subscribe_free(self, conn):
        from aioesphomeapi.api_pb2 import BluetoothConnectionsFreeResponse  # pylint: disable=no-name-in-module

        with self._lock:
            if conn not in self._subscribers:
                self._subscribers.append(conn)
            slots = self._slots
        if slots is not None:
            conn.send_messages([BluetoothConnectionsFreeResponse(
                free=slots["free"], limit=slots["limit"], allocated=slots["allocated"])])
        elif self._connect() is None:
            conn.send_messages([BluetoothConnectionsFreeResponse(free=0, limit=0)])
        # else: the "slots" event of the new socket answers

    def release(self, conn):
        with self._lock:
            if conn in self._subscribers:
                self._subscribers.remove(conn)
            mine = [a for a, c in self._owners.items() if c is conn]
            for addr in mine:
                del self._owners[addr]
        for addr in mine:
            _LOGGER.info("active connections: %x: the Home Assistant connection closed, disconnecting", addr)
            self._send(op="disconnect", addr=addr)

    def device_request(self, conn, msg):
        from aioesphomeapi import api_pb2 as pb  # pylint: disable=no-name-in-module

        addr, kind = msg.address, msg.request_type
        if kind in (REQ_CONNECT, REQ_CONNECT_V3_WITH_CACHE, REQ_CONNECT_V3_WITHOUT_CACHE):
            with self._lock:
                self._owners[addr] = conn
            atype = msg.address_type if msg.has_address_type else 0
            if not self._send(op="connect", addr=addr, atype=atype):
                with self._lock:
                    self._owners.pop(addr, None)
                conn.send_messages([pb.BluetoothDeviceConnectionResponse(address=addr, connected=False)])
        elif kind == REQ_DISCONNECT:
            with self._lock:
                self._owners[addr] = conn
            if not self._send(op="disconnect", addr=addr):
                conn.send_messages([pb.BluetoothDeviceConnectionResponse(address=addr, connected=False)])
        elif kind == REQ_CLEAR_CACHE:
            conn.send_messages([pb.BluetoothDeviceClearCacheResponse(address=addr, success=True)])
        elif kind == REQ_PAIR:
            conn.send_messages([pb.BluetoothDevicePairingResponse(address=addr, paired=False, error=ERR_NOT_SUPPORTED)])
        elif kind == REQ_UNPAIR:
            conn.send_messages([pb.BluetoothDeviceUnpairingResponse(address=addr, success=False,
                                                                    error=ERR_NOT_SUPPORTED)])

    def gatt_request(self, conn, op, msg, **extra):
        from aioesphomeapi.api_pb2 import BluetoothGATTErrorResponse  # pylint: disable=no-name-in-module

        addr = msg.address
        handle = getattr(msg, "handle", 0)
        with self._lock:
            owned = self._owners.get(addr) is conn
        if not owned or not self._send(op=op, addr=addr, handle=handle, **extra):
            conn.send_messages([BluetoothGATTErrorResponse(address=addr, handle=handle, error=ERR_NOT_CONNECTED)])


PROXY = BtProxy()


def handle_message(conn, msg):
    """Handle the Bluetooth proxy messages of one connection. Return True if
    msg was one of them (the caller then has nothing more to do)."""
    from aioesphomeapi import api_pb2 as pb  # pylint: disable=no-name-in-module

    if isinstance(msg, pb.SubscribeBluetoothLEAdvertisementsRequest):
        PROXY.subscribe(conn, msg.flags)
        return True
    if isinstance(msg, pb.UnsubscribeBluetoothLEAdvertisementsRequest):
        PROXY.unsubscribe(conn)
        return True
    if isinstance(msg, pb.BluetoothScannerSetModeRequest):
        PROXY.set_mode(conn, msg.mode)
        return True
    if isinstance(msg, pb.BluetoothSetConnectionParamsRequest):
        # The kernel owns the connection parameters. Refuse the request.
        conn.send_messages([pb.BluetoothSetConnectionParamsResponse(address=msg.address, error=ERR_GENERIC)])
        return True
    gatt = PROXY.gatt
    if isinstance(msg, pb.SubscribeBluetoothConnectionsFreeRequest):
        if PROXY.active():
            gatt.subscribe_free(conn)
        else:
            conn.send_messages([pb.BluetoothConnectionsFreeResponse(free=0, limit=0)])
        return True
    if isinstance(msg, pb.BluetoothDeviceRequest):
        if PROXY.active() or msg.request_type == REQ_DISCONNECT:
            gatt.device_request(conn, msg)
        else:
            _LOGGER.info("Bluetooth connect request ignored: BT_ACTIVE is off")
            conn.send_messages([pb.BluetoothDeviceConnectionResponse(address=msg.address, connected=False)])
        return True
    gatt_ops = (
        (pb.BluetoothGATTGetServicesRequest, "services", lambda m: {}),
        (pb.BluetoothGATTReadRequest, "read", lambda m: {}),
        (pb.BluetoothGATTReadDescriptorRequest, "read_desc", lambda m: {}),
        (pb.BluetoothGATTWriteRequest, "write", lambda m: {"data": m.data.hex(), "response": m.response}),
        (pb.BluetoothGATTWriteDescriptorRequest, "write_desc", lambda m: {"data": m.data.hex()}),
        (pb.BluetoothGATTNotifyRequest, "notify", lambda m: {"enable": m.enable}),
    )
    for cls, op, extra in gatt_ops:
        if isinstance(msg, cls):
            gatt.gatt_request(conn, op, msg, **extra(msg))
            return True
    return False
