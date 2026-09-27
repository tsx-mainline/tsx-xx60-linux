#!/bin/bash
# Build regdump (ARM, static musl) from regdump.c in an Alpine armv7 container
# (qemu-user, same approach as rootfs/src/sendspin/build.sh). The static
# binary runs on the stock Android shell and on mainline.
#
#   tools/regs/build.sh          -> tools/regs/regdump
#
# BUILD_HOST (optional, no default): build on that host over ssh instead of
# here; pass it on the command line.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

if [ -n "${BUILD_HOST:-}" ] && [ -z "${ON_HOST:-}" ]; then
	ssh -o BatchMode=yes "$BUILD_HOST" "mkdir -p '$HERE'"
	rsync -a "$HERE/regdump.c" "$HERE/build.sh" "$BUILD_HOST:$HERE/"
	ssh -o BatchMode=yes "$BUILD_HOST" "ON_HOST=1 bash $HERE/build.sh"
	rsync -a "$BUILD_HOST:$HERE/regdump" "$HERE/regdump"
	ls -l "$HERE/regdump"
	exit 0
fi

docker run --rm --platform linux/arm/v7 -v "$HERE:/w" -w /w alpine:3.24 sh -euc "
	apk add --no-cache build-base >/dev/null
	gcc -O2 -static -o regdump regdump.c
	strip -s regdump
	chown $(id -u):$(id -g) regdump
"
file "$HERE/regdump" 2>/dev/null || true
echo "built $HERE/regdump ($(du -h "$HERE/regdump" | cut -f1))"
