"""Passive Bluetooth proxy for the ESPHome device of the panel.

Home Assistant uses an ESPHome device as a remote Bluetooth adapter when the
DeviceInfoResponse announces Bluetooth proxy feature flags. This module adds
the passive part of that protocol (aioesphomeapi 46.2.0, bleak-esphome 4.1):

  DeviceInfoResponse
      bluetooth_proxy_feature_flags = PASSIVE_SCAN | RAW_ADVERTISEMENTS (33)
      bluetooth_mac_address         = the address that tsx-bt loaded
  SubscribeBluetoothLEAdvertisementsRequest (flags RAW_ADVERTISEMENTS)
      -> BluetoothLERawAdvertisementsResponse messages, up to 16
         advertisements each, at most every 100 ms
  UnsubscribeBluetoothLEAdvertisementsRequest, or a closed connection
      -> no more advertisements for that connection

No active connections (GATT), no pairing, no scanner mode switch: Home
Assistant then treats the panel as a non-connectable, passive scanner.

The advertisements come from tsx-btscan (/usr/local/lib/tsx/btscan.py, run
as root by /etc/init.d/tsx-bt) over a SOCK_SEQPACKET Unix socket. The
format of one message is in the docstring of btscan.py. This module connects
only while at least one Home Assistant connection is subscribed, and
tsx-btscan scans only while a client is connected.

The proxy is on when $TSX_RUN_DIR/bt.conf (written by tsx-config apply from
panel.conf BT_PROXY) says PROXY="on". Both front ends use one module-level
instance (PROXY): tsx-esphome (esphome_server.py) and the voice satellite
(tsx_lva). The voice satellite runs as the kiosk user. It can read bt.conf
and bt.mac (mode 644) and connect to the socket (group kiosk).
Test hooks: TSX_RUN_DIR, TSX_BT_CONF, TSX_BT_MAC_FILE, TSX_BT_ADV_SOCKET.
"""

import logging
import os
import socket
import struct
import threading
import time

_LOGGER = logging.getLogger("tsx_panel.bluetooth")

FEATURE_PASSIVE_SCAN = 1
FEATURE_RAW_ADVERTISEMENTS = 32
FEATURES = FEATURE_PASSIVE_SCAN | FEATURE_RAW_ADVERTISEMENTS
SUBSCRIPTION_FLAG_RAW = 1
BATCH_MAX = 16
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


class BtProxy:
    def __init__(self, run_dir=None):
        run = run_dir or os.environ.get("TSX_RUN_DIR", "/run/tsx")
        self.conf_path = os.environ.get("TSX_BT_CONF", os.path.join(run, "bt.conf"))
        self.mac_path = os.environ.get("TSX_BT_MAC_FILE", os.path.join(run, "bt.mac"))
        self.sock_path = os.environ.get("TSX_BT_ADV_SOCKET", os.path.join(run, "bt-adv.sock"))
        self._lock = threading.Lock()
        self._subscribers = []
        self._thread = None
        self._wake = threading.Event()

    # ---- configuration ---------------------------------------------------
    def enabled(self):
        return _conf_value(self.conf_path, "PROXY") == "on"

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
        fields = {"bluetooth_proxy_feature_flags": FEATURES}
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

    def unsubscribe(self, conn):
        with self._lock:
            if conn in self._subscribers:
                self._subscribers.remove(conn)
                _LOGGER.info("Bluetooth advertisements: %d subscriber(s)", len(self._subscribers))
        self._wake.set()

    def _targets(self):
        with self._lock:
            return list(self._subscribers)

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
        batch = []
        next_flush = time.monotonic() + FLUSH_INTERVAL
        while self._targets():
            try:
                msg = sock.recv(128)
                if not msg:
                    _LOGGER.warning("the scanner closed the connection")
                    break
                rec = parse_record(msg)
                if rec is not None:
                    batch.append(rec)
            except socket.timeout:
                pass
            except OSError as err:
                _LOGGER.warning("scanner connection: %s", err)
                break
            now = time.monotonic()
            if batch and (len(batch) >= BATCH_MAX or now >= next_flush):
                self._send(batch)
                batch = []
            if now >= next_flush:
                next_flush = now + FLUSH_INTERVAL
        if batch and self._targets():
            self._send(batch)


PROXY = BtProxy()


def handle_message(conn, msg):
    """Handle the Bluetooth proxy messages of one connection. Return True if
    msg was one of them (the caller then has nothing more to do)."""
    from aioesphomeapi.api_pb2 import (  # pylint: disable=no-name-in-module
        SubscribeBluetoothLEAdvertisementsRequest,
        UnsubscribeBluetoothLEAdvertisementsRequest,
    )

    if isinstance(msg, SubscribeBluetoothLEAdvertisementsRequest):
        PROXY.subscribe(conn, msg.flags)
        return True
    if isinstance(msg, UnsubscribeBluetoothLEAdvertisementsRequest):
        PROXY.unsubscribe(conn)
        return True
    return False
