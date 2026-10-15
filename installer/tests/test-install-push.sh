#!/bin/bash
# Host test: the push path of the installer (docs/install.md "Network
# requirements"). The host opens every connection and sends every file over
# it. The panel opens no connection to the host. The test needs no docker, no
# root and no panel. Stand-ins replace ssh:
#   - a fake rescue: "ssh ... CMD" runs CMD locally under busybox sh (the shell
#     of the rescue), with stdin passed through. FAKE_SSH_CUT=N passes only the
#     first N bytes of stdin (a lost connection). FAKE_SSH_FLIP=N changes byte
#     N (a corrupt stream). FAKE_SSH_SLOW=S stops for S seconds after the
#     first MiB (a slow link).
#   - a fake Crestron root shell for steps/rootsh: an interactive bash on a
#     real pty (python3 pty.spawn), like "ssh -tt admin@panel rootsh".
# Checks:
#   1. tsx_write_verify streams an image from stdin onto a "device" file and
#      reads it back. The host compares the sha256 (tsx_write_result_check).
#   2. a short stream (lost connection) and a corrupt stream fail the readback
#   3. resume: the same push again after a short stream writes the full image
#   4. progress lines (MiB, percent) while the stream runs
#   5. tsx_push_dir: one tar stream, sha256 check in the "rescue", DEST is
#      replaced only after a good check
#   6. steps/rootsh --put: every byte value passes the pty unchanged, sha256
#      checked. A root shell that cannot go raw stops with a message
#   7. the installer has no HTTP path any more
#   8. tsx_push_bundle (the factory bundle of tsx-restore-factory): only the
#      files of SHA256SUMS go, the old DEST goes first, progress lines for a
#      large push, and a dry run of tsx-restore-factory names the push
#   9. the rescue screen while a push arrives: tsx-op, the state line with
#      the MiB, and /run/tsx-progress in the format of pr_dd
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HERE/lib/tsx-rescue.sh"
for t in busybox python3 sha256sum tar; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED test-install-push: no $t on this host"; exit 0; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
. "$LIB"   # tsx_push_dir, tsx_write_result_check (host side)

# ---- the fake rescue: ssh [options] [user@]host CMD -> busybox sh -c CMD ----
mkdir -p "$W/bin"
cat > "$W/bin/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in
	-o|-i|-p|-c|-e|-l) shift 2;; -*) shift;; *) break;; esac; done
shift   # [user@]host
if [ -n "${FAKE_SSH_CUT:-}" ]; then
	head -c "$FAKE_SSH_CUT" | busybox sh -c "$*"
elif [ -n "${FAKE_SSH_SLOW:-}" ]; then
	(head -c 1048576; sleep "$FAKE_SSH_SLOW"; cat) | busybox sh -c "$*"
elif [ -n "${FAKE_SSH_FLIP:-}" ]; then
	python3 -I -c 'import sys; d=bytearray(sys.stdin.buffer.read()); n=int(sys.argv[1]); d[n]^=0xff; sys.stdout.buffer.write(d)' "$FAKE_SSH_FLIP" | busybox sh -c "$*"
else
	exec busybox sh -c "$*"
fi
EOF
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH" TSX_PROGRESS_FILE="$W/progress" TSX_RUN="$W/run"
mkdir -p "$W/run"

MIB=1048576
head -c $((6 * MIB)) /dev/urandom > "$W/root.img"
SHA=$(sha256sum < "$W/root.img" | cut -d' ' -f1)
BYTES=$(stat -c %s "$W/root.img")
fresh_dev() { head -c $((8 * MIB)) /dev/zero > "$W/p8"; }
push_root() {  # the host side of step 4: stream the image into the rescue
	ssh -o Ciphers=x root@rescue ". '$LIB'; tsx_write_verify '$W/p8' - $BYTES $SHA root 'eMMC root'" < "$W/root.img" 2>"$W/push.err"
}

echo "== 1. a full stream: written, read back, the host compares the sha256"
fresh_dev
OUT=$(push_root); rc=$?
[ $rc = 0 ] && ok "tsx_write_verify returns 0" || bad "rc $rc: $OUT $(cat "$W/push.err")"
cmp -s -n "$BYTES" "$W/root.img" "$W/p8" && ok "the device holds the image" || bad "device differs from the image"
tsx_write_result_check "$OUT" root "$SHA" && ok "host check: WRITE-RESULT root sha256 = the payload" || bad "host check failed: $OUT"
tsx_write_result_check "$OUT" root "0000$SHA" && bad "host check accepts a wrong sha256" || ok "host check refuses another sha256"
tsx_write_result_check "$OUT" boot "$SHA" && bad "host check accepts a missing boot line" || ok "host check needs the line of the right image"

echo "== 2. a short stream (lost connection) and a corrupt stream fail"
fresh_dev
OUT=$(FAKE_SSH_CUT=$((BYTES / 2)) push_root); rc=$?
[ $rc != 0 ] && ok "short stream: rc $rc" || bad "short stream accepted"
case "$OUT" in *"ok=0"*) ok "short stream: WRITE-RESULT ok=0";; *) bad "short stream: $OUT";; esac
tsx_write_result_check "$OUT" root "$SHA" && bad "host check accepts the short stream" || ok "host check refuses the short stream"
fresh_dev
OUT=$(FAKE_SSH_FLIP=123457 push_root); rc=$?
[ $rc != 0 ] && ok "corrupt stream: rc $rc" || bad "corrupt stream accepted"
tsx_write_result_check "$OUT" root "$SHA" && bad "host check accepts the corrupt stream" || ok "host check refuses the corrupt stream"

echo "== 3. resume: the same push again after a short stream"
fresh_dev
FAKE_SSH_CUT=$((BYTES / 3)) push_root >/dev/null
OUT=$(push_root); rc=$?
[ $rc = 0 ] && tsx_write_result_check "$OUT" root "$SHA" && ok "the second push writes and verifies the full image" || bad "resume failed: $OUT"

echo "== 4. progress lines while the stream runs"
fresh_dev
rm -f "$W/progress"
( (for i in 0 1 2 3 4 5; do dd if="$W/root.img" bs=$MIB skip=$i count=1 2>/dev/null; sleep 0.7; done) \
	| TSX_PR_DD_TICK=1 ssh root@rescue ". '$LIB'; tsx_write_verify '$W/p8' - $BYTES $SHA root 'eMMC root'" > "$W/slow.out" 2>&1 ) &
SP=$!
n=0; while [ ! -s "$W/progress" ] && [ $n -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
FIRST=$(cat "$W/progress" 2>/dev/null)
sleep 2; LATER=$(cat "$W/progress" 2>/dev/null)
wait $SP; OUT=$(cat "$W/slow.out")
case "$OUT" in *"eMMC root: "*"/6 MiB ("*"%)"*) ok "progress: $(printf '%s\n' "$OUT" | grep -m1 'eMMC root: ' | sed 's/^ *//')";; *) bad "no progress line: $OUT";; esac
tsx_write_result_check "$OUT" root "$SHA" && ok "the slow stream verifies" || bad "slow stream: $OUT"
case "$FIRST" in "0 0 $((6 * MIB)) eMMC root") ok "the screen file has a 0% line at once (no bar of the step before)";; *) bad "first progress line: '$FIRST'";; esac
case "$LATER" in [1-9]*" 0 $((6 * MIB)) eMMC root") ok "the screen file follows the write: $LATER";; *) bad "later progress line: '$LATER'";; esac
[ ! -e "$W/progress" ] && ok "the screen file is gone after the write (no stale bar for the next step)" || bad "progress file left: $(cat "$W/progress")"

echo "== 5. tsx_push_dir: one tar stream, sha256 check, replace only after a good check"
mkdir -p "$W/src/sub" "$W/r"
echo one > "$W/src/a.txt"; head -c 300000 /dev/urandom > "$W/src/sub/b.bin"
(cd "$W/src" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
OUT=$(tsx_push_dir "$W/src" "$W/r/b" ssh root@rescue 2>&1); rc=$?
[ $rc = 0 ] && ok "push rc 0 ($OUT)" || bad "push failed: $OUT"
cmp -s "$W/src/sub/b.bin" "$W/r/b/sub/b.bin" && cmp -s "$W/src/a.txt" "$W/r/b/a.txt" && ok "the files arrived" || bad "files differ"
cp -r "$W/src" "$W/src2"; echo changed > "$W/src2/a.txt"   # SHA256SUMS no longer matches
OUT=$(tsx_push_dir "$W/src2" "$W/r/b" ssh root@rescue 2>&1); rc=$?
[ $rc != 0 ] && ok "a sha256 mismatch fails the push (rc $rc)" || bad "mismatch accepted: $OUT"
case "$OUT" in *"a.txt: FAILED"*"sha256 check FAILED"*) ok "the output names the bad file";; *) bad "output: $OUT";; esac
[ "$(cat "$W/r/b/a.txt")" = one ] && ok "DEST keeps the last good copy" || bad "DEST changed after a failed check"
mkdir -p "$W/r/b/tfa/settings_x" "$W/r/b/psr"; echo old-set > "$W/r/b/tfa/settings_x/stereo.cnt"; echo old-psr > "$W/r/b/psr/SOURCE"; echo stale > "$W/r/b/kiosk-url.txt"
OUT=$(tsx_push_dir "$W/src" "$W/r/b" --keep "tfa psr ledstock" ssh root@rescue 2>&1); rc=$?
[ $rc = 0 ] && [ "$(cat "$W/r/b/tfa/settings_x/stereo.cnt" 2>/dev/null)" = old-set ] && [ -f "$W/r/b/psr/SOURCE" ] \
	&& ok "--keep: a resume keeps tfa and psr of the earlier attempt" || bad "--keep lost the earlier sets: $OUT"
[ ! -e "$W/r/b/kiosk-url.txt" ] && ok "--keep: other files of the old DEST are gone (no stale kiosk-url.txt)" || bad "a stale file survived"
case "$OUT" in *"kept $W/r/b/tfa from an earlier attempt"*) ok "--keep: the output names what it kept";; *) bad "keep output: $OUT";; esac
rm -f "$W/src2/SHA256SUMS"
tsx_push_dir "$W/src2" "$W/r/b" ssh root@rescue >/dev/null 2>&1 && bad "a directory with no SHA256SUMS was pushed" || ok "no SHA256SUMS: refused"

echo "== 6. steps/rootsh --put through a real pty (the Crestron root shell)"
mkdir -p "$W/pty/bin" "$W/pty/dst"
cat > "$W/pty/bin/sshpass" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != ssh ]; do shift; done; shift; exec "$(dirname "$0")/ssh" "$@"
EOF
cat > "$W/pty/bin/ssh" <<'EOF'
#!/bin/bash
# "ssh -tt admin@panel rootsh": an interactive root bash on a pty
exec python3 -I -c 'import pty; pty.spawn(["bash", "--norc", "--noprofile", "-i"])'
EOF
chmod +x "$W/pty/bin/"*
python3 -I -c 'import sys; sys.stdout.buffer.write(bytes(range(256)) * 64 + b"\n~.\n~?\r\n\x03\x04\x11\x13\x1a\x7f")' > "$W/put.bin"
head -c $((2 * MIB)) /dev/urandom >> "$W/put.bin"
OUT=$(PATH="$W/pty/bin:$PATH" TSX_ADMIN_PW=x "$HERE/steps/rootsh" --put fakepanel "$W/put.bin" "$W/pty/dst/put.bin" 2>&1); rc=$?
[ $rc = 0 ] && ok "rootsh --put rc 0" || bad "rootsh --put rc $rc: $OUT"
cmp -s "$W/put.bin" "$W/pty/dst/put.bin" && ok "every byte value passed the pty unchanged (^C, ^D, ^S, DEL, CR, ~.)" || bad "the copy differs"
case "$OUT" in *"verified ("*"sha256 "*) ok "the copy is sha256 checked";; *) bad "no verify line: $OUT";; esac
REALBB=$(command -v busybox)
cat > "$W/pty/bin/busybox" <<EOF
#!/bin/bash
# a root shell whose tty cannot go raw
[ "\$1" = stty ] && exit 1; exec "$REALBB" "\$@"
EOF
chmod +x "$W/pty/bin/busybox"
sed -i 's|exec python3|export PATH='"$W/pty/bin"':$PATH; exec python3|' "$W/pty/bin/ssh"
OUT=$(PATH="$W/pty/bin:$PATH" TSX_ADMIN_PW=x TSX_PUT_READY_S=6 timeout 60 "$HERE/steps/rootsh" --put fakepanel "$W/put.bin" "$W/pty/dst/put2.bin" 2>&1); rc=$?
[ $rc = 1 ] && ok "no raw mode: rc 1" || bad "no raw mode: rc $rc: $OUT"
case "$OUT" in *"did not get ready"*) ok "no raw mode: the message says so, and no byte was sent";; *) bad "no raw mode: $OUT";; esac
[ ! -s "$W/pty/dst/put2.bin" ] && ok "nothing written without the ready marker" || bad "bytes were written"
"$HERE/steps/rootsh" --put fakepanel "$W/put.bin" '/data/x;reboot' >/dev/null 2>&1 && bad "a DEST with shell characters was accepted" || ok "a DEST with shell characters is refused"

echo "== 7. no HTTP path is left"
grep -nE 'http\.server|wget|BASEURL|root-url' "$HERE/tsx-install-mainline" && bad "tsx-install-mainline still serves or fetches over HTTP" || ok "tsx-install-mainline: no HTTP server, no wget"
grep -nE 'wget|ROOT_URL|root-url' "$HERE/steps/tsx-rescue-install" && bad "tsx-rescue-install still downloads" || ok "tsx-rescue-install: no download"
grep -q -- '--root-from - 2>&1" < "\$FLAVOR_DIR/root.img"' "$HERE/tsx-install-mainline" && ok "step 4 streams root.img over ssh" || bad "step 4 does not stream root.img"
grep -q 'tsx_write_result_check "\$RS_OUT" root' "$HERE/tsx-install-mainline" && ok "the host compares the root sha256" || bad "no host compare of the root sha256"
for f in "$HERE/steps/tsx-rescue-install" "$LIB"; do busybox sh -n "$f" && ok "busybox sh -n $(basename "$f")" || bad "busybox sh -n $(basename "$f")"; done

echo "== 8. tsx_push_bundle: the factory bundle of tsx-restore-factory"
mkdir -p "$W/fb" "$W/r2"
head -c $((3 * MIB)) /dev/urandom > "$W/fb/system.img"; echo boot > "$W/fb/boot-golden.img"
printf '#!/bin/sh\necho emmc\n' > "$W/fb/tsx-emmc-restore"; chmod +x "$W/fb/tsx-emmc-restore"
echo junk > "$W/fb/build.log"   # not in SHA256SUMS: stays on the host
(cd "$W/fb" && sha256sum system.img boot-golden.img tsx-emmc-restore > SHA256SUMS)
mkdir -p "$W/r2/b"; echo stale > "$W/r2/b/old.img"
OUT=$(TSX_PUSH_PROGRESS_MIB=1 TSX_PR_DD_TICK=1 tsx_push_bundle "$W/fb" "$W/r2/b" ssh root@rescue 2>&1); rc=$?
[ $rc = 0 ] && ok "push rc 0" || bad "push failed: $OUT"
cmp -s "$W/fb/system.img" "$W/r2/b/system.img" && [ -x "$W/r2/b/tsx-emmc-restore" ] && [ ! -L "$W/r2/b/system.img" ] \
	&& ok "the files arrived as files (not links), the mode is kept" || bad "bundle files differ"
[ ! -e "$W/r2/b/build.log" ] && ok "a file that SHA256SUMS does not list stays on the host" || bad "build.log was sent"
[ ! -e "$W/r2/b/old.img" ] && ok "the old DEST is gone" || bad "old.img survived"
case "$OUT" in *"pushed $W/r2/b: 3 files, sha256 checked"*) ok "the output counts 3 files";; *) bad "output: $OUT";; esac
# a slow link: the rescue prints progress lines (MiB, percent, seconds) while
# tar reads the stream in the foreground
OUT=$(TSX_PUSH_PROGRESS_MIB=1 TSX_PR_DD_TICK=1 FAKE_SSH_SLOW=2.5 tsx_push_bundle "$W/fb" "$W/r2/b" ssh root@rescue 2>&1)
case "$OUT" in *"push $W/r2/b: "*" MiB ("*"%), "*" s"*) ok "progress: $(printf '%s\n' "$OUT" | grep -m1 "push $W/r2/b: " | sed 's/^ *//')";; *) bad "no progress line: $OUT";; esac
echo changed > "$W/fb/boot-golden.img"
OUT=$(tsx_push_bundle "$W/fb" "$W/r2/b" ssh root@rescue 2>&1); rc=$?
[ $rc != 0 ] && case "$OUT" in *"boot-golden.img: FAILED"*) true;; *) false;; esac && ok "a changed file fails the sha256 check (rc $rc)" || bad "mismatch: rc $rc $OUT"
rm -f "$W/fb/boot-golden.img"
tsx_push_bundle "$W/fb" "$W/r2/b" ssh root@rescue >/dev/null 2>&1 && bad "a missing file was not seen" || ok "a file of SHA256SUMS that is missing stops the push"
grep -nE 'http\.server|wget|BASEURL' "$HERE/tsx-restore-factory" && bad "tsx-restore-factory still serves or fetches over HTTP" || ok "tsx-restore-factory: no HTTP server, no wget"
# a dry run with a made-up bundle names the push
mkdir -p "$W/fbd" "$W/fbin"
for f in factory.manifest emmc.manifest uboot-check.txt; do echo "unit=test" > "$W/fbd/$f"; done
echo identity_and_hw=identical > "$W/fbd/env-identity.txt"
(cd "$W/fbd" && sha256sum factory.manifest emmc.manifest > SHA256SUMS)
for t in sshpass curl; do command -v $t >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 1\n' > "$W/fbin/$t"; chmod +x "$W/fbin/$t"; }; done
OUT=$(PATH="$W/fbin:$PATH" "$HERE/tsx-restore-factory" --bundle "$W/fbd" --dry-run --uart no --ws-ip 192.0.2.1 --port 8081 --results "$W/rf.txt" 192.0.2.10 2>&1); rc=$?
[ $rc = 0 ] && ok "tsx-restore-factory --dry-run rc 0" || bad "dry run rc $rc: $OUT"
case "$OUT" in *"step 3: rm -rf /tmp/b"*"one tar stream over ssh (tsx_push_bundle"*"opens no connection to this host"*) ok "the dry run names the push over ssh";; *) bad "dry run: $OUT";; esac
case "$OUT" in *"--port is ignored"*) ok "--port is accepted and ignored";; *) bad "no --port note: $OUT";; esac

echo "== 9. the rescue screen while a push arrives"
mkdir -p "$W/scr"; echo boot > "$W/fb/boot-golden.img"
(cd "$W/fb" && sha256sum system.img boot-golden.img tsx-emmc-restore > SHA256SUMS)
( TSX_PUSH_SCREEN=1 TSX_RUN=$W/scr TSX_PROGRESS_FILE=$W/scr/tsx-progress TSX_PR_DD_TICK=1 FAKE_SSH_SLOW=3 \
	TSX_PUSH_OP="factory restore" TSX_PUSH_LABEL="the factory bundle" tsx_push_bundle "$W/fb" "$W/r4/b" ssh root@rescue > "$W/scr.out" 2>&1 ) &
PP=$!
n=0; while [ ! -s "$W/scr/tsx-progress" ] && [ $n -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
sleep 1.2
ST=$(cat "$W/scr/tsx-install-state" 2>/dev/null); PR=$(cat "$W/scr/tsx-progress" 2>/dev/null); OP=$(cat "$W/scr/tsx-op" 2>/dev/null)
wait $PP; rc=$?
[ $rc = 0 ] || cat "$W/scr.out"
case "$ST" in "receiving the factory bundle from the host: "[0-9]*" of "[0-9]*" MiB") ok "state while data arrives: $ST";; *) bad "state: '$ST'";; esac
case "$OP" in [0-9]*" factory restore") ok "tsx-op: PID and the name of the operation";; *) bad "tsx-op: '$OP'";; esac
set -- $PR
[ "${2:-}" = 0 ] && [ "${1:-0}" -gt 0 ] && [ "${4:-} ${5:-} ${6:-}" = "the factory bundle" ] && ok "tsx-progress: POS 0 LEN NAME, as pr_dd writes it ($PR)" || bad "tsx-progress: '$PR'"
[ $rc = 0 ] && grep -q '^idle: received the factory bundle$' "$W/scr/tsx-install-state" && ok "after the push: the state goes back to idle (the screen hides it)" || bad "after: rc $rc $(cat "$W/scr/tsx-install-state")"
OUT=$( TSX_PUSH_SCREEN=1 TSX_RUN=$W/scr TSX_PROGRESS_FILE=$W/scr/tsx-progress FAKE_SSH_CUT=50000 tsx_push_bundle "$W/fb" "$W/r4/b" ssh root@rescue 2>&1 ); rc=$?
[ $rc != 0 ] && grep -q '^failed: receiving the install files from the host' "$W/scr/tsx-install-state" && ok "a stream that stops: the screen state says failed" || bad "cut: rc $rc $(cat "$W/scr/tsx-install-state")"
grep -q 'printf "%s 0 %s %s\\n" $((n \* 1024)) @TOTALB@ "$L" > "$P"' "$HERE/lib/tsx-rescue.sh" && ok "the receiver writes POS OFF LEN NAME" || bad "receiver format"
grep -q 'echo "\$\$ install" > "\$RUN/tsx-op"' "$HERE/steps/tsx-rescue-install" && grep -q 'printf .*TSX_PROGRESS_FILE:-/run/tsx-progress' "$LIB" \
	&& ok "the root stream (tsx-rescue-install run, pr_dd) still registers and writes its progress" || bad "root stream screen"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-push || echo FAIL test-install-push
exit $F
