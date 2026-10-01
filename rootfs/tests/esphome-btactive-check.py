#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Client-side check of the active Bluetooth proxy (BT_ACTIVE=on). It uses
the client code of Home Assistant: aioesphomeapi for the API and the
ESPHomeClient of bleak-esphome (the bleak backend that Home Assistant uses
for an ESPHome proxy) for the BLE link. The peer is bt-gatt-peer.py: the
fake one in rootfs/tests/test-esphome.sh, or a real peripheral on a panel.

  esphome-btactive-check.py HOST PORT --addr C0:FF:EE:00:00:01 [--atype 1]
      [--silent C0:FF:EE:00:00:EE] [--cycles 5] [--limit 3] [--key BASE64]
      [--adv] [--json RESULT] [--gap-name NAME] [--retries N]

Checks: the feature flags, the slot count, connect, the services, read,
write with and without response, a refused read, notifications on and off,
disconnect, --cycles connect/disconnect cycles, a drop by the peer and the
reconnect after it, a connect timeout (--silent), and with --adv that raw
advertisements keep arriving between the links. --retries N: try a connect
again up to N times when the link fails while it comes up, like
bleak-retry-connector in Home Assistant (a Linux peer drops some links,
docs/hardware.md). Prints one "OK:" line per check and the timings. Exit
status 1 on the first failure.
"""
import argparse
import asyncio
import contextlib
import json
import statistics
import sys
import time

from aioesphomeapi import APIClient, BluetoothProxyFeature
from bleak.backends.device import BLEDevice
from bleak.exc import BleakError
from bleak_esphome.backend.client import ESPHomeClient, ESPHomeClientData
from bleak_esphome.backend.device import ESPHomeBluetoothDevice

LONG = (b"hello tsx " * 10)[:100]
U_NAME = "00002a00-0000-1000-8000-00805f9b34fb"
U_LONG = "0000fff1-0000-1000-8000-00805f9b34fb"
U_RW = "7e570001-0000-4000-8000-747378746573"
U_NOTIFY = "0000fff3-0000-1000-8000-00805f9b34fb"
U_CTRL = "0000fff4-0000-1000-8000-00805f9b34fb"
U_DENIED = "0000fff5-0000-1000-8000-00805f9b34fb"
CCCD = "00002902-0000-1000-8000-00805f9b34fb"
WANT_FLAGS = (BluetoothProxyFeature.PASSIVE_SCAN | BluetoothProxyFeature.RAW_ADVERTISEMENTS
              | BluetoothProxyFeature.ACTIVE_CONNECTIONS | BluetoothProxyFeature.REMOTE_CACHING
              | BluetoothProxyFeature.CACHE_CLEARING)


class Failed(Exception):
    pass


def check(cond, text):
    if not cond:
        raise Failed(text)
    print(f"OK: {text}", flush=True)


class StubScanner:
    """The part of ESPHomeScanner that ESPHomeClient uses."""

    @contextlib.contextmanager
    def connecting(self):
        yield


class Adverts:
    def __init__(self):
        self.times = []

    def __call__(self, msg):
        now = time.monotonic()
        self.times.extend([now] * len(msg.advertisements))

    def count(self, t0, t1):
        return sum(1 for t in self.times if t0 <= t < t1)


async def run(args):
    res = {}
    cli = APIClient(args.host, args.port, None, noise_psk=args.key)
    await cli.connect(login=False)
    info = await cli.device_info()
    flags = info.bluetooth_proxy_feature_flags_compat(cli.api_version)
    check(flags == WANT_FLAGS, f"device info: Bluetooth proxy flags {int(flags)} = passive, raw advertisements, "
          "active connections, remote caching, cache clearing")
    source = info.bluetooth_mac_address or info.mac_address
    bdev = ESPHomeBluetoothDevice(info.name, source, available=True)
    cli.subscribe_bluetooth_connections_free(bdev.async_update_ble_connection_limits)
    adverts = Adverts()
    if args.adv:
        cli.subscribe_bluetooth_le_raw_advertisements(adverts)
    for _ in range(50):
        if bdev.ble_connections_limit:
            break
        await asyncio.sleep(0.1)
    check(bdev.ble_connections_limit == args.limit and bdev.ble_connections_free == args.limit,
          f"connections free: {bdev.ble_connections_free} of {bdev.ble_connections_limit}")
    data = ESPHomeClientData(bluetooth_device=bdev, client=cli, device_info=info, api_version=cli.api_version,
                             title=info.name, scanner=StubScanner())
    dropped = []

    def make(addr, atype):
        dev = BLEDevice(addr, "tsx-test-peer", {"source": source, "address_type": atype})
        return ESPHomeClient(dev, client_data=data, disconnected_callback=lambda *_: dropped.append(time.monotonic()))

    failed = []

    async def connect(client, **kw):
        """Connect like bleak-retry-connector does: try again after a link
        that the peer dropped while it came up (--retries)."""
        for attempt in range(args.retries + 1):
            t = time.monotonic()
            try:
                await client.connect(pair=False, **kw)
                return
            except BleakError as err:
                if attempt == args.retries or "while connecting" not in str(err):
                    raise
                failed.append(round(time.monotonic() - t, 2))
                await asyncio.sleep(0.5)

    peer = make(args.addr, args.atype)
    t0 = time.monotonic()
    await connect(peer)
    res["connect_s"] = round(time.monotonic() - t0, 3)
    check(peer.is_connected, f"connect (with service discovery) in {res['connect_s']:.2f} s, MTU {peer.mtu_size}")
    await asyncio.sleep(0.3)
    check(bdev.ble_connections_free == args.limit - 1 and len(bdev.ble_allocations) == 1,
          f"connections free: {bdev.ble_connections_free}, allocated {len(bdev.ble_allocations)}")
    svcs = peer.services
    chars = {c.uuid: c for s in svcs for c in s.characteristics}
    check(set(chars) >= {U_NAME, U_LONG, U_RW, U_NOTIFY, U_CTRL, U_DENIED},
          f"services: {len(list(svcs))} services, {len(chars)} characteristics, the 128-bit one included")
    check(chars[U_NOTIFY].get_descriptor(CCCD) is not None and "notify" in chars[U_NOTIFY].properties,
          "the notify characteristic has its CCCD")
    check(set(chars[U_RW].properties) >= {"read", "write", "write-without-response"},
          f"properties of the writable characteristic: {chars[U_RW].properties}")

    t0 = time.monotonic()
    val = await peer.read_gatt_char(chars[U_LONG])
    res["read_ms"] = round((time.monotonic() - t0) * 1000, 1)
    check(bytes(val) == LONG, f"read: 100 bytes in {res['read_ms']} ms")
    check(bytes(await peer.read_gatt_char(chars[U_NAME])) == args.gap_name.encode(), "read: the device name")
    t0 = time.monotonic()
    await peer.write_gatt_char(chars[U_RW], b"panel", response=True)
    res["write_ms"] = round((time.monotonic() - t0) * 1000, 1)
    check(bytes(await peer.read_gatt_char(chars[U_RW])) == b"panel", f"write with response in {res['write_ms']} ms")
    await peer.write_gatt_char(chars[U_RW], b"quick", response=False)
    await asyncio.sleep(0.3)
    check(bytes(await peer.read_gatt_char(chars[U_RW])) == b"quick", "write without response")
    try:
        await peer.read_gatt_char(chars[U_DENIED])
        check(False, "a refused read raises")
    except BleakError as err:
        check("Read not permitted" in str(err) or "2" in str(err), f"a refused read raises: {err}")

    got = []
    await peer.start_notify(chars[U_NOTIFY], lambda d: got.append((time.monotonic(), bytes(d))))
    await asyncio.sleep(1.5)
    n = len(got)
    vals = [int.from_bytes(d, "little") for _, d in got]
    check(n >= 5 and vals == sorted(vals), f"notifications: {n} in 1.5 s, in order")
    await peer.stop_notify(chars[U_NOTIFY])
    await asyncio.sleep(0.5)
    before = len(got)
    await asyncio.sleep(1.0)
    check(len(got) == before, "notifications stop after stop_notify (the client writes the CCCD, the proxy stops forwarding)")

    t0 = time.monotonic()
    await peer.disconnect()
    res["disconnect_s"] = round(time.monotonic() - t0, 3)
    check(not peer.is_connected, f"disconnect in {res['disconnect_s']:.2f} s")
    for _ in range(30):
        if bdev.ble_connections_free == args.limit:
            break
        await asyncio.sleep(0.1)
    check(bdev.ble_connections_free == args.limit, "the slot is free again")

    times = []
    t_between = []
    for i in range(args.cycles):
        c = make(args.addr, args.atype)
        t0 = time.monotonic()
        await connect(c, dangerous_use_bleak_cache=True)
        up = time.monotonic() - t0
        v = await c.read_gatt_char(c.services.get_characteristic(U_NAME))
        t1 = time.monotonic()
        await c.disconnect()
        times.append((up, time.monotonic() - t1))
        if bytes(v) != args.gap_name.encode():
            raise Failed(f"cycle {i + 1}: read {v!r}")
        t_between.append(time.monotonic())
        await asyncio.sleep(args.pause)
    if args.cycles:
        ups = [u for u, _ in times]
        downs = [d for _, d in times]
        res["cycles"] = args.cycles
        res["cycle_connect_s"] = [round(min(ups), 3), round(statistics.mean(ups), 3), round(max(ups), 3)]
        res["cycle_disconnect_s"] = [round(min(downs), 3), round(statistics.mean(downs), 3), round(max(downs), 3)]
        check(True, f"{args.cycles} connect/read/disconnect cycles: connect min/avg/max "
              f"{res['cycle_connect_s']} s, disconnect {res['cycle_disconnect_s']} s")
    if args.adv and t_between:
        n_adv = sum(adverts.count(t, t + args.pause) for t in t_between)
        res["adverts_between_links"] = n_adv
        check(n_adv > 0, f"raw advertisements between the links: {n_adv} in {len(t_between)} pauses "
              f"of {args.pause} s")

    # the peer drops the link, then a reconnect
    peer = make(args.addr, args.atype)
    await connect(peer, dangerous_use_bleak_cache=True)
    ctrl = peer.services.get_characteristic(U_CTRL)
    dropped.clear()
    t0 = time.monotonic()
    with contextlib.suppress(BleakError, TimeoutError):
        await peer.write_gatt_char(ctrl, b"\x01", response=True)
    for _ in range(100):
        if dropped and not peer.is_connected:
            break
        await asyncio.sleep(0.1)
    res["peer_drop_s"] = round((dropped[0] if dropped else time.monotonic()) - t0, 3)
    check(bool(dropped) and not peer.is_connected, f"the peer drops the link: the client sees it in {res['peer_drop_s']:.2f} s")
    await asyncio.sleep(args.pause)
    t0 = time.monotonic()
    await connect(peer, dangerous_use_bleak_cache=True)
    res["reconnect_s"] = round(time.monotonic() - t0, 3)
    check(peer.is_connected and bytes(await peer.read_gatt_char(peer.services.get_characteristic(U_NAME))) == args.gap_name.encode(),
          f"reconnect after the drop in {res['reconnect_s']:.2f} s")
    await peer.disconnect()

    if args.silent:
        ghost = make(args.silent, 1)
        t0 = time.monotonic()
        try:
            await ghost.connect(pair=False, timeout=40)
            check(False, "a device that does not answer: the connect fails")
        except (BleakError, TimeoutError) as err:
            res["connect_timeout_s"] = round(time.monotonic() - t0, 3)
            check(True, f"a device that does not answer: the connect fails after {res['connect_timeout_s']:.1f} s ({err})")
        for _ in range(30):
            if bdev.ble_connections_free == args.limit:
                break
            await asyncio.sleep(0.1)
        check(bdev.ble_connections_free == args.limit, "all slots free at the end")
    res["failed_attempts"] = failed
    if failed:
        print(f"NOTE: {len(failed)} connect attempt(s) failed while the link came up and were tried again", flush=True)
    await cli.disconnect()
    if args.json:
        with open(args.json, "w", encoding="ascii") as fobj:
            json.dump(res, fobj, indent=1)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("port", type=int)
    ap.add_argument("--addr", required=True)
    ap.add_argument("--atype", type=int, default=0)
    ap.add_argument("--silent")
    ap.add_argument("--cycles", type=int, default=5)
    ap.add_argument("--pause", type=float, default=0.5, help="seconds between the links")
    ap.add_argument("--limit", type=int, default=3)
    ap.add_argument("--key")
    ap.add_argument("--adv", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--retries", type=int, default=0,
                    help="connect attempts to repeat after a link that failed while it came up")
    ap.add_argument("--gap-name", default="tsx-test-peer",
                    help="the device name (0x2A00) of the peer: the adapter name for bt-gatt-peer-bluez.py")
    args = ap.parse_args()
    try:
        return asyncio.run(run(args))
    except Failed as err:
        print(f"FAIL: {err}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
