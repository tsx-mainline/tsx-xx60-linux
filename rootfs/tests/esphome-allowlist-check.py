#!/usr/bin/env python3
"""Client-side check for rootfs/tests/test-esphome.sh's HA_ALLOW_FROM test:
connects to a tsx-esphome instance and asserts the connection either
succeeds (an allowed peer) or is closed by the server (a denied one) -- see
rootfs/voice/shim/tsx_panel/security.py.
"""
import asyncio
import sys

from aioesphomeapi import APIClient
from aioesphomeapi.core import APIConnectionError


async def main(port: int, expect: str) -> int:
    client = APIClient("127.0.0.1", port, None)
    try:
        await asyncio.wait_for(client.connect(login=False), timeout=5)
        connected = True
    except (APIConnectionError, asyncio.TimeoutError, OSError, ConnectionResetError):
        connected = False
    if connected:
        try:
            await client.device_info()
        except (APIConnectionError, ConnectionResetError):
            connected = False
    try:
        await client.disconnect()
    except Exception:  # noqa: BLE001
        pass

    if expect == "allow":
        assert connected, "expected the connection to be allowed, it was refused/closed"
        print("OK: allowed peer connected")
    else:
        assert not connected, "expected the connection to be refused/closed, it succeeded"
        print("OK: denied peer's connection was closed")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(int(sys.argv[1]), sys.argv[2])))
