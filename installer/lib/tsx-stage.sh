# tsx-stage.sh: the host side of "stage on the panel first" (docs/install.md
# "Stage on the panel first"). installer/tsx-install-mainline sources it (bash).
# Before the rescue boot, the host copies the install bundle and a gzip of the
# root image onto the card of the panel. The rescue then installs from that
# copy (installer/steps/tsx-rescue-staged) and needs no network. A lost link
# or a network move during the rescue no longer stops the install.
#
# Where the stage goes:
#   stock Android    card p5 ("sdcard", ext2, about 1.4 GiB): MOUNT/tsx-stage
#   a mainline panel card p4 (tsxdata, /data): /data/tsx-stage
# Both places are on the card. The install formats them, or (a reinstall that
# keeps /data) the rescue removes the stage before it writes.
#
# The caller provides log, run_stream_cmd and the variables HERE, RESULTS,
# TMPFILES (an array of files to remove at exit) and TSX_CONFIG_BIN (the
# tsx-config of tsx-linux-common, lib/tsx-config-prompt.sh).

# tsx_bundle_make DIR CONFIG URL FLAVOR_DIR: the install bundle for /tmp/b of
# the rescue (steps/tsx-rescue-install) in DIR: the scripts of the rescue,
# panel.conf (CONFIG, if set), kiosk-url.txt (URL, if set), and manifest and
# boot.img of FLAVOR_DIR (if set: --fetch adds them on the panel). root.img
# (about 1 GiB) does not fit in the RAM of the rescue, so the bundle never has
# it: the host streams it, or the stage carries a gzip of it.
tsx_bundle_make() {
	local d=$1 conf=$2 url=$3 fdir=$4
	[ -n "$url" ] && printf '%s\n' "$url" > "$d/kiosk-url.txt"
	[ -n "$conf" ] && { install -m 600 "$conf" "$d/panel.conf"; log "  panel.conf included in the install bundle ($(TSX_CONF="$conf" "$TSX_CONFIG_BIN" show | wc -l) keys set)"; }
	[ -z "$fdir" ] || cp "$fdir/manifest" "$fdir/boot.img" "$d/"
	cp "$HERE/lib/tsx-rescue.sh" "$HERE/lib/tsx-tfa.sh" "$HERE/lib/tsx-psr.sh" "$HERE/lib/tsx-ledstock.sh" "$HERE/emmc/tsx-usb-recovery" "$HERE/steps/tsx-rescue-install" "$d/"
	chmod +x "$d/tsx-rescue-install" "$d/tsx-usb-recovery"
	tsx_bundle_sums "$d"
}
# tsx_bundle_sums DIR: SHA256SUMS of every file of the bundle DIR.
tsx_bundle_sums() { (cd "$1" && find . -type f ! -name 'SHA256SUMS*' -print | sort | xargs sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS); }

# tfa_puf_fetch DIR: rootfs/vendor-fetch.sh here (the .puf download, cached),
# then put its DSP files in DIR (the tfa/ layout with SOURCE and SHA256SUMS).
# Sets TFA_PUF_N.
tfa_puf_fetch() {
	local dir=$1 fetch="$HERE/../rootfs/vendor-fetch.sh" local_dir v n=0
	local_dir=${TFA_VENDOR_LOCAL:-"$HERE/../rootfs/vendor-local/tfa9890"}
	log "  TFA9890: rootfs/vendor-fetch.sh on this host (Crestron's .puf, 357 MB, downloaded once and cached). The log is in $RESULTS"
	command -v unzip >/dev/null || busybox --list 2>/dev/null | grep -x unzip >/dev/null \
		|| log "  WARNING: no unzip on this host (neither unzip nor busybox unzip): vendor-fetch.sh will fail unless its files are already cached"
	[ -x "$fetch" ] && "$fetch" >>"$RESULTS" 2>&1 || { log "  WARNING: rootfs/vendor-fetch.sh failed (see $RESULTS)"; return 1; }
	rm -rf "$dir"; mkdir -p "$dir"
	for v in $TSX_TFA_VARIANTS; do
		[ -f "$local_dir/$v/stereo.cnt" ] || continue
		mkdir -p "$dir/$v"; cp "$local_dir/$v/stereo.cnt" "$dir/$v/"; n=$((n + 1))
	done
	[ $n -gt 0 ] || { log "  WARNING: vendor-fetch.sh left no stereo.cnt in $local_dir"; rm -rf "$dir"; return 1; }
	{ echo "source=puf"; echo "firmware=$(basename "${TFA_PUF_URL:-tsw-xx60_3.002.1061.001.puf}") (rootfs/vendor-fetch.sh, pinned sha256)"
	  for v in $TSX_TFA_VARIANTS; do [ -f "$dir/$v/stereo.cnt" ] && echo "$v=$(sha256sum < "$dir/$v/stereo.cnt" | cut -d' ' -f1) pinned"; done; } > "$dir/SOURCE"
	(cd "$dir" && find . -type f ! -name SHA256SUMS | sed 's#^\./##' | sort | xargs sha256sum > SHA256SUMS)
	TFA_PUF_N=$n
}
# psr_puf_fetch DIR: rootfs/vendor-fetch.sh --psr here, then put the PSR file
# in DIR (the psr/ layout with SOURCE and SHA256SUMS). Sets PSR_PUF_SHA.
psr_puf_fetch() {
	local dir=$1 fetch="$HERE/../rootfs/vendor-fetch.sh" local_dir sha
	local_dir=${PSR_VENDOR_LOCAL:-"$HERE/../rootfs/vendor-local/csr8811"}
	log "  Bluetooth PSR: rootfs/vendor-fetch.sh --psr on this host (Crestron's .puf, 357 MB, downloaded once and cached). The log is in $RESULTS"
	[ -x "$fetch" ] && "$fetch" --psr >>"$RESULTS" 2>&1 || { log "  WARNING: rootfs/vendor-fetch.sh --psr failed (see $RESULTS)"; return 1; }
	[ -f "$local_dir/$TSX_PSR_NAME" ] || { log "  WARNING: vendor-fetch.sh --psr left no $TSX_PSR_NAME in $local_dir"; return 1; }
	rm -rf "$dir"; mkdir -p "$dir"
	cp "$local_dir/$TSX_PSR_NAME" "$dir/"
	sha=$(sha256sum < "$dir/$TSX_PSR_NAME" | cut -d' ' -f1)
	{ echo "source=puf"; echo "firmware=$(basename "${TFA_PUF_URL:-tsw-xx60_3.002.1061.001.puf}") (rootfs/vendor-fetch.sh --psr, pinned sha256)"
	  echo "sha256=$sha $([ "$sha" = "$(tsx_psr_pinned)" ] && echo pinned || echo unpinned)"; } > "$dir/SOURCE"
	(cd "$dir" && sha256sum "$TSX_PSR_NAME" SOURCE > SHA256SUMS)
	PSR_PUF_SHA=$sha
}

# tsx_stage_puf_files BUNDLE TFA_SOURCE PSR_SOURCE: the .puf files for a
# stage. The rescue looks on the panel first. With puf, the stage carries the
# download. With auto, it carries the files only if this host has them in its
# cache already (the rescue uses them only when the panel has none).
tsx_stage_puf_files() {
	local d=$1 tfa_cached psr_cached
	tfa_cached=$(ls "${TFA_VENDOR_LOCAL:-$HERE/../rootfs/vendor-local/tfa9890}"/*/stereo.cnt 2>/dev/null | head -n 1) || tfa_cached=
	psr_cached=$(ls "${PSR_VENDOR_LOCAL:-$HERE/../rootfs/vendor-local/csr8811}/$TSX_PSR_NAME" 2>/dev/null) || psr_cached=
	case "$2" in
	puf) tfa_puf_fetch "$d/tfa" || log "  WARNING: no .puf DSP files for the stage";;
	auto) [ -z "$tfa_cached" ] || tfa_puf_fetch "$d/tfa-puf" || true;;
	esac
	case "$3" in
	puf) psr_puf_fetch "$d/psr" || log "  WARNING: no .puf PSR file for the stage";;
	auto) [ -z "$psr_cached" ] || psr_puf_fetch "$d/psr-puf" || true;;
	esac
	tsx_bundle_sums "$d"
}


# tsx_stage_rescue_ok IMG: true if the rescue image IMG has the staged-install
# runner (/usr/sbin/tsx-rescue-staged, installer/rescue/mkrescue.sh). An older
# rescue image cannot run a stage by itself.
tsx_stage_rescue_ok() {
	python3 -I - "$1" <<'PY'
import gzip, struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
h = struct.unpack_from('<8s10I', d, 0)
if h[0] != b'ANDROID!':
    sys.exit(1)
ks, rs, ps = h[1], h[3], h[8]
pad = lambda n: (n + ps - 1) // ps * ps
rd = d[ps + pad(ks): ps + pad(ks) + rs]
out = b''
while rd:
    z = zlib.decompressobj(31)
    try:
        out += z.decompress(rd)
    except zlib.error:
        break
    rd = z.unused_data.lstrip(b'\0')
sys.exit(0 if b'usr/sbin/tsx-rescue-staged' in out and b'tsx-rescue-staged auto' in out else 1)
PY
}

# tsx_stage_gzip ROOT_IMG: make a gzip of ROOT_IMG. The file
# ROOT_IMG.gz next to the image is used again when ROOT_IMG.gz.info names the
# same sha256 of the root. Else the function makes it there, or in a
# temporary file when the folder is read-only. It prints a progress line
# about every 10 s. Sets STAGE_GZ (the path), STAGE_GZ_SHA and STAGE_GZ_BYTES.
tsx_stage_gzip() {
	local img=$1 want gz info pid t0 n
	want=$(sha256sum < "$img" | cut -d' ' -f1)
	gz=$img.gz info=$img.gz.info
	if [ -f "$gz" ] && [ -f "$info" ] && [ "$(sed -n 's/^root_sha256=//p' "$info")" = "$want" ] \
		&& [ "$(sed -n 's/^gz_bytes=//p' "$info")" = "$(stat -c %s "$gz")" ]; then
		STAGE_GZ_SHA=$(sed -n 's/^gz_sha256=//p' "$info"); STAGE_GZ_BYTES=$(stat -c %s "$gz")
		log "  root.img.gz: using $gz ($((STAGE_GZ_BYTES / 1048576)) MiB, made earlier for this root image)"
		STAGE_GZ=$gz; return 0
	fi
	if ! { : > "$gz.part"; } 2>/dev/null; then
		gz=$(mktemp "$RESULTS.root-gz.XXXXXX"); TMPFILES+=("$gz"); info=
	else rm -f "$gz.part"
	fi
	log "  root.img.gz: compressing $(basename "$img") ($(( $(stat -c %s "$img") / 1048576 )) MiB) with gzip -6 to $gz"
	t0=$(date +%s)
	if command -v pigz >/dev/null 2>&1; then pigz -6 -c "$img" > "$gz.part" & else gzip -6 -c "$img" > "$gz.part" & fi
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		sleep 1; n=$(( $(date +%s) - t0 ))
		[ $((n % 10)) = 0 ] && log "  root.img.gz: $(( $(stat -c %s "$gz.part" 2>/dev/null || echo 0) / 1048576 )) MiB written, ${n} s"
	done
	wait "$pid" || { rm -f "$gz.part"; log "  root.img.gz: gzip failed"; return 1; }
	mv "$gz.part" "$gz"
	STAGE_GZ_SHA=$(sha256sum < "$gz" | cut -d' ' -f1); STAGE_GZ_BYTES=$(stat -c %s "$gz")
	[ -z "$info" ] || printf 'root_sha256=%s\ngz_sha256=%s\ngz_bytes=%s\n' "$want" "$STAGE_GZ_SHA" "$STAGE_GZ_BYTES" > "$info"
	log "  root.img.gz: $((STAGE_GZ_BYTES / 1048576)) MiB in $(( $(date +%s) - t0 )) s"
	STAGE_GZ=$gz
}

# tsx_stage_build OUT BUNDLE GZ KERNEL KEEP GOLDEN TFA_SOURCE PSR_SOURCE [EXTRA]:
# make the stage folder OUT for tsx_push_dir: STAGE, bundle/ (a link to
# BUNDLE), root.img.gz (a link to GZ) and SHA256SUMS over all of them. EXTRA
# holds more key=value lines for STAGE. Needs STAGE_GZ_SHA and STAGE_GZ_BYTES
# (tsx_stage_gzip).
tsx_stage_build() {
	local out=$1 bundle=$2 gz=$3
	rm -rf "$out"; mkdir -p "$out"
	{ echo "format=tsx-stage-1"; echo "kernel=$4"; echo "keep_data=$5"; echo "golden=$6"
	  echo "tfa_source=$7"; echo "psr_source=$8"
	  echo "root_gz_bytes=$STAGE_GZ_BYTES"; echo "root_gz_sha256=$STAGE_GZ_SHA"
	  [ -z "${9:-}" ] || printf '%s\n' "$9"; } > "$out/STAGE"
	ln -s "$(cd "$bundle" && pwd)" "$out/bundle"
	ln -s "$(cd "$(dirname "$gz")" && pwd)/$(basename "$gz")" "$out/root.img.gz"
	{ sha256sum "$out/STAGE" | sed "s#  $out/#  #"
	  echo "$STAGE_GZ_SHA  root.img.gz"
	  (cd "$bundle" && find . -type f -print | sed 's#^\./##' | sort | xargs sha256sum | sed 's#  #  bundle/#'); } > "$out/SHA256SUMS"
}

# tsx_stage_kib OUT: the size of the stage folder in KiB, links followed.
tsx_stage_kib() { du -skL "$1" | cut -f1; }

# tsx_stage_push_kiosk OUT SSH...: copy the stage folder to /data/tsx-stage of a
# running mainline panel (tsx_push_dir: one tar stream, sha256 check, the old
# stage replaced only after a good check, progress). Checks the free space of
# /data first. Returns 1 when it does not fit or the copy fails. Test hook:
# TSX_STAGE_KIOSK_DIR (default /data/tsx-stage).
tsx_stage_push_kiosk() {
	local out=$1 need free d=${TSX_STAGE_KIOSK_DIR:-/data/tsx-stage}; shift
	need=$(( $(tsx_stage_kib "$out") + 16384 ))
	free=$("$@" "rm -rf $d.new; df -Pk ${d%/*} | awk 'NR==2{print \$4}'" </dev/null 2>/dev/null) || free=
	case "$free" in ''|*[!0-9]*) log "  stage: cannot read the free space of ${d%/*} on the panel"; return 1;; esac
	if [ "$free" -lt "$need" ]; then
		log "  stage: ${d%/*} has $((free / 1024)) MiB free, the stage needs $((need / 1024)) MiB"
		return 1
	fi
	log "  stage: copying $((need / 1024 - 16)) MiB to $d on the panel ($((free / 1024)) MiB free)"
	TSX_PUSH_LABEL="the stage" run_stream_cmd tsx_push_dir "$out" "$d" "$@" </dev/null
}

# tsx_stage_push_android OUT HOST: copy the stage folder to card p5 of a stock
# Android panel over the root shell (steps/rootsh --put, sha256 checked). The
# arm payload must be in /data/tsx-inst (it has tsx-lib.sh). The files go to
# MOUNT/tsx-stage.new first, and the folder is renamed to MOUNT/tsx-stage last,
# so the rescue never sees half a stage. Sets STAGE_ANDROID_DIR.
tsx_stage_push_android() {
	local out=$1 h=$2 mnt need free t
	mnt=$("$HERE/steps/rootsh" "$h" '. /data/tsx-inst/android/tsx-lib.sh; tsx_find_disk && [ "$TSX_DISK_LAYOUT" = stock ] && tsx_mounts_of "$P5" | head -n 1' 2>>"$RESULTS" | tr -d '\r' | grep '^/' | tail -n 1) || mnt=
	[ -n "$mnt" ] || { log "  stage: card p5 (sdcard) is not mounted on the panel"; return 1; }
	case "$mnt" in *[!A-Za-z0-9/._-]*) log "  stage: unusual mount point of p5: $mnt"; return 1;; esac
	need=$(( $(tsx_stage_kib "$out") + 16384 ))
	free=$("$HERE/steps/rootsh" "$h" "rm -rf $mnt/tsx-stage.new; busybox df -Pk $mnt | busybox awk 'NR==2{print \$4}'" 2>>"$RESULTS" | tr -dc '0-9\n' | grep . | tail -n 1) || free=
	[ -n "$free" ] || { log "  stage: cannot read the free space of $mnt on the panel"; return 1; }
	if [ "$free" -lt "$need" ]; then
		log "  stage: card p5 ($mnt) has $((free / 1024)) MiB free, the stage needs $((need / 1024)) MiB"
		return 1
	fi
	log "  stage: copying $((need / 1024 - 16)) MiB to $mnt/tsx-stage on the panel ($((free / 1024)) MiB free)"
	t=$(mktemp "$RESULTS.stage-tar.XXXXXX"); TMPFILES+=("$t")
	tar -h --owner=0 --group=0 -C "$out" -cf "$t" STAGE SHA256SUMS bundle || return 1
	"$HERE/steps/rootsh" "$h" "mkdir -p $mnt/tsx-stage.new" >/dev/null 2>>"$RESULTS" || return 1
	run_stream_cmd "$HERE/steps/rootsh" --put "$h" "$t" "$mnt/tsx-stage.new/stage.tar" || return 1
	run_stream_cmd "$HERE/steps/rootsh" --put "$h" "$out/root.img.gz" "$mnt/tsx-stage.new/root.img.gz" || return 1
	"$HERE/steps/rootsh" "$h" "cd $mnt/tsx-stage.new && busybox tar -xf stage.tar && rm -f stage.tar && cd / && rm -rf $mnt/tsx-stage && mv $mnt/tsx-stage.new $mnt/tsx-stage && sync && echo STAGE-OK" 2>>"$RESULTS" | grep -q STAGE-OK \
		|| { log "  stage: unpacking the stage on the panel failed"; return 1; }
	STAGE_ANDROID_DIR=$mnt/tsx-stage
	log "  stage: $mnt/tsx-stage is complete (each file sha256 checked)"
}

# tsx_staged_follow LINE [--no-start] SSH...: print the log of the staged
# install in the rescue from LINE on, until the run ends or the connection
# drops. It copies the runner of this host to /run first. It starts the runner
# if the rescue has not started one in this boot (an older rescue image),
# unless --no-start (a resume: an earlier run of the push path can still be
# busy). It prints the STAGED-RESULT line last. The status is that of the
# remote "follow": 0 done, 1 failed, 2 still running, 3 no stage, 255 ssh
# failed.
tsx_staged_follow() {
	local from=$1 start="&& sh /run/tsx-rescue-staged.host start"; shift
	[ "${1:-}" = --no-start ] && { start=; shift; }
	"$@" "cat > /run/tsx-rescue-staged.host && chmod 755 /run/tsx-rescue-staged.host $start" \
		< "$HERE/steps/tsx-rescue-staged" || return 255
	"$@" "sh /run/tsx-rescue-staged.host follow $from" </dev/null
}
