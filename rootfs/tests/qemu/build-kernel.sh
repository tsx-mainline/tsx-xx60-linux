#!/bin/bash
# Build the audio-loopback host-test virt kernel, locally in docker.
# Output: build-virt/arch/arm/boot/zImage
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd); TOP=$(cd "$REPO/.." && pwd)
LINUX=${LINUX_DIR:-$TOP/linux}
CCACHE_DIR_HOST=${CCACHE_DIR:-$HOME/.cache/tsx-ccache}
B=$HERE/build-virt; mkdir -p "$B" "$CCACHE_DIR_HOST"
docker image inspect tsx-mainline >/dev/null 2>&1 || docker build -q -t tsx-mainline -f "$REPO/ci/Dockerfile.mainline" "$REPO/ci"
docker image inspect tsx-mainline-ccache >/dev/null 2>&1 || docker build -q -t tsx-mainline-ccache -f "$REPO/ci/Dockerfile.ccache" "$REPO/ci"
docker run --rm -u "$(id -u):$(id -g)" -v "$TOP:$TOP" -v "$CCACHE_DIR_HOST:/ccache" -e CCACHE_BASEDIR="$TOP" -w "$LINUX" tsx-mainline-ccache bash -c "
  set -e; export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
  M='make O=$B CC=\"ccache arm-linux-gnueabihf-gcc\"'
  eval \$M multi_v7_defconfig >/dev/null
  scripts/kconfig/merge_config.sh -m -O $B $B/.config $REPO/rootfs/config/qemu-virt.config $HERE/virt-audio.config >/dev/null
  eval \$M olddefconfig >/dev/null
  for l in \$(grep -hE '^CONFIG_[A-Z0-9_]+=y' $REPO/rootfs/config/qemu-virt.config $HERE/virt-audio.config); do grep -qx \"\$l\" $B/.config || echo \"WARN: \$l not set\"; done
  eval \$M -j\$(nproc) zImage
"
ls -l "$B/arch/arm/boot/zImage"
