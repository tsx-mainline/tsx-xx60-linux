#!/bin/bash
# Build the xx60 kiosk rootfs (Alpine armv7) and the switch_root
# initramfs. The build runs in docker with qemu-user binfmt.
#
#   ./build-rootfs.sh [modules|rootfs|initramfs|all]
#
# Outputs (out/): rootfs.tar.gz, rootfs.ext4 (1492 MiB = mmcblk0p5), rootfs.manifest
# (exact package versions), rootfs.sizes, rootfs.sha256, initramfs-switchroot.cpio.gz
#
# Env:
# ALPINE (default v3.24).
# KBUILD is the kernel build dir that supplies the modules. The build only
# reads it. The default is every flavor build dir that tools/build/kbuild.sh
# made next to this repo (../build-lts and ../build-stable, whichever exist),
# else ../build.
# IMG_MB (default 1492).
# "modules" copies the stripped *.ko files of KBUILD into
# modules/lib/modules/<release>. The rootfs build then includes that tree.
# "modules" replaces only the dir of that release and the older trees of the
# same kernel series (same major.minor, for example an earlier 6.18.y build).
# The tree of the other flavor stays. An earlier "modules" run with the other
# KBUILD staged that tree. Run "modules" once per flavor (KBUILD=../build-lts,
# then KBUILD=../build-stable) to get a rootfs with both.
# KVER selects which release trees under modules/lib/modules/ the build copies
# into the rootfs. There can be several, for example from `make modules_install
# INSTALL_MOD_PATH=...` for more than one kernel. The default is every release
# dir found there, space-separated. Set KVER to build for one release only.
# DRM_MESON, PANEL_LVDS, LIMA, touch and backlight are built in, so the panel
# works without modules. The modules are extras (USB, sound, ...).
# Downloads: only Alpine packages from dl-cdn.alpinelinux.org (branch $ALPINE)
# and the alpine:3.24 docker image. out/rootfs.manifest records the versions.
# PROFILE (default ha) is what the image holds: console (text login and SSH),
# kiosk (console plus the browser kiosk) or ha (kiosk plus the Home Assistant
# layer). rootfs/profiles/*.list name the files, packages and services of each
# profile (docs/rootfs.md "Profiles").
# TSX_DEV_ROOT_HASH (optional) is a crypt(3) hash for the root password of the
# image, for our own test builds only. Without it, the image has no root
# password: the field is locked, and the installer sets the login (docs/rootfs.md
# "Root login"). A public image never uses it. Example:
#   TSX_DEV_ROOT_HASH=$(openssl passwd -6 mypassword) ./build-rootfs.sh rootfs
# TSX_DEV_RESCUE_HASH (optional) does the same for the root password of the
# rescue initramfs (./build-rootfs.sh initramfs). Without it, the rescue has no
# fixed password (docs/recovery.md).
# CHROMIUM_ES2_PATCH (default 1) patches the Chromium ES3 to ES2 fallback gate
# (src/chromium-es2/). 0 gives the stock binary. TSX_APK_LOCAL disables it.
# This project's apk repository is tsx-aports (docs/updates.md).
# TSX_APK_URL (default https://tsx-aports.unexceptional.net) is the base URL
# that /etc/apk/repositories on the panel lists first (<url>/<ALPINE>/common
# and /xx60). The build never fetches it.
# TSX_APK_LOCAL (optional) is a local copy of the published tree: the directory
# that holds <ALPINE>/common and <ALPINE>/xx60, for example from tsx-aports
# scripts/index.sh --out DIR. The build then installs the packages in
# packages-tsx.txt (tsx-xx60-chromium, both kernel flavors, sendspin-cli,
# tensorflow-lite-c, tsx-keys) from that copy. It does not use the Alpine
# chromium with the in-place patch, or the local sendspin and TFLite builds.
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
# This is the same class of bug as the "ash dd stdin trap" in docs/recovery.md.
# Here pipefail causes it, not a backgrounded job.
KVER=${KVER:-$(ls "$MODULES/lib/modules" 2>/dev/null | tr '\n' ' ' || true)}
IMG_MB=${IMG_MB:-1492}
UIDGID="$(id -u):$(id -g)"
# The armv7 containers (rootfs, initramfs) need qemu-user. "modules" does not.
need_binfmt() { [ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || { echo "need qemu-arm binfmt (qemu-user-static)"; exit 1; }; }

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

rootfs() {
	need_binfmt
	local mnt=() apk=()
	[ -d "$MODULES" ] && mnt=(-v "$MODULES:/modules:ro")
	if [ -n "${TSX_APK_LOCAL:-}" ]; then
		[ -d "$TSX_APK_LOCAL/$ALPINE" ] || { echo "TSX_APK_LOCAL=$TSX_APK_LOCAL has no $ALPINE/ (a tsx-aports published tree)"; exit 1; }
		mnt+=(-v "$(cd "$TSX_APK_LOCAL" && pwd):/aports:ro"); apk=(-e TSX_APK_LOCAL=/aports)
	fi
	docker run --rm --platform linux/arm/v7 -v "$HERE:/w" "${mnt[@]}" "${apk[@]}" \
		-e ALPINE="$ALPINE" -e PROFILE="${PROFILE:-ha}" -e TSX_DEV_ROOT_HASH="${TSX_DEV_ROOT_HASH:-}" -e KVER="$KVER" -e OUT=/w/out -e UIDGID="$UIDGID" -e IMG_MB="$IMG_MB" -e CHROMIUM_ES2_PATCH="${CHROMIUM_ES2_PATCH:-1}" \
		-e TSX_APK_URL="${TSX_APK_URL:-https://tsx-aports.unexceptional.net}" \
		-e TFA_VENDOR_FETCH="${TFA_VENDOR_FETCH:-yes}" \
		"$IMAGE" /w/mkrootfs.sh
}

initramfs() {
	need_binfmt
	docker run --rm --platform linux/arm/v7 -v "$HERE:/w" -e ALPINE="$ALPINE" -e TSX_DEV_RESCUE_HASH="${TSX_DEV_RESCUE_HASH:-}" "$IMAGE" sh -c "
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
