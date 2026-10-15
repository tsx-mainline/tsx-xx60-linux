#!/bin/bash
# Host test: the host side of the installer with the tools of a mainline
# panel (a seed panel, docs/install.md "Install from another panel"). A panel
# has busybox tar, find, sha256sum, du, stat and gzip, not the GNU tools of a
# PC. This test puts busybox versions of them first in PATH and runs the push
# and stage tests again:
#   1. installer/tests/test-install-push.sh (tsx_push_dir, tsx_push_bundle,
#      the rescue screen of a push)
#   2. installer/tests/test-install-stage.sh (root.img.gz, the stage folder,
#      the stage copy to a kiosk, the runner)
#   3. tsx_tar_c: GNU tar gets --owner=0 --group=0, busybox tar does not
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
BB=$(command -v busybox) || { echo "SKIPPED test-install-seed: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
mkdir -p "$W/bb"
for t in tar find sha256sum du stat gzip; do
	"$BB" --list | grep -qx "$t" || { echo "SKIPPED test-install-seed: busybox has no $t"; exit 0; }
	ln -s "$BB" "$W/bb/$t"
done
export PATH="$W/bb:$PATH"
[ "$(readlink -f "$(command -v tar)")" = "$(readlink -f "$BB")" ] && ok "tar, find, sha256sum, du, stat and gzip are busybox now" || bad "PATH"

for t in test-install-push test-install-stage; do
	echo "== $t with the busybox tools"
	if bash "$HERE/tests/$t.sh" > "$W/$t.log" 2>&1; then ok "$t: $(tail -n 1 "$W/$t.log")"
	else bad "$t: $(grep FAIL "$W/$t.log" | head -n 5 | tr '\n' ' ')"; fi
done

echo "== tsx_tar_c"
. "$HERE/lib/tsx-rescue.sh"
mkdir -p "$W/src"; echo x > "$W/src/f"
tsx_tar_c -C "$W/src" -cf "$W/a.tar" f && "$BB" tar -tf "$W/a.tar" | grep -qx f && ok "busybox tar: an archive without --owner" || bad "busybox tar_c"
if tar_gnu=$(PATH=${PATH#"$W/bb:"} command -v tar) && "$tar_gnu" --help 2>&1 | grep -q -- '--owner='; then
	PATH=${PATH#"$W/bb:"} bash -c '. "$1"; tsx_tar_c -C "$2" -cf "$3" f' _ "$HERE/lib/tsx-rescue.sh" "$W/src" "$W/g.tar" \
		&& "$tar_gnu" -tvf "$W/g.tar" | grep -q ' root/root ' && ok "GNU tar: the owner in the archive is root" || bad "GNU tar_c: $("$tar_gnu" -tvf "$W/g.tar")"
else
	echo "  skip: no GNU tar on this host"
fi

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-seed || echo FAIL test-install-seed
exit $F
