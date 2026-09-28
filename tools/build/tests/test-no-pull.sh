#!/bin/bash
# Host test: remote-build.sh's --no-pull / REMOTE_PULL=0 opt-out (README.md
# "Remote build (optional)"). No ssh/rsync needed for this one: the arg
# parser and maybe_pull() are self-contained, so pull them out of the real
# script (same technique as test-push-protect.sh's PROTECT= extraction) and
# exercise them directly with a stub pull().
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

# --- the arg-parsing block: DEST=... through "set -- ${ARGS[@]}" ----------
argblock=$(sed -n '/^DEST= MODS=0/,/^set -- "\${ARGS\[@\]}"$/p' "$HERE/remote-build.sh")
[ -n "$argblock" ] || { echo "FAIL: could not extract the arg-parsing block from remote-build.sh"; exit 1; }

run_args() {  # run_args ARG... ; prints "PULL=x CMD=y" after parsing
	bash -c "$argblock"$'\n''CMD=${1:-}; echo "PULL=$PULL CMD=$CMD"' -- "$@"
}

[ "$(run_args rootfs)" = "PULL=1 CMD=rootfs" ] && ok "default: PULL=1" || bad "default PULL wrong: $(run_args rootfs)"
[ "$(run_args --no-pull rootfs)" = "PULL=0 CMD=rootfs" ] && ok "--no-pull sets PULL=0" || bad "--no-pull did not set PULL=0: $(run_args --no-pull rootfs)"
[ "$(REMOTE_PULL=0 bash -c "$argblock"$'\n''echo "PULL=$PULL"' -- rootfs)" = "PULL=0" ] && ok "REMOTE_PULL=0 sets PULL=0" || bad "REMOTE_PULL=0 ignored"
[ "$(REMOTE_PULL=0 bash -c "$argblock"$'\n''echo "PULL=$PULL"' -- --no-pull rootfs)" = "PULL=0" ] && ok "--no-pull and REMOTE_PULL=0 agree" || bad "--no-pull/REMOTE_PULL=0 combo wrong"

# --- maybe_pull() itself: PULL=1 pulls, PULL=0 prints and leaves things put ---
fn=$(sed -n '/^maybe_pull() {/,/^}$/p' "$HERE/remote-build.sh")
[ -n "$fn" ] || { echo "FAIL: could not extract maybe_pull() from remote-build.sh"; exit 1; }

out=$(HOST=buildhost.example PULL=1 bash -c "
say() { :; }
pull() { echo \"PULLED: \$*\"; }
$fn
maybe_pull /local/dest /remote/a /remote/b
")
[ "$out" = "PULLED: /local/dest /remote/a /remote/b" ] && ok "PULL=1: delegates to pull() with all args" || bad "PULL=1 behavior wrong: $out"

out=$(HOST=buildhost.example PULL=0 bash -c "
say() { echo \"SAY: \$*\"; }
pull() { echo \"PULLED: \$*\"; }
$fn
maybe_pull /local/dest /remote/a /remote/b
")
echo "$out" | grep -q '^PULLED:' && bad "PULL=0 must not call pull(): $out"
echo "$out" | grep -qF '/local/dest' && bad "PULL=0 must not print the (unused) local dest dir: $out"
echo "$out" | grep -qF 'buildhost.example:/remote/a' && echo "$out" | grep -qF 'buildhost.example:/remote/b' \
	&& ok "PULL=0: prints where each artifact is on the host, does not pull" \
	|| bad "PULL=0 did not report both remote paths: $out"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-no-pull || echo FAIL test-no-pull
exit $F
