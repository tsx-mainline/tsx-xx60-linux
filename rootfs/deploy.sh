#!/bin/bash
# Host side of the installation: drives install.sh on a panel that runs the
# rescue system (rootfs switch_root initramfs or rescue initramfs), over ssh.
#
#   ./deploy.sh IP [--url URL] [--token-file F] [--bootimg boot.img] [--check-only]
#
# 1. copies install.sh + tsx-disk.sh to /tmp/tsx on the panel, runs "check"
# 2. pulls the first MiB of p5 to backups/p5-first1M-<time>.img (host)
# 3. optional: copies the boot image to panel RAM for --bootimg
# 4. streams out/rootfs.tar.gz over ssh into "install.sh install"
# Nothing is written to the panel before step 4. Password "tsx" (sshpass) or keys.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IP=${1:?usage: deploy.sh IP [--url URL] [--token-file F] [--bootimg IMG] [--check-only]}; shift
URL= TOKF= BOOTIMG= CHECK=0
while [ $# -gt 0 ]; do
	case "$1" in
	--url) URL=$2; shift;; --token-file) TOKF=$2; shift;; --bootimg) BOOTIMG=$2; shift;;
	--check-only) CHECK=1;; *) echo "unknown option $1"; exit 2;;
	esac; shift
done
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$IP")
command -v sshpass >/dev/null && [ -z "${SSH_AUTH_SOCK:-}${NO_SSHPASS:-}" ] && SSH=(sshpass -p "${TSX_PASS:-tsx}" "${SSH[@]}")
R() { "${SSH[@]}" "$@"; }

R 'mkdir -p /tmp/tsx'
R 'cat > /tmp/tsx/install.sh && chmod +x /tmp/tsx/install.sh' < "$HERE/install.sh"
R 'cat > /tmp/tsx/uninstall.sh && chmod +x /tmp/tsx/uninstall.sh' < "$HERE/uninstall.sh"
R 'cat > /tmp/tsx/tsx-disk.sh' < "$HERE/tsx-disk.sh"
R '/tmp/tsx/install.sh check'
[ $CHECK = 1 ] && exit 0

mkdir -p "$HERE/backups"
B=$HERE/backups/p5-first1M-$(date +%Y%m%d-%H%M%S).img
R '/tmp/tsx/install.sh backup-p5head' > "$B"
[ "$(stat -c %s "$B")" = 1048576 ] || { echo "p5 head backup has wrong size"; exit 1; }
P5SHA=$(sha256sum < "$B" | cut -d' ' -f1); echo "p5 head backup: $B ($P5SHA)"

ARGS=(--rootfs - --sha256 "$(cut -d' ' -f1 < <(grep rootfs.tar.gz "$HERE/out/rootfs.sha256"))" --p5-backup-sha256 "$P5SHA")
[ -n "$URL" ] && ARGS+=(--url "$URL")
if [ -n "$TOKF" ]; then R 'umask 077; cat > /tmp/tsx/token' < "$TOKF"; ARGS+=(--token-file /tmp/tsx/token); fi
if [ -n "$BOOTIMG" ]; then
	R 'cat > /tmp/tsx/boot.img' < "$BOOTIMG"
	ARGS+=(--bootimg /tmp/tsx/boot.img --bootimg-sha256 "$(sha256sum < "$BOOTIMG" | cut -d' ' -f1)")
fi
echo "streaming rootfs ($(du -h "$HERE/out/rootfs.tar.gz" | cut -f1)) ..."
R "/tmp/tsx/install.sh install $(printf "%q " "${ARGS[@]}")" < "$HERE/out/rootfs.tar.gz"
