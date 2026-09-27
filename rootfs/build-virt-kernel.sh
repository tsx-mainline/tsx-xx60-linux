#!/bin/bash
# Builds a qemu "virt" test kernel (NOT for the panel) from the kernel fork worktree.
# Output: build-virt/arch/arm/boot/zImage. About 10-20 min with -j4.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
LINUXTOP=$(cd "$HERE/../.." && pwd)
LINUX=${LINUX_DIR:-$LINUXTOP/linux}
J=${J:-4}
[ -d "$HERE/linux" ] || git -C "$LINUX" worktree add "$HERE/linux" -b tsx-virt-test tsx-vid2-pll
REPO=$(cd "$HERE/.." && pwd)
docker image inspect tsx-mainline >/dev/null 2>&1 || docker build -q -t tsx-mainline -f "$REPO/ci/Dockerfile.mainline" "$REPO/ci"
docker run --rm -u "$(id -u):$(id -g)" -v "$TOP:$TOP" -w "$HERE/linux" tsx-mainline bash -c "
  set -e; B=$HERE/build-virt; export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
  make O=\$B multi_v7_defconfig >/dev/null
  scripts/kconfig/merge_config.sh -m -O \$B \$B/.config $HERE/config/qemu-virt.config >/dev/null
  make O=\$B olddefconfig >/dev/null
  for l in \$(grep -E '^CONFIG_' $HERE/config/qemu-virt.config); do grep -qx \"\$l\" \$B/.config || echo \"WARN: \$l not set\"; done
  make O=\$B -j$J zImage
"
ls -l "$HERE/build-virt/arch/arm/boot/zImage"
