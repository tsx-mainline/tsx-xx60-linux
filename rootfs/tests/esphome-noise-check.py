#!/usr/bin/env python3
"""Client-side checks for rootfs/tests/test-esphome.sh's encryption tests
(HA_API_KEY, rootfs/voice/shim/tsx_panel/noise.py): each mode connects with
aioesphomeapi (Home Assistant's own client) and expects exactly the error
Home Assistant's ESPHome integration keys its behavior on -- a quick,
specific refusal, never a hang.

  esphome-noise-check.py PORT wrong-key KEY        InvalidEncryptionKeyAPIError
                                                   (+ the server's name/MAC)
  esphome-noise-check.py PORT plaintext            RequiresEncryptionAPIError
  esphome-noise-check.py PORT noise-on-plain KEY   EncryptionPlaintextAPIError
"""
import asyncio
import sys

from aioesphomeapi import APIClient
from aioesphomeapi.core import (
    EncryptionPlaintextAPIError,
    InvalidEncryptionKeyAPIError,
    RequiresEncryptionAPIError,
)

WANT = {
    "wrong-key": InvalidEncryptionKeyAPIError,
    "plaintext": RequiresEncryptionAPIError,
    "noise-on-plain": EncryptionPlaintextAPIError,
}


async def main(port: int, mode: str, key) -> int:
    client = APIClient("127.0.0.1", port, None, noise_psk=key)
    want = WANT[mode]
    try:
        await asyncio.wait_for(client.connect(login=False), timeout=5)
    except asyncio.TimeoutError:
        print(f"FAIL: {mode}: no answer within 5 s (wanted {want.__name__})")
        return 1
    except want as err:
        extra = ""
        if isinstance(err, InvalidEncryptionKeyAPIError):
            # HA's config flow uses these to name the device in the
            # "enter the encryption key" dialog
            extra = f" (server said name={err.received_name!r} mac={err.received_mac!r})"
            if not err.received_name or not err.received_mac:
                print(f"FAIL: {mode}: server hello carried no name/MAC{extra}")
                return 1
        print(f"OK: {mode}: {want.__name__}{extra}")
        return 0
    except Exception as err:  # noqa: BLE001
        print(f"FAIL: {mode}: {type(err).__name__}: {err} (wanted {want.__name__})")
        return 1
    finally:
        try:
            await client.disconnect(force=True)
        except Exception:  # noqa: BLE001
            pass
    print(f"FAIL: {mode}: connected (wanted {want.__name__})")
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(int(sys.argv[1]), sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)))
