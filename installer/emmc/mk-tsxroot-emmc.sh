#!/bin/bash
# Host: build the COMPACT ext4 image for eMMC p8 (LABEL=tsxroot-emmc) that
# installer/steps/tsx-rescue-install writes straight into the partition (v2:
# rescue-first install, docs/install.md). Unlike the old steps/mkp2rootfs.sh
# (which repacks an EXISTING rootfs.ext4 build for p2 of the SD card), this
# script builds directly from the rootfs TARBALL. It keeps the /lib/modules
# trees of BOTH kernels (the tarball from rootfs/build-rootfs.sh carries the
# modules of both flavors, see docs/kernel.md). `tsx-update-boot --emmc`
# switches an installed panel between lts and stable by writing only the boot
# image, so the modules of the other flavor must already be on the root. They
# cost a few tens of MiB of install streaming. --modules-ver names the flavor
# that boots first. Its modules must be present.
#
# The script sizes the image to its CONTENT, not to the partition. p8 is ~2.9
# GiB (see the eMMC region table in docs/boot.md), but the rootfs is under 1
# GiB. A partition-sized image would waste ~2 GiB of streaming time and eMMC
# wear for nothing. The recipe: give mke2fs -d a working image close to the
# content size from the start, and grow and retry if that undershoots. Do not
# build at the full partition size and shrink afterward. That does NOT reach a
# tight minimum, because the block allocator of ext4 spreads data across
# however big the device is TOLD to be, and resize2fs -M cannot undo that.
# Then make a fine trim (`resize2fs -M`, usually a no-op given the sizing
# above). Then grow back up by a margin (the larger of 64 MiB or 10%). This
# leaves headroom before the own `resize2fs` of installer/steps/tsx-rescue-install
# (no size argument) grows it the rest of the way to fill the real p8 on the
# panel. --bytes (the size of eMMC p8, i.e. the minimum size of the target
# partition) stays a required argument. It caps the compact size (the script
# refuses if the content is too big to fit). The manifest records it for the
# sanity check of tsx-rescue-install.
#
# The fstab treatment is the same as installer/emmc/migrate-to-emmc.sh applies
# at runtime (LABEL=tsxroot-emmc, /media/bootfat and /data added). The mke2fs
# feature set is the same as in steps/mkp2rootfs.sh. So a v2 install and a
# migrated card-stage install produce the same on-disk layout (see docs/rootfs.md
# and rootfs/mkrootfs.sh for why metadata_csum_seed and orphan_file stay off).
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
	*) sed -n '2,39p' "$0"; exit 2;;
esac; shift; done
if [ -n "$LIST" ]; then
	tar tzf "$LIST" | sed -n 's#^\./lib/modules/\([^/]*\)/.*#\1#p' | sort -u
	exit 0
fi
[ -n "$TAR" ] && [ -f "$TAR" ] || { echo "mk-tsxroot-emmc.sh: --rootfs-tar FILE required" >&2; exit 2; }
[ -n "$MVER" ] || { echo "mk-tsxroot-emmc.sh: --modules-ver VERSION required (see --list-versions)" >&2; exit 2; }
[ -n "$BYTES" ] || { echo "mk-tsxroot-emmc.sh: --bytes N required (the eMMC p8 partition size. See docs/boot.md eMMC region table)" >&2; exit 2; }
OUT=${OUT:?--out IMG required}
# Capture the list into a variable first. Do not pipe `tar tzf ... | grep -q ...`
# directly. Under `set -o pipefail`, the early exit of grep -q on the first
# match sends SIGPIPE to tar. Then the exit status of the PIPELINE is the
# nonzero status of tar instead of the status of grep. This is the same class
# of bug as the "ash dd stdin trap" in docs/recovery.md. Here pipefail triggers
# it, not a backgrounded job.
TARLIST=$(tar tzf "$TAR")
grep -q "^\./lib/modules/$MVER/" <<< "$TARLIST" || { echo "mk-tsxroot-emmc.sh: $TAR has no /lib/modules/$MVER (see --list-versions)" >&2; exit 1; }

# Compute this on the HOST first. The /src of the container is a bind mount
# that does not exist outside it. So anything that needs that path must run
# inside the heredoc below (\$-escaped). Only plain values (already-known
# strings and numbers) cross the boundary unescaped.
TARNAME=$(basename "$TAR")
# docker -v needs an absolute host path. A relative one ("rootfs/out", as
# release.yml passes it) counts as a named-volume name, and docker refuses it.
TARDIR=$(cd "$(dirname "$TAR")" && pwd)
TARSHA=$(sha256sum < "$TAR" | cut -d' ' -f1)
BUILDTS=$(date -Iseconds 2>/dev/null || date)

W=$(mktemp -d "${TMPDIR:-/var/tmp}/mktsxroot.XXXX"); trap 'rm -rf "$W"' EXIT
# KIOSK_URL travels through the own environment of the container (-e), not
# through the heredoc string below. An arbitrary URL that passes through
# several layers of shell quoting can silently lose or change a character.
# Here the sh of the CONTAINER reads $TSX_KIOSK_URL, and this host bash does
# not touch it.
docker run --rm --platform linux/amd64 -e TSX_KIOSK_URL="$URL" -v "$TARDIR:/src:ro" -v "$W:/w" alpine:3.24 sh -euc "
	apk add -q --no-cache e2fsprogs e2fsprogs-extra >/dev/null
	mkdir -p /tmp/root; cd /tmp/root   # container-local, never bind-mounted: /w/root.img is the
	tar xzf /src/$TARNAME              # only thing that needs to reach the host, so nothing here
	                                    # is left root-owned in a host-visible directory afterward
	# The module trees of both flavors stay (tsx-update-boot --emmc switches kernels).
	# fstab: LABEL=tsxroot-emmc, plus the boot FAT partition and tsxdata (the same
	# recipe that installer/emmc/migrate-to-emmc.sh applies to a migrated card install)
	sed -i 's#^LABEL=tsxroot  *#LABEL=tsxroot-emmc   #' etc/fstab
	grep -q '/media/bootfat' etc/fstab || echo '/dev/mmcblk0p1  /media/bootfat  vfat    noauto,rw,noatime,umask=022  0 0' >> etc/fstab
	grep -q 'LABEL=tsxdata' etc/fstab || echo 'LABEL=tsxdata   /data           ext4    rw,noatime,nofail         0      0' >> etc/fstab
	for d in data media/bootfat var/log var/lib/tsx root home; do mkdir -p \"\$d\"; done
	[ ! -e etc/init.d/tsx-sendspin ] || mkdir -p var/lib/sendspin   # ha profile only
	[ -n \"\$TSX_KIOSK_URL\" ] && [ -f etc/kiosk.conf ] && sed -i \"s|^KIOSK_URL=.*|KIOSK_URL=\\\"\$TSX_KIOSK_URL\\\"|\" etc/kiosk.conf
	{ echo 'root=emmc'; echo 'built=(host, mk-tsxroot-emmc.sh $BUILDTS)'; echo 'source_tar_sha256=$TARSHA'; echo 'kernel_modules_ver=$MVER'; echo 'kernel_flavor=$FLAVOR'; } > etc/tsx/emmc-root.info
	# Size the WORKING image to the content, not to the partition. mke2fs picks
	# the journal, inode table and flex_bg in proportion to the size it is TOLD.
	# The block allocator of ext4 spreads data across that declared size. So
	# building at the full partition size (2932 MiB) and shrinking afterward with
	# resize2fs -M does NOT reliably reach a tight minimum. Verified by hand: a
	# 2932 MiB build minimized no smaller than ~1.2 GiB for content that fits a
	# 630 MiB image built directly. So give mke2fs -d a size close to the content
	# from the start (content + 10% + 16 MiB). Grow and retry if that undershoots
	# (ENOSPC while populating).
	CONTENT=\$(du -sb /tmp/root | cut -f1)
	ATTEMPT=\$(( CONTENT + CONTENT / 10 + 16 * 1048576 ))
	TRY=0
	while :; do
		truncate -s \$ATTEMPT /w/root.img
		mke2fs -q -F -t ext4 -O ^metadata_csum_seed,^orphan_file -L tsxroot-emmc -m 0 -d /tmp/root /w/root.img 2>/w/mke2fs.err && break
		TRY=\$((TRY + 1))
		[ \$TRY -le 5 ] || { echo 'mk-tsxroot-emmc.sh: ERROR: mke2fs -d could not fit the content after 5 attempts:' >&2; cat /w/mke2fs.err >&2; exit 1; }
		ATTEMPT=\$(( ATTEMPT + ATTEMPT / 5 + 16 * 1048576 ))
	done
	e2fsck -fy /w/root.img >/dev/null
	# Do a fine trim (usually a no-op given the sizing above, but cheap insurance).
	# Then grow back up by a margin, so the script does not write p8 down to the
	# exact last byte. The margin is the larger of 64 MiB or 10% of the minimum.
	# installer/steps/tsx-rescue-install grows the file system the rest of the way
	# to fill the real (larger) p8 once the image is written to the panel.
	resize2fs -M /w/root.img >/dev/null
	MINBLOCKS=\$(dumpe2fs -h /w/root.img 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,\"\",\$2); print \$2}')
	BS=\$(dumpe2fs -h /w/root.img 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,\"\",\$2); print \$2}')
	MINBYTES=\$((MINBLOCKS * BS))
	MARGIN=\$((MINBYTES / 10)); [ \$MARGIN -ge 67108864 ] && : || MARGIN=67108864
	# Round up to a whole MiB, not just a file system block. pr_dd and the readback
	# of tsx-rescue-install both work in whole-MiB dd blocks (bs=1M count=N). So the
	# image size must be a MiB multiple. Otherwise the trailing partial MiB stays
	# unwritten, while the readback sha256 still covers the whole file.
	TARGETBYTES=\$(( (MINBYTES + MARGIN + 1048575) / 1048576 * 1048576 ))
	[ \$TARGETBYTES -le $BYTES ] || { echo \"mk-tsxroot-emmc.sh: ERROR: compact size (\$TARGETBYTES bytes) exceeds the partition size ($BYTES bytes): content grew too large for --bytes\" >&2; exit 1; }
	truncate -s \$TARGETBYTES /w/root.img
	resize2fs /w/root.img >/dev/null
	e2fsck -fy /w/root.img >/dev/null
	echo \$MINBYTES > /w/minbytes.txt
	# Read the block size and the free blocks of the final image HERE. The container
	# has e2fsprogs. The host may not have it, or may have dumpe2fs only in an sbin dir
	# that is not on a non-root PATH. The free-space check below then saw 0.
	dumpe2fs -h /w/root.img 2>/dev/null | awk -F: '
		/^Block size/{gsub(/ /,\"\",\$2); bs=\$2} /^Free blocks/{gsub(/ /,\"\",\$2); fb=\$2} END{print bs, fb}' > /w/fsinfo.txt
	chown $(id -u):$(id -g) /w/root.img /w/minbytes.txt /w/fsinfo.txt
"
MINBYTES=$(cat "$W/minbytes.txt")
read -r BS FREEBLOCKS < "$W/fsinfo.txt"
[ -n "$BS" ] && [ -n "$FREEBLOCKS" ] || { echo "mk-tsxroot-emmc.sh: ERROR: could not read the image's block size / free blocks" >&2; exit 1; }
FREE_MIB=$((BS * FREEBLOCKS / 1048576))
TARGETBYTES=$(stat -c %s "$W/root.img")
MARGIN_MIB=$(( (TARGETBYTES - MINBYTES) / 1048576 ))
echo "mk-tsxroot-emmc.sh: content minimum $((MINBYTES / 1048576)) MiB, compact image $((TARGETBYTES / 1048576)) MiB (+${MARGIN_MIB} MiB margin, ${FREE_MIB} MiB free), partition floor $((BYTES / 1048576)) MiB"
[ "$FREE_MIB" -ge 40 ] || { echo "mk-tsxroot-emmc.sh: ERROR: only ${FREE_MIB} MiB free in the compact image (need >= 40 MiB)" >&2; exit 1; }
mv "$W/root.img" "$OUT"
{ echo "format=tsx-rescue-install-1"; echo "kernel_flavor=$FLAVOR"; echo "root_bytes=$(stat -c %s "$OUT")"; echo "root_partition_min_bytes=$BYTES"; echo "root_sha256=$(sha256sum < "$OUT" | cut -d' ' -f1)"; } > "$OUT.manifest-fragment"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "mk-tsxroot-emmc.sh: $OUT: $(stat -c %s "$OUT") bytes, modules $MVER ($FLAVOR), sha256 $(cut -c1-16 "$OUT.sha256")"
