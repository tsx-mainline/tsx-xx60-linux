#!/bin/bash
# Offload a kernel / rootfs build to another machine over ssh, instead of
# building here. OPT-IN: needs BUILD_HOST and BUILD_DIR, both with NO
# default. If BUILD_HOST is unset, this script just runs the equivalent
# LOCAL build (kbuild.sh / build-rootfs.sh / mkbootimg.sh) and exits --
# building locally needs neither this script nor BUILD_HOST at all; call
# those directly if you prefer.
#
#   BUILD_HOST=<ssh host> BUILD_DIR=<remote repo path> \
#     tools/build/remote-build.sh [--dest DIR] [--with-modules] [-j N] <command> [arg]
#
#   kernel [--flavor lts|stable | BRANCH]  push the worktree that has BRANCH checked
#                    out (default: the branch for --flavor/$FLAVOR, default lts ->
#                    tsx-xx60-6.18; stable -> tsx-xx60-7.2; a literal BRANCH argument
#                    overrides both) in the kernel fork checkout LINUX_DIR (default
#                    ../linux next to this repo, one git worktree per branch) + the
#                    shared .git, run kbuild.sh there (zImage dtbs modules, -j20),
#                    pull back zImage, board DTB, test.img, kernel.release,
#                    kernel.commit to <worktree>/../out-<flavor> or --dest DIR.
#   rootfs           push rootfs/ sources, run build-rootfs.sh rootfs, pull back
#                    rootfs.{ext4,tar.gz,manifest,sizes,sha256} to rootfs/out or --dest.
#                    --with-modules: first stage the modules of every flavor built on
#                    the HOST (build-lts, build-stable next to the fork checkout; run
#                    "kernel" for each flavor first), so the rootfs carries both
#                    trees; default: no modules, like the local build.
#                    Prebuilt inputs that exist only on the host (rootfs/src/sendspin/out/,
#                    rootfs/voice/tflite/libtensorflowlite_c.so) survive the push.
#                    TSX_APK_LOCAL=<local tsx-aports published tree>: mirrored to
#                    rootfs/aports-local/ on the host and installed from there
#                    (build-rootfs.sh); TSX_APK_URL is passed through.
#   initramfs        build-rootfs.sh initramfs -> initramfs-switchroot.cpio.gz
#   image [--flavor lts|stable | BRANCH]   rootfs/mkbootimg.sh with KDIR = the host's
#                    out-<flavor>/ of the resolved branch's worktree (same default/
#                    override rule as "kernel") -> tsxboot.img{,.sha256}. Needs
#                    "kernel" and "initramfs" run on the host before.
#   sync             full resync of the mirror (this repo + the linux fork checkout)
#   jobs             list the last jobs on the host (logs in tools/build/state/jobs/)
#
# Env: BUILD_HOST (ssh destination, required to actually go remote), BUILD_DIR
# (remote path this repo is mirrored to, required with BUILD_HOST -- the
# remote kernel fork checkout is assumed to be BUILD_DIR/../linux, the same
# sibling layout as locally; override with REMOTE_LINUX_DIR). FLAVOR (or
# --flavor) picks lts (default) or stable for "kernel"/"image" when no
# explicit BRANCH is given.
#
# Safety: never deletes local files (pull-back is rsync without --delete; it only
# overwrites the named artifacts in the destination). --delete is used only for the
# pushed SOURCE dirs on the host; build/out dirs on the host are excluded (protected).
# The build runs detached on the host (setsid); if this script or the ssh link dies,
# the job continues; see "jobs". Two builds of the same build dir are serialized
# by flock on the host.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)               # .../tsx-xx60-linux
TOP=$(cd "$REPO/.." && pwd)
LINUX=${LINUX_DIR:-$TOP/linux}                # the kernel fork checkout, sibling of this repo
DEST= MODS=0 J= FLAVOR=${FLAVOR:-lts}
ARGS=() JOBREF=
while [ $# -gt 0 ]; do case $1 in
	--dest) DEST=$(mkdir -p "$2" && cd "$2" && pwd); shift;;
	--with-modules) MODS=1;;
	-j) J=$2; shift;;
	--flavor) FLAVOR=$2; shift;;
	--flavor=*) FLAVOR=${1#--flavor=};;
	-h|--help) sed -n '2,35p' "$0"; exit 0;;
	*) ARGS+=("$1");; esac; shift; done
set -- "${ARGS[@]}"
CMD=${1:-}; ARG=${2:-}
say() { echo "[remote-build] $*"; }
case $FLAVOR in lts|stable) ;; *) echo "remote-build: --flavor/\$FLAVOR must be lts or stable (got $FLAVOR)"; exit 1;; esac
flavor_branch() { case $1 in lts) echo tsx-xx60-6.18;; stable) echo tsx-xx60-7.2;; esac; }

# --- no BUILD_HOST: build locally with the same scripts this wrapper would
# otherwise run over ssh, and stop here. -----------------------------------
if [ -z "${BUILD_HOST:-}" ]; then
	say "BUILD_HOST not set: building locally (this wrapper is opt-in; you can also call the scripts below directly)"
	case $CMD in
	kernel) exec "$HERE/kbuild.sh" -f "$FLAVOR" ${J:+-j "$J"} ${DEST:+-d "$DEST"} kernel image;;
	rootfs) [ $MODS = 1 ] && "$REPO/rootfs/build-rootfs.sh" modules
		"$REPO/rootfs/build-rootfs.sh" rootfs
		[ -z "$DEST" ] || { mkdir -p "$DEST"; cp "$REPO"/rootfs/out/rootfs.* "$DEST/"; }
		exit 0;;
	initramfs) "$REPO/rootfs/build-rootfs.sh" initramfs
		[ -z "$DEST" ] || { mkdir -p "$DEST"; cp "$REPO/rootfs/out/initramfs-switchroot.cpio.gz" "$DEST/"; }
		exit 0;;
	image) KDIR=${KDIR:-$TOP/out-$FLAVOR} "$REPO/rootfs/mkbootimg.sh"
		[ -z "$DEST" ] || { mkdir -p "$DEST"; cp "$REPO"/rootfs/out/tsxboot.img* "$DEST/"; }
		exit 0;;
	sync|jobs) say "$CMD is a no-op for a local build"; exit 0;;
	*) sed -n '2,35p' "$0"; exit 1;; esac
fi

# --- BUILD_HOST set: go remote. --------------------------------------------
HOST=$BUILD_HOST
BUILD_DIR=${BUILD_DIR:?BUILD_DIR must be set together with BUILD_HOST (remote path to mirror this repo to)}
RHOST_LINUX=${REMOTE_LINUX_DIR:-$(dirname "$BUILD_DIR")/linux}
SSH=(ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "$HOST")
export RSYNC_RSH="ssh -o BatchMode=yes -o ServerAliveInterval=30"
RS=(rsync -a --no-specials --no-devices)
rsh() { "${SSH[@]}" "$@"; }

worktree_of() {  # branch -> local worktree path
	git -C "$LINUX" worktree list --porcelain | awk -v b="refs/heads/$1" '
		/^worktree /{w=substr($0,10)} $0=="branch " b {print w; exit}'
}

remote_worktree_path() {  # local worktree path -> its path on the remote
	# Every worktree of the kernel fork (LINUX_DIR itself, or one added beside
	# it with "git worktree add") shares LINUX_DIR's parent directory locally;
	# mirror that same relationship under RHOST_LINUX's parent remotely.
	echo "$(dirname "$RHOST_LINUX")/$(basename "$1")"
}

push_common() {
	rsh "mkdir -p $BUILD_DIR/tools/build $BUILD_DIR/kernel/out"
	"${RS[@]}" --delete --exclude /state "$HERE/" "$HOST:$BUILD_DIR/tools/build/"
	"${RS[@]}" --delete "$REPO/ci/" "$HOST:$BUILD_DIR/ci/"
	"${RS[@]}" "$REPO/kernel/mkimage.sh" "$REPO/kernel/aml-dt.py" "$REPO/kernel/KERNEL_REV.lts" "$REPO/kernel/KERNEL_REV.stable" "$HOST:$BUILD_DIR/kernel/"
	[ -f "$REPO/kernel/out/initramfs.cpio.gz" ] && "${RS[@]}" "$REPO/kernel/out/initramfs.cpio.gz" "$HOST:$BUILD_DIR/kernel/out/"
	true
}

push_git() {  # shared object store + worktree metadata (refs, per-worktree index/HEAD)
	[ -d "$LINUX/.git" ] || return 0
	rsh "mkdir -p $RHOST_LINUX"
	"${RS[@]}" --delete --exclude '*.lock' --exclude gc.log "$LINUX/.git/" "$HOST:$RHOST_LINUX/.git/"
}

push_tree() {  # $1 = local worktree dir, $2 = remote worktree dir; mirror the checkout
	rsh "mkdir -p $2"
	"${RS[@]}" --delete --exclude '*.o' --exclude '*.ko' --exclude '.*.cmd' "$1/" "$HOST:$2/"
	# A linked worktree's .git file (and the fork's worktrees/<name>/gitdir)
	# hold LOCAL absolute paths. Point both at the remote copy, or git on the
	# host reads a different (or stale) repository at the local path and the
	# build gets the wrong HEAD, a "-dirty" release and a KERNEL_REV warning.
	if [ -f "$1/.git" ]; then
		local name
		name=$(basename "$(sed -n 's/^gitdir: //p' "$1/.git")")
		[ -n "$name" ] || { echo "cannot read the worktree name from $1/.git"; exit 1; }
		rsh "d=$RHOST_LINUX/.git/worktrees/$name; [ -d \$d ] || { echo \"no \$d on the host\"; exit 1; }; printf 'gitdir: %s\n' \$d > $2/.git; printf '%s\n' $2/.git > \$d/gitdir"
	fi
}

# Build inputs that are built once on the host and never committed
# (rootfs/src/sendspin/build.sh, rootfs/voice/build-tflite.sh): rsync "protect"
# rules keep --delete from removing them when the local tree does not have
# them. A local copy, if there is one, is still sent.
PROTECT=(--filter='P /sendspin/out/' --filter='P /tflite/libtensorflowlite_c.so')
push_rootfs() {
	local p=$REPO/rootfs
	rsh "mkdir -p $BUILD_DIR/rootfs"
	for d in overlay src initramfs config voice; do [ -d "$p/$d" ] && "${RS[@]}" --delete "${PROTECT[@]}" "$p/$d/" "$HOST:$BUILD_DIR/rootfs/$d/"; done
	for f in mkrootfs.sh build-rootfs.sh mkbootimg.sh packages.txt packages-tsx.txt vendor-fetch.sh install.sh tsx-disk.sh authorized_keys; do [ -e "$p/$f" ] && "${RS[@]}" "$p/$f" "$HOST:$BUILD_DIR/rootfs/"; done
	true
}

# run a script detached on the host, stream its log, return its exit code
rjob() {
	local name=$1 script=$2 jd=$BUILD_DIR/tools/build/state/jobs id
	id=$name-$(date +%Y%m%d-%H%M%S)-$$
	# The .rc file holds the real exit status, or "killed:SIG" when the job got a
	# signal (e.g. host reboot) -- a job that dies without any trap (SIGKILL, power
	# loss) leaves no .rc file; the wrapper then sees the pid gone and reports 255.
	rsh "mkdir -p $jd && cat > $jd/$id.sh" <<<"set -uo pipefail
st=$jd/$id.rc
for sig in TERM INT HUP QUIT; do trap \"echo killed:SIG\$sig > \$st; exit 143\" \$sig; done
trap 'rc=\$?; [ -s \$st ] || echo \$rc > \$st' EXIT
cd $BUILD_DIR
$script"
	JOBREF=$jd/$id.sh
	rsh "cd $jd && setsid -f bash -c 'echo \$\$ > $id.pid; exec bash $id.sh' > $id.log 2>&1 < /dev/null; for i in \$(seq 50); do [ -s $id.pid ] && break; sleep 0.1; done"
	say "job $id on $HOST (log $jd/$id.log)"
	local off=0 chunk rc='' n
	chunk=$(mktemp)
	trap 'say "interrupted; the job keeps running on $HOST: ssh $HOST tail -f $jd/$id.log"; rm -f "$chunk"; exit 130' INT TERM
	while :; do
		rc=$(rsh "cat $jd/$id.rc 2>/dev/null || kill -0 \$(cat $jd/$id.pid) 2>/dev/null || { sleep 2; cat $jd/$id.rc 2>/dev/null || echo 255; }") || rc=''
		if rsh "tail -c +$((off+1)) $jd/$id.log" > "$chunk" 2>/dev/null; then
			n=$(stat -c %s "$chunk"); off=$((off+n)); cat "$chunk"
		fi
		[ -n "$rc" ] && break
		sleep 5
	done
	rm -f "$chunk"; trap - INT TERM
	say "job $id exit $rc"
	case $rc in ''|*[!0-9]*) say "job did not finish normally ($rc)"; return 143;; esac
	return "$rc"
}

pull() {  # pull host files (absolute paths) into $1 (never --delete)
	local to=$1; shift; mkdir -p "$to"
	local f bad=0; for f in "$@"; do
		if ! rsh "test -e $f"; then echo "  (missing on host: $f)"; bad=1
		elif [ -n "${JOBREF:-}" ] && ! rsh "test $f -nt $JOBREF"; then echo "  STALE on host (older than this job), not pulled: $f"; bad=1
		else "${RS[@]}" "$HOST:$f" "$to/"; echo "  $to/$(basename "$f")"; fi
	done
	return $bad
}

t0=$(date +%s)
case $CMD in
kernel)
	br=${ARG:-$(flavor_branch "$FLAVOR")}; wt=$(worktree_of "$br")
	[ -n "$wt" ] || { echo "branch $br is not checked out in any worktree of $LINUX"; exit 1; }
	rwt=$(remote_worktree_path "$wt")
	say "kernel $br ($FLAVOR): $wt -> $rwt on $HOST"
	push_common; push_git; push_tree "$wt" "$rwt"
	say "push done ($(( $(date +%s) - t0 )) s)"
	rjob "kernel-$br" "flock $BUILD_DIR/kernel/.kbuild-$br.lock $BUILD_DIR/tools/build/kbuild.sh -f $FLAVOR -w $rwt ${J:+-j $J} kernel image"
	to=${DEST:-$(dirname "$wt")/out-$FLAVOR}
	rout=$(dirname "$rwt")/out-$FLAVOR
	say "artifacts:"
	pull "$to" "$rout/zImage" "$rout/meson8m2-crestron-tsw1060.dtb" "$rout/test.img" "$rout/kernel.release" "$rout/kernel.commit";;
rootfs)
	push_common; push_rootfs
	if [ $MODS = 1 ]; then
		# every flavor built on the host: kbuild.sh -w <worktree> builds into
		# <worktree>/../build-<flavor>, i.e. next to the fork checkout
		kb=$(dirname "$RHOST_LINUX")
		m="rm -rf modules; n=0; for f in lts stable; do [ -d $kb/build-\$f ] || continue; KBUILD=$kb/build-\$f ./build-rootfs.sh modules; n=\$((n+1)); done; [ \$n -gt 0 ] || { echo \"no kernel build dir ($kb/build-lts or build-stable) on the host: run kernel first\"; exit 1; }"
	else m="rm -rf modules"; fi
	# TSX_APK_LOCAL (a local tsx-aports published tree): mirrored next to the
	# rootfs sources on the host and used from there
	apkenv="TSX_APK_URL=${TSX_APK_URL:-https://tsx-aports.unexceptional.net}"
	if [ -n "${TSX_APK_LOCAL:-}" ]; then
		say "tsx-aports tree $TSX_APK_LOCAL -> $BUILD_DIR/rootfs/aports-local"
		rsh "mkdir -p $BUILD_DIR/rootfs/aports-local"
		"${RS[@]}" --delete "$TSX_APK_LOCAL/" "$HOST:$BUILD_DIR/rootfs/aports-local/"
		apkenv="$apkenv TSX_APK_LOCAL=$BUILD_DIR/rootfs/aports-local"
	fi
	rjob rootfs "cd $BUILD_DIR/rootfs && flock $BUILD_DIR/rootfs/.rootfs.lock env $apkenv bash -c 'set -e; $m; ./build-rootfs.sh rootfs'"
	to=${DEST:-$REPO/rootfs/out}; o=$BUILD_DIR/rootfs/out
	say "artifacts:"
	pull "$to" "$o/rootfs.ext4" "$o/rootfs.tar.gz" "$o/rootfs.manifest" "$o/rootfs.sizes" "$o/rootfs.sha256";;
initramfs)
	push_common; push_rootfs
	rjob initramfs "cd $BUILD_DIR/rootfs && flock $BUILD_DIR/rootfs/.rootfs.lock ./build-rootfs.sh initramfs"
	say "artifacts:"; pull "${DEST:-$REPO/rootfs/out}" "$BUILD_DIR/rootfs/out/initramfs-switchroot.cpio.gz";;
image)
	br=${ARG:-$(flavor_branch "$FLAVOR")}; wt=$(worktree_of "$br")
	[ -n "$wt" ] || { echo "branch $br is not checked out in any worktree"; exit 1; }
	kd=$(dirname "$(remote_worktree_path "$wt")")/out-$FLAVOR
	push_common; push_rootfs
	rjob image "cd $BUILD_DIR/rootfs && KDIR=$kd ./mkbootimg.sh"
	say "artifacts:"; pull "${DEST:-$REPO/rootfs/out}" "$BUILD_DIR/rootfs/out/tsxboot.img" "$BUILD_DIR/rootfs/out/tsxboot.img.sha256";;
sync)
	say "full mirror sync (no --delete)"
	"${RS[@]}" --info=stats1 --filter="merge $HERE/rsync-filter.txt" "$REPO/" "$HOST:$BUILD_DIR/"
	[ -d "$LINUX" ] && "${RS[@]}" --info=stats1 --exclude '*.o' --exclude '*.ko' --exclude '.*.cmd' "$LINUX/" "$HOST:$RHOST_LINUX/"
	true;;
jobs)
	rsh "cd $BUILD_DIR/tools/build/state/jobs 2>/dev/null && for f in \$(ls -t *.log | head -15); do j=\${f%.log}; printf '%-45s rc=%s  %s\n' \$j \"\$(cat \$j.rc 2>/dev/null || echo running)\" \"\$(date -r \$f '+%F %T')\"; done";;
*) sed -n '2,32p' "$0"; exit 1;;
esac
say "total $(( $(date +%s) - t0 )) s"
