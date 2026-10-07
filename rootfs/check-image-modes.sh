#!/bin/sh
# Check the owner and the modes of the files that the image build owns.
# mkrootfs.sh runs this script on the image tree before it makes the tarball.
# A failed check stops the build.
#
#   check-image-modes.sh ROOT
#
# The script checks these paths: the files of profiles/image.list (fstab,
# inittab, the profile marker) and /lib/modules with everything under it.
# Each path must belong to root and have no write bit for the group or for
# others. The init system and the module loader trust these files. A source
# checkout can give the image files that the group can write, and a CI
# archive can give the module trees a foreign owner.
#
# Env for host tests: TSX_IMAGE_UID and TSX_IMAGE_GID give the owner to expect
# (default 0 and 0). TSX_PROFILE_DIR gives the profile folder (default
# profiles/ next to this script).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PD=${TSX_PROFILE_DIR:-$HERE/profiles}
UID_WANT=${TSX_IMAGE_UID:-0}
GID_WANT=${TSX_IMAGE_GID:-0}
R=${1:-}
[ -d "$R" ] || { echo "usage: check-image-modes.sh ROOT" >&2; exit 2; }

paths=
[ ! -e "$R/lib/modules" ] || paths="$R/lib/modules"
for f in $(awk '/^[ \t]*(#|$)/ { next } $1 == "image" { print $2 }' "$PD/image.list"); do
	[ ! -e "$R/$f" ] || paths="$paths $R/$f"
done
[ -n "$paths" ] || { echo "check-image-modes: no path to check in $R" >&2; exit 2; }

# shellcheck disable=SC2086
found=$(find $paths ! -type l \( -perm /022 -o ! -user "$UID_WANT" -o ! -group "$GID_WANT" \) -exec ls -ldn {} + 2>&1) || true
if [ -n "$found" ]; then
	echo "check-image-modes: these paths are not owned by $UID_WANT:$GID_WANT, or the group or others can write them:" >&2
	printf '%s\n' "$found" | sed "s|$R||; s|^|  |" >&2
	exit 1
fi
echo "check-image-modes: ok ($(echo $paths | wc -w) paths, owner $UID_WANT:$GID_WANT, no group or other write)"
