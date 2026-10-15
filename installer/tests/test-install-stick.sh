#!/bin/bash
# Host test: install from a USB stick (docs/install.md "Install from a USB
# stick"). No docker, no root, no panel, no stick.
#   1. installer/tsx-make-stick: the folder (jabil.txt within the limits of
#      U-Boot, tsx-rescue.img, the stage, SHA256SUMS, README.txt), the root
#      login check, --no-config, an older rescue image is refused
#   2. steps/tsx-rescue-staged on the stick folder (fake tsx-rescue-install,
#      fake p1): the install runs, the stick does not change, p1 gets the
#      rescue of the stick and tsxstick.done, the old p1:boot.img is kept
#   3. the same stick again: no second install, and jabil.txt is renamed so
#      the next boot reaches the kiosk
#   4. a stick without panel.conf: refused on a stock card, nothing written
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
for t in busybox python3 sha256sum gzip; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED test-install-stick: no $t on this host"; exit 0; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
MIB=1048576

# ---- a fake payload with a rescue image that has the runner ----------------------
mkimg() {  # OUT [with-runner]
	python3 -I - "$1" "${2:-}" <<'PY'
import gzip, struct, sys
ps = 2048
rd = gzip.compress(b'070701...init...')
if sys.argv[2]:
    rd += gzip.compress(b'070701...usr/sbin/tsx-rescue-staged...::once:/usr/sbin/tsx-rescue-staged auto\n')
k = b'\0' * 4096
hdr = struct.pack('<8s10I', b'ANDROID!', len(k), 0x8000, len(rd), 0x1000000, 0, 0, 0x100, ps, 0, 0)
pad = lambda b: b + b'\0' * ((ps - len(b) % ps) % ps)
open(sys.argv[1], 'wb').write(pad(hdr) + pad(k) + pad(rd))
PY
}
P=$W/payload; mkdir -p "$P/lts"
mkimg "$P/rescue.img" yes
head -c $((3 * MIB)) /dev/urandom > "$P/lts/root.img"; head -c $((1 * MIB)) /dev/zero >> "$P/lts/root.img"
head -c 100000 /dev/urandom > "$P/lts/boot.img"
ROOT_SHA=$(sha256sum < "$P/lts/root.img" | cut -d' ' -f1); BOOT_SHA=$(sha256sum < "$P/lts/boot.img" | cut -d' ' -f1)
printf 'format=tsx-rescue-install-1\nroot_bytes=%s\nroot_sha256=%s\nboot_sha256=%s\nkernel_flavor=lts\n' "$(stat -c %s "$P/lts/root.img")" "$ROOT_SHA" "$BOOT_SHA" > "$P/lts/manifest"
(cd "$P/lts" && sha256sum manifest root.img boot.img > SHA256SUMS)
printf 'SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host"\nKIOSK_URL="https://ha.example.org"\n' > "$W/panel.conf"
mk() { TFA_VENDOR_LOCAL=$W/none PSR_VENDOR_LOCAL=$W/none "$HERE/tsx-make-stick" --payload "$P" --kernel lts "$@" > "$W/mk.out" 2>&1; }

echo "== 1. installer/tsx-make-stick"
S=$W/stick
mk --out "$S" --config "$W/panel.conf"; rc=$?
[ $rc = 0 ] && ok "tsx-make-stick rc 0" || bad "rc $rc: $(tail -n 5 "$W/mk.out")"
[ "$(wc -l < "$S/jabil.txt")" = 3 ] && [ "$(stat -c %s "$S/jabil.txt")" -lt 150 ] && awk 'length($0) >= 50 {b = 1} END {exit b}' "$S/jabil.txt" && [ "$(sed -n 3p "$S/jabil.txt")" = tsx-rescue.img ] \
	&& ok "jabil.txt: three lines, under 150 bytes, names under 50 characters, the 10-inch line names tsx-rescue.img" || bad "jabil.txt: $(cat "$S/jabil.txt")"
cmp -s "$P/rescue.img" "$S/tsx-rescue.img" && ok "tsx-rescue.img is the rescue of the payload" || bad "tsx-rescue.img"
grep -q '^source=stick$' "$S/tsx-stage/STAGE" && grep -q '^golden=stick$' "$S/tsx-stage/STAGE" && grep -q "^rescue_sha256=$(sha256sum < "$P/rescue.img" | cut -d' ' -f1)$" "$S/tsx-stage/STAGE" && grep -q '^needs_mainline=0$' "$S/tsx-stage/STAGE" \
	&& ok "STAGE: source=stick, golden=stick, the sha256 of the rescue, needs_mainline=0" || bad "STAGE: $(cat "$S/tsx-stage/STAGE")"
[ -f "$S/tsx-stage/bundle/panel.conf" ] && grep -q '^KERNEL_FLAVOR="lts"' "$S/tsx-stage/bundle/panel.conf" && ok "the bundle has panel.conf with KERNEL_FLAVOR" || bad "panel.conf in the bundle"
(cd "$S" && sha256sum -c SHA256SUMS >/dev/null) && ok "SHA256SUMS of the stick folder" || bad "stick SHA256SUMS"
[ -f "$S/README.txt" ] && ! find "$S" -type l | grep -q . && ok "README.txt, and no links (a FAT stick has none)" || bad "README or links"
mk --out "$W/s2" --yes; rc=$?
[ $rc != 0 ] && grep -q -- "--yes needs --config FILE or --no-config" "$W/mk.out" && ok "--yes with no config: refused" || bad "--yes: rc $rc"
printf 'KIOSK_URL="https://ha.example.org"\n' > "$W/nologin.conf"
mk --out "$W/s3" --config "$W/nologin.conf"; rc=$?
[ $rc != 0 ] && grep -q "No root password and no SSH public key" "$W/mk.out" && ok "a config with no root login: refused" || bad "no login: rc $rc"
mkimg "$W/old.img"; cp -r "$P" "$W/oldpay"; cp "$W/old.img" "$W/oldpay/rescue.img"
TFA_VENDOR_LOCAL=$W/none PSR_VENDOR_LOCAL=$W/none "$HERE/tsx-make-stick" --payload "$W/oldpay" --kernel lts --out "$W/s4" --no-config > "$W/mk.out" 2>&1; rc=$?
[ $rc != 0 ] && grep -q "cannot run a stage" "$W/mk.out" && ok "an older rescue image: refused" || bad "old rescue: rc $rc"

echo "== 2. the rescue runs the stage of the stick"
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
chmod +x "$W/fake-install"
mkdir -p "$W/p1"; echo crestron-golden > "$W/p1/boot.img"
BEFORE=$(cd "$S" && find . -type f -exec sha256sum {} + | sort)
rr() { rm -rf "$W/run" "$W/tmp"; mkdir -p "$W/run" "$W/tmp"
	TSX_RUN=$W/run TSX_TMP=$W/tmp TSX_STICK_DIR=$1 TSX_P1_DIR=$W/p1 TSX_STAGED_INSTALL=$W/fake-install TSX_NO_REBOOT=1 TSX_STATUS=$W/run/st \
		TSX_PROGRESS_FILE=$W/run/prog TSX_DISK_LAYOUT=${LAYOUT:-card} busybox sh "$HERE/steps/tsx-rescue-staged" auto; }
rr "$S"; rc=$?
[ $rc = 0 ] && [ "$(cat "$W/run/tsx-staged.state")" = done ] && cmp -s "$P/lts/root.img" "$W/p8" && ok "the stick stage installs (the root image through gunzip)" || bad "stick run: rc $rc $(cat "$W/run/tsx-staged.log")"
[ "$BEFORE" = "$(cd "$S" && find . -type f -exec sha256sum {} + | sort)" ] && ok "the stick did not change (no file renamed, removed or written)" || bad "the stick changed"
cmp -s "$W/p1/boot.img" "$S/tsx-rescue.img" && cmp -s "$W/p1/tsxboot.img" "$S/tsx-rescue.img" && ok "p1: boot.img and tsxboot.img are the rescue of the stick" || bad "p1 slots"
[ "$(cat "$W/p1/tsxstick.done")" = "$(sha256sum < "$S/tsx-stage/STAGE" | cut -d' ' -f1)" ] && ok "p1:tsxstick.done names this stage" || bad "tsxstick.done"
[ "$(cat "$W/tmp/tsx-p1-boot.old")" = crestron-golden ] && ok "the old p1:boot.img is kept for /data/tsx/backup" || bad "old golden not kept"
grep -q '^done: the install is complete. Remove the USB stick' "$W/run/st" && ok "the screen asks to remove the stick" || bad "screen: $(cat "$W/run/st")"

echo "== 3. the same stick again"
rm -f "$W/p8"
rr "$S"; rc=$?
[ $rc = 0 ] && [ ! -e "$W/p8" ] && grep -q 'installed from this USB stick already' "$W/run/st" && ok "no second install, the screen says why" || bad "second run: rc $rc $(cat "$W/run/st" 2>/dev/null)"
[ ! -e "$S/jabil.txt" ] && [ -f "$S/jabil.txt.done" ] && ok "the stick stayed in: jabil.txt is now jabil.txt.done, so the next boot reaches the kiosk" || bad "jabil.txt not renamed"
mv "$S/jabil.txt.done" "$S/jabil.txt"

echo "== 4. a stick without panel.conf"
mk --out "$W/s5" --no-config; rc=$?
[ $rc = 0 ] && grep -q '^needs_mainline=1$' "$W/s5/tsx-stage/STAGE" && [ ! -e "$W/s5/tsx-stage/bundle/panel.conf" ] && ok "--no-config: no panel.conf, needs_mainline=1" || bad "--no-config: rc $rc"
rm -f "$W/p8" "$W/p1/tsxstick.done"; echo crestron-golden > "$W/p1/boot.img"; rm -f "$W/p1/tsxboot.img"
LAYOUT=stock rr "$W/s5"; rc=$?
[ $rc = 1 ] && [ ! -e "$W/p8" ] && [ ! -e "$W/p1/tsxboot.img" ] && grep -q 'for panels that run mainline only' "$W/run/tsx-staged.state" && ok "on a stock card: refused, nothing written" || bad "stock: rc $rc $(cat "$W/run/tsx-staged.state")"
LAYOUT=card rr "$W/s5"; rc=$?
[ $rc = 0 ] && [ -e "$W/p8" ] && ok "on a folded card (a mainline panel): it installs" || bad "card: rc $rc"
busybox sh -n "$HERE/steps/tsx-rescue-staged" && ok "busybox sh -n tsx-rescue-staged" || bad "sh -n"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-stick || echo FAIL test-install-stick
exit $F
