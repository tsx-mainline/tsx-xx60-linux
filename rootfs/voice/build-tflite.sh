#!/bin/sh
# Build libtensorflowlite_c.so (TensorFlow Lite C API 2.17.1, the version the
# pymicro-wakeword / pyopen-wakeword wheels ship) for Alpine armv7 (musl).
# PyPI only has a glibc armv7 build (Cortex-A7, neon-vfpv4): it does not load
# on musl, not even with gcompat (strtoll_l missing), and vfpv4 is not on the
# Cortex-A9. Run INSIDE an armv7 alpine:3.24 container on the build host:
#   docker run --rm --platform linux/arm/v7 -v $P17:$P17 alpine:3.24 sh $P17/voice/build-tflite.sh
# Result: voice/tflite/libtensorflowlite_c.so + SHA256SUMS + BUILDINFO, which
# install-lva.sh installs (checksum verified). Compiler flags = Alpine armv7
# defaults (armv7-a, vfpv3-d16, hard float): no NEON assumed. musl has no
# strtoll_l: flatbuffers is built with FLATBUFFERS_LOCALE_INDEPENDENT=0.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
P17=$(cd "$HERE/.." && pwd)
TF=2.17.1
TF_SHA256=2d3cfb48510f92f3a52fb05b820481c6f066a342a9f5296fe26d72c4ea757700
C=${TFLITE_CACHE:-$P17/cache}
B=${TFLITE_BUILD:-$P17/build-tflite}   # kept between runs (incremental)
apk add -q --no-cache build-base cmake samurai git curl python3 linux-headers patch >/dev/null
mkdir -p "$C" /build
[ -s "$C/tensorflow-$TF.tar.gz" ] || curl -fsSL -o "$C/tensorflow-$TF.tar.gz" https://github.com/tensorflow/tensorflow/archive/refs/tags/v$TF.tar.gz
echo "$TF_SHA256  $C/tensorflow-$TF.tar.gz" | sha256sum -c -
[ -d /build/tensorflow-$TF ] || tar -C /build -xzf "$C/tensorflow-$TF.tar.gz"
mkdir -p $B
cmake -S /build/tensorflow-$TF/tensorflow/lite/c -B $B -G Ninja \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DTFLITE_ENABLE_XNNPACK=OFF -DTFLITE_ENABLE_GPU=OFF \
	-DTFLITE_ENABLE_NNAPI=OFF -DTFLITE_ENABLE_MMAP=ON \
	-DCMAKE_C_FLAGS="-O2 -fPIC" -DCMAKE_CXX_FLAGS="-O2 -fPIC -Wno-error -DFLATBUFFERS_LOCALE_INDEPENDENT=0" >/build/cmake.log 2>&1 || { tail -40 /build/cmake.log; exit 1; }
ninja -C $B -j"${JOBS:-20}" tensorflowlite_c
O=$HERE/tflite; mkdir -p "$O"
install -m 755 $B/libtensorflowlite_c.so "$O/libtensorflowlite_c.so"
strip "$O/libtensorflowlite_c.so"
{
	echo "TensorFlow Lite C $TF (tensorflow-$TF.tar.gz sha256 $TF_SHA256)"
	echo "built $(date -u +%FT%TZ) in alpine $(cat /etc/alpine-release) $(uname -m), $(gcc --version | head -1)"
	echo "cmake: Release, XNNPACK/GPU/NNAPI off, Alpine armv7 default CPU flags (no NEON)"
} > "$O/BUILDINFO"
(cd "$O" && sha256sum libtensorflowlite_c.so > SHA256SUMS)
readelf -d "$O/libtensorflowlite_c.so" | grep NEEDED
cat "$O/BUILDINFO" "$O/SHA256SUMS"
[ -n "${UIDGID:-}" ] && chown -R "$UIDGID" "$O"
