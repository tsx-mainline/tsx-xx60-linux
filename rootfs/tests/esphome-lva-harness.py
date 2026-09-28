#!/usr/bin/env python3
"""Voice-satellite code path for rootfs/tests/test-esphome.sh, without the
audio/wake-word stack: runs the real tsx_lva patches (security.enforce(),
the ServerState name patch, the panel-entity plugin) and serves the REAL
linux_voice_assistant VoiceSatelliteProtocol on a port, exactly the way
linux_voice_assistant/__main__.py does (loop.create_server(lambda:
VoiceSatelliteProtocol(state))). Only the pieces that need hardware or
compiled wheels are no-op stand-ins: the wake-word engines
(pymicro_wakeword / pyopen_wakeword, stub modules below), the mpv players
and the wake/stop models. Same idea as the fake sysfs/CLI fixtures the
standalone test uses.

  esphome-lva-harness.py PORT      (env as for tsx_panel.esphome_server)
"""
import asyncio
import logging
import os
import sys
import tempfile
import types
from pathlib import Path
from queue import Queue


def _stub_wakeword_modules():
    for mod_name, cls_names in (
        ("pymicro_wakeword", ("MicroWakeWord", "MicroWakeWordFeatures")),
        ("pyopen_wakeword", ("OpenWakeWord", "OpenWakeWordFeatures")),
    ):
        mod = types.ModuleType(mod_name)
        for cls_name in cls_names:
            setattr(mod, cls_name, type(cls_name, (), {"process_streaming": lambda self, audio: []}))
        sys.modules[mod_name] = mod


class _NullPlayer:
    """Stands in for MpvMediaPlayer: accepts every call, plays nothing."""

    def __getattr__(self, _name):
        return lambda *args, **kwargs: None


async def _main(port: int) -> None:
    import tsx_lva  # noqa: WPS433

    tsx_lva._patch()  # pylint: disable=protected-access

    from linux_voice_assistant.models import Preferences, ServerState  # noqa: WPS433
    from linux_voice_assistant.satellite import VoiceSatelliteProtocol  # noqa: WPS433
    from linux_voice_assistant import zeroconf as lva_zeroconf  # noqa: WPS433

    tmp = Path(tempfile.mkdtemp(prefix="tsx-lva-harness-"))
    stop_word = types.SimpleNamespace(is_active=False, id="stop", wake_word="stop")
    state = ServerState(
        name="lva-02aabbccddee",  # what LVA's __main__ passes; tsx_lva's patch must replace it
        friendly_name="hostname-fallback",
        mac_address="02:aa:bb:cc:dd:ee",
        ip_address="127.0.0.1",
        network_interface="lo",
        version="test",
        esphome_version="test",
        audio_queue=Queue(),
        entities=[],
        available_wake_words={},
        wake_words={},
        active_wake_words=set(),
        stop_word=stop_word,
        music_player=_NullPlayer(),
        tts_player=_NullPlayer(),
        wakeup_sound="", start_listening_sound="", processing_sound="",
        timer_finished_sound="", mute_sound="", unmute_sound="",
        button_double_press_sound="", button_triple_press_sound="", button_long_press_sound="",
        preferences=Preferences(),
        preferences_path=tmp / "preferences.json",
        download_dir=tmp,
    )
    print(f"harness: ServerState name={state.name!r} friendly_name={state.friendly_name!r}", flush=True)

    # the mDNS record LVA would register (not actually announced here)
    info = lva_zeroconf.AsyncServiceInfo(
        "_esphomelib._tcp.local.", f"{state.name}._esphomelib._tcp.local.",
        addresses=[bytes((127, 0, 0, 1))], port=port, properties={"mac": state.mac_address},
        server=f"{state.name}.local.")
    txt = {k.decode(): (v.decode() if v is not None else None) for k, v in info.properties.items()}
    print(f"harness: mDNS TXT {sorted(txt.items())}", flush=True)

    loop = asyncio.get_running_loop()
    await loop.create_server(lambda: VoiceSatelliteProtocol(state), host="127.0.0.1", port=port)
    print(f"harness: listening on 127.0.0.1:{port}", flush=True)
    await asyncio.Future()


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    os.environ.setdefault("TSX_VOICE_WAKE", "local")
    os.environ.setdefault("TSX_VOICE_KEEP_OUTPUT_OPEN", "1")
    _stub_wakeword_modules()
    asyncio.run(_main(int(sys.argv[1])))


if __name__ == "__main__":
    main()
