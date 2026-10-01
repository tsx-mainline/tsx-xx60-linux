#!/bin/bash
# Push-day prep. The script squashes the "import" branch of tsx-xx60-linux
# into one clean commit, or into one commit per group of a todo file. Then it
# scans every repo that a push would send, for things that must never leave
# this workstation. It prints a report and the exact push commands that a
# person would run. The script never pushes, never adds a remote, and never
# touches an existing branch other than the squash target.
#
#   tools/release/prepare-publish.sh --leak-patterns PATH [options]
#
# Required:
#   --leak-patterns PATH   file of extended-regex patterns (case-insensitive),
#                          one per line, '#' and blank lines ignored. See
#                          local-tools/leak-patterns.txt in this project. That
#                          file is NOT part of this repo, so give the path.
#                          The script reads the content into a throwaway temp
#                          file for grep -f and never writes it anywhere else.
#
# Options:
#   --squash-branch NAME   branch that this script (re)creates from the tree
#                          of import (default: publish-candidate)
#   --todo FILE            build the squash branch as a chain of commits, one
#                          per group of FILE, and not as one commit. See below.
#   --msg-dir DIR          directory with one message file per group, named
#                          DIR/Gnn.txt (subject, blank line, body). Required
#                          with --todo.
#   --source-branch NAME   branch whose tree the last squash commit must equal
#                          (default: import)
#   --skip-squash          only scan, do not create or update the squash branch
#   --max-blob-size BYTES  flag tracked blobs bigger than this (default: 2097152 = 2 MiB)
#   --repo NAME=PATH       override a repo path (repeatable). NAME is one of
#                          xx60-linux, aports, linux. Defaults: this repo,
#                          ../tsx-aports, ../linux (the sibling layout that
#                          tools/build/remote-build.sh uses)
#   --linux-branch BRANCH  a branch of the "linux" repo to scan (repeatable).
#                          Default: tsx-xx60-6.18 tsx-xx60-7.2 tsx-xx60.
#                          The script skips branches that do not exist,
#                          without a message.
#   --linux-upstream-remote NAME  a remote of the "linux" repo whose history
#                          counts as already public (repeatable). Default:
#                          torvalds stable linux-next xdarklight. The script
#                          does not scan again the commits that one of these
#                          remotes has. This is the same convention as the
#                          pre-push hook of local-tools/leak-hook.sh:
#                          "git log <tip> --not --remotes"
#   --push-url NAME=URL    override the URL in the printed push command for a
#                          repo (default: https://github.com/tsx-mainline/<repo-dirname>,
#                          the org where this project already publishes docs.
#                          See README.md and docs/kernel.md)
#
# Todo file: a line "# Gnn [text] subject" starts group Gnn. The lines
# "pick HASH ..." and "fixup HASH ..." that follow list the old commits of that
# group. Other comment lines and blank lines are ignored. The tree of a group
# is the tree of its newest commit, so every new commit has a tree that the old
# history had. Each group must be closed: its commits plus all earlier groups
# must be exactly the history of its newest commit. A group cannot cut a
# side branch of a merge. The new commit gets the date of the newest old
# commit of its group. The last tree must equal the tree of the source branch.
# New commits are signed when commit.gpgsign is true in the repo config.
#
# Exit status: 0 if the squash (unless skipped) succeeded and every scan came
# back clean. 1 if any repo or category found something. In both cases the
# script prints the full report. It pushes nothing and writes nothing beyond
# the squash branch.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)          # .../tsx-xx60-linux
TOP=$(cd "$REPO/.." && pwd)

LEAKPATS= SQUASH_BRANCH=publish-candidate DO_SQUASH=1 MAXBLOB=2097152
TODO= MSGDIR= SOURCE_BRANCH=import
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
	--todo) TODO=$2; shift;;
	--msg-dir) MSGDIR=$2; shift;;
	--source-branch) SOURCE_BRANCH=$2; shift;;
	--skip-squash) DO_SQUASH=0;;
	--max-blob-size) MAXBLOB=$2; shift;;
	--repo) k=${2%%=*}; REPOPATH[$k]=${2#*=}; shift;;
	# first --linux-branch/--linux-upstream-remote replaces the built-in
	# default list. Later ones append to what the user is building up.
	--linux-branch) [ "$LINUX_BRANCHES_SET" = 1 ] || { LINUX_BRANCHES=(); LINUX_BRANCHES_SET=1; }
	                LINUX_BRANCHES+=("$2"); shift;;
	--linux-upstream-remote) [ "$UPSTREAM_REMOTES_SET" = 1 ] || { UPSTREAM_REMOTES=(); UPSTREAM_REMOTES_SET=1; }
	                UPSTREAM_REMOTES+=("$2"); shift;;
	--push-url) k=${2%%=*}; PUSHURL[$k]=${2#*=}; shift;;
	-h|--help) sed -n '2,64p' "$0"; exit 0;;
	*) echo "prepare-publish: unknown option $1" >&2; exit 1;; esac; shift; done

[ -n "$LEAKPATS" ] || { echo "prepare-publish: --leak-patterns PATH is required" >&2; exit 1; }
[ -r "$LEAKPATS" ] || { echo "prepare-publish: cannot read $LEAKPATS" >&2; exit 1; }
if [ -n "$TODO" ]; then
	[ -r "$TODO" ] || { echo "prepare-publish: cannot read $TODO" >&2; exit 1; }
	[ -d "$MSGDIR" ] || { echo "prepare-publish: --todo needs --msg-dir DIR" >&2; exit 1; }
fi

say() { echo "[prepare-publish] $*"; }
FAIL=0

# --- leak-patterns file -> a throwaway grep -f file (comments/blanks out). ---
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
# squash: tsx-xx60-linux only. Without --todo it builds one new commit (no
# parent) from the tree of the source branch and points $SQUASH_BRANCH at it.
# With --todo it builds one commit per group (see "Todo file" above). It never
# checks out anything, so it never switches any worktree's branch (several
# worktrees share this .git -- REPO-RULES.md).
# ---------------------------------------------------------------------------
IDENT_NAME=unex IDENT_MAIL=7575866+unex@users.noreply.github.com

# sign_args: "-S" when the repo config turns commit signing on. git commit-tree
# does not read commit.gpgsign by itself.
sign_args() {
	[ "$(git -C "${REPOPATH[xx60-linux]}" config --type=bool --get commit.gpgsign 2>/dev/null)" = true ] && echo -S
}

# check_final_tree TIP: the last commit must have the tree of the source branch
check_final_tree() {
	local repo=${REPOPATH[xx60-linux]} want got
	want=$(git -C "$repo" rev-parse "$SOURCE_BRANCH^{tree}") || { FAIL=1; return; }
	got=$(git -C "$repo" rev-parse "$1^{tree}")
	if [ "$want" = "$got" ]; then say "tree check: $SQUASH_BRANCH has the tree of $SOURCE_BRANCH"
	else
		echo "prepare-publish: tree check FAILED: $SQUASH_BRANCH differs from $SOURCE_BRANCH"
		git -C "$repo" diff --stat "$SOURCE_BRANCH" "$1" | tail -5; FAIL=1
	fi
}

squash_from_todo() {
	local repo=${REPOPATH[xx60-linux]} line cmd hash num
	tmp=$(mktemp -d); trap 'rm -rf "$tmp"; rm -f "$patf" "$aipatf"' EXIT
	local -a gnum=()
	local n=-1 total=0
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
		'# G'[0-9]*) num=${line#\# }; num=${num%% *}; n=$((n+1)); gnum[$n]=$num; : > "$tmp/m.$n";;
		pick\ *|fixup\ *)
			[ "$n" -ge 0 ] || { echo "prepare-publish: $TODO: '$line' comes before a group header"; FAIL=1; return; }
			set -- $line; hash=$2
			git -C "$repo" rev-parse --verify -q "$hash^{commit}" >/dev/null \
				|| { echo "prepare-publish: $TODO: no such commit '$hash'"; FAIL=1; return; }
			git -C "$repo" rev-parse "$hash^{commit}" >> "$tmp/m.$n"; total=$((total+1));;
		esac
	done < "$TODO"
	[ "$n" -ge 0 ] || { echo "prepare-publish: $TODO has no group"; FAIL=1; return; }
	sort "$tmp"/m.* | uniq -d | grep -q . && { echo "prepare-publish: $TODO lists a commit twice"; FAIL=1; return; }

	say "todo: $((n+1)) groups, $total old commits"
	local i prev= tip tree msgf date commit cnt
	: > "$tmp/seen"
	for i in $(seq 0 "$n"); do
		num=${gnum[$i]}; msgf=$MSGDIR/$num.txt
		[ -s "$tmp/m.$i" ] || { echo "prepare-publish: group $num has no commits"; FAIL=1; return; }
		[ -r "$msgf" ] || { echo "prepare-publish: missing message file $msgf"; FAIL=1; return; }
		# the newest member: the one that no other member descends from
		tip=$(git -C "$repo" merge-base --independent $(cat "$tmp/m.$i") | head -1)
		cat "$tmp/m.$i" >> "$tmp/seen"
		sort "$tmp/seen" > "$tmp/seen.s"
		git -C "$repo" rev-list "$tip" | sort > "$tmp/hist.s"
		if ! cmp -s "$tmp/seen.s" "$tmp/hist.s"; then
			echo "prepare-publish: group $num does not close at a first-parent commit (members and earlier groups differ from the history of ${tip:0:7})"
			diff "$tmp/seen.s" "$tmp/hist.s" | head -5; FAIL=1; return
		fi
		tree=$(git -C "$repo" rev-parse "$tip^{tree}")
		date=$(git -C "$repo" log -1 --format=%cI "$tip")
		commit=$(GIT_AUTHOR_NAME=$IDENT_NAME GIT_AUTHOR_EMAIL=$IDENT_MAIL GIT_AUTHOR_DATE=$date \
		         GIT_COMMITTER_NAME=$IDENT_NAME GIT_COMMITTER_EMAIL=$IDENT_MAIL GIT_COMMITTER_DATE=$date \
		         git -C "$repo" commit-tree $(sign_args) "$tree" ${prev:+-p $prev} -F "$msgf") \
			|| { echo "prepare-publish: commit-tree failed for group $num"; FAIL=1; return; }
		cnt=$(wc -l < "$tmp/m.$i")
		say "group $num: ${commit:0:12} tree of ${tip:0:7} ($cnt old commits) $(head -1 "$msgf")"
		prev=$commit
	done
	git -C "$repo" update-ref "refs/heads/$SQUASH_BRANCH" "$prev"
	say "squash: refs/heads/$SQUASH_BRANCH -> $prev ($((n+1)) commits)"
	check_final_tree "$prev"
}

squash_xx60_linux() {
	local repo=${REPOPATH[xx60-linux]} tree commit
	git -C "$repo" rev-parse --verify "$SOURCE_BRANCH" >/dev/null 2>&1 || { echo "prepare-publish: $repo has no '$SOURCE_BRANCH' branch"; FAIL=1; return; }
	if [ -n "$TODO" ]; then squash_from_todo; return; fi
	tree=$(git -C "$repo" rev-parse "$SOURCE_BRANCH^{tree}")
	commit=$(GIT_AUTHOR_NAME=$IDENT_NAME GIT_AUTHOR_EMAIL=$IDENT_MAIL \
	         GIT_COMMITTER_NAME=$IDENT_NAME GIT_COMMITTER_EMAIL=$IDENT_MAIL \
	         git -C "$repo" commit-tree $(sign_args) "$tree" -m "tsx-xx60-linux: mainline port for the Crestron TSW/TSS-x60 panels")
	git -C "$repo" update-ref "refs/heads/$SQUASH_BRANCH" "$commit"
	say "squash: refs/heads/$SQUASH_BRANCH -> $commit (1 commit, tree of $SOURCE_BRANCH)"
	check_final_tree "$commit"
}

# ---------------------------------------------------------------------------
# scan_range REPO_KEY LABEL REV...
# REV... is what "git log" takes to list the commits that a push would send.
# For a repo with no remotes yet, REV is a full-history REF. Otherwise REV is
# "BRANCH --not --remotes=U1 --remotes=U2 ..." so that the scan skips what a
# known-public remote already has. The pre-push hook of local-tools/leak-hook.sh
# uses the same idiom.
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
