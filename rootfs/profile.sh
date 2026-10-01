#!/bin/sh
# profile.sh: the image profiles of the rootfs build (docs/rootfs.md "Profiles").
#
#   profile.sh includes PROFILE         lists in effect, for example "console kiosk"
#   profile.sh entries PROFILE [KIND]   the lines of those lists. With KIND, only
#                                       those lines, without the KIND word
#   profile.sh has PROFILE KIND NAME    exit 0 if the profile has that entry
#   profile.sh packages PROFILE FILE    the lines of a package file (packages.txt,
#                                       packages-tsx.txt) that the profile installs
#   profile.sh stage PROFILE ROOTFS     copy the overlay into ROOTFS, minus the
#                                       files of the profiles that build on PROFILE,
#                                       plus the files of profiles/PROFILE/overlay
#   profile.sh unclassified             list overlay files that no list names
#
# The profiles are console, kiosk and ha. Each one holds all the earlier ones.
# profiles/<name>.list holds the entries that the profile adds. mkrootfs.sh and
# rootfs/tests/test-profiles.sh both use this script, so the test checks the
# same code that builds the image.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PD=${TSX_PROFILE_DIR:-$HERE/profiles}
OV=${TSX_OVERLAY_DIR:-$HERE/overlay}
ALL="console kiosk ha"

die() { echo "profile.sh: $*" >&2; exit 2; }

includes() {
	case "$1" in
	console) echo "console";;
	kiosk) echo "console kiosk";;
	ha) echo "console kiosk ha";;
	*) die "unknown profile '$1' (use console, kiosk or ha)";;
	esac
}

# entries PROFILE: the lines of the lists in effect
entries() {
	inc=$(includes "$1")
	for l in $inc; do
		[ -r "$PD/$l.list" ] || die "no $PD/$l.list"
		awk '/^[ \t]*(#|$)/ { next } { print }' "$PD/$l.list"
	done
}

# others PROFILE: the profiles that are not in effect
others() {
	inc=" $(includes "$1") "
	for l in $ALL; do case "$inc" in *" $l "*) ;; *) echo "$l";; esac; done
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
includes) [ $# = 1 ] || die "usage: includes PROFILE"; includes "$1";;
entries)
	[ $# -ge 1 ] || die "usage: entries PROFILE [KIND]"
	if [ $# = 2 ]; then entries "$1" | awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; else entries "$1"; fi;;
has)
	[ $# = 3 ] || die "usage: has PROFILE KIND NAME"
	entries "$1" | awk -v k="$2" -v n="$3" '$1 == k && $NF == n { f = 1 } END { exit !f }';;
packages)
	[ $# = 2 ] || die "usage: packages PROFILE FILE"
	entries "$1" | awk '$1 == "pkg" { print $2 }' > "${TMPDIR:-/tmp}/profile-pkgs.$$"
	awk 'NR == FNR { want[$1] = 1; next }
		/^#/ || /^[ \t]*$/ { next }
		{ n = $1; sub(/=.*/, "", n); if (n in want) print }' "${TMPDIR:-/tmp}/profile-pkgs.$$" "$2"
	rm -f "${TMPDIR:-/tmp}/profile-pkgs.$$";;
stage)
	[ $# = 2 ] || die "usage: stage PROFILE ROOTFS"
	p=$1; R=$2
	includes "$p" >/dev/null
	mkdir -p "$R"
	cp -a "$OV"/. "$R"/
	for o in $(others "$p"); do
		awk '$1 == "overlay" { print $2 }' "$PD/$o.list" | while read -r f; do
			rm -f "$R/$f"
			# drop directories that this removal left empty
			d=$(dirname "$f")
			while [ "$d" != . ]; do rmdir "$R/$d" 2>/dev/null || break; d=$(dirname "$d"); done
		done
	done
	# the files that only this profile has. A symbolic link is followed, so
	# the image holds the file and not a link into the repository.
	[ -d "$PD/$p/overlay" ] && cp -aL "$PD/$p/overlay"/. "$R"/
	exit 0;;
unclassified)
	( cd "$OV" && find . \( -type f -o -type l \) | sed 's|^\./||' | grep -v '__pycache__' | sort ) > "${TMPDIR:-/tmp}/profile-ov.$$"
	for l in $ALL; do awk '$1 == "overlay" { print $2 }' "$PD/$l.list"; done | sort > "${TMPDIR:-/tmp}/profile-ls.$$"
	comm -23 "${TMPDIR:-/tmp}/profile-ov.$$" "${TMPDIR:-/tmp}/profile-ls.$$"
	rm -f "${TMPDIR:-/tmp}/profile-ov.$$" "${TMPDIR:-/tmp}/profile-ls.$$";;
*) sed -n '2,19p' "$0" >&2; exit 2;;
esac
