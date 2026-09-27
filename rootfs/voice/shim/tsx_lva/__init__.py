"""TSX panel glue around linux-voice-assistant .

Runs linux_voice_assistant.__main__.run() after a few in-process adaptations,
all driven by environment variables that /etc/init.d/tsx-voice sets from
/etc/tsx/voice.conf:

  TSX_VOICE_PTT=/run/tsx/voice/ptt   FIFO; each line is a command:
        ptt              push-to-talk toggle (idle: start listening, busy: stop)
        start_listening, stop_pipeline, mute_mic, unmute_mic, volume_up,
        volume_down, stop_timer_ringing, ... (any peripheral API command)
  TSX_VOICE_HOOK=/usr/local/bin/tsx-voice-hook
        run with detection|listen|think|speak|error|done on assistant events
        (ducking of the "Media" softvol, LED bar, /run/tsx/voice/voice.state)
  TSX_VOICE_WAKE=ptt|local
        ptt: no on-device wake word or stop word inference (saves CPU; the
        models are still loaded so HA's wake word select keeps working)
  TSX_VOICE_KEEP_OUTPUT_OPEN=0|1
        1 = upstream behaviour (mpv plays silence between sounds, the output
        stream stays open, SPK_EN and dmix stay active all the time)
"""

import asyncio
import json
import logging
import os
import queue
import subprocess
import sys
import threading

_LOGGER = logging.getLogger("tsx_lva")

_HOOK_EVENTS = {
    "wake_word_detected": "detection",
    "listening": "listen",
    "thinking": "think",
    "tts_speaking": "speak",
    "pipeline_error": "error",
    "idle": "done",
    "disconnected": "done",
}


class _Glue:
    def __init__(self):
        self.api = None  # PeripheralAPIServer
        self.hook = os.environ.get("TSX_VOICE_HOOK", "")
        self._hooks: "queue.Queue[str]" = queue.Queue()
        self.last_hook = None

    # --- hooks (sequential, off the event loop) ---------------------------
    def hook_event(self, name):
        arg = _HOOK_EVENTS.get(name)
        if not arg or not self.hook:
            return
        if arg == self.last_hook and arg in ("done", "listen"):
            return
        self.last_hook = arg
        self._hooks.put(arg)

    def _hook_worker(self):
        while True:
            arg = self._hooks.get()
            try:
                subprocess.run([self.hook, arg], timeout=15, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            except Exception as err:  # noqa: BLE001
                _LOGGER.warning("hook %s %s failed: %s", self.hook, arg, err)

    # --- push-to-talk FIFO -------------------------------------------------
    def _command(self, line):
        api = self.api
        if api is None or api._loop is None:  # pylint: disable=protected-access
            _LOGGER.warning("command %r ignored: peripheral API not running", line)
            return
        state = api._state  # pylint: disable=protected-access
        if line == "ptt":
            sat = state.satellite if state is not None else None
            if sat is None:
                _LOGGER.warning("push-to-talk ignored: Home Assistant not connected")
                return
            busy = getattr(sat, "_pipeline_active", False) or getattr(sat, "_timer_finished", False)
            line = "stop_pipeline" if busy else "start_listening"
            if getattr(sat, "_timer_finished", False):
                line = "stop_timer_ringing"
        _LOGGER.info("FIFO command: %s", line)
        asyncio.run_coroutine_threadsafe(
            api._dispatch_command(json.dumps({"command": line})), api._loop)  # pylint: disable=protected-access

    def _fifo_worker(self, path):
        while True:
            try:
                with open(path, "r", encoding="utf-8") as fifo:  # blocks until a writer opens
                    for line in fifo:
                        line = line.strip()
                        if line:
                            self._command(line)
            except Exception as err:  # noqa: BLE001
                _LOGGER.warning("FIFO %s: %s", path, err)
                threading.Event().wait(2.0)

    def start_threads(self):
        if self.hook:
            threading.Thread(target=self._hook_worker, name="tsx-hook", daemon=True).start()
        fifo = os.environ.get("TSX_VOICE_PTT", "")
        if fifo:
            threading.Thread(target=self._fifo_worker, args=(fifo,), name="tsx-ptt", daemon=True).start()


GLUE = _Glue()


def _patch():
    from linux_voice_assistant import peripheral_api  # noqa: WPS433

    cls = peripheral_api.PeripheralAPIServer
    orig_start, orig_emit = cls.start, cls.emit_event

    async def start(self):
        GLUE.api = self
        await orig_start(self)
        if self._loop is None:  # pylint: disable=protected-access
            # websockets missing: still let the FIFO dispatch commands
            self._loop = asyncio.get_running_loop()  # pylint: disable=protected-access

    async def emit_event(self, event, data=None):
        GLUE.hook_event(getattr(event, "value", str(event)))
        await orig_emit(self, event, data)

    cls.start, cls.emit_event = start, emit_event

    if os.environ.get("TSX_VOICE_WAKE", "local") == "ptt":
        import pymicro_wakeword  # noqa: WPS433
        import pyopen_wakeword  # noqa: WPS433

        # no features -> no inference; wake word and stop word never fire
        pymicro_wakeword.MicroWakeWordFeatures.process_streaming = lambda self, audio: []
        pyopen_wakeword.OpenWakeWordFeatures.process_streaming = lambda self, audio: []
        # logging is not configured yet (LVA does it in main): print
        print("tsx_lva: push-to-talk only: on-device wake word disabled", file=sys.stderr, flush=True)

    if os.environ.get("TSX_VOICE_KEEP_OUTPUT_OPEN", "0") != "1":
        from linux_voice_assistant.player import libmpv  # noqa: WPS433

        orig_init = libmpv.LibMpvPlayer.__init__

        def init(self, *args, **kwargs):
            orig_init(self, *args, **kwargs)
            self._mpv["audio-stream-silence"] = False  # pylint: disable=protected-access
            self._mpv["audio-buffer"] = float(os.environ.get("TSX_VOICE_AUDIO_BUFFER", "0.2"))  # pylint: disable=protected-access

        libmpv.LibMpvPlayer.__init__ = init


def main():
    _patch()
    GLUE.start_threads()
    from linux_voice_assistant.__main__ import run  # noqa: WPS433

    run()
