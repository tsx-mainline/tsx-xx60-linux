#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A BLE test peripheral on a Linux host with BlueZ (bluetoothd), for the
hardware test of the active Bluetooth proxy. It is the BlueZ form of
bt-gatt-peer.py hw: on a host where bluetoothd runs, bluetoothd owns the
ATT channel, so the GATT server goes through its D-Bus API.

  bt-gatt-peer-bluez.py LOG [--adapter hci0] [--name tsx-test-peer]

Needs the dbus-fast package (pip, in a venv) and the right to call org.bluez
on the system bus (root on most hosts). It registers one advertisement
(connectable, with the name) and one GATT application, and removes both on
SIGTERM or SIGINT. It changes no adapter setting.

The service 0xFFF0 has the characteristics of bt-gatt-peer.py:
  0xFFF1 read: "hello tsx " repeated to 100 bytes
  7e570001-0000-4000-8000-747378746573 read, write, write without response
  0xFFF3 read, notify: a 4-byte counter, every 0.2 s while notifying
  0xFFF4 write: 01 = disconnect the central (from this side)
  0xFFF5 read: refused (read not permitted)
The device name characteristic (0x2A00) is the adapter name of BlueZ.
"""
import argparse
import asyncio
import signal
import struct
import sys
import time

from dbus_fast import BusType, DBusError, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import PropertyAccess, ServiceInterface, dbus_property, method

BLUEZ = "org.bluez"
APP = "/org/tsx/peer"
ADV = "/org/tsx/peer/adv0"
LONG = (b"hello tsx " * 10)[:100]
U_SVC = "0000fff0-0000-1000-8000-00805f9b34fb"
CHARS = [
    ("0000fff1-0000-1000-8000-00805f9b34fb", ["read"]),
    ("7e570001-0000-4000-8000-747378746573", ["read", "write", "write-without-response"]),
    ("0000fff3-0000-1000-8000-00805f9b34fb", ["read", "notify"]),
    ("0000fff4-0000-1000-8000-00805f9b34fb", ["write"]),
    ("0000fff5-0000-1000-8000-00805f9b34fb", ["read"]),
]


def log_to(path):
    fobj = open(path, "a", buffering=1, encoding="ascii")
    return lambda text: fobj.write(f"{time.strftime('%H:%M:%S')} {time.monotonic():.3f} {text}\n")


class Advertisement(ServiceInterface):
    def __init__(self, name):
        super().__init__("org.bluez.LEAdvertisement1")
        self.local_name = name  # not "name": that is the interface name of ServiceInterface

    @method()
    def Release(self):  # noqa: N802
        pass

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":  # noqa: N802,F821
        return "peripheral"

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":  # noqa: N802,F821
        return self.local_name

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":  # noqa: N802,F821
        return [U_SVC]


class Service(ServiceInterface):
    def __init__(self):
        super().__init__("org.bluez.GattService1")

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":  # noqa: N802,F821
        return U_SVC

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":  # noqa: N802,F821
        return True


class Char(ServiceInterface):
    def __init__(self, peer, idx, uuid, flags):
        super().__init__("org.bluez.GattCharacteristic1")
        self.peer = peer
        self.idx = idx
        self.uuid = uuid
        self.flags = flags
        self.value = {0: LONG, 1: b"init", 2: struct.pack("<I", 0)}.get(idx, b"")
        self.notifying = False

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":  # noqa: N802,F821
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":  # noqa: N802,F821
        return APP + "/service0"

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":  # noqa: N802,F821
        return self.flags

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "ay":  # noqa: N802,F821
        return self.value

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":  # noqa: N802,F821
        off = options.get("offset", Variant("q", 0)).value
        dev = options["device"].value if "device" in options else "/unknown"
        self.peer.log(f"read {self.uuid[:8]} offset {off} from {dev.rsplit('/', 1)[-1]}")
        if self.idx == 4:
            raise DBusError("org.bluez.Error.NotPermitted", "read not permitted")
        return self.value[off:]

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}"):  # noqa: N802,F821
        kind = options.get("type", Variant("s", "request")).value
        off = options.get("offset", Variant("q", 0)).value
        dev = options["device"].value if "device" in options else "/unknown"
        self.peer.log(f"write {self.uuid[:8]} {kind} offset {off} {bytes(value).hex()}")
        if self.idx == 3:
            if bytes(value)[:1] == b"\x01":
                self.peer.drop(dev)
            return
        self.value = self.value[:off] + bytes(value)

    @method()
    def StartNotify(self):  # noqa: N802
        self.peer.log(f"notify on {self.uuid[:8]}")
        self.notifying = True

    @method()
    def StopNotify(self):  # noqa: N802
        self.peer.log(f"notify off {self.uuid[:8]}")
        self.notifying = False


class App(ServiceInterface):
    def __init__(self, objects):
        super().__init__("org.freedesktop.DBus.ObjectManager")
        self.objects = objects

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":  # noqa: N802,F821
        out = {}
        for path, iface in self.objects:
            props = {}
            for prop in ("UUID", "Primary", "Service", "Flags", "Value"):
                if hasattr(type(iface), prop):
                    val = getattr(iface, prop)
                    sig = {"UUID": "s", "Primary": "b", "Service": "o", "Flags": "as", "Value": "ay"}[prop]
                    props[prop] = Variant(sig, val)
            out[path] = {iface.name: props}
        return out


class Peer:
    def __init__(self, args):
        self.args = args
        self.log = log_to(args.log)
        self.bus = None
        self.adapter = f"/org/bluez/{args.adapter}"

    def drop(self, dev_path):
        self.log(f"drop requested: Device1.Disconnect {dev_path.rsplit('/', 1)[-1]}")
        asyncio.get_running_loop().create_task(self.disconnect(dev_path))

    async def disconnect(self, dev_path):
        await asyncio.sleep(0.05)  # answer the write first
        try:
            obj = await self.bus.introspect(BLUEZ, dev_path)
            dev = self.bus.get_proxy_object(BLUEZ, dev_path, obj).get_interface("org.bluez.Device1")
            await dev.call_disconnect()
            self.log("disconnected the central")
        except DBusError as err:
            self.log(f"disconnect failed: {err}")

    async def run(self):
        self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        svc = Service()
        chars = [Char(self, i, u, f) for i, (u, f) in enumerate(CHARS)]
        objects = [(APP + "/service0", svc)] + [(f"{APP}/service0/char{i}", c) for i, c in enumerate(chars)]
        app = App(objects)
        self.bus.export(APP, app)
        for path, iface in objects:
            self.bus.export(path, iface)
        adv = Advertisement(self.args.name)
        self.bus.export(ADV, adv)
        obj = await self.bus.introspect(BLUEZ, self.adapter)
        proxy = self.bus.get_proxy_object(BLUEZ, self.adapter, obj)
        gatt_mgr = proxy.get_interface("org.bluez.GattManager1")
        adv_mgr = proxy.get_interface("org.bluez.LEAdvertisingManager1")
        await gatt_mgr.call_register_application(APP, {})
        await adv_mgr.call_register_advertisement(ADV, {})
        self.log(f"advertising {self.args.name}, GATT application registered")
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        counter = 0
        notify = chars[2]
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), 0.2)
            except asyncio.TimeoutError:
                pass
            if notify.notifying:
                counter += 1
                notify.value = struct.pack("<I", counter)
                notify.emit_properties_changed({"Value": notify.value})
        for call in (adv_mgr.call_unregister_advertisement(ADV), gatt_mgr.call_unregister_application(APP)):
            try:
                await call
            except DBusError as err:
                self.log(f"unregister: {err}")
        self.log("stopped: advertisement and GATT application removed")
        self.bus.disconnect()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--adapter", default="hci0")
    ap.add_argument("--name", default="tsx-test-peer")
    args = ap.parse_args()
    asyncio.run(Peer(args).run())
    return 0


if __name__ == "__main__":
    sys.exit(main())
