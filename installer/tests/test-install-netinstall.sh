#!/bin/bash
# Host test: download the release on the panel (docs/install.md "Download
# the release on the panel"). No network, no root, no panel: the "release" is
# a folder (curl file://), and a throwaway RSA key signs its SHA256SUMS.
#   1. lib/tsx-verify-sig.py: a good signature, a changed file, another key
#   2. steps/tsx-netinstall: the signature check before the large downloads,
#      the sha256 check of each file, the stage in the format of
#      steps/tsx-rescue-staged, and the result line
#   3. the failures: no signature, a bad signature, a changed file, no room,
#      a release without the files of the download mode
#   4. steps/tsx-rescue-staged installs that stage (fake tsx-rescue-install)
#   5. tsx-install-mainline: --fetch in a dry run, --fetch refused for stock
#      Android
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
for t in busybox python3 sha256sum curl openssl gzip; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED test-install-netinstall: no $t on this host"; exit 0; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
MIB=1048576
V=$HERE/lib/tsx-verify-sig.py

openssl genrsa -out "$W/k.pem" 2048 2>/dev/null && openssl rsa -in "$W/k.pem" -pubout -out "$W/k.pub" 2>/dev/null
openssl genrsa -out "$W/other.pem" 2048 2>/dev/null && openssl rsa -in "$W/other.pem" -pubout -out "$W/other.pub" 2>/dev/null

echo "== 1. lib/tsx-verify-sig.py"
echo data > "$W/f"; openssl dgst -sha256 -sign "$W/k.pem" -out "$W/f.sig" "$W/f"
python3 -I "$V" "$W/k.pub" "$W/f" "$W/f.sig" >/dev/null && ok "a good signature: rc 0" || bad "good signature refused"
echo datA > "$W/g"
python3 -I "$V" "$W/k.pub" "$W/g" "$W/f.sig" 2>/dev/null; [ $? = 1 ] && ok "a changed file: rc 1" || bad "changed file accepted"
python3 -I "$V" "$W/other.pub" "$W/f" "$W/f.sig" 2>/dev/null; [ $? = 1 ] && ok "another key: rc 1" || bad "another key accepted"
python3 -I "$V" "$W/f" "$W/f" "$W/f.sig" 2>/dev/null; [ $? = 2 ] && ok "not a key: rc 2" || bad "not a key"
python3 -I "$V" "$HERE/../rootfs/overlay/etc/apk/keys/"tsx-mainline-*.rsa.pub "$W/f" "$W/f.sig" 2>/dev/null; [ $? = 1 ] && ok "the project key parses (4096 bit) and refuses the test signature" || bad "the project key"

echo "== 2. steps/tsx-netinstall from a release folder"
REL=$W/rel; mkdir -p "$REL"
head -c $((3 * MIB)) /dev/urandom > "$W/root.img"; head -c $((2 * MIB)) /dev/zero >> "$W/root.img"
head -c 200000 /dev/urandom > "$REL/tsx-xx60-lts-boot.img"; head -c 300000 /dev/urandom > "$REL/tsx-xx60-rescue.img"
gzip -6 -n -c "$W/root.img" > "$REL/tsx-xx60-lts-root.img.gz"
ROOT_SHA=$(sha256sum < "$W/root.img" | cut -d' ' -f1); BOOT_SHA=$(sha256sum < "$REL/tsx-xx60-lts-boot.img" | cut -d' ' -f1)
printf 'format=tsx-rescue-install-1\nroot_bytes=%s\nroot_sha256=%s\nboot_sha256=%s\nkernel_flavor=lts\n' "$(stat -c %s "$W/root.img")" "$ROOT_SHA" "$BOOT_SHA" > "$REL/tsx-xx60-lts-manifest"
echo other > "$REL/tsx-xx60-lts-payload.tar.zst"
(cd "$REL" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -exec sha256sum {} + | sort -k2 > SHA256SUMS)
openssl dgst -sha256 -sign "$W/k.pem" -out "$REL/SHA256SUMS.sig" "$REL/SHA256SUMS"
net_dir() {  # a fresh /data/tsx-net as the host copies it
	rm -rf "$W/data"; mkdir -p "$W/data/tsx-net/bundle"
	cp "$HERE/steps/tsx-netinstall" "$V" "$W/data/tsx-net/"
	cp "$HERE/lib/tsx-rescue.sh" "$W/data/tsx-net/bundle/"; echo 'KIOSK_URL="https://ha.example.org"' > "$W/data/tsx-net/bundle/panel.conf"
	(cd "$W/data/tsx-net/bundle" && sha256sum tsx-rescue.sh panel.conf > SHA256SUMS)
}
netinstall() { TSX_NET_TICK=1 TSX_NET_DF_KIB=${DFK:-10000000} busybox sh "$W/data/tsx-net/tsx-netinstall" --base "file://$1" --flavor lts --keep 1 --golden 1 \
	--tfa-source auto --psr-source none --keys "$W/k.pub" --stage "$W/data/tsx-stage" 2>&1; }
net_dir
OUT=$(netinstall "$REL"); rc=$?
[ $rc = 0 ] && ok "netinstall rc 0" || bad "netinstall rc $rc: $OUT"
case "$OUT" in *"SHA256SUMS: signature ok (k.pub)"*) ok "the signature is checked first";; *) bad "no signature line: $OUT";; esac
case "$OUT" in *"NETINSTALL-RESULT ok=1 rescue_sha256=$(sha256sum < "$REL/tsx-xx60-rescue.img" | cut -d' ' -f1) boot_sha256=$BOOT_SHA root_sha256=$ROOT_SHA"*) ok "the result line names the signed sha256 values";; *) bad "result: $OUT";; esac
S=$W/data/tsx-stage
[ -f "$S/STAGE" ] && [ -f "$S/bundle/manifest" ] && [ -f "$S/bundle/boot.img" ] && [ -f "$S/bundle/panel.conf" ] && [ -f "$S/rescue.img" ] && [ -f "$S/root.img.gz" ] \
	&& ok "the stage: STAGE, the bundle with manifest, boot.img and panel.conf, root.img.gz, rescue.img" || bad "stage layout: $(find "$S" | sort | tr '\n' ' ')"
(cd "$S/bundle" && sha256sum -c SHA256SUMS >/dev/null) && ok "the SHA256SUMS of the bundle covers the new files" || bad "bundle SHA256SUMS"
grep -q '^format=tsx-stage-1$' "$S/STAGE" && grep -q "^root_gz_sha256=$(sha256sum < "$REL/tsx-xx60-lts-root.img.gz" | cut -d' ' -f1)$" "$S/STAGE" && grep -q '^golden=1$' "$S/STAGE" \
	&& ok "STAGE: format, golden, the sha256 of root.img.gz" || bad "STAGE: $(cat "$S/STAGE")"
[ ! -e "$W/data/tsx-net/bundle" ] && [ ! -e "$S.new" ] && ok "the bundle moved into the stage, no tsx-stage.new is left" || bad "leftovers"

echo "== 3. failures"
net_dir; rm -f "$REL/SHA256SUMS.sig.keep"; mv "$REL/SHA256SUMS.sig" "$REL/SHA256SUMS.sig.keep"
OUT=$(netinstall "$REL"); rc=$?
[ $rc = 1 ] && case "$OUT" in *"a release with no signature"*"NETINSTALL-RESULT ok=0"*) true;; *) false;; esac && ok "no SHA256SUMS.sig: refused" || bad "no sig: rc $rc $OUT"
mv "$REL/SHA256SUMS.sig.keep" "$REL/SHA256SUMS.sig"
net_dir; cp "$REL/SHA256SUMS" "$W/sums.keep"; echo "0000  ./extra" >> "$REL/SHA256SUMS"
OUT=$(netinstall "$REL"); rc=$?
[ $rc = 1 ] && case "$OUT" in *"has no good signature"*) true;; *) false;; esac && [ ! -e "$W/data/tsx-net/dl/tsx-xx60-lts-root.img.gz" ] \
	&& ok "a changed SHA256SUMS: refused before the large downloads" || bad "bad sig: rc $rc $OUT"
cp "$W/sums.keep" "$REL/SHA256SUMS"
net_dir; cp "$REL/tsx-xx60-lts-boot.img" "$W/boot.keep"; echo x >> "$REL/tsx-xx60-lts-boot.img"
OUT=$(netinstall "$REL"); rc=$?
[ $rc = 1 ] && case "$OUT" in *"tsx-xx60-lts-boot.img has a wrong sha256"*) true;; *) false;; esac && [ ! -e "$S" ] && ok "a changed file of the release: refused, no stage" || bad "changed file: rc $rc $OUT"
cp "$W/boot.keep" "$REL/tsx-xx60-lts-boot.img"
net_dir; OUT=$(DFK=100 netinstall "$REL"); rc=$?
[ $rc = 1 ] && case "$OUT" in *"KiB free, the download needs"*) true;; *) false;; esac && ok "no room on /data: refused" || bad "no room: rc $rc $OUT"
OLD=$W/old; mkdir -p "$OLD"; cp "$REL/tsx-xx60-lts-payload.tar.zst" "$OLD/"; (cd "$OLD" && sha256sum ./tsx-xx60-lts-payload.tar.zst > SHA256SUMS); openssl dgst -sha256 -sign "$W/k.pem" -out "$OLD/SHA256SUMS.sig" "$OLD/SHA256SUMS"
net_dir; OUT=$(netinstall "$OLD"); rc=$?
[ $rc = 1 ] && case "$OUT" in *"a release from before the download mode"*) true;; *) false;; esac && ok "an older release (no files of the download mode): refused" || bad "old release: rc $rc $OUT"
net_dir; mkdir -p "$W/data/tsx-net/dl"; head -c 1000 "$REL/tsx-xx60-lts-root.img.gz" > "$W/data/tsx-net/dl/tsx-xx60-lts-root.img.gz.part"
OUT=$(netinstall "$REL"); rc=$?
[ $rc = 0 ] && cmp -s "$REL/tsx-xx60-lts-root.img.gz" "$S/root.img.gz" && ok "a partial download of an earlier try: curl goes on, the file is complete" || bad "resume: rc $rc $OUT"

echo "== 4. steps/tsx-rescue-staged installs the downloaded stage"
cat > "$W/fake-install" <<EOF
#!/bin/sh
cmd=\$1 b=\$2; shift 2
case \$cmd in
tfa) echo "TFA-RESULT source=root count=3"; mkdir -p "\$b/tfa-panel/v";;
psr|ledstock) ;;
check) case "\$*" in *"--root-from -"*) echo "check OK";; *) exit 1;; esac;;
run) cat > "$W/p8"; g=\$(sha256sum < "$W/p8" | cut -d' ' -f1)
	echo "WRITE-RESULT name=boot bytes=1 sha256=$BOOT_SHA ok=1"; echo "WRITE-RESULT name=root bytes=1 sha256=\$g ok=1";;
esac
EOF
chmod +x "$W/fake-install"; mkdir -p "$W/run" "$W/tmp"
TSX_RUN=$W/run TSX_TMP=$W/tmp TSX_STAGE_DIR=$S TSX_STAGED_INSTALL=$W/fake-install TSX_NO_REBOOT=1 TSX_STATUS=$W/run/st busybox sh "$HERE/steps/tsx-rescue-staged" auto; rc=$?
[ $rc = 0 ] && [ "$(cat "$W/run/tsx-staged.state")" = done ] && cmp -s "$W/root.img" "$W/p8" && ok "the runner writes the downloaded root image (gunzip on stdin)" || bad "runner: rc $rc $(cat "$W/run/tsx-staged.log")"

echo "== 5b. --payload-out: a payload folder for a seed panel"
net_dir; rm -rf "$W/data/tsx-stage"
# the seed layout: the script in installer/steps, the verifier in installer/lib
OUT=$(TSX_NET_TICK=1 TSX_NET_DF_KIB=10000000 busybox sh "$HERE/steps/tsx-netinstall" --base "file://$REL" --flavor lts --keys "$W/k.pub" --payload-out "$W/pay" 2>&1); rc=$?
[ $rc = 0 ] && ok "--payload-out rc 0" || bad "--payload-out rc $rc: $OUT"
cmp -s "$W/root.img" "$W/pay/lts/root.img" && [ -f "$W/pay/rescue.img" ] && [ -f "$W/pay/lts/boot.img" ] && (cd "$W/pay/lts" && sha256sum -c SHA256SUMS >/dev/null) \
	&& ok "the payload layout of --payload (rescue.img, lts/{manifest,boot.img,root.img,SHA256SUMS})" || bad "payload layout: $(find "$W/pay" | sort | tr '\n' ' ')"
grep -q "^root_sha256=$ROOT_SHA$" "$W/pay/lts/root.img.gz.info" && ok "root.img.gz.info: the stage of the installer uses the gzip again" || bad "root.img.gz.info"
[ ! -e "$W/data/tsx-stage" ] && [ ! -e "$W/pay/.dl" ] && [ ! -e "$HERE/steps/dl" ] && ok "--payload-out makes no stage and leaves no download folder" || bad "a stage or a download folder was left"

echo "== 5. tsx-install-mainline --fetch"
OUT=$(TSX_PANEL_KIND=mainline "$HERE/tsx-install-mainline" 192.0.2.10 --fetch v9.9.9 --kernel lts --yes --dry-run --results "$W/dry.txt" 2>&1); rc=$?
[ $rc = 0 ] && case "$OUT" in *"PAYLOAD=(none: --fetch v9.9.9)"*"releases/download/v9.9.9, checks the signature"*) true;; *) false;; esac \
	&& ok "dry run: no payload needed, the release URL and the signature check are named" || bad "dry run: rc $rc $OUT"
OUT=$(TSX_PANEL_KIND=android "$HERE/tsx-install-mainline" 192.0.2.10 --fetch v9.9.9 --kernel lts --yes --dry-run --results "$W/dry2.txt" 2>&1); rc=$?
[ $rc != 0 ] && case "$OUT" in *"--fetch needs a panel that runs mainline"*) true;; *) false;; esac && ok "--fetch on stock Android: refused" || bad "android: rc $rc $OUT"
OUT=$("$HERE/tsx-install-mainline" 192.0.2.10 --fetch v9.9.9 --stage no --kernel lts --dry-run 2>&1); rc=$?
[ $rc = 2 ] && ok "--fetch with --stage no: refused" || bad "--stage no: rc $rc"
for f in "$HERE/steps/tsx-netinstall"; do busybox sh -n "$f" && ok "busybox sh -n $(basename "$f")" || bad "busybox sh -n $(basename "$f")"; done

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-netinstall || echo FAIL test-install-netinstall
exit $F
