#!/bin/bash
# Build the xx60 rootfs (Alpine armv7) and the switch_root initramfs from
# packages. The build runs in docker. A host of another architecture needs
# qemu-user binfmt for the armv7 containers. An arm64 host with 32-bit support
# runs them natively.
#
#   ./build-rootfs.sh [modules|rootfs|initramfs|all]
#
# Outputs (out/): rootfs.tar.gz, rootfs.ext4 (1492 MiB = mmcblk0p5), rootfs.manifest
# (exact package versions), rootfs.sizes, rootfs.sha256, initramfs-switchroot.cpio.gz
#
# Env:
# TSX_APK_LOCAL (required for rootfs, initramfs and all) is a local copy of the
# published tree of the apk repository of this project: the directory that
# holds <ALPINE>/common and <ALPINE>/xx60, for example from tsx-aports
# scripts/index.sh --out DIR or from rootfs/fetch-apk-tree.sh. The rootfs build
# installs the profile meta package (tsx-xx60-console, tsx-xx60-kiosk or
# tsx-xx60-ha), the packages of packages-tsx.txt and the Alpine packages of
# packages.txt. The initramfs build takes the packages of initramfs/packages.pin
# from it. Nothing is compiled. The kernel modules come from the kernel packages.
# ALPINE (default v3.24).
# IMG_MB (default 1492).
# "modules" copies the stripped *.ko files of KBUILD (the kernel build dir, read
# only) into modules/lib/modules/<release>. The kernel bundle of tsx-aports uses
# them (.github/workflows/release.yml). The image takes the module trees from the
# kernel packages. A tree that the packages lack, for example the one of the
# kernel that a release builds, comes from here. The default KBUILD is every
# flavor build dir that tools/build/kbuild.sh made next to this repo
# (../build-lts and ../build-stable, whichever exist), else ../build.
# "modules" replaces only the dir of that release and the older trees of the
# same kernel series (same major.minor, for example an earlier 6.18.y build).
# The tree of the other flavor stays. Run "modules" once per flavor
# (KBUILD=../build-lts, then KBUILD=../build-stable) to stage both.
# KVER selects which release trees under modules/lib/modules/ the image build may
# copy. The default is every release dir found there, space-separated.
# Downloads: only Alpine packages from dl-cdn.alpinelinux.org (branch $ALPINE)
# and the alpine:3.24 docker image. out/rootfs.manifest records the versions.
# PROFILE (default ha) is what the image holds: console (text login and SSH),
# kiosk (console plus the browser kiosk) or ha (kiosk plus the Home Assistant
# layer). rootfs/profiles/*.list name the packages and services of each
# profile (docs/rootfs.md "Profiles").
# TSX_DEV_ROOT_HASH (optional) is a crypt(3) hash for the root password of the
# image, for our own test builds only. Without it, the image has no root
# password: the field is locked, and the installer sets the login (docs/rootfs.md
# "Root login"). A public image never uses it. Example:
#   TSX_DEV_ROOT_HASH=$(openssl passwd -6 mypassword) ./build-rootfs.sh rootfs
# TSX_DEV_RESCUE_HASH (optional) does the same for the root password of the
# rescue initramfs (./build-rootfs.sh initramfs). Without it, the rescue has no
# fixed password (docs/recovery.md).
# TSX_APK_URL (default https://tsx-aports.unexceptional.net) is the base URL
# that /etc/apk/repositories on the panel lists first (<url>/<ALPINE>/common
# and /xx60). The build never fetches it.
# TSX_SKIP_BOOT_CHECK=1 skips the check of the kernel packages (comparison
# builds only).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
OUT=$HERE/out; mkdir -p "$OUT"
ALPINE=${ALPINE:-v3.24}
IMAGE=${IMAGE:-alpine:3.24}
KBUILD_SET=${KBUILD:+1}
KBUILD=${KBUILD:-$TOP/build}
MODULES=$HERE/modules
# The "|| true" after the pipe is needed. Under pipefail, the ls exit status
# is nonzero when $MODULES/lib/modules does not exist yet. That is the normal
# case before anyone runs "modules". The nonzero status fails the pipeline and
# kills the script under set -e, even with stderr redirected to /dev/null.
KVER=${KVER:-$(ls "$MODULES/lib/modules" 2>/dev/null | tr '\n' ' ' || true)}
IMG_MB=${IMG_MB:-1492}
UIDGID="$(id -u):$(id -g)"
# The armv7 containers (rootfs, initramfs) must run on this host. This is true
# with qemu-user binfmt (qemu-user-static), or natively on an arm64 host that
# runs 32-bit code. A trial run of the build image tells both cases apart, and
# the line that it prints shows which case this host is. "modules" does not
# need it.
need_armv7() {
	local a
	a=$(docker run --rm --platform linux/arm/v7 "$IMAGE" apk --print-arch) || {
		echo "this host cannot run armv7 containers: it needs qemu-arm binfmt (qemu-user-static) or an arm64 host with 32-bit support"; exit 1; }
	echo "armv7 container check: host $(uname -m), qemu-arm binfmt $([ -e /proc/sys/fs/binfmt_misc/qemu-arm ] && echo registered || echo absent), container $a"
}

# On a native arm64 host, uname -m of an armv7 container says aarch64 (the
# kernel is 64-bit), and build tools would pick the 64-bit code. linux32 makes
# it say armv8l, like a 32-bit ARM machine. Under qemu-user it says armv7l
# already, and this prints nothing.
arm32() { if [ "$(uname -m)" = aarch64 ]; then echo linux32; fi; }

modules() {
	# This step only reads the build dir of another agent. It runs no make and
	# writes nothing there.
	local rel; rel=$(cat "$KBUILD/include/config/kernel.release")
	# Refuse stale modules. Their vermagic must name the release of the kernel image.
	local one; one=$(find "$KBUILD" -name '*.ko' ! -path '*/source/*' -print -quit)
	[ -n "$one" ] || { echo "no *.ko in $KBUILD (run 'make modules' there first)"; return 1; }
	local vm; vm=$(grep -a -m1 -o 'vermagic=[^ ]*' "$one" | cut -d= -f2)
	[ "$vm" = "$rel" ] || { echo "stale modules in $KBUILD: vermagic $vm, kernel $rel (rebuild modules there first)"; return 1; }
	# Replace only this release and the older trees of the same series
	# (major.minor). Other series (the other flavor) stay staged.
	local ser old; ser=$(echo "$rel" | cut -d. -f1-2)
	for old in "$MODULES/lib/modules/$ser".*; do
		[ -d "$old" ] || continue
		echo "modules: replacing staged tree ${old##*/}"; rm -rf "$old"
	done
	local D=$MODULES/lib/modules/$rel; mkdir -p "$D/kernel"
	(cd "$KBUILD" && find . -name '*.ko' ! -path './source/*' -printf '%P\n') | while read -r m; do
		mkdir -p "$D/kernel/$(dirname "$m")"; cp "$KBUILD/$m" "$D/kernel/$m"; done
	sed 's|^|kernel/|; s|\.o$|.ko|' "$KBUILD/modules.order" > "$D/modules.order"
	sed 's|^|kernel/|' "$KBUILD/modules.builtin" > "$D/modules.builtin"
	[ -f "$KBUILD/modules.builtin.modinfo" ] && cp "$KBUILD/modules.builtin.modinfo" "$D/"
	docker run --rm -u "$UIDGID" -v "$MODULES:$MODULES" tsx-mainline \
		find "$D" -name '*.ko' -exec arm-linux-gnueabihf-strip --strip-debug {} +
	echo "modules for $rel: $(find "$D" -name '*.ko' | wc -l) files, $(du -sh "$D" | cut -f1)"
	# SOURCE has one line per staged release: "<release> source: <KBUILD> (<commit>)".
	local r rest
	{ if [ -f "$MODULES/SOURCE" ]; then
		while read -r r rest; do
			if [ "$r" != "$rel" ] && [ -d "$MODULES/lib/modules/$r" ]; then echo "$r $rest"; fi
		done < "$MODULES/SOURCE"
	  fi
	  echo "$rel source: $KBUILD ($(git -C "$KBUILD/source" rev-parse --short HEAD 2>/dev/null || echo '?'))"; } > "$MODULES/SOURCE.new"
	mv "$MODULES/SOURCE.new" "$MODULES/SOURCE"
	echo "staged module trees: $(ls "$MODULES/lib/modules" | tr '\n' ' ')"
}

# The apk tree: a required directory with <ALPINE>/common and <ALPINE>/xx60.
# It becomes the read-only mount /aports in the container.
need_apk_tree() {
	[ -n "${TSX_APK_LOCAL:-}" ] || { echo "TSX_APK_LOCAL is required (a tsx-aports published tree with $ALPINE/common and $ALPINE/xx60, see rootfs/fetch-apk-tree.sh)"; exit 1; }
	[ -d "$TSX_APK_LOCAL/$ALPINE" ] || { echo "TSX_APK_LOCAL=$TSX_APK_LOCAL has no $ALPINE/ (a tsx-aports published tree)"; exit 1; }
}

rootfs() {
	need_apk_tree; need_armv7
	local mnt=()
	[ -d "$MODULES" ] && mnt=(-v "$MODULES:/modules:ro")
	mnt+=(-v "$(cd "$TSX_APK_LOCAL" && pwd):/aports:ro")
	mnt+=(-v "$(cd "$HERE/../kernel" && pwd):/kernel:ro")   # the kernel pins (check-boot-images.py)
	docker run --rm --platform linux/arm/v7 -v "$HERE:/w" "${mnt[@]}" -e TSX_APK_LOCAL=/aports \
		-e ALPINE="$ALPINE" -e PROFILE="${PROFILE:-ha}" -e TSX_DEV_ROOT_HASH="${TSX_DEV_ROOT_HASH:-}" -e KVER="$KVER" -e OUT=/w/out -e UIDGID="$UIDGID" -e IMG_MB="$IMG_MB" \
		-e TSX_APK_URL="${TSX_APK_URL:-https://tsx-aports.unexceptional.net}" \
		-e TFA_VENDOR_FETCH="${TFA_VENDOR_FETCH:-yes}" \
		-e TSX_SKIP_BOOT_CHECK="${TSX_SKIP_BOOT_CHECK:-0}" \
		"$IMAGE" $(arm32) /w/mkrootfs.sh
}

initramfs() {
	need_apk_tree; need_armv7
	local mnt=()
	mnt+=(-v "$(cd "$TSX_APK_LOCAL" && pwd):/aports:ro")
	# initramfs/mkinitramfs-switchroot.sh takes the rescue tools, the splash and the
	# board files from the packages of initramfs/packages.pin when TSX_FROM_PACKAGES
	# is 1. The stamp of the initramfs covers that script, so the script keeps its
	# old switch until the next release of the kernel packages.
	docker run --rm --platform linux/arm/v7 -v "$HERE:/w" "${mnt[@]}" -e TSX_APK_LOCAL=/aports -e ALPINE="$ALPINE" -e TSX_FROM_PACKAGES=1 -e TSX_DEV_RESCUE_HASH="${TSX_DEV_RESCUE_HASH:-}" "$IMAGE" sh -c "
		printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' $ALPINE $ALPINE > /etc/apk/repositories
		apk add -q --no-cache cpio mkpasswd >/dev/null
		/w/initramfs/mkinitramfs-switchroot.sh /w/out/initramfs-switchroot.cpio.gz /w/authorized_keys
		chown $UIDGID /w/out/initramfs-switchroot.cpio.gz"
}

# "modules" without KBUILD stages the default kbuild.sh build dir of each flavor.
modules_all() {
	local f n=0
	if [ -n "$KBUILD_SET" ]; then modules; return; fi
	for f in lts stable; do
		[ -d "$TOP/build-$f" ] || continue
		echo "modules: $f from $TOP/build-$f"
		KBUILD=$TOP/build-$f modules; n=$((n + 1))
	done
	[ "$n" -gt 0 ] || modules
}

case "${1:-all}" in
modules) modules_all;;
rootfs) rootfs;;
initramfs) initramfs;;
all) rootfs; initramfs;;
*) echo "usage: $0 [modules|rootfs|initramfs|all]"; exit 1;;
esac
