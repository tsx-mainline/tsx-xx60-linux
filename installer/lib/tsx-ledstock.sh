# tsx-ledstock.sh: find the stock firmware image of the USB LED bar
# (statussign_*.upg) on the panel itself, before the install overwrites the
# eMMC root region. tsx-ledbar-flash loads it back into the bar (docs/rootfs.md
# "Front keys, key LEDs, and the LED bar"). It is a Crestron file: it never
# goes into a repository, a package or an image, and it never leaves the
# panel.
# These files source it:
#   - installer/steps/tsx-rescue-install (the `ledstock` command, in the
#     rescue: busybox ash, RAM root). It runs BEFORE anything is written to
#     the eMMC.
#   - installer/lib/tests/test-tsx-ledstock.sh (host tests, made-up files only)
# Use POSIX sh + `local`. The code reads block devices and never writes them.
# It mounts the old root read-only with `noload` (no journal replay).
#
# The sources, in order. The first valid file wins.
#   android-system  stock Android: the eMMC root region is the Android system
#                   partition then (build.prop at its top). The file is at
#                   vendor/firmware/ or system/vendor/firmware/
#   earlier         a file that an earlier attempt in this same rescue session
#                   already collected (a re-run after a failed install)
# A mainline root has no copy. On a reinstall, the copy lives on tsxdata
# (/data/tsx/vendor/) and tsx-rescue-install keeps it with the data.
#
# tsx_ledstock_validate checks the file: Motorola S-records (S3 lines), the
# first record is the application tag at 0xBAD0ADD0, 1 KiB to 1 MiB. The
# check does not pin a sha256, because the stock firmware of a unit can differ.

TSX_LEDSTOCK_GLOB='statussign_*.upg'
TSX_LEDSTOCK_DIRS='vendor/firmware system/vendor/firmware'

# tsx_ledstock_validate FILE: print one line. Return 0 (valid) or 2 (reject).
tsx_ledstock_validate() {
	local f=$1 size sha first
	[ -f "$f" ] || { echo "missing"; return 2; }
	size=$(wc -c < "$f" | tr -d ' ')
	sha=$(sha256sum < "$f" | cut -d' ' -f1)
	{ [ "$size" -ge 1024 ] && [ "$size" -le 1048576 ]; } || { echo "implausible size $size bytes (sha256 $sha)"; return 2; }
	if LC_ALL=C tr -d '\r\n\040-\176' < "$f" | head -c 1 | grep -q .; then
		echo "not a text file (sha256 $sha)"; return 2
	fi
	if LC_ALL=C tr -d '\r' < "$f" | grep -Ev '^S[0-9A-Fa-f][0-9A-Fa-f]+$' | grep -q .; then
		echo "a line is not an S-record (sha256 $sha)"; return 2
	fi
	first=$(head -n 1 "$f" | tr -d '\r')
	case $first in
	S3??BAD0ADD0*) ;;
	*) echo "no application tag record at 0xBAD0ADD0 (sha256 $sha)"; return 2;;
	esac
	echo "sha256 $sha, $size bytes"
	return 0
}

# tsx_ledstock_find DIR: print the last (by name) statussign_*.upg in DIR.
tsx_ledstock_find() {
	ls -1 "$1"/$TSX_LEDSTOCK_GLOB 2>/dev/null | sort | tail -n 1
}

# tsx_ledstock_collect OUTDIR ROOTDEV [EARLIERDIR]: try the sources in order.
# On success, OUTDIR holds the .upg file and a SOURCE file (source=,
# firmware=, sha256=). The last line printed is
# "LEDSTOCK-RESULT source=<name> ok=<0|1>". The function always returns 0.
tsx_ledstock_collect() {
	local out=$1 root=$2 earlier=${3:-} w m src f fw rc why d name
	w=$out.tmp; rm -rf "$w"; mkdir -p "$w"
	m=
	if [ -d "$root" ]; then m=$root
	else
		m=${TSX_RUN:-/run}/tsx-ledstock-oldroot; mkdir -p "$m"
		mount -t ext4 -o ro,noload "$root" "$m" 2>/dev/null || { echo "ledstock: $root does not mount as ext4"; m=; }
	fi
	for src in android-system earlier; do
		f= fw=
		case $src in
		android-system)
			[ -n "$m" ] && [ -f "$m/build.prop" ] || continue
			for d in $TSX_LEDSTOCK_DIRS; do
				f=$(tsx_ledstock_find "$m/$d")
				[ -n "$f" ] && break
			done
			[ -n "$f" ] || continue
			fw="Android $(sed -n 's/^ro\.build\.display\.id=//p' "$m/build.prop" | head -n 1)"
			;;
		earlier)
			[ -n "$earlier" ] || continue
			f=$(tsx_ledstock_find "$earlier")
			[ -n "$f" ] || continue
			fw="$(sed -n 's/^firmware=//p' "$earlier/SOURCE" 2>/dev/null | head -n 1) (kept from an earlier attempt)"
			;;
		esac
		name=$(basename "$f")
		rc=0; why=$(tsx_ledstock_validate "$f") || rc=$?
		if [ "$rc" != 0 ]; then echo "ledstock: $src: $name REJECTED: $why"; continue; fi
		echo "ledstock: $src: $name ok: $why"
		cp "$f" "$w/$name" || { echo "ledstock: $src: copy failed"; continue; }
		{ echo "source=$src"; echo "firmware=$fw"; echo "file=$name"
		  echo "sha256=$(sha256sum < "$w/$name" | cut -d' ' -f1)"; } > "$w/SOURCE"
		[ -n "$m" ] && [ ! -d "$root" ] && umount "$m" 2>/dev/null
		rm -rf "$out"; mv "$w" "$out"
		echo "LEDSTOCK-RESULT source=$src ok=1"
		return 0
	done
	[ -n "$m" ] && [ ! -d "$root" ] && umount "$m" 2>/dev/null
	rm -rf "$w"
	echo "ledstock: no stock LED bar firmware image ($TSX_LEDSTOCK_GLOB) found in the stock system of this panel"
	echo "LEDSTOCK-RESULT source=none ok=0"
	return 0
}

# tsx_ledstock_deploy BUNDLE_LEDSTOCK_DIR DATA_MNT: copy the collected image
# into DATA_MNT/tsx/vendor/ (tsxdata, mounted read-write). Print the progress
# lines. A copy that is already there stays and is replaced only by a valid
# new one. It never fails the install: the return value is always 0.
tsx_ledstock_deploy() {
	local b=$1 dm=$2 dest f name want have
	dest=$dm/tsx/vendor
	f=$(tsx_ledstock_find "$b")
	if [ -n "$f" ]; then
		name=$(basename "$f")
		want=$(sha256sum < "$f" | cut -d' ' -f1)
		mkdir -p "$dest"
		if cp "$f" "$dest/$name.new" 2>/dev/null \
			&& [ "$(sha256sum < "$dest/$name.new" | cut -d' ' -f1)" = "$want" ] \
			&& chmod 644 "$dest/$name.new" && mv "$dest/$name.new" "$dest/$name"; then
			cp "$b/SOURCE" "$dest/$name.source" 2>/dev/null || true
			echo "  ledstock: $name copied to /data/tsx/vendor/ ($want, source $(sed -n 's/^source=//p' "$b/SOURCE" 2>/dev/null))"
		else
			rm -f "$dest/$name.new"
			echo "  WARNING: ledstock: $name copy failed (non-fatal: tsx-ledbar-flash cannot load the stock firmware back)"
		fi
		return 0
	fi
	have=$(tsx_ledstock_find "$dest")
	if [ -n "$have" ]; then
		echo "  ledstock: kept the copy on tsxdata: /data/tsx/vendor/$(basename "$have")"
	else
		echo "  ledstock: no stock LED bar firmware image to keep. tsx-ledbar-flash cannot load the stock firmware back"
	fi
	return 0
}
