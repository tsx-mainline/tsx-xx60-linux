"""Fake Home Assistant for the voice satellite test (guest side).

Talks to linux-voice-assistant on $LVA_HOST:6053 with aioesphomeapi's
APIClient, i.e. the same library and calls HA's ESPHome integration uses:
connect, device_info, list_entities_services, voice assistant configuration,
subscribe_voice_assistant (API audio). Then a conversation is triggered
(mode "ptt": `tsx-voice ptt`; mode "wake": the okay_nabu sample is played
into the loopback card so the microphone hears it), the microphone stream is
checked for a known 440 Hz tone, the pipeline events of a real HA run are
sent (run start, STT, intent, TTS with a URL served here) and the TTS reply
must come back through the loopback capture; then an announcement
(assist_satellite.announce) must be played and acknowledged.
Prints "CHECK ok|FAIL <name>" lines; exit code = number of failures.
"""
import asyncio
import functools
import http.server
import math
import os
import struct
import subprocess
import sys
import threading
import time
import wave

from aioesphomeapi import APIClient
from aioesphomeapi.model import VoiceAssistantEventType as E

MODE = sys.argv[1] if len(sys.argv) > 1 else "ptt"
T = os.environ.get("TEST_DIR", "/test")
HTTP_PORT = 8123
fails = 0


def log(*a):
    print("fake_ha:", *a, flush=True)


def check(name, ok):
    global fails
    print(f"CHECK {'ok' if ok else 'FAIL'} {name}", flush=True)
    if not ok:
        fails += 1


def tone_wav(path, rate, secs, freq, dbfs):
    amp = 32767 * 10 ** (dbfs / 20)
    n = int(rate * secs)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(amp * math.sin(2 * math.pi * freq * i / rate))) for i in range(n)))


def goertzel_db(pcm, rate, freq):
    """Level of freq in dBFS (peak of a sine), from 16-bit mono PCM."""
    n = len(pcm) // 2
    if n < 256:
        return -200.0
    s = struct.unpack(f"<{n}h", pcm[: n * 2])
    k = 2 * math.cos(2 * math.pi * freq / rate)
    q1 = q2 = 0.0
    for x in s:
        q0 = k * q1 - q2 + x
        q2, q1 = q1, q0
    power = q1 * q1 + q2 * q2 - k * q1 * q2
    amp = 2 * math.sqrt(max(power, 0.0)) / n
    return 20 * math.log10(max(amp, 1e-9) / 32768)


def tone_profile(pcm, rate, freq, win=0.25):
    """Max level of freq over short windows and the seconds where it is present (> -40 dBFS)."""
    step = int(rate * win) * 2
    levels = [goertzel_db(pcm[i:i + step], rate, freq) for i in range(0, len(pcm) - step + 1, step)]
    if not levels:
        return -200.0, 0.0, ""
    present = sum(1 for x in levels if x > -40) * win
    trace = " ".join(f"{x:.0f}" for x in levels)
    return max(levels), present, trace


def vol(ctl):
    out = subprocess.run(["amixer", "-c", "TSW1060", "sget", ctl], capture_output=True, text=True).stdout
    for tok in out.replace("[", " ").replace("]", " ").split():
        if tok.endswith("%"):
            return int(tok[:-1])
    return None


def serve_http():
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory="/tmp/www")
    handler.log_message = lambda *a: None
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


async def main():
    os.makedirs("/tmp/www", exist_ok=True)
    tone_wav("/tmp/www/tts.wav", 22050, 2.0, 660, -20.0)
    tone_wav("/tmp/www/announce.wav", 22050, 1.5, 550, -20.0)
    serve_http()

    host = os.environ.get("LVA_HOST", "127.0.0.1")  # LVA binds to the default-route address
    c = APIClient(host, 6053, None, client_info="fake-ha")
    t0 = time.monotonic()
    await c.connect(login=True)
    info = await c.device_info()
    log(f"Master at connect: {vol('Master')}")
    log("device_info:", info.name, "|", info.friendly_name, "|", info.model, "| flags", info.voice_assistant_feature_flags)
    check("ESPHome API connect + device_info (name lva-*)", info.name.startswith("lva-"))
    check("voice assistant feature flags set", bool(info.voice_assistant_feature_flags))
    entities, _services = await c.list_entities_services()
    kinds = sorted({type(e).__name__ for e in entities})
    log("entities:", len(entities), kinds)
    check("entities include a media player", "MediaPlayerInfo" in kinds)
    cfg = await c.get_voice_assistant_configuration(10)
    log("wake words available:", [w.id for w in cfg.available_wake_words], "active:", cfg.active_wake_words)
    check("voice assistant configuration lists okay_nabu", any(w.id == "okay_nabu" for w in cfg.available_wake_words))

    started = asyncio.Event()
    finished = asyncio.Event()
    audio = bytearray()
    collecting = [False]
    start_info = {}

    async def handle_start(conversation_id, flags, audio_settings, wake_word_phrase):
        start_info["phrase"] = wake_word_phrase
        log("handle_start: wake word", repr(wake_word_phrase), "flags", flags)
        started.set()
        return 0  # audio over the API connection

    async def handle_stop(abort):
        log("handle_stop abort", abort)

    async def handle_audio(data, data2):
        if collecting[0]:
            audio.extend(data)

    async def handle_finished(msg):
        log("announce finished:", msg)
        finished.set()

    c.subscribe_voice_assistant(handle_start=handle_start, handle_stop=handle_stop,
                                handle_audio=handle_audio, handle_announcement_finished=handle_finished)
    await asyncio.sleep(1)
    pid = os.environ.get("LVA_PID")
    if pid:  # CPU of the connected, idle satellite (wake word inference runs only while HA is connected)
        def ticks():
            with open(f"/proc/{pid}/stat") as f:
                v = f.read().rsplit(")", 1)[1].split()
            return int(v[11]) + int(v[12])
        a = ticks(); await asyncio.sleep(20); b = ticks()
        log(f"CPU while connected and idle ({MODE}): {(b - a) / 20:.0f} % of one vCPU (qemu TCG, not panel speed)")
    subprocess.run(["amixer", "-q", "-c", "TSW1060", "sset", "Media", "80%"])

    # --- start a conversation ------------------------------------------------
    if MODE == "wake":
        log("playing the okay_nabu sample into the loopback card")
        subprocess.run(["aplay", "-q", "-D", "speaker", f"{T}/okay_nabu/1.wav"])
        timeout = 60
    else:
        r = subprocess.run(["tsx-voice", "ptt"], capture_output=True, text=True)
        check(f"tsx-voice ptt exit 0 ({r.stderr.strip()})", r.returncode == 0)
        timeout = 30
    try:
        await asyncio.wait_for(started.wait(), timeout)
    except asyncio.TimeoutError:
        pass
    check(f"{MODE}: satellite requested a pipeline run ({time.monotonic() - t0:.1f} s after connect)", started.is_set())
    if not started.is_set():
        return
    if MODE == "wake":
        check(f"wake word phrase is 'Okay Nabu' ({start_info.get('phrase')!r})", (start_info.get("phrase") or "").lower() == "okay nabu")
    else:
        check("push-to-talk run has no wake word phrase", not start_info.get("phrase"))
    await asyncio.sleep(1.5)
    check(f"Media ducked to 20 while listening ({vol('Media')})", vol("Media") == 20)
    log(f"Master while listening: {vol('Master')}")

    # --- microphone: a 440 Hz tone played into the loopback must arrive -----
    collecting[0] = True
    p = subprocess.Popen(["aplay", "-q", "-D", "speaker", f"{T}/tone5s-440-m30dB.wav"])
    await asyncio.sleep(3.0)
    collecting[0] = False
    p.wait()
    lvl, secs, trace = tone_profile(bytes(audio), 16000, 440)
    log(f"mic stream: {len(audio)} bytes, 440 Hz max {lvl:.1f} dBFS, present {secs:.2f} s; per 0.25 s: {trace}")
    check(f"mic audio streamed at 16 kHz ({len(audio)} bytes in 3 s)", len(audio) >= 16000 * 2 * 2)
    check(f"mic stream carries the -30 dBFS 440 Hz tone ({lvl:.1f} dBFS)", abs(lvl - (-30.0)) <= 2.0)

    # --- the HA pipeline events, TTS reply ------------------------------------
    rec = subprocess.Popen(["arecord", "-q", "-D", "mic", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", "-d", "7"],
                           stdout=subprocess.PIPE)
    url = f"http://127.0.0.1:{HTTP_PORT}/tts.wav"
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_RUN_START, {"url": url})
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_STT_START, None)
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_STT_VAD_END, None)
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_STT_END, {"text": "turn on the kitchen light"})
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_INTENT_START, None)
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_INTENT_END, {"conversation_id": "x", "continue_conversation": "0"})
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_TTS_START, {"text": "Turned on the light"})
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_TTS_END, {"url": url})
    c.send_voice_assistant_event(E.VOICE_ASSISTANT_RUN_END, None)
    try:
        await asyncio.wait_for(finished.wait(), 30)
    except asyncio.TimeoutError:
        pass
    check("TTS reply played and acknowledged (VoiceAssistantAnnounceFinished)", finished.is_set())
    out, _ = await asyncio.to_thread(rec.communicate)
    lvl, secs, trace = tone_profile(out, 16000, 660)
    log(f"loopback during TTS: 660 Hz max {lvl:.1f} dBFS, present {secs:.2f} s of 2.0; per 0.25 s: {trace}")
    check(f"TTS audio reached the speaker PCM (660 Hz at {lvl:.1f} dBFS, sent at -20)", abs(lvl - (-20.0)) <= 3.0)
    await asyncio.sleep(1.5)
    check(f"Media restored to 80 after the reply ({vol('Media')})", vol("Media") == 80)

    # --- announcement (assist_satellite.announce) -----------------------------
    rec = subprocess.Popen(["arecord", "-q", "-D", "mic", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", "-d", "6"],
                           stdout=subprocess.PIPE)
    try:
        res = await c.send_voice_assistant_announcement_await_response(
            f"http://127.0.0.1:{HTTP_PORT}/announce.wav", 30, text="announcement")
        log("announce result:", res)
        ok = True
    except Exception as err:  # noqa: BLE001
        log("announce error:", repr(err))
        ok = False
    check("announcement played and acknowledged", ok)
    out, _ = await asyncio.to_thread(rec.communicate)
    lvl, secs, trace = tone_profile(out, 16000, 550)
    log(f"loopback during announcement: 550 Hz max {lvl:.1f} dBFS, present {secs:.2f} s of 1.5; per 0.25 s: {trace}")
    check(f"announcement audio reached the speaker PCM (550 Hz at {lvl:.1f} dBFS)", abs(lvl - (-20.0)) <= 3.0)
    await c.disconnect()


try:
    asyncio.run(main())
except Exception as e:  # noqa: BLE001
    log("error:", repr(e))
    fails += 1
print(f"fake_ha: {fails} failed", flush=True)
sys.exit(fails)
