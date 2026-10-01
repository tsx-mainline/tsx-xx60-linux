#!/bin/bash
# Host test: remote-build.sh must stop before it sends anything when an ignored
# or proprietary file is in a folder it copies, and ci/check-no-proprietary.sh
# must exit non-zero for a tarball with a .puf file. The test uses stub ssh
# and rsync programs. It contacts no host and compiles nothing.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../../.." && pwd)
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
GIT=(git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false)

# a temp copy of the committed tree, as a git checkout of its own
mkdir -p "$T/tsx-xx60-linux" "$T/bin"
git -C "$HERE" archive HEAD | tar -x -C "$T/tsx-xx60-linux"
R=$T/tsx-xx60-linux
(cd "$R" && git init -q && "${GIT[@]}" add -A && "${GIT[@]}" commit -qm base)

# stub ssh and rsync: log every call, do nothing
for c in ssh rsync; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
run() { (cd "$R" && PATH="$T/bin:$PATH" BUILD_HOST=stub.example BUILD_DIR=/stub/build timeout 60 tools/build/remote-build.sh "$@" 2>&1); }

# 1. a clean tree reaches the stub (sync sends and returns)
: > "$T/calls.log"
out=$(run sync); rc=$?
[ $rc = 0 ] && [ -s "$T/calls.log" ] && ok "clean tree: sync reaches ssh/rsync" || bad "clean tree was refused or sent nothing (rc=$rc): $out"

# 2. an ignored .puf in a folder that rootfs copies stops every entry point
mkdir -p "$R/rootfs/overlay/opt"; : > "$R/rootfs/overlay/opt/firmware.puf"
for cmd in rootfs initramfs image sync; do
	: > "$T/calls.log"
	out=$(run $cmd); rc=$?
	if [ $rc != 0 ] && [ ! -s "$T/calls.log" ] && grep -q 'firmware.puf' <<<"$out" && grep -q 'clean export or worktree' <<<"$out"; then
		ok "$cmd: refused, names the file, nothing sent"
	else bad "$cmd: rc=$rc calls=$(wc -l < "$T/calls.log"): $out"; fi
done
rm "$R/rootfs/overlay/opt/firmware.puf"

# 3. an untracked TFA container is refused too, an untracked normal file is not
: > "$R/rootfs/overlay/opt/stereo.cnt"
: > "$T/calls.log"; out=$(run rootfs); rc=$?
[ $rc != 0 ] && [ ! -s "$T/calls.log" ] && ok "untracked .cnt: refused" || bad "untracked .cnt not refused (rc=$rc)"
rm "$R/rootfs/overlay/opt/stereo.cnt"

# 4. the proprietary-file check exits non-zero for a tarball with a .puf
mkdir -p "$T/t/usr/local/share/tsx/tfa9890/x"; : > "$T/t/fw.puf"
tar czf "$T/bad.tar.gz" -C "$T/t" .
out=$("$HERE/ci/check-no-proprietary.sh" "$T/bad.tar.gz" 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'fw.puf' <<<"$out" && grep -q 'clean export or worktree' <<<"$out" && ok "check-no-proprietary: exit 1 with message" || bad "check did not stop (rc=$rc): $out"
mkdir -p "$T/c"; : > "$T/c/a.txt"; tar czf "$T/good.tar.gz" -C "$T/c" .
"$HERE/ci/check-no-proprietary.sh" "$T/good.tar.gz" >/dev/null 2>&1 && ok "check-no-proprietary: clean tarball passes" || bad "clean tarball failed"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-send-guard || echo FAIL test-send-guard
exit $F
