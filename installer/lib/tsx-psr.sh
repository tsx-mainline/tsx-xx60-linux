# tsx-psr.sh: find the CSR8811 Bluetooth PSR file (PSR-CSR8811.psr) on the
# panel itself, before the install overwrites the eMMC root region. tsx-bt
# loads it into the chip (docs/hardware.md "Bluetooth (CSR8811)"). It is a
# Crestron file: it never goes into a repository or an image, and it never
# leaves the panel.
# These files source it:
#   - installer/steps/tsx-rescue-install (the `psr` command, in the rescue:
#     busybox ash, RAM root). It runs BEFORE anything is written to the eMMC.
#   - installer/tsx-install-mainline (host: tsx_psr_plan only)
#   - installer/lib/tests/test-tsx-psr.sh (host tests, made-up files only)
# Use POSIX sh + `local`. The code reads block devices and never writes them.
# It mounts the old root read-only with `noload` (no journal replay).
#
# The sources, in order. The first valid file wins.
#   root            the current mainline root (a reinstall):
#                   usr/local/share/tsx/csr8811/PSR-CSR8811.psr on eMMC p8
#   android-system  stock Android: the same eMMC region is the Android system
#                   partition then (build.prop at its top), with the file at
#                   bin/PSR-CSR8811.psr
#   earlier         a file that an earlier attempt in this same rescue session
#                   already collected (a re-run after a failed install)
#
# How tsx_psr_validate checks the file:
#   sha256 = the pinned one                          -> ok
#   another sha256, but a sane PSR text file (1..64 KiB, printable ASCII,
#   every line that starts with '&' is "&KEY = WORD ...", one key at least)
#                                                    -> accepted with a warning
#   anything else                                    -> rejected
# If the panel has no valid file, the host can take it from the .puf download
# (rootfs/vendor-fetch.sh --psr, see tsx_psr_plan below). Without a file, the
# panel still works: tsx-bt then loads only the Bluetooth address, and the
# chip runs on its ROM defaults.
# A panel with government=1 (the TSW-760-NC, docs/hardware.md "Panel
# variants") has no Bluetooth module and needs no PSR file. The psr command
# reads the flag first (tsx_psr_government). Then it looks for no file and
# records "not-needed" (tsx_psr_not_needed), and the host downloads no .puf.
# Test hooks: TSX_PSR_PINNED (replaces the pinned sha256) and a directory as
# the root device (used as the mounted root).

TSX_PSR_NAME=PSR-CSR8811.psr
TSX_PSR_REL=usr/local/share/tsx/csr8811

# The sha256 of bin/PSR-CSR8811.psr in system.img of the public Crestron
# firmware tsw-xx60_3.002.1061.001 (7814 bytes). tsx-bt has the same value.
tsx_psr_pinned() {
	echo "${TSX_PSR_PINNED:-96709f6ca529efb0dc8cf48165ba0c1c1934236794424aa539810376676aa8be}"
}

# tsx_psr_government CMDLINE_FILE: print 0 or 1, or nothing if the flag is
# not known. The source is androidboot.government=N on the kernel command
# line: U-Boot builds it from its env at every boot, also for the rescue. If
# the line has no such word, and the caller has sourced tsx-lib.sh and set
# FWP (tsx_pick_fwenv) and FWCFG, the U-Boot env itself (tsx_env).
tsx_psr_government() {
	local w g=
	for w in $(cat "${1:-/proc/cmdline}" 2>/dev/null); do
		case $w in androidboot.government=*) g=${w#androidboot.government=};; esac
	done
	if [ -z "$g" ] && [ -n "${FWP:-}" ] && type tsx_env >/dev/null 2>&1; then
		g=$(tsx_env government 2>/dev/null) || g=
	fi
	case $g in 0|1) echo "$g";; esac
	return 0
}

# tsx_psr_not_needed OUTDIR: record in OUTDIR/SOURCE that this panel needs
# no PSR file (government=1). OUTDIR gets no PSR file. "run" copies the
# SOURCE file into the new root.
tsx_psr_not_needed() {
	rm -rf "$1"; mkdir -p "$1"
	{ echo "source=not-needed"
	  echo "firmware=none (government=1: this panel has no Bluetooth module)"
	  echo "sha256=none"; } > "$1/SOURCE"
	echo "psr: government=1: this panel has no Bluetooth module. No PSR file is needed"
	echo "PSR-RESULT source=not-needed ok=0 government=1"
}

# tsx_psr_validate FILE: print one line. Return 0 (pinned sha256), 1 (unknown
# sha256, sane PSR text) or 2 (reject).
tsx_psr_validate() {
	local f=$1 size sha nkeys
	[ -f "$f" ] || { echo "missing"; return 2; }
	size=$(wc -c < "$f" | tr -d ' ')
	sha=$(sha256sum < "$f" | cut -d' ' -f1)
	if [ "$sha" = "$(tsx_psr_pinned)" ]; then echo "sha256 $sha (pinned)"; return 0; fi
	[ "$size" -ge 1 ] && [ "$size" -le 65536 ] || { echo "implausible size $size bytes (sha256 $sha)"; return 2; }
	if LC_ALL=C tr -d '\t\r\n\040-\176' < "$f" | head -c 1 | grep -q .; then
		echo "not a text file (sha256 $sha)"; return 2
	fi
	if grep '^[[:space:]]*&' "$f" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
		| grep -Ev '^&[0-9A-Fa-f]{1,4}[[:space:]]*=([[:space:]]*[0-9A-Fa-f]{1,4})+$' | grep -q .; then
		echo "a key line is not '&KEY = WORD ...' (sha256 $sha)"; return 2
	fi
	nkeys=$(grep -c '^[[:space:]]*&' "$f")
	[ "$nkeys" -ge 1 ] || { echo "no PS key in the file (sha256 $sha)"; return 2; }
	echo "sha256 $sha is NOT the pinned one. Sane PSR text, $nkeys keys, $size bytes"
	return 1
}

# tsx_psr_collect OUTDIR ROOTDEV [EARLIERDIR]: try the sources in order. On
# success, OUTDIR holds PSR-CSR8811.psr and a SOURCE file (source=,
# firmware=, sha256=<hash> pinned|unpinned). The last line printed is
# "PSR-RESULT source=<name> ok=<0|1>". The function always returns 0.
tsx_psr_collect() {
	local out=$1 root=$2 earlier=${3:-} w m src f fw rc why
	w=$out.tmp; rm -rf "$w"; mkdir -p "$w"
	m=
	if [ -d "$root" ]; then m=$root
	else
		m=${TSX_RUN:-/run}/tsx-psr-oldroot; mkdir -p "$m"
		mount -t ext4 -o ro,noload "$root" "$m" 2>/dev/null || { echo "psr: $root does not mount as ext4"; m=; }
	fi
	for src in root android-system earlier; do
		f= fw=
		case $src in
		root)
			[ -n "$m" ] && [ -f "$m/$TSX_PSR_REL/$TSX_PSR_NAME" ] || continue
			f=$m/$TSX_PSR_REL/$TSX_PSR_NAME
			fw=$(sed -n 's/^firmware=//p' "$m/$TSX_PSR_REL/SOURCE" 2>/dev/null | head -n 1)
			fw=${fw:-copied from the previous mainline root}
			;;
		android-system)
			[ -n "$m" ] && [ -f "$m/build.prop" ] && [ -f "$m/bin/$TSX_PSR_NAME" ] || continue
			f=$m/bin/$TSX_PSR_NAME
			fw="Android $(sed -n 's/^ro\.build\.display\.id=//p' "$m/build.prop" | head -n 1)"
			;;
		earlier)
			[ -n "$earlier" ] && [ -f "$earlier/$TSX_PSR_NAME" ] || continue
			f=$earlier/$TSX_PSR_NAME
			fw="$(sed -n 's/^firmware=//p' "$earlier/SOURCE" 2>/dev/null | head -n 1) (kept from an earlier attempt)"
			;;
		esac
		rc=0; why=$(tsx_psr_validate "$f") || rc=$?
		case $rc in
		0) echo "psr: $src: $TSX_PSR_NAME ok: $why";;
		1) echo "psr: $src: WARNING: $TSX_PSR_NAME: $why. Accepted (from: $fw)";;
		*) echo "psr: $src: $TSX_PSR_NAME REJECTED: $why"; continue;;
		esac
		cp "$f" "$w/$TSX_PSR_NAME" || { echo "psr: $src: copy failed"; continue; }
		{ echo "source=$src"; echo "firmware=$fw"
		  echo "sha256=$(sha256sum < "$w/$TSX_PSR_NAME" | cut -d' ' -f1) $([ $rc = 0 ] && echo pinned || echo unpinned)"; } > "$w/SOURCE"
		[ -n "$m" ] && [ ! -d "$root" ] && umount "$m" 2>/dev/null
		rm -rf "$out"; mv "$w" "$out"
		echo "PSR-RESULT source=$src ok=1"
		return 0
	done
	[ -n "$m" ] && [ ! -d "$root" ] && umount "$m" 2>/dev/null
	rm -rf "$w"
	echo "psr: no Bluetooth PSR file on the panel. tsx-bt will load only the Bluetooth address"
	echo "PSR-RESULT source=none ok=0"
	return 0
}

# tsx_psr_plan MODE PANEL_OK [GOVERNMENT]: print what the host does next
# (--psr-source MODE). PANEL_OK is 1 if the rescue found a valid file, 0 if
# it found none, or "-" if nobody asked the rescue. GOVERNMENT is 1 if the
# rescue reported government=1. The rescue looks only in modes auto and
# panel, so only these two modes know the flag.
#   use-panel   keep the file of the panel, no download
#   puf         run rootfs/vendor-fetch.sh --psr (the .puf download) and push its file
#   none        no PSR file
#   not-needed  government=1: no PSR file, no download. The rescue has
#               recorded SOURCE (source=not-needed)
tsx_psr_plan() {
	case "$1:${3:-}" in auto:1|panel:1) echo not-needed; return 0;; esac
	case "$1:$2" in
	none:*) echo none;;
	puf:*) echo puf;;
	panel:1|auto:1) echo use-panel;;
	panel:*) echo none;;
	auto:*) echo puf;;
	*) echo none; return 1;;
	esac
}
