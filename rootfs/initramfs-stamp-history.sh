#!/bin/sh
# Print the initramfs stamps of the history of this checkout: one line
# "<stamp> <commit>" for each commit that changed a source of the stamp
# (rootfs/initramfs, rootfs/install.sh, rootfs/tsx-disk.sh) or the stamp
# script itself. The newest commit comes first. The stamp of each commit comes
# from the initramfs-stamp.sh of that commit, run on the rootfs/ files of that
# commit. A commit without initramfs-stamp.sh, or where it fails, gives no line.
#
# The rootfs build uses the list when TSX_STAMP_OLDER_OK=1
# (rootfs/build-rootfs.sh): a kernel package with the stamp of an older commit
# of this history has an older initramfs of these same sources. Only the
# initramfs sources differ, so check-boot-images.py then gives a warning and
# not an error.
#
# Usage: initramfs-stamp-history.sh [REV]   (default HEAD)
# Needs git and the full history (a shallow clone gives an error).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REV=${1:-HEAD}
TOP=$(git -C "$HERE" rev-parse --show-toplevel)
cd "$TOP"
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
	echo "initramfs-stamp-history.sh: the clone is shallow, so the history is not complete (git fetch --unshallow, or actions/checkout with fetch-depth: 0)" >&2
	exit 1
fi
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
git log --format=%H "$REV" -- rootfs/initramfs rootfs/install.sh rootfs/tsx-disk.sh rootfs/initramfs-stamp.sh |
while read -r c; do
	git cat-file -e "$c:rootfs/initramfs-stamp.sh" 2>/dev/null || continue
	rm -rf "$W/t"; mkdir "$W/t"
	# All of rootfs/: the stamp script of an older commit can read other files.
	git archive "$c" rootfs </dev/null | tar -x -C "$W/t"
	s=$(sh "$W/t/rootfs/initramfs-stamp.sh" </dev/null 2>/dev/null) || continue
	printf '%s %s\n' "$s" "$c"
done
