#!/bin/bash
# Host test: builds three THROWAWAY git repos (never the real tsx-mainline
# ones) in a tmp dir. It plants one issue of each kind that prepare-publish.sh
# must catch: a leak, an AI-attribution trailer, a private key and a bare
# .rsa, a proprietary filename, a big blob, and a local-only tag. It also
# builds a clean control. Then it runs the real script against the repos
# with --repo overrides. The test needs no ssh and no network, and it adds no
# remote to any real repo.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/prepare-publish.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIPPED test-prepare-publish: no git"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkrepo() { mkdir -p "$W/$1"; git -C "$W/$1" init -q; git -C "$W/$1" config user.name t; git -C "$W/$1" config user.email t@example.com; }

# --- xx60-linux fixture: a dirty "import" history. A leak is added and later
# removed. The squash must still produce a single commit without the leak,
# because it takes only the CURRENT tree of import and not its history. ------
mkrepo xxl; cd "$W/xxl"
git checkout -q -b import
echo ok > README; git add README; git commit -q -m init
mkdir sec; printf '10.1.%d.186 leak\n' 4 > sec/x; git add sec; git commit -q -m "leak"
git rm -q -r sec; git commit -q -m "remove leak (still in history)"
cd "$W"

# --- aports fixture: clean "main" -----------------------------------------
mkrepo aports; cd "$W/aports"
git checkout -q -b main
echo ok > README; git add README; git commit -q -m init
cd "$W"

# --- linux fixture: an upstream remote + one dirty branch, one clean ------
mkrepo upstream; cd "$W/upstream"
git checkout -q -b master; echo up > b; git add b; git commit -q -m base
cd "$W"
git clone -q "$W/upstream" linux
cd "$W/linux"; git remote rename origin torvalds
git checkout -q -b tsx-xx60-6.18 torvalds/master
echo f > feature; git add feature; git commit -q -m "feature: fine"
# built from split words so this line never spells the AI-attribution/leak
# patterns it exists to exercise (see leak-patterns.txt / REPO-RULES.md)
trailer_k="Co-Authored-By:"; trailer_v="Cla""ude"
mail_a="noreply@anthro""pic"; mail_b=".com"
git commit -q --allow-empty -m "$(printf 'oops\n\n%s %s <%s%s>\n' "$trailer_k" "$trailer_v" "$mail_a" "$mail_b")"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n' > id.rsa
git add id.rsa; git commit -q -m "oops key"
dd if=/dev/zero of=big.bin bs=1M count=3 status=none 2>/dev/null
git add big.bin; git commit -q -m "oops big blob"
: > sshShell.sh; git add sshShell.sh; git commit -q -m "oops proprietary"
git tag local/scratch; git tag pre-scrub-v1
git checkout -q -b tsx-xx60-7.2 torvalds/master
echo f > feature72; git add feature72; git commit -q -m "feature: clean flavor"
cd "$W"

cat > "$W/fixture-patterns.txt" <<'EOF'
# fixture patterns only, not the real project's
\b10\.1\.[0-9]{1,3}\.[0-9]{1,3}\b
EOF

run() { "$SCRIPT" --leak-patterns "$W/fixture-patterns.txt" --repo xx60-linux="$W/xxl" \
        --repo aports="$W/aports" --repo linux="$W/linux" "$@"; }

# --- squash: a clean single commit, no trace of the removed-but-still- ----
# -in-history leak, correct author -----------------------------------------
out=$(run --squash-branch squashed --linux-branch tsx-xx60-7.2 2>&1); rc=$?
echo "$out" | grep -q 'squash: refs/heads/squashed' && ok "squash branch created" || bad "no squash message in output"
[ "$(git -C "$W/xxl" rev-list --count squashed)" = 1 ] && ok "squash branch has exactly one commit" || bad "squash branch commit count wrong"
git -C "$W/xxl" log -1 --format='%an <%ae>' squashed | grep -qF 'unex <7575866+unex@users.noreply.github.com>' \
	&& ok "squash commit authored as unex" || bad "squash commit author wrong"
[ "$(git -C "$W/xxl" branch --show-current)" != "squashed" ] && ok "squash never checked out a branch (no working tree touched)" || bad "squash switched HEAD"
echo "$out" | grep -q '^-- tsx-xx60-linux:squashed' && echo "$out" | sed -n '/^-- tsx-xx60-linux:squashed/,/^$/p' | grep -q 'ok: no leak-pattern hits' \
	&& ok "squashed xx60-linux scans clean (the old leak was squashed away)" || bad "squashed xx60-linux still shows a leak"
[ "$rc" = 0 ] && ok "clean-only run (7.2 branch, which is clean) exits 0" || bad "expected exit 0 for the clean-only run, got $rc"

# --- dirty linux branch: every category must be caught --------------------
out=$(run --squash-branch squashed2 --linux-branch tsx-xx60-6.18 2>&1); rc=$?
[ "$rc" = 1 ] && ok "dirty run exits 1" || bad "expected exit 1 for the dirty run, got $rc"
echo "$out" | grep -q 'AI ATTRIBUTION hits' && echo "$out" | grep -qi 'claude' && ok "AI-attribution trailer caught" || bad "AI-attribution trailer missed"
echo "$out" | grep -q 'PRIVATE KEY hits' && echo "$out" | grep -q 'BEGIN RSA PRIVATE KEY' && echo "$out" | grep -q 'id.rsa (no matching .pub)' \
	&& ok "PEM block and bare .rsa both caught" || bad "private-key check missed something"
echo "$out" | grep -q 'PROPRIETARY FILE hits' && echo "$out" | grep -q 'sshShell.sh' && ok "proprietary filename caught" || bad "sshShell.sh not caught"
echo "$out" | grep -q 'LARGE BLOB hits' && echo "$out" | grep -q 'big.bin' && ok "large blob caught" || bad "large blob not caught"
echo "$out" | grep -q 'local/pre-scrub-\* tags present\|local-only tags present' && echo "$out" | grep -q 'local/scratch' && echo "$out" | grep -q 'pre-scrub-v1' \
	&& ok "local/pre-scrub-* tags reported" || bad "bad tags not reported"

# --- an empty (--allow-empty) commit must not be silently skipped by the --
# history walk (a pathspec on git log/rev-list prunes TREESAME commits.
# This is what the AI-attribution assertion above already exercises, but
# assert directly that the commit is not just accidentally absent upstream) -
git -C "$W/linux" log --oneline tsx-xx60-6.18 | grep -q '^[0-9a-f]* oops$' && ok "fixture's empty commit exists on the branch" || bad "test fixture itself is wrong"

# --- never pushes, never adds a remote -------------------------------------
echo "$out" | grep -q '^git push ' && ok "prints push commands" || bad "no push commands printed"
[ "$(git -C "$W/xxl" remote)" = "" ] && ok "xx60-linux fixture: no remote added" || bad "a remote was added to xx60-linux fixture"
[ "$(git -C "$W/aports" remote)" = "" ] && ok "aports fixture: no remote added" || bad "a remote was added to aports fixture"
[ "$(git -C "$W/linux" remote)" = "torvalds" ] && ok "linux fixture: still just its one fixture remote" || bad "linux fixture remotes changed"

# --- the .git of a linked worktree is a FILE, not a directory. Several
# worktrees share one .git in the real repos that this script scans. The
# script must not treat such a worktree as "no repo here". ------------------
git -C "$W/xxl" worktree add -q -b wt-check "$W/xxl-wt" import
out=$(run --repo xx60-linux="$W/xxl-wt" --skip-squash --squash-branch import 2>&1)
echo "$out" | grep -q 'no repo at' && bad "a linked worktree was reported as \"no repo\"" || ok "a linked worktree scans normally (not skipped)"

# --- --leak-patterns is required -------------------------------------------
"$SCRIPT" --repo xx60-linux="$W/xxl" >/tmp/pp-missing-arg.$$ 2>&1; rc=$?
[ "$rc" != 0 ] && ok "refuses to run without --leak-patterns" || bad "ran without --leak-patterns"
rm -f "/tmp/pp-missing-arg.$$"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-prepare-publish || echo FAIL test-prepare-publish
exit $F
