#!/bin/bash
# Push-day prep: squash tsx-xx60-linux's "import" branch tree into one clean
# commit, then scan every repo that would be pushed for the things that must
# never leave this workstation. Prints a report and the exact push commands
# a person would run -- this script never pushes, never adds a remote, and
# never touches an existing branch other than the squash target.
#
#   tools/release/prepare-publish.sh --leak-patterns PATH [options]
#
# Required:
#   --leak-patterns PATH   extended-regex (case-insensitive) patterns file,
#                          one per line, '#'/blank ignored (see
#                          local-tools/leak-patterns.txt in this project --
#                          NOT part of this repo; the path is yours to give).
#                          Its content is read into a throwaway temp file for
#                          grep -f and never written anywhere else.
#
# Options:
#   --squash-branch NAME   branch this script (re)creates from import's tree
#                          (default: publish-candidate)
#   --skip-squash          scan only, do not create/update the squash branch
#   --max-blob-size BYTES  flag tracked blobs bigger than this (default: 2097152 = 2 MiB)
#   --repo NAME=PATH       override a repo path, repeatable; NAME is one of
#                          xx60-linux, aports, linux (default: this repo,
#                          ../tsx-aports, ../linux -- the sibling layout used
#                          by tools/build/remote-build.sh)
#   --linux-branch BRANCH  a branch of the "linux" repo to scan, repeatable
#                          (default: tsx-xx60-6.18 tsx-xx60-7.2 tsx-xx60 --
#                          any that do not exist are skipped, silently)
#   --linux-upstream-remote NAME  a remote of the "linux" repo whose history
#                          counts as already-public (repeatable; default:
#                          torvalds stable linux-next xdarklight -- commits
#                          reachable from one of these are NOT re-scanned,
#                          same convention as local-tools/leak-hook.sh's
#                          pre-push hook: "git log <tip> --not --remotes")
#   --push-url NAME=URL    override the URL printed in the push command for
#                          a repo (default: https://github.com/tsx-mainline/<repo-dirname>,
#                          the org this project already publishes docs
#                          under -- see README.md / docs/kernel.md)
#
# Exit status: 0 if the squash (unless skipped) succeeded and every scan came
# back clean; 1 if any repo/category found something. Either way the full
# report is printed; nothing is pushed and nothing beyond the squash branch
# is written.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)          # .../tsx-xx60-linux
TOP=$(cd "$REPO/.." && pwd)

LEAKPATS= SQUASH_BRANCH=publish-candidate DO_SQUASH=1 MAXBLOB=2097152
declare -A REPOPATH=( [xx60-linux]="$REPO" [aports]="$TOP/tsx-aports" [linux]="$TOP/linux" )
declare -A PUSHURL=( [xx60-linux]="https://github.com/tsx-mainline/tsx-xx60-linux" \
                     [aports]="https://github.com/tsx-mainline/tsx-aports" \
                     [linux]="https://github.com/tsx-mainline/linux" )
LINUX_BRANCHES=(tsx-xx60-6.18 tsx-xx60-7.2 tsx-xx60)
UPSTREAM_REMOTES=(torvalds stable linux-next xdarklight)
LINUX_BRANCHES_SET=0 UPSTREAM_REMOTES_SET=0

while [ $# -gt 0 ]; do case $1 in
	--leak-patterns) LEAKPATS=$2; shift;;
	--squash-branch) SQUASH_BRANCH=$2; shift;;
	--skip-squash) DO_SQUASH=0;;
	--max-blob-size) MAXBLOB=$2; shift;;
	--repo) k=${2%%=*}; REPOPATH[$k]=${2#*=}; shift;;
	# first --linux-branch/--linux-upstream-remote replaces the built-in
	# default list; later ones append to what the user is building up.
	--linux-branch) [ "$LINUX_BRANCHES_SET" = 1 ] || { LINUX_BRANCHES=(); LINUX_BRANCHES_SET=1; }
	                LINUX_BRANCHES+=("$2"); shift;;
	--linux-upstream-remote) [ "$UPSTREAM_REMOTES_SET" = 1 ] || { UPSTREAM_REMOTES=(); UPSTREAM_REMOTES_SET=1; }
	                UPSTREAM_REMOTES+=("$2"); shift;;
	--push-url) k=${2%%=*}; PUSHURL[$k]=${2#*=}; shift;;
	-h|--help) sed -n '2,45p' "$0"; exit 0;;
	*) echo "prepare-publish: unknown option $1" >&2; exit 1;; esac; shift; done

[ -n "$LEAKPATS" ] || { echo "prepare-publish: --leak-patterns PATH is required" >&2; exit 1; }
[ -r "$LEAKPATS" ] || { echo "prepare-publish: cannot read $LEAKPATS" >&2; exit 1; }

say() { echo "[prepare-publish] $*"; }
FAIL=0

# --- leak-patterns file -> a throwaway grep -f file (comments/blanks out); ---
# never copied anywhere that could end up committed.
patf=$(mktemp); trap 'rm -f "$patf"' EXIT
grep -v -e '^#' -e '^[[:space:]]*$' "$LEAKPATS" > "$patf"
[ -s "$patf" ] || { echo "prepare-publish: $LEAKPATS has no usable patterns" >&2; exit 1; }

# built into this script (not private data -- generic AI-attribution wording,
# the same thing REPO-RULES.md already tells every agent to keep out). One
# per line, like the leak-patterns file, so grep -f treats each as its own
# alternative instead of one pattern with literal embedded newlines.
aipatf=$(mktemp); trap 'rm -f "$patf" "$aipatf"' EXIT
cat > "$aipatf" <<'AIPATS'
co-authored-by:.*cla[u]de
generated (with|by).*claude
claude[ -]?code
noreply@anthropic\.com
anthropic\.com/claude
🤖
AIPATS

# ---------------------------------------------------------------------------
# squash: tsx-xx60-linux only. Builds a brand-new commit (no parent) from
# import's current tree with a clean message, and points $SQUASH_BRANCH at
# it. Never checks out anything, so it never switches any worktree's branch
# (several worktrees share this .git -- REPO-RULES.md).
# ---------------------------------------------------------------------------
squash_xx60_linux() {
	local repo=${REPOPATH[xx60-linux]} tree commit
	git -C "$repo" rev-parse --verify import >/dev/null 2>&1 || { echo "prepare-publish: $repo has no 'import' branch"; FAIL=1; return; }
	tree=$(git -C "$repo" rev-parse import^{tree})
	commit=$(GIT_AUTHOR_NAME=unex GIT_AUTHOR_EMAIL=7575866+unex@users.noreply.github.com \
	         GIT_COMMITTER_NAME=unex GIT_COMMITTER_EMAIL=7575866+unex@users.noreply.github.com \
	         git -C "$repo" commit-tree "$tree" -m "tsx-xx60-linux: mainline port for the Crestron TSW/TSS-x60 panels")
	git -C "$repo" update-ref "refs/heads/$SQUASH_BRANCH" "$commit"
	say "squash: refs/heads/$SQUASH_BRANCH -> $commit (1 commit, import's current tree)"
}

# ---------------------------------------------------------------------------
# scan_range REPO_KEY LABEL REV...   -- REV... is what "git log" takes to
# enumerate the commits that would actually be pushed (a full-history REF for
# a repo with no remotes yet, or "BRANCH --not --remotes=U1 --remotes=U2 .."
# to scan only what is not already reachable from a known-public remote --
# the same idiom local-tools/leak-hook.sh's pre-push hook already uses).
# ---------------------------------------------------------------------------
scan_range() {
	local key=$1 label=$2; shift 2
	local repo=${REPOPATH[$key]}
	# -e, not -d: a linked worktree's .git is a FILE pointing at the shared gitdir.
	git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "  ($label: no repo at $repo, skipped)"; return; }
	git -C "$repo" rev-parse --verify "$1" >/dev/null 2>&1 || { echo "  ($label: no such ref '$1', skipped)"; return; }
	local -a rev=("$@")
	echo "-- $label ($repo, ${rev[*]}) --"

	local hits
	hits=$(git -C "$repo" log -p --no-color --format='%an %ae%n%cn %ce%n%B' "${rev[@]}" 2>/dev/null \
	       | grep -v -e '^-' -e '^ ' | grep -n -i -E -f "$patf")
	if [ -n "$hits" ]; then echo "  LEAK PATTERN hits:"; echo "$hits" | sed 's/^/    /' | head -20; FAIL=1
	else echo "  ok: no leak-pattern hits"; fi

	hits=$(git -C "$repo" log -p --no-color --format='%an %ae%n%cn %ce%n%B' "${rev[@]}" 2>/dev/null \
	       | grep -v -e '^-' -e '^ ' | grep -n -i -E -f "$aipatf")
	if [ -n "$hits" ]; then echo "  AI ATTRIBUTION hits:"; echo "$hits" | sed 's/^/    /' | head -20; FAIL=1
	else echo "  ok: no AI-attribution lines"; fi

	hits=$(git -C "$repo" log -p --no-color "${rev[@]}" 2>/dev/null \
	       | grep '^+' | grep -v '^+++' \
	       | grep -n -E -- '-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----')
	local tip=${rev[0]}
	local rsahits
	rsahits=$(git -C "$repo" ls-tree -r --name-only "$tip" -- . 2>/dev/null | grep -E '\.rsa$' | while read -r f; do
		git -C "$repo" cat-file -e "$tip:$f.pub" 2>/dev/null || echo "$f (no matching .pub)"
	done)
	if [ -n "$hits$rsahits" ]; then
		echo "  PRIVATE KEY hits:"; [ -n "$hits" ] && echo "$hits" | sed 's/^/    PEM: /' | head -10
		[ -n "$rsahits" ] && echo "$rsahits" | sed 's/^/    .rsa: /'
		FAIL=1
	else echo "  ok: no private-key material"; fi

	hits=$(git -C "$repo" log --diff-filter=A --name-only --format= "${rev[@]}" 2>/dev/null | sort -u \
	       | grep -i -E '\.(puf|cnt|img|ext4)$|(^|/)sshShell\.sh$|(^|/)vendor-(local|cache|bin)/')
	if [ -n "$hits" ]; then echo "  PROPRIETARY FILE hits (ever added):"; echo "$hits" | sed 's/^/    /'; FAIL=1
	else echo "  ok: no proprietary file names in history"; fi

	hits=$(git -C "$repo" rev-list --objects "${rev[@]}" 2>/dev/null \
	       | git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' 2>/dev/null \
	       | awk -v m="$MAXBLOB" '$2=="blob" && $3+0>m {printf "    %s bytes  %s\n",$3,$4}')
	if [ -n "$hits" ]; then echo "  LARGE BLOB hits (> $MAXBLOB bytes):"; echo "$hits"; FAIL=1
	else echo "  ok: no blob over $MAXBLOB bytes"; fi

	local tags
	tags=$(git -C "$repo" tag -l 'local/*' 'pre-scrub-*')
	if [ -n "$tags" ]; then echo "  NOTE: local-only tags present (do not push with --tags/--all): $(echo "$tags" | tr '\n' ' ')"
	else echo "  ok: no local/pre-scrub-* tags"; fi
}

say "repos: xx60-linux=${REPOPATH[xx60-linux]} aports=${REPOPATH[aports]} linux=${REPOPATH[linux]}"

if [ "$DO_SQUASH" = 1 ]; then squash_xx60_linux; else say "--skip-squash: not touching $SQUASH_BRANCH"; fi

echo
echo "=== scan ==="
scan_range xx60-linux "tsx-xx60-linux:$SQUASH_BRANCH" "$SQUASH_BRANCH"
echo
scan_range aports "tsx-aports:main" main
echo
for br in "${LINUX_BRANCHES[@]}"; do
	notargs=(); for u in "${UPSTREAM_REMOTES[@]}"; do notargs+=(--remotes="$u"); done
	scan_range linux "linux:$br" "$br" --not "${notargs[@]}"
	echo
done

echo "=== report ==="
if [ "$FAIL" = 0 ]; then say "clean: nothing found across all repos/categories scanned above"
else say "ISSUES FOUND above -- fix them (edit content, never bypass the leak-hook) before anyone pushes"; fi

echo
echo "=== push commands (not run) ==="
echo "git push ${PUSHURL[xx60-linux]} $SQUASH_BRANCH:main"
echo "git push ${PUSHURL[aports]} main"
lb=(); for br in "${LINUX_BRANCHES[@]}"; do git -C "${REPOPATH[linux]}" rev-parse --verify "$br" >/dev/null 2>&1 && lb+=("$br"); done
[ "${#lb[@]}" -gt 0 ] && echo "git push ${PUSHURL[linux]} ${lb[*]}"
echo "# no --tags, no --all -- local/*, pre-scrub-* tags stay local"

exit "$FAIL"
