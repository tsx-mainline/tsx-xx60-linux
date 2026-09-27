#!/bin/sh
# Fail if a built rootfs tarball/ext4 image carries any Crestron proprietary
# file. The only proprietary files mkrootfs.sh ever writes are the TFA9890
# DSP tuning containers (rootfs/mkrootfs.sh, usr/local/share/tsx/tfa9890/),
# copied in only when TFA_VENDOR_LOCAL/TFA_VENDOR_SRC point at them or
# TFA_VENDOR_FETCH pulls Crestron's .puf; CI builds always set
# TFA_VENDOR_FETCH=no and leave TFA_VENDOR_SRC unset, so none should ever be
# present here. This is a check on the build's OUTPUT, independent of that
# env var, so a future change to mkrootfs.sh cannot silently reintroduce one.
#
#   ci/check-no-proprietary.sh <rootfs.tar.gz> <rootfs.ext4>
set -eu
TAR=$1 IMG=$2
PATTERN='\.(cnt|puf)$|usr/local/share/tsx/tfa9890/'
bad=0

echo "== $TAR"
if tar tzf "$TAR" | grep -E "$PATTERN"; then bad=1; fi

echo "== $IMG"
MNT=$(mktemp -d)
sudo mount -o loop,ro "$IMG" "$MNT"
HITS=$(find "$MNT" \( -iname '*.cnt' -o -iname '*.puf' -o -path "$MNT/usr/local/share/tsx/tfa9890/*" \) 2>/dev/null || true)
sudo umount "$MNT"
rmdir "$MNT"
if [ -n "$HITS" ]; then echo "$HITS"; bad=1; fi

if [ "$bad" != 0 ]; then
	echo "FAIL: proprietary file(s) found in the build output (see above)"
	exit 1
fi
echo "ok: no *.cnt, *.puf, or usr/local/share/tsx/tfa9890/ in $TAR or $IMG"
