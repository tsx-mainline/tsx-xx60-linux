#!/bin/sh
# Install linux-voice-assistant (OHF-Voice, Home Assistant Assist satellite over
# the ESPHome native API) into DESTROOT/opt/lva and the launcher
# DESTROOT/usr/local/bin/linux-voice-assistant. Runs in the armv7 Alpine
# build container (mkrootfs.sh
# qemu test); the target needs the Alpine packages listed under "voice" in
# packages.txt (python3, py3-numpy, py3-protobuf, py3-cryptography,
# py3-tzlocal, py3-aiohappyeyeballs, py3-zeroconf, py3-mpv + mpv-libs,
# alsa-utils).
#
# Pinned sources (sha256 below): linux-voice-assistant v1.1.15 (GitHub tag),
# aioesphomeapi 45.3.1 (the version LVA pins; musllinux armv7 cp314 wheel),
# netifaces2 0.0.22 (musllinux armv7 abi3 wheel), getmac 0.9.5, websockets 12.0
# (LVA uses the legacy websockets.server API; Alpine has 16), noiseprotocol
# 0.3.1, chacha20poly1305-reuseable 0.13.2, async-interrupt 1.2.2,
# pymicro-features 2.0.2 (sdist, C++ extension compiled here),
# pymicro-wakeword 2.5.0 and pyopen-wakeword 1.1.0 (sdists; their bundled
# x86-64 libtensorflowlite_c.so is replaced by voice/tflite/, TensorFlow Lite
# C 2.17.1 built for Alpine armv7 by rootfs/voice/build-tflite.sh).
# Not installed: soundcard (PulseAudio only; voice/shim/soundcard is an ALSA
# stand-in on arecord), webrtc-noise-gain (ZL38051 does AEC/NR; LVA imports
# it only with --mic-auto-gain/--mic-noise-suppression), types-protobuf.
# aioesphomeapi asks for cryptography>=48 and zeroconf>=0.149.16; Alpine has
# 47.0 and 0.147: LVA only uses the plaintext frame helper, the protobuf
# messages and AsyncZeroconf (checked by the voice qemu test).
set -eu
DEST=${1:?usage: install-lva.sh DESTROOT}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${LVA_CACHE:-/build/lva}
LVA=1.1.15
PY=3.14
mkdir -p "$W"
apk add -q --no-cache python3 python3-dev py3-pip py3-setuptools py3-numpy build-base curl >/dev/null
v=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
[ "$v" = "$PY" ] || { echo "install-lva.sh: build python $v, wheels are pinned for $PY"; exit 1; }
if [ -x "$DEST/usr/bin/python3" ]; then
	t=$(readlink "$DEST/usr/bin/python3" 2>/dev/null || true)
	case "$t" in python$PY|*/python$PY|"") ;; *) echo "install-lva.sh: target python3 -> $t, not $PY"; exit 1;; esac
fi
PYPI=https://files.pythonhosted.org/packages
fetch() {  # url file sha256
	[ -s "$W/$2" ] || curl -fsSL -o "$W/$2" "$1"
	echo "$3  $W/$2" | sha256sum -c - >/dev/null || { echo "sha256 mismatch: $2"; exit 1; }
}
fetch https://github.com/OHF-Voice/linux-voice-assistant/archive/refs/tags/v$LVA.tar.gz \
	linux-voice-assistant-$LVA.tar.gz 077696e60b57ae3a98aca3d49d1b9f9971ffd36d62f5c23b8603ccc4c9fcdbd8
fetch $PYPI/0b/16/9d55765807a7e9c318e4636233c0d8b84768df366b5469a9727349109d80/aioesphomeapi-45.3.1-cp314-cp314-musllinux_1_2_armv7l.whl \
	aioesphomeapi-45.3.1-cp314-cp314-musllinux_1_2_armv7l.whl 95d70a740ab15be4fed5c850d8161c9ee37f641184b30b8a39d64ddefdae81d8
fetch $PYPI/52/7a/63c6607f5b12c2367d8bc37025bde067ec8eecad9b97c8d8c39eadd1411b/netifaces2-0.0.22-cp37-abi3-musllinux_1_1_armv7l.whl \
	netifaces2-0.0.22-cp37-abi3-musllinux_1_1_armv7l.whl 03151c24171e6da9079e5abcd303f3e0d8ac275a8fe4e178f82fdf1590f989e4
fetch $PYPI/18/85/4cdbc925381422397bd2b3280680e130091173f2c8dfafb9216eaaa91b00/getmac-0.9.5-py2.py3-none-any.whl \
	getmac-0.9.5-py2.py3-none-any.whl 22b8a3e15bc0c6bfa94651a3f7f6cd91b59432e1d8199411d4fe12804423e0aa
fetch $PYPI/79/4d/9cc401e7b07e80532ebc8c8e993f42541534da9e9249c59ee0139dcb0352/websockets-12.0-py3-none-any.whl \
	websockets-12.0-py3-none-any.whl dc284bbc8d7c78a6c69e0c7325ab46ee5e40bb4d50e494d8131a07ef47500e9e
fetch $PYPI/9d/e1/76e4694201d67b93a6f1644b2588b4a3d965419fe189416e3496cf415db5/noiseprotocol-0.3.1-py3-none-any.whl \
	noiseprotocol-0.3.1-py3-none-any.whl 2e1a603a38439636cf0ffd8b3e8b12cee27d368a28b41be7dbe568b2abb23111
fetch $PYPI/fa/30/a4e44159996e832512f93ec6db89756ed72fe454ce3de1978e3a39c10bcd/chacha20poly1305_reuseable-0.13.2-py3-none-any.whl \
	chacha20poly1305_reuseable-0.13.2-py3-none-any.whl c7dba7c3604a9fa51bcfef9e4bfdaa3bfaadd88b6c5436a27be1c7e9c4081048
fetch $PYPI/5a/77/060b972fa7819fa9eea9a70acf8c7c0c58341a1e300ee5ccb063e757a4a7/async_interrupt-1.2.2-py3-none-any.whl \
	async_interrupt-1.2.2-py3-none-any.whl 0a8deb884acfb5fe55188a693ae8a4381bbbd2cb6e670dac83869489513eec2c
fetch $PYPI/39/46/328092b4df890385594cf3d3e6015da72d77f63c58d3057276ac2353e891/pymicro_features-2.0.2.tar.gz \
	pymicro_features-2.0.2.tar.gz 0d0bed7843ec78b6ced82d1a2dcddeb4fe5df61b3af80a281d0868c8e279c727
fetch $PYPI/3b/93/9e8a000f8f8bda01ec53534bdf07c3413ffd659352a0117ac106f9beff7e/pymicro_wakeword-2.5.0.tar.gz \
	pymicro_wakeword-2.5.0.tar.gz 2355c1cb3fbfe4a59f4eccd6f17bd3eca260f7c6fb701fe3c44ccc98d49dd19e
fetch $PYPI/52/3e/37c8601f87173acfed77a3133c69eb350d2563f41174d70129ff51e6b297/pyopen_wakeword-1.1.0.tar.gz \
	pyopen_wakeword-1.1.0.tar.gz 080c0bda64d9aa4dd254413ba6fa417bd090c566c0610ebbb571d81f27851602
# TensorFlow Lite C for Alpine armv7 (rootfs/voice/build-tflite.sh)
(cd "$HERE/tflite" && sha256sum -c SHA256SUMS >/dev/null) || { echo "voice/tflite: checksum mismatch or missing"; exit 1; }

O=$DEST/opt/lva; L=$O/lib; A=$O/app
rm -rf "$O" && mkdir -p "$L" "$A"
pip install -q --no-deps --no-compile --no-build-isolation --disable-pip-version-check \
	--root-user-action=ignore --target "$L" \
	"$W/aioesphomeapi-45.3.1-cp314-cp314-musllinux_1_2_armv7l.whl" \
	"$W/netifaces2-0.0.22-cp37-abi3-musllinux_1_1_armv7l.whl" \
	"$W/getmac-0.9.5-py2.py3-none-any.whl" "$W/websockets-12.0-py3-none-any.whl" \
	"$W/noiseprotocol-0.3.1-py3-none-any.whl" "$W/chacha20poly1305_reuseable-0.13.2-py3-none-any.whl" \
	"$W/async_interrupt-1.2.2-py3-none-any.whl" \
	"$W/pymicro_features-2.0.2.tar.gz" "$W/pymicro_wakeword-2.5.0.tar.gz" "$W/pyopen_wakeword-1.1.0.tar.gz"
# the sdists carry an x86-64 libtensorflowlite_c.so: replace it (one copy, one link)
for m in pymicro_wakeword pyopen_wakeword; do rm -rf "$L/$m/lib"; mkdir -p "$L/$m/lib"; done
install -m 755 "$HERE/tflite/libtensorflowlite_c.so" "$L/pymicro_wakeword/lib/libtensorflowlite_c.so"
ln -s ../../pymicro_wakeword/lib/libtensorflowlite_c.so "$L/pyopen_wakeword/lib/libtensorflowlite_c.so"
find "$L" -name '*.so' -newer "$W/pymicro_features-2.0.2.tar.gz" -path '*pymicro_features*' -exec strip {} + 2>/dev/null || true
rm -rf "$L/bin" "$L"/*.dist-info/RECORD
# the application: LVA looks for wakewords/, sounds/, version.txt next to its package
rm -rf "$W/src" && mkdir -p "$W/src" && tar -C "$W/src" -xzf "$W/linux-voice-assistant-$LVA.tar.gz"
S=$W/src/linux-voice-assistant-$LVA
cp -r "$S/linux_voice_assistant" "$S/wakewords" "$S/sounds" "$A/"
echo "$LVA" > "$A/version.txt"
cp "$S/LICENSE.md" "$A/"
# TSX glue: ALSA soundcard stand-in, FIFO push-to-talk, hooks
cp -r "$HERE/shim" "$O/shim"
find "$O" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
cat > "$O/VERSION" <<V
linux-voice-assistant $LVA; aioesphomeapi 45.3.1, netifaces2 0.0.22, getmac 0.9.5, websockets 12.0,
noiseprotocol 0.3.1, chacha20poly1305-reuseable 0.13.2, async-interrupt 1.2.2, pymicro-features 2.0.2,
pymicro-wakeword 2.5.0, pyopen-wakeword 1.1.0; $(head -1 "$HERE/tflite/BUILDINFO"); (install-lva.sh)
V
mkdir -p "$DEST/usr/local/bin"
cat > "$DEST/usr/local/bin/linux-voice-assistant" <<'EOT'
#!/bin/sh
# linux-voice-assistant with the TSX glue (see /opt/lva/shim/tsx_lva/__init__.py)
PYTHONPATH=/opt/lva/shim:/opt/lva/app:/opt/lva/lib${PYTHONPATH:+:$PYTHONPATH} exec python3 -m tsx_lva "$@"
EOT
chmod 755 "$DEST/usr/local/bin/linux-voice-assistant"
echo "installed $(head -1 "$O/VERSION" | cut -d';' -f1) in $O ($(du -sh "$O" | cut -f1))"
