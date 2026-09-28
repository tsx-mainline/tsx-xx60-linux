#!/bin/bash
# Build the xx60 kiosk rootfs (Alpine armv7) and the switch_root
# initramfs, in docker with qemu-user binfmt.
#
#   ./build-rootfs.sh [modules|rootfs|initramfs|all]
#
# Outputs (out/): rootfs.tar.gz, rootfs.ext4 (1492 MiB = mmcblk0p5), rootfs.manifest
# (exact package versions), rootfs.sizes, rootfs.sha256, initramfs-switchroot.cpio.gz
#
# Env: ALPINE (default v3.24), KBUILD (kernel build dir to take modules from,
# read only; default the kernel fork checkout's own build dir, the LVDS-driving
# kernel that drives the panel), IMG_MB (default 1492). "modules" copies KBUILD's
# *.ko (stripped) into modules/lib/modules/<release>; the rootfs build then
# includes that tree. KVER (default: every release dir found under
# modules/lib/modules, space-separated) selects which of possibly several
# release trees under modules/lib/modules/ (e.g. from `make modules_install
# INSTALL_MOD_PATH=...` for more than one kernel) get copied into the rootfs;
# set it explicitly to build for only one. DRM_MESON, PANEL_LVDS, LIMA, touch
# and backlight are built in, so the panel works without modules; they are
# extras (USB, sound, ...).
# Downloads: only Alpine packages from dl-cdn.alpinelinux.org (branch $ALPINE)
# and the alpine:3.24 docker image; versions are recorded in out/rootfs.manifest.
# CHROMIUM_ES2_PATCH (default 1): patch Chromium's ES3->ES2 fallback gate
# (src/chromium-es2/); 0 = stock binary.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
OUT=$HERE/out; mkdir -p "$OUT"
ALPINE=${ALPINE:-v3.24}
IMAGE=${IMAGE:-alpine:3.24}
KBUILD=${KBUILD:-$TOP/build}
MODULES=$HERE/modules
# "|| true" after the pipe: under pipefail, ls's exit status (nonzero when
# $MODULES/lib/modules does not exist yet -- the normal case before "modules"
# has ever been run) still fails the pipeline and kills the script under set
# -e, even with stderr redirected to /dev/null (the same class of bug as the
# "ash dd stdin trap" in docs/recovery.md, just pipefail instead of a
# backgrounded job).
KVER=${KVER:-$(ls "$MODULES/lib/modules" 2>/dev/null | tr '\n' ' ' || true)}
IMG_MB=${IMG_MB:-1492}
UIDGID="$(id -u):$(id -g)"
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || { echo "need qemu-arm binfmt (qemu-user-static)"; exit 1; }

modules() {
	# read-only copy of another agent's build dir: no make, nothing written there
	local rel; rel=$(cat "$KBUILD/include/config/kernel.release")
	# refuse stale modules: their vermagic must name the release of the kernel image
	local one; one=$(find "$KBUILD" -name '*.ko' ! -path '*/source/*' -print -quit)
	[ -n "$one" ] || { echo "no *.ko in $KBUILD (run 'make modules' there first)"; return 1; }
	local vm; vm=$(grep -a -m1 -o 'vermagic=[^ ]*' "$one" | cut -d= -f2)
	[ "$vm" = "$rel" ] || { echo "stale modules in $KBUILD: vermagic $vm, kernel $rel (rebuild modules there first)"; return 1; }
	rm -rf "$MODULES"; local D=$MODULES/lib/modules/$rel; mkdir -p "$D/kernel"
	(cd "$KBUILD" && find . -name '*.ko' ! -path './source/*' -printf '%P\n') | while read -r m; do
		mkdir -p "$D/kernel/$(dirname "$m")"; cp "$KBUILD/$m" "$D/kernel/$m"; done
	sed 's|^|kernel/|; s|\.o$|.ko|' "$KBUILD/modules.order" > "$D/modules.order"
	sed 's|^|kernel/|' "$KBUILD/modules.builtin" > "$D/modules.builtin"
	[ -f "$KBUILD/modules.builtin.modinfo" ] && cp "$KBUILD/modules.builtin.modinfo" "$D/"
	docker run --rm -u "$UIDGID" -v "$MODULES:$MODULES" tsx-mainline \
		find "$D" -name '*.ko' -exec arm-linux-gnueabihf-strip --strip-debug {} +
	echo "modules for $rel: $(find "$D" -name '*.ko' | wc -l) files, $(du -sh "$D" | cut -f1)"
	echo "source: $KBUILD ($(git -C "$KBUILD/source" rev-parse --short HEAD 2>/dev/null || echo '?'))" > "$MODULES/SOURCE"
}

rootfs() {
	local mnt=()
	[ -d "$MODULES" ] && mnt=(-v "$MODULES:/modules:ro")
	docker run --rm --platform linux/arm/v7 -v "$HERE:/w" "${mnt[@]}" \
		-e ALPINE="$ALPINE" -e KVER="$KVER" -e OUT=/w/out -e UIDGID="$UIDGID" -e IMG_MB="$IMG_MB" -e CHROMIUM_ES2_PATCH="${CHROMIUM_ES2_PATCH:-1}" \
		"$IMAGE" /w/mkrootfs.sh
}

initramfs() {
	docker run --rm --platform linux/arm/v7 -v "$HERE:/w" -e ALPINE="$ALPINE" "$IMAGE" sh -c "
		printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' $ALPINE $ALPINE > /etc/apk/repositories
		apk add -q --no-cache cpio mkpasswd >/dev/null
		/w/initramfs/mkinitramfs-switchroot.sh /w/out/initramfs-switchroot.cpio.gz /w/authorized_keys
		chown $UIDGID /w/out/initramfs-switchroot.cpio.gz"
}

case "${1:-all}" in
modules) modules;;
rootfs) rootfs;;
initramfs) initramfs;;
all) rootfs; initramfs;;
*) echo "usage: $0 [modules|rootfs|initramfs|all]"; exit 1;;
esac
