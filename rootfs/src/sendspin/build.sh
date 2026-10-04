#!/bin/bash
# Build sendspin-cli (Sendspin/sendspin-cpp-cli, C++20) for Alpine 3.24 armv7
# (musl) in an armv7 container (local by default). A host of another
# architecture runs the container under qemu-user. The upstream armv7 release
# binaries are glibc (Debian trixie) and do not run on Alpine.
#   rootfs/src/sendspin/build.sh             -> rootfs/src/sendspin/out/sendspin-cli
# Deps (Alpine): build-base cmake git linux-headers alsa-lib-dev avahi-compat-libdns_sd avahi-dev
# Runtime on the panel: alsa-lib, avahi, avahi-compat-libdns_sd, dbus (avahi-daemon).
# CMake FetchContent fetches everything else (ArduinoJson, micro-flac,
# micro-opus, IXWebSocket) at pinned tags and links it statically.
#
# BUILD_HOST (optional, no default): run the build over ssh on that
# host instead of here (for example a faster machine). If unset, build locally.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${SENDSPIN_CLI_TAG:-v0.3.0}
if [ -n "${BUILD_HOST:-}" ] && [ -z "${ON_HOST:-}" ]; then
	ssh -o BatchMode=yes "$BUILD_HOST" "mkdir -p '$HERE'"
	rsync -a "$HERE/build.sh" "$BUILD_HOST:$HERE/"
	ssh -o BatchMode=yes "$BUILD_HOST" "ON_HOST=1 SENDSPIN_CLI_TAG=$TAG bash $HERE/build.sh"
	mkdir -p "$HERE/out"; rsync -a "$BUILD_HOST:$HERE/out/" "$HERE/out/"
	ls -l "$HERE/out"; exit 0
fi
mkdir -p "$HERE/out" "$HERE/cache"
# On a native arm64 host, uname -m of an armv7 container says aarch64 (the
# kernel is 64-bit), and CMake would pick the 64-bit code. linux32 makes it say
# armv8l, like a 32-bit ARM machine. Under qemu-user it says armv7l already.
A32=; if [ "$(uname -m)" = aarch64 ]; then A32=linux32; fi
docker run --rm --platform linux/arm/v7 -v "$HERE:/w" -w /w alpine:3.24 $A32 sh -euc "
	apk add --no-cache build-base cmake samurai git linux-headers alsa-lib-dev avahi-compat-libdns_sd avahi-dev >/dev/null
	[ -d cache/src/.git ] || git clone -q https://github.com/Sendspin/sendspin-cpp-cli cache/src
	cd cache/src && git fetch -q --tags && git checkout -q $TAG && cd /w
	cmake -S cache/src -B cache/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_FLAGS='-mcpu=cortex-a9 -mfpu=neon' -DCMAKE_CXX_FLAGS='-mcpu=cortex-a9 -mfpu=neon' \
		-DSENDSPIN_CLI_WITH_PORTAUDIO=OFF -DSENDSPIN_CLI_WITH_PULSE=OFF -DSENDSPIN_CLI_WITH_PIPEWIRE=OFF
	cmake --build cache/build -j\$(nproc)
	strip -o out/sendspin-cli cache/build/sendspin-cli
	./out/sendspin-cli --version || true
	./out/sendspin-cli --help | head -40 > out/help.txt || true
	scanelf -n out/sendspin-cli 2>/dev/null || true
	chown -R $(id -u):$(id -g) out cache
"
