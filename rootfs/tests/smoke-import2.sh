#!/bin/sh
set -u
ROOT=$1   # repo root (this script does $ROOT/rootfs/voice)
apk add -q --no-cache python3 py3-zeroconf py3-numpy py3-protobuf py3-cryptography py3-tzlocal py3-aiohappyeyeballs py3-mpv mpv-libs alsa-utils >/dev/null
T=/tmp/v; mkdir -p $T/voice; cp -r $ROOT/rootfs/voice/. $T/voice/
LVA_CACHE=/lvacache sh $T/voice/install-lva.sh / || exit 1
export PYTHONPATH=/opt/lva/shim:/opt/lva/app:/opt/lva/lib
step() { echo "--- $1"; shift; timeout 120 python3 -u -c "$*"; echo "rc $?"; }
step imports 'import importlib.metadata as md, linux_voice_assistant.__main__, linux_voice_assistant.satellite, linux_voice_assistant.peripheral_api, zeroconf, websockets, cryptography, google.protobuf as pb; print("aioesphomeapi", md.version("aioesphomeapi"), "zeroconf", zeroconf.__version__, "websockets", websockets.__version__, "cryptography", cryptography.__version__, "protobuf", pb.__version__)'
step netifaces 'import netifaces; print(netifaces.default_gateway()); print(netifaces.interfaces())'
step getmac 'from getmac import get_mac_address as g; print(g(interface="eth0"))'
step mpv 'import mpv; p=mpv.MPV(ao="null"); print("libmpv ok", [d["name"] for d in p.audio_device_list][:5]); p.terminate()'
step tflite 'from pymicro_wakeword import MicroWakeWord, Model; m=MicroWakeWord.from_builtin(Model.OKAY_NABU); print("tflite ok", m.wake_word)'
step patch 'import tsx_lva; tsx_lva._patch(); print("patch ok")'
du -sh /opt/lva /opt/lva/lib /opt/lva/app
