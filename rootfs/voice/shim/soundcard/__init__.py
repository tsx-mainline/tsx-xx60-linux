"""Minimal ALSA stand-in for the "soundcard" package (TSX panel).

linux-voice-assistant records through soundcard, which only has a PulseAudio
backend on Linux. The panel has no sound server: the ZL38051 echo-cancelled
capture is shared by ALSA dsnoop and exposed as the "mic" PCM
(/etc/asound.conf), which ALSA resamples to 16 kHz mono. This module offers
the subset LVA uses (default_microphone, get_microphone, all_microphones,
Microphone.recorder().record()) on top of `arecord`.

Environment:
  TSX_LVA_MIC        default ALSA PCM (default "mic")
  TSX_LVA_ARECORD    arecord binary (default "arecord")
  TSX_LVA_MIC_RETRY  restarts of a dead arecord before the process exits (10)
"""

import logging
import os
import subprocess
import sys
import time

import numpy as np

__all__ = ["all_microphones", "default_microphone", "get_microphone", "Microphone"]
_LOGGER = logging.getLogger(__name__)
_ARECORD = os.environ.get("TSX_LVA_ARECORD", "arecord")


class _Recorder:
    def __init__(self, pcm, samplerate, channels, blocksize):
        self.pcm = pcm
        self.samplerate = int(samplerate)
        self.channels = int(channels or 1)
        self.blocksize = int(blocksize or 1024)
        self._proc = None
        self._fails = 0
        self._retry = int(os.environ.get("TSX_LVA_MIC_RETRY", "10"))

    def _start(self):
        cmd = [_ARECORD, "-D", self.pcm, "-q", "-t", "raw", "-f", "S16_LE",
               "-r", str(self.samplerate), "-c", str(self.channels)]
        _LOGGER.debug("soundcard shim: %s", " ".join(cmd))
        self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, bufsize=0)

    def _stop(self):
        p, self._proc = self._proc, None
        if p is None:
            return
        try:
            p.terminate()
            p.wait(timeout=2)
        except Exception:  # noqa: BLE001
            p.kill()

    def __enter__(self):
        self._start()
        return self

    def __exit__(self, *exc):
        self._stop()
        return False

    def _read_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self._proc.stdout.read(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return bytes(buf)

    def record(self, numframes=None):
        """Return float32 samples, shape (numframes, channels), range [-1, 1]."""
        n = int(numframes or self.blocksize)
        want = n * self.channels * 2
        while True:
            data = self._read_exact(want)
            if data is not None:
                self._fails = 0
                a = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
                return a.reshape(n, self.channels)
            rc = self._proc.poll() if self._proc else None
            self._fails += 1
            _LOGGER.warning("soundcard shim: arecord on %s ended (rc %s), restart %d/%d",
                            self.pcm, rc, self._fails, self._retry)
            self._stop()
            if self._fails > self._retry:
                # LVA runs the recorder in a daemon thread: sys.exit() there would
                # only end the thread and leave a deaf satellite. Exit the process
                # so the supervisor restarts it.
                _LOGGER.error("soundcard shim: microphone lost, exiting")
                sys.stderr.flush()
                os._exit(3)
            time.sleep(1.0)
            self._start()


class Microphone:
    def __init__(self, pcm):
        self.id = pcm
        self.name = pcm
        self.channels = 1
        self.isloopback = False

    def recorder(self, samplerate, channels=None, blocksize=None):
        return _Recorder(self.id, samplerate, channels, blocksize)

    def __repr__(self):
        return f"<Microphone {self.name} (ALSA)>"


def default_microphone():
    return Microphone(os.environ.get("TSX_LVA_MIC", "mic"))


def get_microphone(id, include_loopback=False):  # noqa: A002 (soundcard API name)
    if isinstance(id, int):
        mics = all_microphones()
        return mics[id] if 0 <= id < len(mics) else default_microphone()
    return Microphone(str(id))


def all_microphones(include_loopback=False):
    """ALSA capture PCMs as listed by `arecord -L` (names only)."""
    try:
        out = subprocess.run([_ARECORD, "-L"], capture_output=True, text=True, timeout=10).stdout
    except Exception:  # noqa: BLE001
        out = ""
    names = [line for line in out.splitlines() if line and not line[0].isspace()]
    return [Microphone(n) for n in names] or [default_microphone()]
