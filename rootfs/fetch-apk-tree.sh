#!/bin/sh
# Download the published tree of the apk repository of this project. The build
# of the image installs its packages from this tree (docs/rootfs.md "Build the
# image"). Give the folder to build-rootfs.sh as TSX_APK_LOCAL.
#
#   rootfs/fetch-apk-tree.sh DIR [BASE_URL]
#
# DIR gets <ALPINE>/common/armv7 and <ALPINE>/xx60/armv7. Each folder gets
# APKINDEX.tar.gz and every package file that the index names. The script keeps
# a file that DIR already has, so a second run only fetches what is new.
# BASE_URL is the root of the published tree. The default is
# https://tsx-aports.unexceptional.net. ALPINE is the branch (default v3.24).
# The script needs curl, tar and awk.
set -eu
DIR=${1:-}
[ -n "$DIR" ] || { sed -n '2,13p' "$0" >&2; exit 2; }
BASE=${2:-https://tsx-aports.unexceptional.net}; BASE=${BASE%/}
ALPINE=${ALPINE:-v3.24}
for tool in curl tar awk; do
	command -v "$tool" >/dev/null 2>&1 || { echo "fetch-apk-tree: $tool is not installed" >&2; exit 1; }
done
if [ -t 2 ]; then PROGRESS=--progress-bar; else PROGRESS=-sS; fi

for repo in common xx60; do
	d=$DIR/$ALPINE/$repo/armv7
	u=$BASE/$ALPINE/$repo/armv7
	mkdir -p "$d"
	echo "== $repo: $u/APKINDEX.tar.gz"
	curl -fL --retry 3 -sS -o "$d/APKINDEX.tar.gz.part" "$u/APKINDEX.tar.gz" || { echo "fetch-apk-tree: cannot get $u/APKINDEX.tar.gz" >&2; exit 1; }
	mv "$d/APKINDEX.tar.gz.part" "$d/APKINDEX.tar.gz"
	# One line for each package: file name and size in bytes.
	tar -xzOf "$d/APKINDEX.tar.gz" APKINDEX | awk '
		/^P:/ { p = substr($0, 3) }
		/^V:/ { v = substr($0, 3) }
		/^S:/ { print p "-" v ".apk", substr($0, 3) }' > "$d/.files"
	n=0; total=$(wc -l < "$d/.files" | tr -d ' ')
	while read -r f size; do
		n=$((n + 1))
		if [ -s "$d/$f" ]; then
			echo "[$n/$total] $f: already here"
			continue
		fi
		echo "[$n/$total] $f ($((size / 1048576)) MiB)"
		curl -fL --retry 3 $PROGRESS -o "$d/$f.part" "$u/$f" || { echo "fetch-apk-tree: cannot get $u/$f" >&2; rm -f "$d/$f.part"; exit 1; }
		mv "$d/$f.part" "$d/$f"
	done < "$d/.files"
	rm -f "$d/.files"
done
echo "tree ready: $DIR/$ALPINE"
