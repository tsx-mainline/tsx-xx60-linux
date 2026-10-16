#!/bin/bash
# Host test: stage on the panel first (docs/install.md "Stage on the panel
# first"). No docker, no root, no panel.
#   1. the host side (lib/tsx-stage.sh): the check of the rescue image for the
#      runner, the gzip cache, the stage folder, and the copy to a "kiosk"
#      (a fake ssh that runs the command under busybox sh on this host)
#   2. the rescue side (steps/tsx-rescue-staged) on that copied stage, with a
#      fake tsx-rescue-install: the stage goes to RAM, the root image goes
#      through gunzip into "run", the stage is gone afterwards, follow and
#      status report the result
#   3. the failures: not enough RAM, a corrupt root.img.gz, no stage, a second
#      runner in the same boot
#   4. the choice of the DSP files: the panel set, the .puf files of the stage
#   5. the wiring: mkrescue.sh puts the runner into the rescue image,
#      release.yml rebuilds the rescue when the runner changes, a dry run of
#      tsx-install-mainline names the stage
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
for t in busybox python3 sha256sum tar gzip; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED test-install-stage: no $t on this host"; exit 0; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
MIB=1048576
RESULTS=$W/results.txt; TMPFILES=()
log() { printf '%s\n' "$*" >> "$RESULTS"; printf '%s\n' "$*" >&2; }
run_stream_cmd() { local tmp rc; tmp=$(mktemp); if "$@" > "$tmp" 2>&1; then rc=0; else rc=$?; fi; RS_OUT=$(cat "$tmp"); cat "$tmp" | tee -a "$RESULTS"; rm -f "$tmp"; return $rc; }
. "$HERE/lib/tsx-rescue.sh"
. "$HERE/lib/tsx-stage.sh"

# ---- a fake ssh: ssh [options] host CMD -> busybox sh -c CMD on this host ----
mkdir -p "$W/bin"
cat > "$W/bin/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o|-i|-p|-c|-e|-l) shift 2;; -*) shift;; *) break;; esac; done
shift
exec busybox sh -c "$*"
EOF
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH"

# ---- a fake payload --------------------------------------------------------------
P=$W/payload/lts; mkdir -p "$P"
head -c $((4 * MIB)) /dev/urandom > "$P/root.img"; head -c $((2 * MIB)) /dev/zero >> "$P/root.img"
head -c 300000 /dev/urandom > "$P/boot.img"
ROOT_SHA=$(sha256sum < "$P/root.img" | cut -d' ' -f1); BOOT_SHA=$(sha256sum < "$P/boot.img" | cut -d' ' -f1)
printf 'format=tsx-rescue-install-1\nroot_bytes=%s\nroot_sha256=%s\nboot_sha256=%s\nkernel_flavor=lts\n' "$(stat -c %s "$P/root.img")" "$ROOT_SHA" "$BOOT_SHA" > "$P/manifest"
BUN=$W/bundle; mkdir -p "$BUN"
cp "$P/manifest" "$P/boot.img" "$HERE/lib/tsx-rescue.sh" "$BUN/"
mkdir -p "$BUN/tfa-puf/settings_a"; echo puf-set > "$BUN/tfa-puf/settings_a/stereo.cnt"
(cd "$BUN" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)

# ---- a fake tsx-rescue-install for the runner ------------------------------------
# tfa: FAKE_TFA_N variants on the panel. run: read the root image on stdin into
# $W/p8 and print the WRITE-RESULT lines like tsx_write_verify does.
cat > "$W/fake-install" <<EOF
#!/bin/sh
cmd=\$1 b=\$2; shift 2
case \$cmd in
tfa) n=\${FAKE_TFA_N:-3}; mkdir -p "\$b/tfa-panel"; i=0; while [ \$i -lt \$n ]; do mkdir -p "\$b/tfa-panel/v\$i"; echo panel > "\$b/tfa-panel/v\$i/stereo.cnt"; i=\$((i + 1)); done
	echo "TFA-RESULT source=root count=\$n";;
psr) [ "\${FAKE_PSR:-1}" = 1 ] && { mkdir -p "\$b/psr"; echo psr > "\$b/psr/PSR-CSR8811.psr"; }; echo "PSR-RESULT ok=\${FAKE_PSR:-1} source=root government=0";;
ledstock) echo "LEDSTOCK-RESULT ok=0";;
check) case "\$*" in *"--root-from -"*) echo "check OK (nothing written) \$*";; *) echo "no root image at \$b/root.img"; exit 1;; esac;;
run) echo "run args: \$*"; cat > "$W/p8"
	echo "WRITE-RESULT name=boot bytes=1 sha256=$BOOT_SHA ok=1"
	g=\$(sha256sum < "$W/p8" | cut -d' ' -f1); o=0; [ "\$g" = "$ROOT_SHA" ] && o=1
	echo "WRITE-RESULT name=root bytes=1 sha256=\$g ok=\$o"; [ \$o = 1 ];;
esac
EOF
chmod +x "$W/fake-install"

echo "== 1. the host side: rescue image check, gzip cache, stage folder, copy to the kiosk"
mkimg() {  # OUT [with-runner]: an Android boot image whose ramdisk is two gzip cpio members
	python3 -I - "$1" "${2:-}" <<'PY'
import gzip, struct, sys
ps = 2048
rd = gzip.compress(b'070701...init...etc/inittab::sysinit:/etc/init.d/rcS\n')
if sys.argv[2]:
    rd += gzip.compress(b'070701...usr/sbin/tsx-rescue-staged...::once:/usr/sbin/tsx-rescue-staged auto\n')
k = b'\0' * 4096
hdr = struct.pack('<8s10I', b'ANDROID!', len(k), 0x8000, len(rd), 0x1000000, 0, 0, 0x100, ps, 0, 0)
pad = lambda b: b + b'\0' * ((ps - len(b) % ps) % ps)
open(sys.argv[1], 'wb').write(pad(hdr) + pad(k) + pad(rd))
PY
}
mkimg "$W/rescue-new.img" yes; mkimg "$W/rescue-old.img"
tsx_stage_rescue_ok "$W/rescue-new.img" && ok "a rescue image with the runner and its inittab line passes" || bad "the new rescue image is refused"
tsx_stage_rescue_ok "$W/rescue-old.img" && bad "an older rescue image passes" || ok "an older rescue image (no runner) is refused"
tsx_stage_gzip "$P/root.img" 2>/dev/null; rc=$?
[ $rc = 0 ] && [ "$STAGE_GZ" = "$P/root.img.gz" ] && [ "$(gunzip -c "$STAGE_GZ" | sha256sum | cut -d' ' -f1)" = "$ROOT_SHA" ] \
	&& ok "root.img.gz next to the image, gunzip gives the root image" || bad "gzip: rc $rc STAGE_GZ=$STAGE_GZ"
[ "$STAGE_GZ_SHA" = "$(sha256sum < "$STAGE_GZ" | cut -d' ' -f1)" ] && [ "$STAGE_GZ_BYTES" = "$(stat -c %s "$STAGE_GZ")" ] && ok "STAGE_GZ_SHA and STAGE_GZ_BYTES" || bad "gz sha/bytes"
touch -d '2000-01-01' "$STAGE_GZ"
OUT=$(tsx_stage_gzip "$P/root.img" 2>&1)
case "$OUT" in *"made earlier for this root image"*) ok "a second run uses the gzip again (the .info names the same root)";; *) bad "no reuse: $OUT";; esac
tsx_stage_build "$W/st" "$BUN" "$STAGE_GZ" lts 1 1 auto auto
grep -q '^format=tsx-stage-1$' "$W/st/STAGE" && grep -q "^root_gz_sha256=$STAGE_GZ_SHA$" "$W/st/STAGE" && grep -q '^keep_data=1$' "$W/st/STAGE" \
	&& ok "STAGE names the format, keep_data and the gzip sha256" || bad "STAGE: $(cat "$W/st/STAGE")"
mkdir -p "$W/kiosk/data"; echo old > "$W/kiosk/data/keep.txt"
OUT=$(TSX_STAGE_KIOSK_DIR=$W/kiosk/data/tsx-stage TSX_PUSH_PROGRESS_MIB=10000 tsx_stage_push_kiosk "$W/st" ssh root@kiosk 2>&1); rc=$?
[ $rc = 0 ] && ok "the stage copy to the kiosk: rc 0" || bad "kiosk copy rc $rc: $OUT"
case "$OUT" in *"files, sha256 checked"*) ok "the kiosk checks SHA256SUMS of the stage";; *) bad "no sha256 check: $OUT";; esac
[ -f "$W/kiosk/data/tsx-stage/STAGE" ] && [ -f "$W/kiosk/data/tsx-stage/bundle/manifest" ] && [ ! -L "$W/kiosk/data/tsx-stage/root.img.gz" ] \
	&& cmp -s "$STAGE_GZ" "$W/kiosk/data/tsx-stage/root.img.gz" && ok "STAGE, bundle/ and root.img.gz arrived as files" || bad "stage layout on the kiosk"
[ -f "$W/kiosk/data/keep.txt" ] && ok "the rest of /data stays" || bad "/data changed"
# no room: a remote that reports 10 KiB free (the busybox of a host can run
# its own df applet before any df in PATH, so the fake ssh answers itself)
mkdir -p "$W/bin-small"
cat > "$W/bin-small/ssh" <<'EOF'
#!/bin/bash
case "$*" in *"df -Pk"*) echo 10; exit 0;; esac   # the free KiB, as the awk on the panel prints it
exit 1
EOF
chmod +x "$W/bin-small/ssh"
OUT=$(TSX_STAGE_KIOSK_DIR=$W/kiosk2/data/tsx-stage tsx_stage_push_kiosk "$W/st" "$W/bin-small/ssh" root@kiosk 2>&1); rc=$?
[ $rc != 0 ] && case "$OUT" in *"MiB free, the stage needs"*) true;; *) false;; esac && ok "no room on /data: the copy is refused before any byte goes" || bad "no-room: rc $rc $OUT"

echo "== 2. the rescue side on the copied stage"
S=$W/kiosk/data/tsx-stage
rr() { TSX_RUN=$W/run TSX_TMP=$W/tmp TSX_STAGE_DIR=$S TSX_STAGED_INSTALL=$W/fake-install TSX_NO_REBOOT=1 TSX_STATUS=$W/run/state "$@"; }
mkdir -p "$W/run" "$W/tmp"
rr busybox sh "$HERE/steps/tsx-rescue-staged" auto; rc=$?
[ $rc = 0 ] && ok "auto: rc 0" || bad "auto rc $rc: $(cat "$W/run/tsx-staged.log")"
[ "$(cat "$W/run/tsx-staged.state")" = done ] && ok "state done" || bad "state: $(cat "$W/run/tsx-staged.state")"
cmp -s "$P/root.img" "$W/p8" && ok "\"run\" got the root image through gunzip on stdin" || bad "the root image differs"
[ ! -e "$S" ] && ok "the stage is gone from the card (it runs once)" || bad "the stage is still there"
[ -f "$W/tmp/b/manifest" ] && [ ! -e "$W/tmp/tsx-root.img.gz" ] && ok "the bundle is in RAM (/tmp/b), root.img.gz is freed after the run" || bad "RAM files"
grep -q 'run args: .*--yes --no-reboot --keep-data --root-from -' "$W/run/tsx-staged.log" && ok "run --yes --no-reboot --keep-data --root-from - (keep_data=1)" || bad "run args: $(grep 'run args' "$W/run/tsx-staged.log")"
grep -q 'check OK (nothing written) --keep-data --root-from -' "$W/run/tsx-staged.log" && ok "check --keep-data --root-from - (no root.img in the bundle)" || bad "check args: $(grep -i check "$W/run/tsx-staged.log")"
grep -q 'tfa: the panel set (3 of 3' "$W/run/tsx-staged.log" && [ -f "$W/tmp/b/tfa/v0/stereo.cnt" ] && [ ! -e "$W/tmp/b/tfa-puf" ] \
	&& ok "tfa: a full panel set wins over the .puf files" || bad "tfa choice: $(grep 'tfa:' "$W/run/tsx-staged.log")"
OUT=$(rr busybox sh "$HERE/steps/tsx-rescue-staged" follow 1); rc=$?
L=$(wc -l < "$W/run/tsx-staged.log")
[ $rc = 0 ] && case "$OUT" in *"WRITE-RESULT name=root"*"STAGED-RESULT state=done lines=$L"*) true;; *) false;; esac && ok "follow: the log, then STAGED-RESULT state=done lines=$L" || bad "follow rc $rc: $OUT"
tsx_write_result_check "$OUT" root "$ROOT_SHA" && tsx_write_result_check "$OUT" boot "$BOOT_SHA" && ok "the host check accepts the followed WRITE-RESULT lines" || bad "host check"
OUT=$(rr busybox sh "$HERE/steps/tsx-rescue-staged" follow $((L + 1)))
[ "$OUT" = "STAGED-RESULT state=done lines=$L" ] && ok "follow from line $((L + 1)) prints only the result (a host that lost the link goes on)" || bad "follow offset: $OUT"
rr busybox sh "$HERE/steps/tsx-rescue-staged" auto; [ "$(cat "$W/run/tsx-staged.state")" = done ] && ok "a second auto in the same boot does nothing" || bad "second auto changed the state"
OUT=$(rr busybox sh "$HERE/steps/tsx-rescue-staged" start)
case "$OUT" in *"started in this boot already"*) ok "start after a run: nothing to start";; *) bad "start: $OUT";; esac

echo "== 3. failures"
fresh() {  # a new boot and a new stage: $1 = TSX_MEMAVAIL_KIB
	rm -rf "$W/run" "$W/tmp" "$W/p8" "$S" "$S.failed"; mkdir -p "$W/run" "$W/tmp"
	TSX_STAGE_KIOSK_DIR=$S TSX_PUSH_PROGRESS_MIB=10000 tsx_stage_push_kiosk "$W/st" ssh root@kiosk >/dev/null 2>&1
}
fresh
TSX_MEMAVAIL_KIB=1000 rr busybox sh "$HERE/steps/tsx-rescue-staged" auto; rc=$?
[ $rc = 1 ] && grep -q '^failed: the RAM has 1000 KiB' "$W/run/tsx-staged.state" && [ -f "$S/STAGE.failed" ] && [ ! -e "$W/p8" ] \
	&& ok "not enough RAM: failed, STAGE.failed, nothing written" || bad "RAM: rc $rc $(cat "$W/run/tsx-staged.state")"
OUT=$(rr busybox sh "$HERE/steps/tsx-rescue-staged" follow 1); rc=$?
[ $rc = 1 ] && case "$OUT" in *"STAGED-RESULT state=failed"*) true;; *) false;; esac && ok "follow: rc 1 and state=failed (the host pushes over ssh instead)" || bad "follow failed: $rc $OUT"
fresh
python3 -I -c 'import sys; f=open(sys.argv[1], "r+b"); f.seek(100); b=f.read(1); f.seek(100); f.write(bytes([b[0] ^ 0xff]))' "$S/root.img.gz"
rr busybox sh "$HERE/steps/tsx-rescue-staged" auto; rc=$?
[ $rc = 1 ] && grep -q 'root.img.gz of the stage has a wrong size or sha256' "$W/run/tsx-staged.state" && [ -d "$S.failed" ] && [ ! -e "$W/p8" ] \
	&& ok "a corrupt root.img.gz: failed, kept as tsx-stage.failed, nothing written" || bad "corrupt: rc $rc $(cat "$W/run/tsx-staged.state")"
rm -rf "$W/run" "$S" "$S.failed"; mkdir -p "$W/run"
rr busybox sh "$HERE/steps/tsx-rescue-staged" auto; rc=$?
[ $rc = 0 ] && [ "$(cat "$W/run/tsx-staged.state")" = nostage ] && ok "no stage: rc 0, state nostage" || bad "no stage: rc $rc $(cat "$W/run/tsx-staged.state" 2>/dev/null)"
OUT=$(rr busybox sh "$HERE/steps/tsx-rescue-staged" follow 1); rc=$?
[ $rc = 3 ] && ok "follow with no stage: rc 3" || bad "follow nostage: rc $rc $OUT"

echo "== 4. the DSP files: the .puf files of the stage when the panel has none"
fresh
FAKE_TFA_N=0 FAKE_PSR=0 rr busybox sh "$HERE/steps/tsx-rescue-staged" auto
grep -q 'tfa: the .puf files of the stage (the panel has 0 of 3' "$W/run/tsx-staged.log" && [ "$(cat "$W/tmp/b/tfa/settings_a/stereo.cnt")" = puf-set ] \
	&& ok "tfa: no panel set, the .puf files of the stage" || bad "tfa puf: $(grep 'tfa:' "$W/run/tsx-staged.log")"
grep -q 'psr: no PSR file' "$W/run/tsx-staged.log" && ok "psr: none on the panel and none in the stage: a note, no stop" || bad "psr: $(grep 'psr:' "$W/run/tsx-staged.log")"
fresh
FAKE_TFA_N=2 rr busybox sh "$HERE/steps/tsx-rescue-staged" auto
grep -q 'tfa: the .puf files of the stage (the panel has 2 of 3' "$W/run/tsx-staged.log" && ok "tfa: a partial panel set, the full .puf set wins (auto)" || bad "tfa partial: $(grep 'tfa:' "$W/run/tsx-staged.log")"

echo "== 5. the wiring"
grep -q 'install -m 755 "$INSTALLER_DIR/steps/tsx-rescue-staged" "$R/usr/sbin/tsx-rescue-staged"' "$HERE/rescue/mkrescue.sh" \
	&& grep -q '::once:/usr/sbin/tsx-rescue-staged auto' "$HERE/rescue/mkrescue.sh" && ok "mkrescue.sh: the runner and its inittab line" || bad "mkrescue.sh wiring"
grep -q "hashFiles('installer/rescue/\*\*', 'installer/rescue-v2/\*\*', 'installer/steps/tsx-rescue-staged'" "$HERE/../.github/workflows/release.yml" \
	&& ok "release.yml: a new runner builds a new rescue image" || bad "release.yml cache key"
grep -q -- '--no-reboot' "$HERE/steps/tsx-rescue-install" && ok "tsx-rescue-install has --no-reboot" || bad "no --no-reboot"
for f in "$HERE/steps/tsx-rescue-staged" "$HERE/steps/tsx-rescue-install" "$HERE/lib/tsx-rescue.sh"; do busybox sh -n "$f" && ok "busybox sh -n $(basename "$f")" || bad "busybox sh -n $(basename "$f")"; done
bash -n "$HERE/lib/tsx-stage.sh" && ok "bash -n tsx-stage.sh" || bad "bash -n tsx-stage.sh"
mkdir -p "$W/dpay"; cp "$W/rescue-new.img" "$W/dpay/rescue.img"; cp -r "$W/payload/lts" "$W/dpay/lts"
(cd "$W/dpay/lts" && sha256sum manifest root.img boot.img > SHA256SUMS)
for st in auto no; do
	OUT=$(TSX_PANEL_KIND=mainline "$HERE/tsx-install-mainline" 192.0.2.10 --payload "$W/dpay" --kernel lts --yes --dry-run --stage $st --results "$W/dry-$st.txt" 2>&1); rc=$?
	case "$st:$OUT" in
	auto:*"stage (--stage auto): before the arm, gzip root.img"*"/data/tsx-stage on the kiosk"*) ok "dry run --stage auto names the stage on /data";;
	no:*"stage: --stage no: the bundle and root.img go over ssh"*) ok "dry run --stage no names the push";;
	*) bad "dry run --stage $st (rc $rc): $OUT";;
	esac
done
# stock Android: no stage, no terminal and no rescue password stop before the arm step
awk '/^stage_panel$/ {s=1} s && /running preflight/ {exit} s' "$HERE/tsx-install-mainline" | grep -qF '[ "$STAGED" != 1 ] && [ -z "$RPW" ] && ! [ -t 0 ]' \
	&& ok "stock Android: no stage and no way to the one-time rescue password stops before the arm step" || bad "no guard between stage_panel and the arm step"
OUT=$("$HERE/tsx-install-mainline" 192.0.2.10 --payload "$W/dpay" --kernel lts --stage maybe --dry-run 2>&1); rc=$?
[ $rc = 2 ] && ok "--stage maybe is refused (rc 2)" || bad "--stage maybe: rc $rc"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-stage || echo FAIL test-install-stage
exit $F
