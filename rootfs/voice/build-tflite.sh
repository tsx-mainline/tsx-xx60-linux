#!/bin/sh
# Build libtensorflowlite_c.so (TensorFlow Lite C API 2.17.1, the version that
# the pymicro-wakeword and pyopen-wakeword wheels ship) for Alpine armv7 (musl).
# PyPI has only a glibc armv7 build (Cortex-A7, neon-vfpv4). It does not load
# on musl, not even with gcompat (strtoll_l is missing). The Cortex-A9 has no
# vfpv4. Run this script on a host with docker:
#   rootfs/voice/build-tflite.sh
# The script starts an armv7 alpine:3.24 container and runs itself in it. An
# arm64 host runs the container natively. Another host needs qemu-user binfmt.
# Result: voice/tflite/libtensorflowlite_c.so, SHA256SUMS and BUILDINFO.
# install-lva.sh installs them and verifies the checksum. The compiler flags
# are the Alpine armv7 defaults (armv7-a, vfpv3-d16, hard float). The build
# does not assume NEON. musl has no strtoll_l, so the build sets
# FLATBUFFERS_LOCALE_INDEPENDENT=0 for flatbuffers.
#
# Env:
# JOBS (default: the number of CPUs) is the number of parallel compile jobs.
# TFLITE_CHECK=1 compares the result with the pin that is in SHA256SUMS now.
# It writes neither SHA256SUMS nor BUILDINFO, and it stops with exit status 1
# when the sums differ. CI uses it. Without it, the script writes the pin
# files, which is the way to pin a new build.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
P17=$(cd "$HERE/.." && pwd)
# Outside a container, run this script in an armv7 container. On a native
# arm64 host, uname -m of that container says aarch64 (the kernel is 64-bit),
# and CMake would pick the 64-bit code. linux32 makes it say armv8l. Under
# qemu-user it says armv7l already.
if ! { [ -f /etc/alpine-release ] && { [ -f /.dockerenv ] || [ -f /run/.containerenv ]; }; }; then
	A32=; if [ "$(uname -m)" = aarch64 ]; then A32=linux32; fi
	exec docker run --rm --platform linux/arm/v7 -e JOBS="${JOBS:-}" -e TFLITE_CHECK="${TFLITE_CHECK:-}" \
		-e UIDGID="$(id -u):$(id -g)" -v "$P17:$P17" "${IMAGE:-alpine:3.24}" $A32 sh "$P17/voice/build-tflite.sh"
fi
TF=2.17.1
TF_SHA256=2d3cfb48510f92f3a52fb05b820481c6f066a342a9f5296fe26d72c4ea757700
C=${TFLITE_CACHE:-$P17/cache}
B=${TFLITE_BUILD:-$P17/build-tflite}   # stays between runs (incremental build)
O=$HERE/tflite
# The container runs as root. Give the files back to the user of the host,
# also when the script stops with an error.
trap '[ -z "${UIDGID:-}" ] || chown -R "$UIDGID" "$O" "$C" "$B" 2>/dev/null || true' EXIT
apk add -q --no-cache build-base cmake samurai git curl python3 linux-headers patch >/dev/null
mkdir -p "$C" /build
[ -s "$C/tensorflow-$TF.tar.gz" ] || curl -fsSL -o "$C/tensorflow-$TF.tar.gz" https://github.com/tensorflow/tensorflow/archive/refs/tags/v$TF.tar.gz
echo "$TF_SHA256  $C/tensorflow-$TF.tar.gz" | sha256sum -c -
[ -d /build/tensorflow-$TF ] || tar -C /build -xzf "$C/tensorflow-$TF.tar.gz"
mkdir -p $B
# The sources of ruy, abseil and the other parts that CMake fetches are in $B.
# __FILE__ and the assert texts put their path into the library, so the library
# would depend on the folder of the build. This option maps $B to a fixed name.
# The library is then the same in every folder, and the pin can hold.
MAP="-ffile-prefix-map=$B=/build/tflite"
cmake -S /build/tensorflow-$TF/tensorflow/lite/c -B $B -G Ninja \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DTFLITE_ENABLE_XNNPACK=OFF -DTFLITE_ENABLE_GPU=OFF \
	-DTFLITE_ENABLE_NNAPI=OFF -DTFLITE_ENABLE_MMAP=ON \
	-DCMAKE_C_FLAGS="-O2 -fPIC $MAP" -DCMAKE_CXX_FLAGS="-O2 -fPIC -Wno-error -DFLATBUFFERS_LOCALE_INDEPENDENT=0 $MAP" >/build/cmake.log 2>&1 || { tail -40 /build/cmake.log; exit 1; }
ninja -C $B -j"${JOBS:-$(nproc)}" tensorflowlite_c
mkdir -p "$O"
install -m 755 $B/libtensorflowlite_c.so "$O/libtensorflowlite_c.so"
strip "$O/libtensorflowlite_c.so"
if [ -n "${TFLITE_CHECK:-}" ]; then
	want=$(cut -d' ' -f1 "$O/SHA256SUMS")
	got=$(sha256sum "$O/libtensorflowlite_c.so" | cut -d' ' -f1)
	if [ "$got" != "$want" ]; then
		echo "FAIL: libtensorflowlite_c.so does not match the pin in voice/tflite/SHA256SUMS"
		echo "  built:  $got"
		echo "  pinned: $want"
		echo "  toolchain: alpine $(cat /etc/alpine-release) $(uname -m), $(gcc --version | head -1)"
		exit 1
	fi
	echo "ok: libtensorflowlite_c.so matches the pin in voice/tflite/SHA256SUMS ($got)"
	readelf -d "$O/libtensorflowlite_c.so" | grep NEEDED
	exit 0
fi
{
	echo "TensorFlow Lite C $TF (tensorflow-$TF.tar.gz sha256 $TF_SHA256)"
	echo "built $(date -u +%FT%TZ) in alpine $(cat /etc/alpine-release) $(uname -m), $(gcc --version | head -1)"
	echo "cmake: Release, XNNPACK/GPU/NNAPI off, Alpine armv7 default CPU flags (no NEON), build folder mapped to /build/tflite"
} > "$O/BUILDINFO"
(cd "$O" && sha256sum libtensorflowlite_c.so > SHA256SUMS)
readelf -d "$O/libtensorflowlite_c.so" | grep NEEDED
cat "$O/BUILDINFO" "$O/SHA256SUMS"
