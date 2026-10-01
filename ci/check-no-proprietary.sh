#!/bin/sh
# Fail if a built rootfs tarball or ext4 image carries a Crestron proprietary
# file. The only proprietary files that mkrootfs.sh ever writes are the
# TFA9890 DSP tuning containers (rootfs/mkrootfs.sh,
# usr/local/share/tsx/tfa9890/). The script copies them only when
# TFA_VENDOR_LOCAL or TFA_VENDOR_SRC points at them, or when TFA_VENDOR_FETCH
# pulls the .puf of Crestron. CI builds always set TFA_VENDOR_FETCH=no and
# leave TFA_VENDOR_SRC unset, so none should be present. This check looks at
# the OUTPUT of the build and does not depend on that env var. So a later
# change to mkrootfs.sh cannot silently add one again. The check also looks
# for the Bluetooth PSR file (PSR-CSR8811.psr, usr/local/share/tsx/csr8811/).
# Only the installer puts it on a panel, never a build.
#   ci/check-no-proprietary.sh <rootfs.tar.gz> [<rootfs.ext4>]
# The ext4 check needs sudo and a loop mount. Leave the image out to check the
# tarball only. The script exits with 1 when it finds a file, so every caller
# stops. Callers must not hide this exit status.
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <rootfs.tar.gz> [<rootfs.ext4>]" >&2; exit 2; }
TAR=$1 IMG=${2:-}
PATTERN='\.(cnt|puf|psr)$|usr/local/share/tsx/(tfa9890|csr8811)/'
bad=0

echo "== $TAR"
if tar tzf "$TAR" | grep -E "$PATTERN"; then bad=1; fi

if [ -n "$IMG" ]; then
	echo "== $IMG"
	MNT=$(mktemp -d)
	sudo mount -o loop,ro "$IMG" "$MNT"
	HITS=$(find "$MNT" \( -iname '*.cnt' -o -iname '*.puf' -o -iname '*.psr' -o -path "$MNT/usr/local/share/tsx/tfa9890/*" \
		-o -path "$MNT/usr/local/share/tsx/csr8811/*" \) 2>/dev/null || true)
	sudo umount "$MNT"
	rmdir "$MNT"
	if [ -n "$HITS" ]; then echo "$HITS"; bad=1; fi
fi

if [ "$bad" != 0 ]; then
	echo "FAIL: the build output holds the proprietary files listed above."
	echo "Do not publish this build. Build from a clean export or worktree (git archive or git worktree add)"
	echo "with TFA_VENDOR_FETCH=no and without ignored folders such as vendor-local or vendor-cache."
	exit 1
fi
echo "ok: no *.cnt, *.puf, *.psr, or usr/local/share/tsx/tfa9890/ in $TAR${IMG:+ or $IMG}"
