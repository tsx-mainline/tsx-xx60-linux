#!/bin/bash
# Top-level build entry point. Every build is local by default (docker on
# this machine). See tools/build/README.md for the opt-in remote build.
#
#   ./build.sh kernel [args]        tools/build/kbuild.sh: zImage + dtbs + boot image
#                                    (--flavor lts|stable, default lts)
#   ./build.sh rootfs [args]        rootfs/build-rootfs.sh: rootfs.ext4/.tar.gz + initramfs
#   ./build.sh virt-kernel [args]   rootfs/build-virt-kernel.sh: qemu -M virt test kernel
#   ./build.sh image [args]         rootfs/mkbootimg.sh: pack the installed-system boot image
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
kernel)      shift; exec "$HERE/tools/build/kbuild.sh" "$@";;
rootfs)      shift; exec "$HERE/rootfs/build-rootfs.sh" "$@";;
virt-kernel) shift; exec "$HERE/rootfs/build-virt-kernel.sh" "$@";;
image)       shift; exec "$HERE/rootfs/mkbootimg.sh" "$@";;
*) sed -n '2,9p' "$0"; exit 2;;
esac
