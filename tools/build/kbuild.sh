#!/bin/bash
# Build the mainline kernel for xx60 (Meson8m2) in the cross-toolchain
# docker image (ci/Dockerfile.mainline). Local by default: no build host,
# no network, other than the one-time image build and, if LINUX_DIR does not
# exist yet, cloning the kernel fork.
#
#   tools/build/kbuild.sh [-f lts|stable | --flavor lts|stable] [-w LINUX_DIR] [-o BUILD_DIR] [-d OUT_DIR] [-j N] <step>...
#   steps: config   : multi_v7_defconfig + arch/arm/configs/tsx-xx60.config + olddefconfig
#                      (also done automatically by "kernel" when BUILD_DIR/.config
#                      is missing or the fragment is newer)
#          kernel   : zImage dtbs modules
#          image    : copy zImage + board DTB to OUT_DIR, write kernel.release
#                     + kernel.commit, and pack OUT_DIR/test.img with
#                     kernel/mkimage.sh (adds an initrd if
#                     rootfs/out/initramfs-switchroot.cpio.gz has been built)
#          cmd "<make args>" : any make target in the build dir
#          stats    : ccache statistics (only with CCACHE=1)
#   (default steps: kernel image)
#
# Flavor: -f / --flavor / $FLAVOR selects which of the two kernel flavors to
# build -- lts (default; tracks kernel/KERNEL_REV.lts, branch tsx-xx60-6.18)
# or stable (kernel/KERNEL_REV.stable, branch tsx-xx60-7.2). Both branches use
# the same config fragment name, arch/arm/configs/tsx-xx60.config.
#
# Kernel source: LINUX_DIR (default: ../linux-<flavor>, a sibling checkout of
# this repo, e.g. ../linux-lts). If it does not exist, it is cloned from
# https://github.com/tsx-mainline/linux and checked out at the commit in
# kernel/KERNEL_REV.<flavor>. An EXISTING LINUX_DIR is used as-is and never
# modified (no fetch, no checkout) -- it is expected to already have the
# right commit checked out; a mismatch is only a warning.
#
# Env: LINUX_DIR, BUILD_DIR (default <LINUX_DIR>/../build-<flavor>), OUT_DIR
# (default <LINUX_DIR>/../out-<flavor>), J (default: all cores). CCACHE=1
# turns on ccache (ci/Dockerfile.ccache, cache dir CCACHE_DIR, default
# ~/.cache/tsx-ccache) -- optional, off by default so a first-time build
# needs nothing persistent.
#
# To build on another machine instead of here, see tools/build/remote-build.sh
# (opt-in, driven by BUILD_HOST).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TOP=$(cd "$REPO/.." && pwd)
FLAVOR=${FLAVOR:-lts}
# --flavor/--flavor=X alongside the short getopts below (getopts has no long-option support)
ARGS=()
while [ $# -gt 0 ]; do case "$1" in
	--flavor=*) FLAVOR=${1#--flavor=}; shift;;
	--flavor) FLAVOR=$2; shift 2;;
	*) ARGS+=("$1"); shift;; esac; done
set -- "${ARGS[@]}"
B= OUT= J=$(nproc) WDIR=
while getopts "f:w:o:d:j:" o; do case $o in
	f) FLAVOR=$OPTARG;; w) WDIR=$OPTARG;; o) B=$OPTARG;; d) OUT=$OPTARG;; j) J=$OPTARG;;
	*) sed -n '2,39p' "$0"; exit 1;; esac; done
shift $((OPTIND-1))
case $FLAVOR in lts|stable) ;; *) echo "kbuild: --flavor/-f must be lts or stable (got $FLAVOR)"; exit 1;; esac

REV_FILE=$REPO/kernel/KERNEL_REV.$FLAVOR
[ -f "$REV_FILE" ] || { echo "kbuild: no $REV_FILE"; exit 1; }
KERNEL_REV=$(grep -v '^#' "$REV_FILE" | tr -d ' \t\r\n')
LINUX_DIR=${WDIR:-${LINUX_DIR:-$TOP/linux-$FLAVOR}}
[ -n "$WDIR" ] && LINUX_DIR=$(cd "$WDIR" && pwd)

if [ ! -e "$LINUX_DIR" ]; then
	echo "kbuild: $LINUX_DIR does not exist, cloning tsx-mainline/linux ($FLAVOR) at $KERNEL_REV"
	git clone -q https://github.com/tsx-mainline/linux "$LINUX_DIR"
	git -C "$LINUX_DIR" checkout -q "$KERNEL_REV"
fi
HEAD=$(git -C "$LINUX_DIR" rev-parse HEAD 2>/dev/null || echo '?')
[ "$HEAD" = "$KERNEL_REV" ] || echo "kbuild: WARNING: $LINUX_DIR is at $HEAD, $REV_FILE wants $KERNEL_REV (not touching your checkout)"

P=$(dirname "$LINUX_DIR"); B=${BUILD_DIR:-${B:-$P/build-$FLAVOR}}; OUT=${OUT_DIR:-${OUT:-$P/out-$FLAVOR}}
mkdir -p "$B" "$OUT"
echo "kernel flavor: $FLAVOR ($REV_FILE)"

docker image inspect tsx-mainline >/dev/null 2>&1 || docker build -q -t tsx-mainline -f "$REPO/ci/Dockerfile.mainline" "$REPO/ci"
IMG=tsx-mainline
RUN_ENV=()
if [ "${CCACHE:-0}" = 1 ]; then
	CCACHE_DIR_HOST=${CCACHE_DIR:-$HOME/.cache/tsx-ccache}; mkdir -p "$CCACHE_DIR_HOST"
	docker build -q -t tsx-mainline-ccache -f "$REPO/ci/Dockerfile.ccache" "$REPO/ci" >/dev/null
	IMG=tsx-mainline-ccache
	RUN_ENV=(-v "$CCACHE_DIR_HOST:/ccache" -e "CCACHE_BASEDIR=$TOP")
	CC="ccache arm-linux-gnueabihf-gcc"
else
	CC="arm-linux-gnueabihf-gcc"
fi

FRAG=$LINUX_DIR/arch/arm/configs/tsx-xx60.config
[ -f "$FRAG" ] || { echo "no $FRAG (is $LINUX_DIR a tsx-xx60 kernel checkout?)"; exit 1; }
MK="make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- CC='$CC' O=$B KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=tsx-build"
DTB=$B/arch/arm/boot/dts/amlogic/meson8m2-crestron-tsw1060.dtb
# The kernel's version suffix (-NNNNN-g<sha>, CONFIG_LOCALVERSION_AUTO) comes
# from git inside the container. A worktree's .git file points into the main
# checkout's git dir, which may live outside $TOP: mount it too, or git fails
# silently and the release is a bare "7.2.8" that no longer names its commit.
GIT_MNT=()
GIT_COMMON=$(git -C "$LINUX_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || GIT_COMMON=
case "$GIT_COMMON" in ""|"$TOP"/*) ;; *) GIT_MNT=(-v "$GIT_COMMON:$GIT_COMMON");; esac
run() { docker run --rm -u "$(id -u):$(id -g)" -v "$TOP:$TOP" "${GIT_MNT[@]}" -e GIT_CONFIG_COUNT=1 \
	-e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' "${RUN_ENV[@]}" -w "$LINUX_DIR" "$IMG" bash -c "$*"; }
config() {
	run "set -e; $MK multi_v7_defconfig
	scripts/kconfig/merge_config.sh -m -O $B $B/.config $FRAG
	$MK olddefconfig
	for l in \$(grep -E '^CONFIG_[A-Z0-9_]+=[ym]' $FRAG); do grep -qx \"\$l\" $B/.config || echo \"WARN: \$l not set\"; done"
	cp "$FRAG" "$B/.tsx-frag.stamp"
}

echo "kernel source $LINUX_DIR ($(git -C "$LINUX_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) $(git -C "$LINUX_DIR" rev-parse --short=12 HEAD 2>/dev/null)$(git -C "$LINUX_DIR" diff --quiet HEAD -- 2>/dev/null || echo ' +local changes'))"
echo "build $B  out $OUT  -j$J  ccache=${CCACHE:-0}"
[ $# -gt 0 ] || set -- kernel image
while [ $# -gt 0 ]; do
	s=$1; shift; t0=$(date +%s)
	case $s in
	config) config;;
	kernel) if [ ! -f "$B/.config" ] || ! cmp -s "$FRAG" "$B/.tsx-frag.stamp"; then config; fi
		run "set -e; $MK -j$J zImage dtbs modules";;
	image)	cp "$B/arch/arm/boot/zImage" "$OUT/zImage"; cp "$DTB" "$OUT/"
		cp "$B/include/config/kernel.release" "$OUT/kernel.release"
		case "$(cat "$OUT/kernel.release")" in *-g[0-9a-f]*) ;; *)
			echo "kbuild: WARNING: kernel release '$(cat "$OUT/kernel.release")' has no -g<commit> suffix (git not usable in the build container?)";; esac
		git -C "$LINUX_DIR" rev-parse HEAD > "$OUT/kernel.commit"
		INITRD=$REPO/rootfs/out/initramfs-switchroot.cpio.gz
		INITRD_ARG=; [ -f "$INITRD" ] && INITRD_ARG="--initrd $INITRD"
		run "$REPO/kernel/mkimage.sh --kernel $OUT/zImage --dtb $OUT/$(basename "$DTB") $INITRD_ARG --out $OUT/test.img"
		(cd "$OUT" && sha256sum zImage "$(basename "$DTB")" test.img > sha256sums.txt)
		ls -l "$OUT";;
	cmd)	run "$MK $1"; shift;;
	stats)	run "ccache -s";;
	*) echo "unknown step $s"; exit 1;;
	esac
	echo "== $s: $(( $(date +%s) - t0 )) s"
done
