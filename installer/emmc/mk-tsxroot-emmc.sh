#!/bin/bash
# Host: build the pre-sized ext4 image for eMMC p8 (LABEL=tsxroot-emmc) that
# installer/steps/tsx-rescue-install writes straight into the partition (v2:
# rescue-first install, docs/install.md). Unlike the old
# steps/mkp2rootfs.sh (which repacks an EXISTING rootfs.ext4 build for the SD
# card's p2), this builds directly from the rootfs TARBALL and keeps only ONE
# kernel's /lib/modules tree (the tarball built by rootfs/build-rootfs.sh
# carries both flavors' modules so a single build serves either -- see
# docs/kernel.md), because the eMMC root never needs the other flavor's modules
# and every MiB here is a MiB streamed to the panel at install time.
#
# Same fstab treatment installer/emmc/migrate-to-emmc.sh applies at runtime
# (LABEL=tsxroot-emmc, /media/bootfat + /data added) and the same mke2fs
# feature set as steps/mkp2rootfs.sh, so a v2 install and a migrated card-stage
# install produce the same on-disk layout.
#
#   mk-tsxroot-emmc.sh --rootfs-tar FILE --modules-ver VERSION --bytes N --out IMG
#                      [--url KIOSK_URL] [--flavor lts|stable]
#   mk-tsxroot-emmc.sh --list-versions FILE     # print the /lib/modules/* trees in FILE
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TAR= MVER= BYTES= OUT= URL= FLAVOR=unknown LIST=
while [ $# -gt 0 ]; do case $1 in
	--rootfs-tar) TAR=$2; shift;; --modules-ver) MVER=$2; shift;; --bytes) BYTES=$2; shift;;
	--out) OUT=$2; shift;; --url) URL=$2; shift;; --flavor) FLAVOR=$2; shift;;
	--list-versions) LIST=$2; shift;;
	*) sed -n '2,20p' "$0"; exit 2;;
esac; shift; done
if [ -n "$LIST" ]; then
	tar tzf "$LIST" | sed -n 's#^\./lib/modules/\([^/]*\)/.*#\1#p' | sort -u
	exit 0
fi
[ -n "$TAR" ] && [ -f "$TAR" ] || { echo "mk-tsxroot-emmc.sh: --rootfs-tar FILE required" >&2; exit 2; }
[ -n "$MVER" ] || { echo "mk-tsxroot-emmc.sh: --modules-ver VERSION required (see --list-versions)" >&2; exit 2; }
[ -n "$BYTES" ] || { echo "mk-tsxroot-emmc.sh: --bytes N required (the eMMC p8 partition size; see docs/boot.md eMMC region table)" >&2; exit 2; }
OUT=${OUT:?--out IMG required}
# captured into a variable first, not `tar tzf ... | grep -q ...` directly:
# under `set -o pipefail`, grep -q's early exit on the first match sends tar
# a SIGPIPE, which makes the PIPELINE's exit status tar's (nonzero) instead
# of grep's -- the exact same class of bug as the "ash dd stdin trap" in
# docs/recovery.md, just triggered by pipefail instead of a backgrounded job.
TARLIST=$(tar tzf "$TAR")
grep -q "^\./lib/modules/$MVER/" <<< "$TARLIST" || { echo "mk-tsxroot-emmc.sh: $TAR has no /lib/modules/$MVER (see --list-versions)" >&2; exit 1; }

# computed on the HOST first: the container's /src is a bind mount that does
# not exist outside it, so anything needing that path must run inside the
# heredoc below (\$-escaped); only plain values (already-known strings/numbers)
# cross the boundary unescaped.
TARNAME=$(basename "$TAR")
TARSHA=$(sha256sum < "$TAR" | cut -d' ' -f1)
BUILDTS=$(date -Iseconds 2>/dev/null || date)

W=$(mktemp -d "${TMPDIR:-/var/tmp}/mktsxroot.XXXX"); trap 'rm -rf "$W"' EXIT
truncate -s "$BYTES" "$W/root.img"
# KIOSK_URL travels through the container's OWN environment (-e), not through
# the heredoc string below: passing an arbitrary URL through several layers of
# shell quoting is exactly the kind of thing that silently mismangles a
# character, and $TSX_KIOSK_URL here is read by the CONTAINER's sh, unescaped
# by this host bash at all.
docker run --rm --platform linux/amd64 -e TSX_KIOSK_URL="$URL" -v "$(dirname "$TAR"):/src:ro" -v "$W:/w" alpine:3.24 sh -euc "
	apk add -q --no-cache e2fsprogs e2fsprogs-extra >/dev/null
	mkdir -p /tmp/root; cd /tmp/root   # container-local, never bind-mounted: /w/root.img is the
	tar xzf /src/$TARNAME              # only thing that needs to reach the host, so nothing here
	                                    # is left root-owned in a host-visible directory afterward
	# keep only this flavor's modules
	for d in lib/modules/*/; do v=\$(basename \"\$d\"); [ \"\$v\" = '$MVER' ] || rm -rf \"\$d\"; done
	# fstab: LABEL=tsxroot-emmc, + the boot FAT partition + tsxdata (same recipe
	# as installer/emmc/migrate-to-emmc.sh applies to a migrated card install)
	sed -i 's#^LABEL=tsxroot  *#LABEL=tsxroot-emmc   #' etc/fstab
	grep -q '/media/bootfat' etc/fstab || echo '/dev/mmcblk0p1  /media/bootfat  vfat    noauto,rw,noatime,umask=022  0 0' >> etc/fstab
	grep -q 'LABEL=tsxdata' etc/fstab || echo 'LABEL=tsxdata   /data           ext4    rw,noatime,nofail         0      0' >> etc/fstab
	for d in data media/bootfat var/log var/lib/tsx var/lib/sendspin root home; do mkdir -p \"\$d\"; done
	[ -n \"\$TSX_KIOSK_URL\" ] && sed -i \"s|^KIOSK_URL=.*|KIOSK_URL=\\\"\$TSX_KIOSK_URL\\\"|\" etc/kiosk.conf
	{ echo 'root=emmc'; echo 'built=(host, mk-tsxroot-emmc.sh $BUILDTS)'; echo 'source_tar_sha256=$TARSHA'; echo 'kernel_modules_ver=$MVER'; echo 'kernel_flavor=$FLAVOR'; } > etc/tsx/emmc-root.info
	mke2fs -q -F -t ext4 -O ^metadata_csum_seed,^orphan_file -L tsxroot-emmc -m 0 -d /tmp/root /w/root.img
	e2fsck -fn /w/root.img
	chown $(id -u):$(id -g) /w/root.img
"
FREE_MIB=$(dumpe2fs -h "$W/root.img" 2>/dev/null | awk -F: '/^Free blocks/{f=$2}END{printf "%d", f*4/1024}')
echo "mk-tsxroot-emmc.sh: p8 image free space: ${FREE_MIB} MiB"
[ "$FREE_MIB" -ge 40 ] || { echo "mk-tsxroot-emmc.sh: ERROR: only ${FREE_MIB} MiB free (need >= 40 MiB)" >&2; exit 1; }
mv "$W/root.img" "$OUT"
{ echo "format=tsx-rescue-install-1"; echo "kernel_flavor=$FLAVOR"; echo "root_bytes=$BYTES"; echo "root_sha256=$(sha256sum < "$OUT" | cut -d' ' -f1)"; } > "$OUT.manifest-fragment"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "mk-tsxroot-emmc.sh: $OUT: $(stat -c %s "$OUT") bytes, modules $MVER ($FLAVOR), sha256 $(cut -c1-16 "$OUT.sha256")"
