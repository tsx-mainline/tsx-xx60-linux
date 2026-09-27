#!/bin/sh
# Feasibility probe (run in an armv7 alpine:3.24 container on the build host):
# can the glibc armv7 libtensorflowlite_c.so from the pymicro-wakeword 2.5.0
# wheel run on musl through gcompat? Also builds pymicro-features from sdist.
set -eu
C=/p17/cache
apk add -q --no-cache python3 py3-pip py3-numpy build-base python3-dev py3-setuptools gcompat libstdc++ >/dev/null
pip install -q --break-system-packages --no-deps --no-build-isolation $C/pymicro_features-2.0.2.tar.gz 2>&1 | tail -2 || true
python3 -c 'import pymicro_features; print("pymicro_features ok")'
mkdir -p /tmp/w && cd /tmp/w && python3 -m zipfile -e $C/pymicro_wakeword-2.5.0-py3-none-manylinux_2_35_armv7l.whl . && export PYTHONPATH=/tmp/w
L=$(python3 -c 'import pymicro_wakeword,os;print(os.path.dirname(pymicro_wakeword.__file__))')/lib/libtensorflowlite_c.so
ls -l /lib/ld-linux-armhf.so.3 2>&1 || true
python3 - "$L" <<'PY'
import ctypes, os, sys
try:
    lib = ctypes.CDLL(sys.argv[1], mode=os.RTLD_GLOBAL); print("dlopen ok", lib.TfLiteVersion.restype)
    lib.TfLiteVersion.restype = ctypes.c_char_p; print("version", lib.TfLiteVersion())
except Exception as e:
    print("dlopen FAILED", e)
PY
cd $C/pmw-git/tests
for m in okay_nabu hey_jarvis; do for n in 1 2 3; do python3 -m pymicro_wakeword --model $m $m/$n.wav || true; done; done
