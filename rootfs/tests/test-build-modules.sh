#!/bin/bash
# Host test: the "modules" step of rootfs/build-rootfs.sh stages the tree of
# one flavor. It does not remove the tree of the other flavor
# (tools/build/README.md "Both kernel flavors in one rootfs"). The test needs
# no kernel build and no docker. It uses two fake kernel build dirs
# (kernel.release, modules.order/builtin, and one *.ko with a vermagic
# string). A stub `docker` is first in PATH (the real one only strips the
# copied *.ko). The test works on a copy of rootfs/build-rootfs.sh, so it
# never touches rootfs/modules/ of the checkout.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

# build-rootfs.sh's TOP (two levels up) is $W: $W/build-<flavor> are the
# default flavor build dirs kbuild.sh would make there
mkdir -p "$W/repo/rootfs" "$W/bin"
cp "$HERE/build-rootfs.sh" "$W/repo/rootfs/"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/docker"; chmod +x "$W/bin/docker"
fakebuild() {   # DIR RELEASE
	mkdir -p "$1/include/config" "$1/drivers/x"
	echo "$2" > "$1/include/config/kernel.release"
	printf 'junk\0vermagic=%s SMP mod_unload ARMv7\0' "$2" > "$1/drivers/x/x.ko"
	echo "drivers/x/x.o" > "$1/modules.order"; : > "$1/modules.builtin"
}
fakebuild "$W/build-lts" 6.18.54-00112-gaaaa
fakebuild "$W/build-stable" 7.2.8-00110-gbbbb
M=$W/repo/rootfs/modules/lib/modules
run() { PATH="$W/bin:$PATH" KBUILD="$1" "$W/repo/rootfs/build-rootfs.sh" modules >"$W/out.txt" 2>&1; }

echo "== 1. lts, then stable: both trees staged"
run "$W/build-lts" && ok "lts modules staged" || bad "lts modules failed: $(cat "$W/out.txt")"
run "$W/build-stable" && ok "stable modules staged" || bad "stable modules failed: $(cat "$W/out.txt")"
[ -f "$M/6.18.54-00112-gaaaa/kernel/drivers/x/x.ko" ] && ok "lts tree kept after the stable run" || bad "lts tree gone: $(ls "$M")"
[ -f "$M/7.2.8-00110-gbbbb/kernel/drivers/x/x.ko" ] && ok "stable tree present" || bad "stable tree missing"
[ "$(wc -l < "$W/repo/rootfs/modules/SOURCE")" = 2 ] && ok "SOURCE has one line per release" || bad "SOURCE: $(cat "$W/repo/rootfs/modules/SOURCE")"

echo "== 2. a newer lts build replaces the older lts tree only"
fakebuild "$W/build-lts" 6.18.55-00001-gcccc
run "$W/build-lts" && ok "new lts modules staged" || bad "new lts failed: $(cat "$W/out.txt")"
[ ! -d "$M/6.18.54-00112-gaaaa" ] && ok "older lts tree removed" || bad "older lts tree still staged"
[ -d "$M/6.18.55-00001-gcccc" ] && [ -d "$M/7.2.8-00110-gbbbb" ] && ok "new lts + stable staged" || bad "staged: $(ls "$M")"
grep -q '^6.18.54' "$W/repo/rootfs/modules/SOURCE" && bad "SOURCE still names the removed tree" || ok "SOURCE dropped the removed tree"
[ "$(ls "$M" | wc -l)" = 2 ] && ok "exactly two trees" || bad "trees: $(ls "$M")"

echo "== 3. stale modules (vermagic != kernel.release) are refused, nothing removed"
printf 'junk\0vermagic=7.2.7 SMP\0' > "$W/build-stable/drivers/x/x.ko"
run "$W/build-stable" && bad "stale modules accepted" || ok "stale modules refused"
[ -d "$M/7.2.8-00110-gbbbb" ] && ok "the staged stable tree is untouched" || bad "stable tree removed by a refused run"

echo "== 4. no KBUILD: every default flavor build dir (build-lts, build-stable) is staged"
rm -rf "$W/repo/rootfs/modules"
fakebuild "$W/build-stable" 7.2.8-00110-gbbbb
PATH="$W/bin:$PATH" "$W/repo/rootfs/build-rootfs.sh" modules >"$W/out.txt" 2>&1 && ok "modules with no KBUILD" || bad "modules with no KBUILD failed: $(cat "$W/out.txt")"
[ -d "$M/6.18.55-00001-gcccc" ] && [ -d "$M/7.2.8-00110-gbbbb" ] && ok "both flavors staged in one run" || bad "staged: $(ls "$M" 2>&1)"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-build-modules || echo FAIL test-build-modules
exit $F
