#!/usr/bin/env python3
"""Client-side checks for rootfs/tests/test-esphome.sh: connects to the
tsx-esphome standalone server under test with aioesphomeapi (the same client
library Home Assistant's ESPHome integration uses) and exercises the panel
entity list of the panel: list entities, toggle the LED bar
light, set the kiosk URL text, receive a key-press event.

  esphome-check.py PORT [--key BASE64] [--name N] [--friendly F] [--voice] [--bare]

--key connects with ESPHome's noise encryption (HA_API_KEY), --voice also
requires the voice satellite's own entities (esphome-lva-harness.py).
--bare: a panel without front keys, an LED bar or an eMMC that reports its
wear: those entities must be absent, and their checks are skipped.
"""
import argparse
import asyncio
import sys

from aioesphomeapi import APIClient
from aioesphomeapi.model import UpdateCommand


async def until(cond, timeout=15.0):
    """Wait until cond() is true, for at most timeout seconds. A fixed sleep
    is too short on a slow host (an emulated CPU), where the server needs
    longer to run a command and publish the new state."""
    end = asyncio.get_running_loop().time() + timeout
    while not cond() and asyncio.get_running_loop().time() < end:
        await asyncio.sleep(0.05)
    await asyncio.sleep(0.05)


async def main(args) -> int:
    client = APIClient("127.0.0.1", args.port, None, noise_psk=args.key)
    await client.connect(login=False)
    try:
        info = await client.device_info()
        assert info.name == args.name, info.name
        assert info.friendly_name == args.friendly, info.friendly_name
        print(f"OK: device name {info.name!r}, friendly name {info.friendly_name!r}"
              f" ({'noise-encrypted' if args.key else 'plaintext'})")

        entities, _services = await client.list_entities_services()
        by_id = {e.object_id: e for e in entities}
        want = {
            "screen", "backlight", "kiosk_url",
            "reload_page", "reboot", "cpu_temp", "uptime", "ip_address",
            "touched_recently", "update", "blank_timeout",
            "verbose_boot",
        }
        optional = {"ledbar", "keypad", "key_power", "key_home", "emmc_life_a", "emmc_life_b", "emmc_eol"}
        if not args.bare:
            want |= optional
        if args.voice:
            want |= {"mute", "thinking_sound", "linux_voice_assistant_media_player"}
        missing = want - by_id.keys()
        assert not missing, f"missing entities: {missing}"
        if args.bare:
            extra = optional & by_id.keys()
            assert not extra, f"entities for hardware this panel does not have: {extra}"
        print(f"OK: {len(entities)} entities, all expected object_ids present"
              + (" (no LED bar, key LEDs, key events or eMMC health)" if args.bare else ""))

        states = {}
        got_state = asyncio.Event()

        def on_state(state):
            states[state.key] = state
            got_state.set()

        client.subscribe_states(on_state)
        first = ["kiosk_url", "blank_timeout", "verbose_boot", "touched_recently", "update"]
        if not args.bare:
            first += ["ledbar", "emmc_life_a", "emmc_life_b", "emmc_eol"]
        await until(lambda: all(by_id[o].key in states for o in first))

        if not args.bare:
            client.light_command(
                key=by_id["ledbar"].key, state=True, rgb=(1.0, 0.0, 0.0), brightness=1.0, color_mode=35,
            )
            await until(lambda: getattr(states.get(by_id["ledbar"].key), "state", False))
            light_state = states.get(by_id["ledbar"].key)
            assert light_state is not None and light_state.state and light_state.red == 1.0, light_state
            print("OK: LED bar light toggled on (red)")

            def state(oid):
                return states.get(by_id[oid].key)

            assert state("emmc_life_a").state == 10.0 and state("emmc_life_b").state == 20.0, (state("emmc_life_a"), state("emmc_life_b"))
            assert state("emmc_eol").state == "normal", state("emmc_eol")
            assert all(by_id[o].entity_category == 2 for o in ("emmc_life_a", "emmc_life_b", "emmc_eol"))
            print("OK: eMMC life used 10 / 20 %, end of life normal (diagnostic entities)")

        text_state = states.get(by_id["kiosk_url"].key)
        assert text_state is not None and text_state.state == "https://ha.example.org/configured", text_state
        print("OK: kiosk URL reports the configured URL, not the live page")

        client.text_command(key=by_id["kiosk_url"].key, state="https://ha.example.org/lovelace/0")
        await until(lambda: getattr(states.get(by_id["kiosk_url"].key), "state", "") == "https://ha.example.org/lovelace/0")
        text_state = states.get(by_id["kiosk_url"].key)
        assert text_state is not None and text_state.state == "https://ha.example.org/lovelace/0", text_state
        print("OK: kiosk URL text set")

        client.number_command(by_id["backlight"].key, 5.0)
        await asyncio.sleep(0.5)
        print("OK: backlight number sent (5.0, test-esphome.sh checks the brightness file)")

        orient = by_id.get("orientation")
        assert orient is not None, "no orientation select"
        assert list(orient.options) == ["landscape", "portrait", "landscape-flipped", "portrait-flipped"], orient.options
        o_state = states.get(orient.key)
        assert o_state is not None and o_state.state == "landscape", o_state
        client.select_command(orient.key, "portrait")
        await until(lambda: getattr(states.get(orient.key), "state", "") == "portrait")
        o_state = states.get(orient.key)
        assert o_state is not None and o_state.state == "portrait", o_state
        client.select_command(orient.key, "sideways")
        await asyncio.sleep(1.0)   # a refused option changes nothing, so there is no state to wait for
        o_state = states.get(orient.key)
        assert o_state is not None and o_state.state == "portrait", o_state
        print("OK: orientation select: four options, reported landscape, set portrait, 'sideways' refused")

        bt_state = states.get(by_id["blank_timeout"].key)
        assert bt_state is not None and bt_state.state == 120.0, bt_state
        client.number_command(by_id["blank_timeout"].key, 600.0)
        await until(lambda: getattr(states.get(by_id["blank_timeout"].key), "state", 0) == 600.0)
        bt_state = states.get(by_id["blank_timeout"].key)
        assert bt_state is not None and bt_state.state == 600.0, bt_state
        print("OK: blank timeout reported (120 s) and set (600 s, test-esphome.sh checks tsx-config)")

        vb_state = states.get(by_id["verbose_boot"].key)
        assert vb_state is not None and not vb_state.state, vb_state
        client.switch_command(key=by_id["verbose_boot"].key, state=True)
        await until(lambda: getattr(states.get(by_id["verbose_boot"].key), "state", False))
        vb_state = states.get(by_id["verbose_boot"].key)
        assert vb_state is not None and vb_state.state, vb_state
        print("OK: verbose boot switch reported off, then set on (test-esphome.sh checks tsx-config)")

        touched = states.get(by_id["touched_recently"].key)
        assert touched is not None and touched.state, touched
        print("OK: touched recently is on (last-input a moment ago)")

        update_state = states.get(by_id["update"].key)
        assert update_state is not None, "no initial state for the update entity"
        assert update_state.current_version == "abc123", update_state
        assert update_state.latest_version == "abc123+1pending", update_state
        assert update_state.release_summary == "pkg1 (1.0 -> 1.1)", update_state
        assert not update_state.in_progress and not update_state.missing_state, update_state
        print("OK: update entity reports tsx-autoupdate's status (installed/latest/release_summary)")

        client.update_command(key=by_id["update"].key, command=UpdateCommand.INSTALL)
        await asyncio.sleep(0.5)
        print("OK: update entity Install sent (test-esphome.sh checks tsx-autoupdate ran)")

        # test-esphome.sh rewrites the fixture's buttons.state "last" line
        # after this point, to simulate a front-key press. Give the daemon's
        # 1 s poll loop a couple of ticks to notice it.
        if not args.bare:
            key_state = None
            for _ in range(40):
                await asyncio.sleep(0.25)
                key_state = states.get(by_id["key_home"].key)
                if key_state is not None:
                    break
            assert key_state is not None and key_state.event_type == "long", key_state
            print("OK: key_home press received as an event (long)")
    finally:
        await client.disconnect()
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("--key")
    parser.add_argument("--name", default="test-panel")
    parser.add_argument("--friendly", default="Test-Panel")
    parser.add_argument("--voice", action="store_true")
    parser.add_argument("--bare", action="store_true")
    sys.exit(asyncio.run(main(parser.parse_args())))
