#!/usr/bin/env python3
"""Client-side check of the Bluetooth proxy for rootfs/tests/test-esphome.sh.
It uses aioesphomeapi (the client library of Home Assistant) the way
bleak-esphome does for a passive proxy: read the feature flags from the
device info, then subscribe to raw advertisements.

  esphome-bt-check.py PORT on|off [--key BASE64] [--mac 02:AA:BB:CC:DD:EE]

on:  flags = PASSIVE_SCAN | RAW_ADVERTISEMENTS, bluetooth_mac_address = --mac,
     and the three advertisements of bt-fake-hci.py arrive (address as the
     48-bit integer, RSSI, address type 0/1, the data bytes).
off: no flags, and a subscription brings no advertisements.
"""
import argparse
import asyncio
import sys

from aioesphomeapi import APIClient, BluetoothProxyFeature

WANT = {
    "C0:FF:EE:00:00:01": (-60, 1, "0201060aff4c001005031c000001"),
    "12:34:56:78:9A:BC": (-75, 0, "0303aafe1116aafe10f403676f6f676c6507"),
    "00:11:22:33:44:55": (-90, 1, ""),
}


def addr_str(value):
    return ":".join(f"{(value >> s) & 0xFF:02X}" for s in range(40, -8, -8))


async def main(args) -> int:
    client = APIClient("127.0.0.1", args.port, None, noise_psk=args.key)
    await client.connect(login=False)
    try:
        info = await client.device_info()
        flags = info.bluetooth_proxy_feature_flags_compat(client.api_version)
        if args.mode == "on":
            want = BluetoothProxyFeature.PASSIVE_SCAN | BluetoothProxyFeature.RAW_ADVERTISEMENTS
            assert flags == want, flags
            assert not flags & BluetoothProxyFeature.ACTIVE_CONNECTIONS, flags
            assert info.bluetooth_mac_address == args.mac, info.bluetooth_mac_address
            print(f"OK: device info: Bluetooth proxy flags {int(flags)} (passive, raw advertisements), "
                  f"address {info.bluetooth_mac_address}")
        else:
            assert flags == 0, flags
            print("OK: device info: no Bluetooth proxy flags (BT_PROXY off)")

        seen = {}
        batches = []

        def on_adv(msg):
            batches.append(len(msg.advertisements))
            for adv in msg.advertisements:
                seen[addr_str(adv.address)] = (adv.rssi, adv.address_type, adv.data.hex())

        unsub = client.subscribe_bluetooth_le_raw_advertisements(on_adv)
        for _ in range(40):
            await asyncio.sleep(0.1)
            if len(seen) >= 3:
                break
        if args.mode == "on":
            assert seen == WANT, seen
            assert max(batches) <= 16, batches
            print(f"OK: raw advertisements arrived ({sum(batches)} in {len(batches)} messages), "
                  "address, RSSI, address type and data exact")
        else:
            assert not seen, seen
            print("OK: no advertisements while BT_PROXY is off")
        unsub()
        await asyncio.sleep(1.0)
    finally:
        await client.disconnect()
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("port", type=int)
    ap.add_argument("mode", choices=("on", "off"))
    ap.add_argument("--key")
    ap.add_argument("--mac", default="02:AA:BB:CC:DD:EE")
    sys.exit(asyncio.run(main(ap.parse_args())))
