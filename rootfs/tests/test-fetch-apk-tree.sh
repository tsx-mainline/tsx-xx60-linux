#!/bin/bash
# Host test for rootfs/fetch-apk-tree.sh. It makes a small published tree in a
# temporary folder, fetches it over file:// and checks the result. It needs no
# network and no root.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
FETCH=$HERE/fetch-apk-tree.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

# mkrepo REPO PKG...: a published folder with one index and the package files.
# A package is NAME-VERSION. The file holds NAME-VERSION as its text.
mkrepo() {
	local repo=$1; shift
	local d=$T/pub/v3.24/$repo/armv7 pkg name ver
	mkdir -p "$d"; : > "$T/APKINDEX"
	for pkg in "$@"; do
		name=${pkg%%=*}; ver=${pkg#*=}
		printf '%s\n' "$name-$ver" > "$d/$name-$ver.apk"
		printf 'C:Q1xx\nP:%s\nV:%s\nA:armv7\nS:%s\nI:0\nT:test\n\n' "$name" "$ver" "$(wc -c < "$d/$name-$ver.apk" | tr -d ' ')" >> "$T/APKINDEX"
	done
	tar -czf "$d/APKINDEX.tar.gz" -C "$T" APKINDEX
}
mkrepo common tsx-base=0.2.0-r2 tsx-keys=1-r0
mkrepo xx60 tsx-xx60-board=0.2.0-r1 tsx-xx60-board-ha=0.2.0-r1 tsx-xx60-console=0.2.0-r0

echo "== fetch the tree"
out=$("$FETCH" "$T/tree" "file://$T/pub" 2>&1); rc=$?
[ $rc = 0 ] && ok "exit 0" || bad "exit $rc: $out"
for f in common/armv7/tsx-base-0.2.0-r2.apk common/armv7/tsx-keys-1-r0.apk xx60/armv7/tsx-xx60-board-0.2.0-r1.apk \
	xx60/armv7/tsx-xx60-board-ha-0.2.0-r1.apk xx60/armv7/tsx-xx60-console-0.2.0-r0.apk common/armv7/APKINDEX.tar.gz xx60/armv7/APKINDEX.tar.gz; do
	[ -s "$T/tree/v3.24/$f" ] && ok "has $f" || bad "no $f"
done
[ "$(cat "$T/tree/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk")" = tsx-xx60-board-0.2.0-r1 ] && ok "a package of the same stem as its subpackage has the right content" || bad "wrong content"
echo "$out" | grep -q '^\[1/2\] ' && echo "$out" | grep -q '^\[3/3\] ' && ok "the output counts the files" || bad "no count in: $out"
ls "$T/tree/v3.24/common/armv7" "$T/tree/v3.24/xx60/armv7" | grep -q '\.part$\|^\.files$' && bad "temporary files stay" || ok "no temporary files stay"

echo "== a second run keeps the files"
out=$("$FETCH" "$T/tree" "file://$T/pub" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(echo "$out" | grep -c 'already here')" = 5 ] && ok "all 5 files are already here" || bad "second run (rc $rc): $out"

echo "== a missing package file stops the run"
rm -rf "$T/tree"; rm "$T/pub/v3.24/xx60/armv7/tsx-xx60-console-0.2.0-r0.apk"
out=$("$FETCH" "$T/tree" "file://$T/pub" 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q 'cannot get .*tsx-xx60-console-0.2.0-r0.apk' && ok "exit $rc and the message names the file" || bad "missing file (rc $rc): $out"
ls "$T/tree/v3.24/xx60/armv7" | grep -q '\.part$' && bad "a .part file stays" || ok "no .part file stays"

echo "== usage"
"$FETCH" >/dev/null 2>&1; [ $? = 2 ] && ok "no folder: exit 2" || bad "no folder is accepted"

echo "$N passed, $F failed"
[ "$F" = 0 ]
