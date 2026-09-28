#!/bin/bash
# Host: build the COMPACT ext4 image for eMMC p8 (LABEL=tsxroot-emmc) that
# installer/steps/tsx-rescue-install writes straight into the partition (v2:
# rescue-first install, docs/install.md). Unlike the old
# steps/mkp2rootfs.sh (which repacks an EXISTING rootfs.ext4 build for the SD
# card's p2), this builds directly from the rootfs TARBALL and keeps only ONE
# kernel's /lib/modules tree (the tarball built by rootfs/build-rootfs.sh
# carries both flavors' modules so a single build serves either -- see
# docs/kernel.md), because the eMMC root never needs the other flavor's modules
# and every MiB here is a MiB streamed to the panel at install time.
#
# The image is sized to its CONTENT, not to the partition: p8 is ~2.9 GiB
# (see docs/boot.md eMMC region table) but the rootfs is under 1 GiB, so
# writing a partition-sized image wastes ~2 GiB of streaming time and eMMC
# wear for nothing. Recipe: mke2fs -d is given a working image close to the
# content size from the start (building at the full partition size and
# shrinking afterward does NOT reach a tight minimum -- ext4's block
# allocator spreads data across however big the device is TOLD to be, and
# resize2fs -M can't undo that), growing and retrying if that undershoots;
# then a fine trim (`resize2fs -M`, usually a no-op given the sizing above),
# then grow back up by a margin (the larger of 64 MiB or 10%) so there is
# headroom before installer/steps/tsx-rescue-install's own `resize2fs` (no
# size arg) grows it the rest of the way to fill the real p8 once it is on
# the panel. --bytes (the eMMC p8 partition size / the target partition's
# minimum size) is kept as the required argument: it caps the compact size
# (refuses if content got too big to fit) and is recorded in the manifest
# for tsx-rescue-install's own sanity check.
#
# Same fstab treatment installer/emmc/migrate-to-emmc.sh applies at runtime
# (LABEL=tsxroot-emmc, /media/bootfat + /data added) and the same mke2fs
# feature set as steps/mkp2rootfs.sh, so a v2 install and a migrated card-stage
# install produce the same on-disk layout (see docs/rootfs.md /
# rootfs/mkrootfs.sh for why metadata_csum_seed/orphan_file stay off).
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
	*) sed -n '2,37p' "$0"; exit 2;;
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
	# Size the WORKING image to the content, not to the partition: mke2fs
	# picks journal/inode-table/flex_bg proportional to the size it is TOLD,
	# and ext4's block allocator spreads data across that declared size, so
	# building at the full partition size (2932 MiB) and shrinking afterward
	# with resize2fs -M does NOT reliably reach a tight minimum -- verified
	# by hand: a 2932 MiB build minimized no smaller than ~1.2 GiB for content
	# that fits a 630 MiB image built directly. So mke2fs -d is given a size
	# close to the content from the start (content + 10% + 16 MiB), growing
	# and retrying if that undershoots (ENOSPC while populating).
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
	# fine trim (usually a no-op given the sizing above, but cheap insurance),
	# then grow back up by a margin so p8 isn't written down to the exact last
	# byte: the larger of 64 MiB or 10% of the minimum.
	# installer/steps/tsx-rescue-install grows this the rest of the way to
	# fill the real (larger) p8 once it is written to the panel.
	resize2fs -M /w/root.img >/dev/null
	MINBLOCKS=\$(dumpe2fs -h /w/root.img 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,\"\",\$2); print \$2}')
	BS=\$(dumpe2fs -h /w/root.img 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,\"\",\$2); print \$2}')
	MINBYTES=\$((MINBLOCKS * BS))
	MARGIN=\$((MINBYTES / 10)); [ \$MARGIN -ge 67108864 ] && : || MARGIN=67108864
	# rounded up to a whole MiB (not just a filesystem block): tsx-rescue-install's
	# pr_dd/readback both work in whole-MiB dd blocks (bs=1M count=N), so the
	# image size must be a MiB multiple or the trailing partial MiB would be
	# left unwritten while the readback sha256 still covers the whole file.
	TARGETBYTES=\$(( (MINBYTES + MARGIN + 1048575) / 1048576 * 1048576 ))
	[ \$TARGETBYTES -le $BYTES ] || { echo \"mk-tsxroot-emmc.sh: ERROR: compact size (\$TARGETBYTES bytes) exceeds the partition size ($BYTES bytes): content grew too large for --bytes\" >&2; exit 1; }
	truncate -s \$TARGETBYTES /w/root.img
	resize2fs /w/root.img >/dev/null
	e2fsck -fy /w/root.img >/dev/null
	echo \$MINBYTES > /w/minbytes.txt
	chown $(id -u):$(id -g) /w/root.img /w/minbytes.txt
"
MINBYTES=$(cat "$W/minbytes.txt")
# one dumpe2fs -h pass, both fields (Block size, Free blocks) at once
read -r BS FREEBLOCKS <<< "$(dumpe2fs -h "$W/root.img" 2>/dev/null | awk -F: '
	/^Block size/{gsub(/ /,"",$2); bs=$2} /^Free blocks/{gsub(/ /,"",$2); fb=$2} END{print bs, fb}')"
FREE_MIB=$((BS * FREEBLOCKS / 1048576))
TARGETBYTES=$(stat -c %s "$W/root.img")
MARGIN_MIB=$(( (TARGETBYTES - MINBYTES) / 1048576 ))
echo "mk-tsxroot-emmc.sh: content minimum $((MINBYTES / 1048576)) MiB, compact image $((TARGETBYTES / 1048576)) MiB (+${MARGIN_MIB} MiB margin, ${FREE_MIB} MiB free), partition floor $((BYTES / 1048576)) MiB"
[ "$FREE_MIB" -ge 40 ] || { echo "mk-tsxroot-emmc.sh: ERROR: only ${FREE_MIB} MiB free in the compact image (need >= 40 MiB)" >&2; exit 1; }
mv "$W/root.img" "$OUT"
{ echo "format=tsx-rescue-install-1"; echo "kernel_flavor=$FLAVOR"; echo "root_bytes=$(stat -c %s "$OUT")"; echo "root_partition_min_bytes=$BYTES"; echo "root_sha256=$(sha256sum < "$OUT" | cut -d' ' -f1)"; } > "$OUT.manifest-fragment"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "mk-tsxroot-emmc.sh: $OUT: $(stat -c %s "$OUT") bytes, modules $MVER ($FLAVOR), sha256 $(cut -c1-16 "$OUT.sha256")"
