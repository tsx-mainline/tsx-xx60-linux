#!/bin/bash
# Build i2crd (ARM, static, nolibc) from i2crd-nolibc.c, in the same
# cross-toolchain image tools/build/kbuild.sh uses for the kernel
# (ci/Dockerfile.mainline: arm-linux-gnueabihf-gcc).
#
#   tools/regs/i2crd/build.sh          -> tools/regs/i2crd/i2crd
#
# Headers come from the kernel fork checkout (LINUX_DIR), generated fresh
# each build instead of a vendored copy: tools/include/nolibc for the nolibc
# runtime, and `make headers_install` for the UAPI headers i2crd-nolibc.c
# needs (linux/i2c.h, linux/i2c-dev.h).
#
# Env: LINUX_DIR (default: ../linux next to this repo, same convention as
# tools/build/kbuild.sh). Builds run on the build host: pass BUILD_HOST=<host>
# on the command line (never written into a repo file) to build there over
# ssh instead of here.
#
# To push the built binary onto a panel shell that has no scp (e.g. the
# rooted Android debug shell): `base64 <i2crd >i2crd.b64` here, paste that
# file's contents on the panel, then `base64 -d <i2crd.b64 >i2crd && chmod
# +x i2crd` there. Nothing base64-encoded is kept in the repo.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
TOP=$(cd "$REPO/.." && pwd)

if [ -n "${BUILD_HOST:-}" ] && [ -z "${ON_HOST:-}" ]; then
	rsync -a "$HERE/" "$BUILD_HOST:$HERE/" --exclude i2crd
	ssh -o BatchMode=yes "$BUILD_HOST" "ON_HOST=1 LINUX_DIR=${LINUX_DIR:-} bash $HERE/build.sh"
	rsync -a "$BUILD_HOST:$HERE/i2crd" "$HERE/i2crd"
	ls -l "$HERE/i2crd"
	exit 0
fi

LINUX_DIR=${LINUX_DIR:-$TOP/linux}
[ -d "$LINUX_DIR" ] || { echo "build.sh: LINUX_DIR $LINUX_DIR not found (kernel fork checkout; see tools/build/kbuild.sh)"; exit 1; }
NOLIBC=$LINUX_DIR/tools/include/nolibc
[ -f "$NOLIBC/nolibc.h" ] || { echo "build.sh: no $NOLIBC/nolibc.h (LINUX_DIR too old? need a kernel with tools/include/nolibc)"; exit 1; }

docker image inspect tsx-mainline >/dev/null 2>&1 || docker build -q -t tsx-mainline -f "$REPO/ci/Dockerfile.mainline" "$REPO/ci"

SYSROOT=$HERE/.sysroot-tmp
rm -rf "$SYSROOT"; mkdir -p "$SYSROOT"
trap 'rm -rf "$SYSROOT"' EXIT
UIDGID="$(id -u):$(id -g)"

run() { docker run --rm -u "$UIDGID" -v "$TOP:$TOP" -w "$LINUX_DIR" tsx-mainline bash -c "$*"; }

echo "== headers_install (ARCH=arm) from $LINUX_DIR"
run "make -s ARCH=arm headers_install INSTALL_HDR_PATH=$SYSROOT >/dev/null"
[ -f "$SYSROOT/include/linux/i2c.h" ] || { echo "build.sh: headers_install did not produce linux/i2c.h"; exit 1; }

echo "== compile"
docker run --rm -u "$UIDGID" -v "$TOP:$TOP" -w "$HERE" tsx-mainline bash -c "
	arm-linux-gnueabihf-gcc -Os -static -nostdlib -fno-stack-protector \
		-fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident \
		-include $NOLIBC/nolibc.h -I$NOLIBC -I$SYSROOT/include \
		-o $HERE/i2crd $HERE/i2crd-nolibc.c
	arm-linux-gnueabihf-strip -s $HERE/i2crd
	file $HERE/i2crd || true
"
echo "built $HERE/i2crd ($(du -h "$HERE/i2crd" | cut -f1))"
