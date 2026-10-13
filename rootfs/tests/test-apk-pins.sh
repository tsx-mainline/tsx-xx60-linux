#!/bin/bash
# Host test for rootfs/check-apk-pins.sh. It makes a small tree with the pins
# of rootfs/initramfs/packages.pin in a temporary folder. It needs no network
# and no root.
#   1. Every pin in an index and in the tree: exit 0.
#   2. A pin whose file is still there (a cache) but no index lists it: exit 1.
#   3. A pin that an index lists but whose file is missing: exit 1.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$HERE/check-apk-pins.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
PINS=$(grep -v -e '^#' -e '^[[:space:]]*$' "$HERE/initramfs/packages.pin")
BOARD=$(printf '%s\n' "$PINS" | grep '^tsx-xx60-board=')
[ -n "$BOARD" ] || { echo "FAIL: packages.pin has no tsx-xx60-board"; exit 1; }
# mktree SKIP: a tree with every pin (tsx-xx60-* in xx60, the rest in common).
# The index leaves out the pin SKIP, but its file is there.
mktree() {
	local skip=$1 pin n v c
	rm -rf "$T/tree"; mkdir -p "$T/tree/v3.24/common/armv7" "$T/tree/v3.24/xx60/armv7"
	: > "$T/common.idx"; : > "$T/xx60.idx"
	for pin in $PINS; do
		n=${pin%%=*} v=${pin#*=}
		case $n in tsx-xx60-*) c=xx60;; *) c=common;; esac
		echo "$n-$v" > "$T/tree/v3.24/$c/armv7/$n-$v.apk"
		[ "$pin" = "$skip" ] || printf 'P:%s\nV:%s\nA:armv7\n\n' "$n" "$v" >> "$T/$c.idx"
	done
	# a newer version of the board in the index too
	printf 'P:tsx-xx60-board\nV:9.9.9-r0\nA:armv7\n\n' >> "$T/xx60.idx"
	for c in common xx60; do cp "$T/$c.idx" "$T/APKINDEX"; tar -czf "$T/tree/v3.24/$c/armv7/APKINDEX.tar.gz" -C "$T" APKINDEX; done
}
busybox sh -n "$CHECK" && ok "busybox sh -n" || bad "busybox sh -n"
echo "== 1. every pin is there"
mktree none
out=$(sh "$CHECK" "$T/tree" 2>&1); rc=$?
[ $rc = 0 ] && ok "exit 0" || bad "exit $rc: $out"
[ "$(echo "$out" | grep -c ': common$\|: xx60$')" = "$(printf '%s\n' "$PINS" | wc -l)" ] && ok "one line for each pin" || bad "lines: $out"
echo "== 2. the board pin is pruned from the index, its file is still in the tree (a cache)"
mktree "$BOARD"
out=$(sh "$CHECK" "$T/tree" 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "^check-apk-pins: ${BOARD%%=*}-${BOARD#*=}: no index of .* lists it" && ok "exit 1, the line names the pin" || bad "exit $rc: $out"
echo "== 3. the index lists the board pin, the file is missing"
mktree none; rm "$T/tree/v3.24/xx60/armv7/${BOARD%%=*}-${BOARD#*=}.apk"
out=$(sh "$CHECK" "$T/tree" 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "listed in xx60, but" && ok "exit 1, the file is missing" || bad "exit $rc: $out"
grep -q 'check-apk-pins.sh' "$HERE/build-rootfs.sh" && ok "build-rootfs.sh initramfs runs the check" || bad "build-rootfs.sh does not run the check"
echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-apk-pins || echo FAIL test-apk-pins
exit $F
