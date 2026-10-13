#!/bin/sh
# Check that the published apk tree has each package version of
# initramfs/packages.pin: the signed index (APKINDEX) lists it and the file is
# in the tree. A file that only a cache still holds does not count, because a
# new build from the published tree would not find it.
#
#   rootfs/check-apk-pins.sh TREE
#
# TREE is a tree of rootfs/fetch-apk-tree.sh (TSX_APK_LOCAL), with
# <ALPINE>/common/armv7 and <ALPINE>/xx60/armv7. ALPINE (default v3.24).
# build-rootfs.sh initramfs runs it first. tsx-aports keeps these versions
# (keep/keep.txt there): its index.sh never prunes them.
# The script needs tar and awk. Exit 0: all pins are there. Exit 1: one is
# missing (the lines name it).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=${1:?usage: check-apk-pins.sh TREE}
ALPINE=${ALPINE:-v3.24}
PINS=$HERE/initramfs/packages.pin
fail=0
for pin in $(grep -v -e '^#' -e '^[[:space:]]*$' "$PINS"); do
	n=${pin%%=*} v=${pin#*=} where=
	for c in common xx60; do
		idx=$TREE/$ALPINE/$c/armv7/APKINDEX.tar.gz
		[ -f "$idx" ] || continue
		if tar -xzOf "$idx" APKINDEX 2>/dev/null | awk -v n="$n" -v v="$v" '
			/^P:/ { p = substr($0, 3) } /^V:/ && p == n && substr($0, 3) == v { f = 1 } END { exit !f }'; then
			where=$c; break
		fi
	done
	if [ -z "$where" ]; then
		echo "check-apk-pins: $n-$v: no index of $TREE/$ALPINE lists it (pruned from the published tree? See keep/keep.txt of tsx-aports)" >&2
		fail=1
	elif [ ! -s "$TREE/$ALPINE/$where/armv7/$n-$v.apk" ]; then
		echo "check-apk-pins: $n-$v: listed in $where, but $where/armv7/$n-$v.apk is not in $TREE/$ALPINE" >&2
		fail=1
	else
		echo "check-apk-pins: $n-$v: $where"
	fi
done
exit $fail
