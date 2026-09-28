#!/bin/sh
# Voice-satellite userland tests in the qemu guest (run.sh): linux-voice-assistant with
# the TSX glue on the ALSA loopback card (id TSW1060, playback 0 -> capture 1),
# driven by fake_ha.py over the ESPHome native API.
T=/test
export TSX_AUDIO_CONF=/tmp/audio.conf TSX_RUN_DIR=/tmp/run TSX_VOICE_RUN=/tmp/voice TSX_VOICE_PTT=/tmp/voice/ptt
export TSX_VOICE_CONF=/tmp/voice.conf TEST_DIR=$T
mkdir -p /tmp/run /tmp/voice /tmp/lva
sed 's|^STATE=.*|STATE=/tmp/asound.state|' /etc/tsx/audio.conf > /tmp/audio.conf
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
vol() { amixer -c TSW1060 sget "$1" 2>/dev/null | sed -n 's/.*\[\([0-9]\{1,3\}\)%\].*/\1/p' | head -1; }
peak() { tsx-peak "$1" 2>/dev/null | awk '/^total/{for(i=1;i<=NF;i++) if($i=="ch0"){print $(i+2); exit}}'; }
loopcheck() {  # $1 = label: -30 dBFS 48 kHz tone via speaker -> mic (16 kHz mono)
	arecord -q -D mic -f S16_LE -r 16000 -c 1 -d 3 /tmp/lc.wav & r=$!
	sleep 0.5; aplay -q -D speaker $T/tone5s-440-m30dB.wav & a=$!; wait $r; kill $a 2>/dev/null; wait $a 2>/dev/null
	echo "loopcheck $1: peak $(peak /tmp/lc.wav) dBFS (expect -30); Master $(vol Master) Media $(vol Media)"
	amixer -c TSW1060 contents | grep -A2 "name=" | grep -E "name=|values=" | paste - - | sed 's/  */ /g'
}
cpu_ticks() { awk '{print $14+$15}' /proc/$1/stat 2>/dev/null; }

echo "--- network"
ip link set eth0 up && udhcpc -i eth0 -n -q -t 5 >/dev/null 2>&1
ip -4 addr show eth0 | grep inet; ip route | head -2
check "guest network up (default route)" sh -c 'ip route | grep -q default'
IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1); echo "guest IP $IP"
tsx-audio init >/dev/null
check "tsx-audio init: Master 100 ($(vol Master)), Media 100 ($(vol Media))" test "$(vol Master)/$(vol Media)" = 100/100

python3 - <<'PY'
import math, struct, wave
def tone(path, rate, secs, f, db):
    a = 32767 * 10 ** (db / 20)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(a * math.sin(2 * math.pi * f * i / rate))) for i in range(int(rate * secs))))
tone("/test/tone5s-440-m30dB.wav", 48000, 5, 440, -30)
PY

echo "--- installed"
cat /opt/lva/VERSION
cat /opt/lva/../lva/lib/pymicro_wakeword/lib/../../../VERSION >/dev/null 2>&1
P="env PYTHONPATH=/opt/lva/shim:/opt/lva/app:/opt/lva/lib python3"
check "all LVA modules import (aioesphomeapi, zeroconf, mpv, numpy, netifaces2, websockets 12)" \
	$P -c 'import linux_voice_assistant.__main__, linux_voice_assistant.satellite, linux_voice_assistant.peripheral_api, mpv, netifaces, websockets; assert websockets.__version__.startswith("12"), websockets.__version__; print("import ok, aioesphomeapi", __import__("importlib.metadata").metadata.version("aioesphomeapi"))'

echo "--- TensorFlow Lite C (musl armv7 build) + microWakeWord on the upstream test samples"
pos=0; neg=0
for n in 1 2 3; do
	$P -m pymicro_wakeword --model okay_nabu $T/okay_nabu/$n.wav 2>&1 | grep -q " detected$" && pos=$((pos + 1))
	for o in hey_jarvis alexa; do
		$P -m pymicro_wakeword --model okay_nabu $T/$o/$n.wav 2>&1 | grep -q " detected$" && neg=$((neg + 1))
	done
done
check "okay_nabu detected in 3/3 positive samples ($pos)" test "$pos" = 3
check "okay_nabu not detected in 6 negative samples ($neg false)" test "$neg" = 0
$P - <<'PY'
import time, wave
from pymicro_wakeword import MicroWakeWord, MicroWakeWordFeatures, Model
m = MicroWakeWord.from_builtin(Model.OKAY_NABU); f = MicroWakeWordFeatures()
with wave.open("/test/okay_nabu/1.wav") as w: a = w.readframes(w.getnframes())
t = time.process_time(); n = 0
for x in f.process_streaming(a):
    m.process_streaming(x); n += 1
dt = time.process_time() - t
print(f"microWakeWord: {len(a)/32000:.2f} s audio, {n} feature windows, {dt:.2f} s CPU in qemu TCG (not panel speed)")
PY
check "openWakeWord features load (pyopen_wakeword, same TFLite lib)" $P -c 'from pyopen_wakeword import OpenWakeWordFeatures; OpenWakeWordFeatures.from_builtin(); print("oww ok")'

echo "--- soundcard shim (arecord on the mic PCM)"
check "shim: 16 kHz mono float blocks with the loopback tone" $P - <<'PY'
import subprocess, time, numpy as np, soundcard as sc
m = sc.default_microphone(); print("default microphone:", m, [x.name for x in sc.all_microphones()][:6])
with m.recorder(samplerate=16000, channels=1, blocksize=1024) as r:
    p = subprocess.Popen(["aplay", "-q", "-D", "speaker", "/test/tone5s-440-m30dB.wav"])
    time.sleep(0.5); blocks = [r.record(1024) for _ in range(40)]; p.kill()
a = np.concatenate(blocks)[:, 0]
pk = 20 * np.log10(np.abs(a[8000:]).max() + 1e-9)
print("shape", blocks[0].shape, blocks[0].dtype, "peak %.1f dBFS" % pk)
assert blocks[0].shape == (1024, 1) and blocks[0].dtype == np.float32 and abs(pk + 30) < 2
PY

echo "--- tsx-voice-run command line"
sed -e 's|^STATE_DIR=.*|STATE_DIR=/tmp/lva|' -e 's|^WAKE=.*|WAKE=ptt|' /etc/tsx/voice.conf > /tmp/voice.conf
CMD=$(tsx-voice-run --print); echo "$CMD"
check "tsx-voice-run: ptt mode, mic PCM, ALSA outputs, state dir" sh -c 'echo "$0" | grep -q "TSX_VOICE_WAKE=ptt" && echo "$0" | grep -q -- "--audio-output-device alsa/speaker" && echo "$0" | grep -q -- "--music-output-device alsa/media" && echo "$0" | grep -q -- "--preferences-file /tmp/lva/preferences.json"' "$CMD"
check "init script start_pre sources (sh -n)" sh -n /etc/init.d/tsx-voice

start_lva() {  # $1 = log
	[ -p /tmp/voice/ptt ] || mkfifo /tmp/voice/ptt
	tcpdump -i eth0 -n -l -A -s 0 udp port 5353 > /tmp/mdns-$2.txt 2>/dev/null & TCPD=$!
	tsx-voice-run --debug > "$1" 2>&1 & LVA=$!
	i=0; while [ $i -lt 240 ]; do grep -q "Server started" "$1" && break; kill -0 $LVA 2>/dev/null || break; sleep 1; i=$((i + 1)); done
	echo "LVA pid $LVA up after ${i} s"
}
stop_lva() { kill $LVA 2>/dev/null; sleep 2; kill -9 $LVA 2>/dev/null; kill $TCPD 2>/dev/null; pkill arecord; pkill aplay; }

loopcheck "before LVA"
echo "=== run 1: WAKE=ptt"
start_lva /tmp/lva-ptt.log ptt
loopcheck "LVA running, HA not connected"
check "linux-voice-assistant started (ESPHome server on 6053)" grep -q "Server started" /tmp/lva-ptt.log
check "listens on tcp 6053 and peripheral API on 127.0.0.1:6055" sh -c 'netstat -ltn | grep -q ":6053 " && netstat -ltn | grep -q "127.0.0.1:6055 "'
check "push-to-talk only: wake word inference disabled (log)" grep -q "push-to-talk only" /tmp/lva-ptt.log
sleep 3
check "mDNS: _esphomelib._tcp announcement sent on eth0" grep -q "_esphomelib" /tmp/mdns-ptt.txt
t1=$(cpu_ticks $LVA); sleep 20; t2=$(cpu_ticks $LVA)
echo "idle CPU (ptt, qemu TCG, not panel speed): $(( (t2 - t1) * 100 / 20 / 100 )) % of one vCPU ($((t2 - t1)) ticks in 20 s)"
LVA_HOST=$IP LVA_PID=$LVA PYTHONPATH=/opt/lva/lib python3 $T/fake_ha.py ptt; rc=$?
check "fake HA over the ESPHome API, push-to-talk conversation (rc $rc)" test "$rc" = 0
loopcheck "after the ptt conversation"
check "hook state back to idle" grep -q 'state=idle' /tmp/voice/voice.state
check "FIFO command dispatched (log)" grep -q "FIFO command: start_listening" /tmp/lva-ptt.log
echo "--- tsx-voice ptt without HA connection (satellite not connected): must not crash"
tsx-voice ptt; sleep 2
check "LVA still running after ptt without HA" kill -0 $LVA
check "ptt without HA logged" grep -q "push-to-talk ignored: Home Assistant not connected" /tmp/lva-ptt.log
stop_lva
echo "--- LVA log (ptt, tail)"; grep -v "DEBUG:aioesphomeapi\|Peripheral event" /tmp/lva-ptt.log | tail -n 30

echo "=== run 2: WAKE=local (microWakeWord okay_nabu)"
sed -i 's|^WAKE=.*|WAKE=local|' /tmp/voice.conf
start_lva /tmp/lva-local.log local
check "LVA started with local wake word" grep -q "Server started" /tmp/lva-local.log
t1=$(cpu_ticks $LVA); sleep 20; t2=$(cpu_ticks $LVA)
echo "idle CPU (local wake word, qemu TCG): $(( (t2 - t1) * 100 / 20 / 100 )) % of one vCPU ($((t2 - t1)) ticks in 20 s)"
LVA_HOST=$IP LVA_PID=$LVA PYTHONPATH=/opt/lva/lib python3 $T/fake_ha.py wake; rc=$?
check "fake HA over the ESPHome API, wake word conversation (rc $rc)" test "$rc" = 0
stop_lva
echo "--- LVA log (local, tail)"; grep -v "DEBUG:aioesphomeapi\|Peripheral event" /tmp/lva-local.log | tail -n 30

grep -h '^CHECK FAIL' /tmp/*.log 2>/dev/null
echo "--- summary: $fails failed"
exit $fails
