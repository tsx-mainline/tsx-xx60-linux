#!/bin/bash
# Host test: the host side of the installer with busybox tools. The installer
# runs on any Linux machine with bash and the tools of docs/install.md "Host
# requirements". On some machines (Alpine, a mainline panel) tar, find,
# sha256sum, du, stat and gzip are the busybox applets, not the GNU tools.
# This test puts busybox versions of them first in PATH and runs the push
# and stage tests again:
#   1. installer/tests/test-install-push.sh (tsx_push_dir, tsx_push_bundle,
#      the rescue screen of a push)
#   2. installer/tests/test-install-stage.sh (root.img.gz, the stage folder,
#      the stage copy to a kiosk, the runner)
#   3. tsx_tar_c: GNU tar gets --owner=0 --group=0, busybox tar does not
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
BB=$(command -v busybox) || { echo "SKIPPED test-install-busybox: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
mkdir -p "$W/bb"
for t in tar find sha256sum du stat gzip; do
	"$BB" --list | grep -x "$t" >/dev/null || { echo "SKIPPED test-install-busybox: busybox has no $t"; exit 0; }
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

echo "== tsx-config on a host that is a panel"
# A host with /run/tsx/hw.conf (a panel with no camera) must not change the
# checks of the panel.conf of the target.
mkdir -p "$W/hostrun/tsx"; echo "CAMERA=no" > "$W/hostrun/tsx/hw.conf"
OUT=$(TSX_RUN=$W/hostrun bash -c '. "$1"; TSX_CONF="$2" "$TSX_CONFIG_BIN" set CAMERA snapshot 2>&1; rm -rf "$TSX_CONFIG_STAGE"' _ "$HERE/lib/tsx-config-prompt.sh" "$W/target.conf")
case "$OUT" in *"no camera"*) bad "the hw.conf of the host changed the check: $OUT";; *) grep -q '^CAMERA="*snapshot' "$W/target.conf" && ok "the hw.conf of the host does not count" || bad "set CAMERA: $OUT $(cat "$W/target.conf")";; esac
OUT=$(TSX_RUN=$W/hostrun bash -c '. "$1"; TSX_HW_CONF=$3 TSX_CONF="$2" "$TSX_CONFIG_BIN" set CAMERA snapshot 2>&1; rm -rf "$TSX_CONFIG_STAGE"' _ "$HERE/lib/tsx-config-prompt.sh" "$W/t2.conf" "$W/hostrun/tsx/hw.conf")
case "$OUT" in *"no camera"*) ok "control: with that hw.conf, tsx-config warns about the camera";; *) bad "control: no warning with the hw.conf: $OUT";; esac

echo "== the shebang of the host scripts"
# A machine can have bash in another folder than /bin (an Alpine panel with a
# bash in /tmp, NixOS). The drivers start these scripts directly, so they use
# /usr/bin/env bash, not /bin/bash.
for f in tsx-install-mainline tsx-restore-factory tsx-make-stick steps/tsx-ensure-root steps/rootsh steps/crestron-admin \
	steps/tsx-deploy-tfa.sh factory/mkbundle.sh steps/legacy/tsx-android-to-card steps/legacy/tsx-card-to-emmc; do
	case "$(head -n 1 "$HERE/$f")" in '#!/usr/bin/env bash'|'#!/bin/sh') ok "$f: $(head -n 1 "$HERE/$f")";; *) bad "$f starts with $(head -n 1 "$HERE/$f")";; esac
done

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-busybox || echo FAIL test-install-busybox
exit $F
