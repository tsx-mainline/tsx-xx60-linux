#!/bin/bash
# Host test for the CSR8811 Bluetooth bring-up of the xx60. tsx-bt comes from
# tsx-linux-common. The chip file and the PSR loader are the real files of
# this repository, and so are board.sh and tsx-hw. No hardware, no compile,
# Python standard library and busybox only:
#  - csr_psload.py (the PSR upload over BCSP) against a fake BlueCore on a
#    pty (bt-fake-bluecore.py): key order, words, PSRAM store, warm reset, a
#    lost packet, a refused key, a silent chip.
#  - tsx-bt with the chip file, a fake sysfs and fake tools: the order of
#    the steps (rfkill pulse, PSR upload, hciattach, HCIDEVUP), the
#    Bluetooth address and its PSR line, the PSR kinds, the state file, and
#    a soft failure with a reason for each broken step.
#  - tsx-bt with the chip file, the real csr_psload.py and the fake BlueCore
#    on a pty: the whole path from "tsx-bt up" to the PS keys.
#  - A panel without a Bluetooth module (the tsx-hw of the xx60 with
#    government=1): state absent with the REASON text, exit 0, and no
#    rfkill, UART or tool call.
# The PSR files here are made up. They are not the vendor file.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$XX60/rootfs/overlay/usr/local/lib/tsx
BT=$(P usr/local/sbin/tsx-bt)
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED common/test-bt-csr8811: no busybox on this host"; exit 0; }
W=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

cat > "$W/base.psr" <<'EOF'
// made-up test PSR: comments, a commented-out key, keys of several sizes
// PSKEY_SOMETHING
&003c = 0426
//&0001 = 0000 a8a8 005b 0002
&212c = 0000 c47d 5714 0018 ff2b ff0e d800 7918 009e 0018 ff2b ff0e c500 8018 00e2 7080
&01f9 = 0001
&01ea = 0001 c200
EOF
echo '&0001 = 00cc ddee 00bb 02aa' > "$W/mac.psr"

echo "== csr_psload.py: PSR parser =="
python3 "$LIB/csr_psload.py" --check "$W/base.psr" "$W/mac.psr" > "$W/check.out" 2>&1 \
	&& [ "$(wc -l < "$W/check.out")" = 5 ] && ok "5 keys parsed, comments and the commented-out key skipped" || bad "parse: $(cat "$W/check.out")"
printf '&0001 = 00zz 1234\n' > "$W/broken.psr"
python3 "$LIB/csr_psload.py" --check "$W/broken.psr" >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "a broken key line is refused (exit 2), never half loaded" || bad "broken line: exit $rc"
python3 - "$LIB" <<'EOF' && ok "PSKEY_BDADDR line: 00m4 m5m6 00m3 m1m2 (the vendor layout)" || bad "bdaddr_psr_line"
import sys; sys.path.insert(0, sys.argv[1]); import csr_psload as c
assert c.bdaddr_psr_line("02:AA:BB:CC:DD:EE") == "&0001 = 00cc ddee 00bb 02aa", c.bdaddr_psr_line("02:AA:BB:CC:DD:EE")
EOF

echo "== csr_psload.py: upload to a fake BlueCore =="
fake() {  # fake MODE [loader args...]
	local mode=$1; shift
	python3 "$HERE/bt-fake-bluecore.py" "$mode" "$W/res-$mode.json" -- \
		python3 "$LIB/csr_psload.py" --device @TTY@ "$@" > "$W/fake-$mode.log" 2>&1
}
fake ok "$W/base.psr" "$W/mac.psr"
python3 - "$W/res-ok.json" <<'EOF' && ok "all keys in file order, the right words, store PSRAM (0x0008), then one warm reset" || { bad "upload to the fake chip"; cat "$W/fake-ok.log"; }
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rc"] == 0, r
assert r["link"], r
want = [[0x003c, 8, [0x0426]],
        [0x212c, 8, [0x0000, 0xc47d, 0x5714, 0x0018, 0xff2b, 0xff0e, 0xd800, 0x7918, 0x009e, 0x0018, 0xff2b, 0xff0e, 0xc500, 0x8018, 0x00e2, 0x7080]],
        [0x01f9, 8, [0x0001]], [0x01ea, 8, [0x0001, 0xc200]], [0x0001, 8, [0x00cc, 0xddee, 0x00bb, 0x02aa]]]
assert r["keys"] == want, r["keys"]
assert r["resets"] == 1, r
EOF
fake csr8811 "$W/base.psr" "$W/mac.psr"
python3 - "$W/res-csr8811.json" <<'EOF' && ok "the CSR8811 link establishment (its own SYNC, no SYNC-RESP, CRC packets): all keys load" || { bad "CSR8811 link establishment"; cat "$W/fake-csr8811.log"; }
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rc"] == 0 and r["link"] and len(r["keys"]) == 5 and r["resets"] == 1, r
EOF
fake lossy --no-reset "$W/base.psr"
python3 - "$W/res-lossy.json" <<'EOF' && ok "a lost packet is sent again, every key arrives once, --no-reset sends no reset" || { bad "lossy link"; cat "$W/fake-lossy.log"; }
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rc"] == 0 and len(r["keys"]) == 4 and r["resets"] == 0, r
EOF
fake refuse "$W/base.psr" "$W/mac.psr"
python3 - "$W/res-refuse.json" <<'EOF' && grep -q 'refused PS key 0x01f9' "$W/fake-refuse.log" \
	&& ok "a refused key stops the upload (exit 1, the key is named, no reset)" || { bad "refused key"; cat "$W/fake-refuse.log"; }
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rc"] == 1 and len(r["keys"]) == 3 and r["resets"] == 0, r
EOF
t0=$(date +%s)
fake silent --timeout 1 "$W/base.psr"
python3 - "$W/res-silent.json" <<'EOF' && grep -q 'no BCSP answer' "$W/fake-silent.log" && [ $(($(date +%s) - t0)) -lt 10 ] \
	&& ok "a silent chip: exit 1 after the link timeout, with the reason" || { bad "silent chip"; cat "$W/fake-silent.log"; }
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rc"] == 1, r
EOF
python3 "$LIB/csr_psload.py" --device "$W/no-such-tty" "$W/base.psr" > "$W/nodev.log" 2>&1; rc=$?
[ $rc = 1 ] && ok "a missing tty: exit 1" || bad "missing tty: exit $rc"

echo "== tsx-bt with the chip file: bring-up with a fake sysfs and fake tools =="
S=$W/sys; R=$W/run; B=$W/bin
mkdir -p "$S/class/net/eth0" "$S/class/net/lo" "$S/class/rfkill/rfkill0" "$S/class/rfkill/rfkill1" "$S/class/bluetooth" "$R" "$B" "$W/lib"
echo 00:00:00:00:00:00 > "$S/class/net/lo/address"
echo 00:10:7f:ab:cd:ef > "$S/class/net/eth0/address"
echo wlan > "$S/class/rfkill/rfkill0/type"; echo phy0 > "$S/class/rfkill/rfkill0/name"; echo 0 > "$S/class/rfkill/rfkill0/soft"
echo bluetooth > "$S/class/rfkill/rfkill1/type"; echo bt-dev > "$S/class/rfkill/rfkill1/name"; echo 0 > "$S/class/rfkill/rfkill1/soft"
: > "$W/ttyAML1"
LOG=$W/calls.log
# The chip file is the real one. board.sh finds it through TSX_BT_LIB, so the
# test puts a copy into the fake lib folder. This also checks that the board
# file names the chip file.
cp "$LIB/bt-chip-csr8811.sh" "$W/lib/"
# fake csr_psload.py: record the call and the soft state of the rfkill
cat > "$W/lib/csr_psload.py" <<EOF
import sys, shutil
args = sys.argv[1:]
if "--check" in args:
    sys.exit(0 if "bad" not in args[-1] else 2)
with open("$LOG", "a") as f:
    f.write("psload rfkill=%s %s\n" % (open("$S/class/rfkill/rfkill1/soft").read().strip(), " ".join(args)))
shutil.copy(args[-1], "$W/loaded-bdaddr.psr")
if open("$W/psload-mode").read().strip() == "fail":
    print("csr_psload: no BCSP answer from the chip (SYNC stage). Check the reset line, the UART and the parity")
    sys.exit(1)
print("csr_psload: done: 5 PS keys loaded from 2 file(s)")
EOF
echo ok > "$W/psload-mode"
# fake btscan.py: "--up" is the HCIDEVUP step of tsx-bt
cat > "$W/lib/btscan.py" <<EOF
import sys
with open("$LOG", "a") as f:
    f.write("hcidevup %s\n" % " ".join(sys.argv[1:]))
EOF
cat > "$B/hciattach" <<EOF
#!/bin/sh
echo "hciattach \$*" >> "$LOG"
[ "\$(cat "$W/attach-mode")" = fail ] && { echo "BCSP initialization timed out"; exit 1; }
[ "\$(cat "$W/attach-mode")" = nodev ] || mkdir -p "$S/class/bluetooth/hci0"
echo "Device setup complete"
EOF
echo ok > "$W/attach-mode"
cat > "$B/hciconfig" <<EOF
#!/bin/sh
echo "hciconfig \$*" >> "$LOG"
exit 0
EOF
mkdir -p "$W/proc/1"; printf 'init\0' > "$W/proc/1/cmdline"
printf '#!/bin/sh\nexit 0\n' > "$B/logger"
chmod +x "$B"/*
cp "$W/base.psr" "$W/vendor.psr"
btsh() { env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_TTY="$W/ttyAML1" TSX_BT_PSR="${PSRF:-$W/vendor.psr}" \
	TSX_BT_LIB="$W/lib" TSX_BT_MODDIR="$W/nomod" \
	TSX_BT_WAIT=1 TSX_BT_SETTLE=0 TSX_PROC="$W/proc" busybox sh "$BT" "$@"; }
st() { sed -n "s/^$1=//p" "$R/bt.state"; }
# hwdetect CMDLINE: write hw.conf with the real tsx-hw of the xx60
hwdetect() { echo "$1" > "$W/proc/cmdline"; env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_PROC="$W/proc" busybox sh "$XX60_HW" detect >/dev/null; }

[ "$(btsh mac)" = 00:10:7F:AB:CD:EF ] && ok "the address is the eth0 MAC, upper case (the vendor value)" || bad "mac: $(btsh mac)"
echo 'MAC="0a:bb:cc:dd:ee:ff"' > "$R/bt.conf"
[ "$(btsh mac)" = 0A:BB:CC:DD:EE:FF ] && ok "BT_MAC (bt.conf MAC) wins" || bad "BT_MAC override: $(btsh mac)"
rm -f "$R/bt.conf"
: > "$LOG"
btsh up > "$W/up.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = up ] && [ "$(st hci)" = hci0 ] && ok "up: exit 0, state=up, hci=hci0" || { bad "up: exit $rc, $(cat "$R/bt.state" 2>/dev/null)"; cat "$W/up.log"; }
[ "$(st psr)" = vendor-unpinned ] && grep -q 'not the pinned one' "$W/up.log" && ok "an unknown PSR loads with a warning that logs its sha256" || bad "psr kind $(st psr)"
[ "$(cat "$R/bt.mac" 2>/dev/null)" = 00:10:7F:AB:CD:EF ] && ok "bt.mac written for the ESPHome device info" || bad "bt.mac: $(cat "$R/bt.mac" 2>/dev/null)"
[ "$(cat "$W/loaded-bdaddr.psr")" = "&0001 = 00ab cdef 007f 0010" ] && ok "the PSKEY_BDADDR line loads last: $(cat "$W/loaded-bdaddr.psr")" || bad "bdaddr psr: $(cat "$W/loaded-bdaddr.psr")"
[ "$(cat "$S/class/rfkill/rfkill1/soft")" = 0 ] && [ "$(cat "$S/class/rfkill/rfkill0/soft")" = 0 ] && ok "the bt-dev rfkill ends unblocked, the wlan rfkill is not touched" || bad "rfkill state"
order=$(sed 's/ .*//' "$LOG" | tr '\n' ' ')
[ "$order" = "psload hciattach hcidevup " ] && ok "order: reset, psload, hciattach, HCIDEVUP" || bad "order: $order"
grep -q '^hcidevup --hci hci0 --up$' "$LOG" && ok "HCIDEVUP runs as btscan.py --hci hci0 --up" || bad "hcidevup call: $(grep hcidevup "$LOG")"
grep -q "^psload rfkill=0 --device $W/ttyAML1 --baud 115200 $W/vendor.psr $R/bt-bdaddr.psr" "$LOG" && ok "psload: unblocked chip, 115200, the vendor PSR first" || bad "psload call: $(grep psload "$LOG")"
grep -q "^hciattach -s 115200 $W/ttyAML1 bcsp 115200" "$LOG" && ok "hciattach -s 115200 TTY bcsp 115200 (the vendor command)" || bad "hciattach call"

failcase() {  # failcase TITLE EXPECTED-REASON-PART
	rm -rf "$S/class/bluetooth/hci0"
	btsh up > "$W/fail.log" 2>&1; rc=$?
	[ $rc = 1 ] && [ "$(st state)" = failed ] && st reason | grep -q "$2" \
		&& ok "$1: exit 1, state=failed, reason '$(st reason)'" || { bad "$1: exit $rc, $(cat "$R/bt.state")"; cat "$W/fail.log"; }
}
echo fail > "$W/psload-mode"; failcase "PSR upload fails (no hw.conf)" "PSR upload: csr_psload: no BCSP answer.*government=unknown"
hwdetect "console=tty0 androidboot.government=0"
failcase "PSR upload fails on a government=0 panel" "this panel has government=0. A panel with government=1 has no Bluetooth module"
rm -f "$R/hw.conf"; echo ok > "$W/psload-mode"
echo fail > "$W/attach-mode"; failcase "hciattach fails" "hciattach: BCSP initialization timed out"
echo nodev > "$W/attach-mode"; failcase "no hci device" "no new hci device"; echo ok > "$W/attach-mode"
mv "$W/ttyAML1" "$W/ttyAML1.x"; failcase "no UART node" "does not exist"; mv "$W/ttyAML1.x" "$W/ttyAML1"

# no address source: no BT_MAC and no network MAC. The controller keeps its
# own address: no PSKEY_BDADDR line, no bt.mac (tsx-btscan writes it then)
mv "$S/class/net/eth0" "$W/eth0.x"; rm -rf "$S/class/bluetooth/hci0" "$R/bt.mac"; : > "$LOG"
btsh up > "$W/nomac.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = up ] && [ -z "$(st mac)" ] && [ ! -e "$R/bt.mac" ] \
	&& grep -q 'the controller keeps its own address' "$W/nomac.log" && ! grep -q 'bt-bdaddr.psr' "$LOG" \
	&& ok "no address source: the bring-up goes on, no address is loaded, no bt.mac (the daemon reads it from the controller)" \
	|| { bad "no address source: exit $rc, $(cat "$R/bt.state")"; cat "$W/nomac.log"; }
mv "$W/eth0.x" "$S/class/net/eth0"

rm -f "$W/vendor.psr"; rm -rf "$S/class/bluetooth/hci0"
btsh up > "$W/up3.log" 2>&1
[ "$(st state)" = up ] && [ "$(st psr)" = bdaddr-only ] && grep -q 'no vendor PSR file' "$W/up3.log" \
	&& ok "no vendor PSR: only the address loads, the bring-up goes on" || bad "no vendor PSR: $(cat "$R/bt.state")"
printf 'bad\n' > "$W/vendor.psr.bad"; cp "$W/vendor.psr.bad" "$W/bad"
rm -rf "$S/class/bluetooth/hci0"
PSRF="$W/bad" btsh up > "$W/up4.log" 2>&1
[ "$(st psr)" = bdaddr-only ] && grep -q 'does not parse' "$W/up4.log" && ok "a PSR that does not parse is left out, with a warning" || bad "bad PSR: $(cat "$W/up4.log")"
: > "$LOG"
# a running hciattach on this tty (a real process with a fake /proc entry),
# and one on another tty that must survive
sleep 300 & A1=$!; sleep 300 & A2=$!; PIDS="$PIDS $A1 $A2"
mkdir -p "$W/proc/$A1" "$W/proc/$A2"
printf 'hciattach\0-s\0115200\0%s\0bcsp\0115200\0' "$W/ttyAML1" > "$W/proc/$A1/cmdline"
printf '/usr/bin/hciattach\0-s\0115200\0/dev/ttyOTHER\0bcsp\0' > "$W/proc/$A2/cmdline"
( sleep 0.3; rm -rf "$W/proc/$A1" ) &
btsh down > "$W/down.log" 2>&1
kill -0 "$A1" 2>/dev/null && bad "down: the hciattach on the panel tty still runs" || ok "down: the hciattach on the panel tty is stopped"
kill -0 "$A2" 2>/dev/null && ok "down: an hciattach on another tty is left alone" || bad "down: killed the hciattach of another tty"
[ "$(st state)" = down ] && [ "$(cat "$S/class/rfkill/rfkill1/soft")" = 1 ] && grep -q '^hciconfig hci0 down' "$LOG" \
	&& ok "down: hci0 down, chip held in reset, state=down" || bad "down: $(cat "$R/bt.state"), $(cat "$LOG")"

echo "== tsx-bt: a panel without a Bluetooth module (tsx-hw of the xx60, government=1) =="
rm -rf "$S/class/bluetooth/hci0" "$R/bt.state" "$R/bt-bdaddr.psr"; : > "$LOG"
echo 0 > "$S/class/rfkill/rfkill1/soft"
hwdetect "console=tty0 androidboot.government=1"
want=$(sed -n 's/^REASON=//p' "$R/hw.conf")
[ -n "$want" ] && [ "$(sed -n 's/^BT=//p' "$R/hw.conf")" = no ] && ok "tsx-hw: BT=no and a REASON text for government=1" || bad "hw.conf: $(cat "$R/hw.conf")"
btsh status > "$W/abs0.log" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^state=absent' "$W/abs0.log" && grep -qxF "reason=$want" "$W/abs0.log" \
	&& ok "status before any run: state=absent with the REASON text, exit 0" || bad "status (absent, no state file): exit $rc, $(cat "$W/abs0.log")"
btsh up > "$W/abs.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = absent ] && [ "$(st reason)" = "$want" ] \
	&& ok "up: exit 0, state=absent, reason '$(st reason)'" || { bad "up (absent): exit $rc, $(cat "$R/bt.state" 2>/dev/null)"; cat "$W/abs.log"; }
[ ! -s "$LOG" ] && [ "$(cat "$S/class/rfkill/rfkill1/soft")" = 0 ] && [ ! -e "$R/bt-bdaddr.psr" ] \
	&& ok "up: no rfkill pulse, no PSR upload, no hciattach" || bad "up (absent) touched the chip: $(cat "$LOG"), soft=$(cat "$S/class/rfkill/rfkill1/soft")"
btsh down > "$W/abs2.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = absent ] && [ "$(cat "$S/class/rfkill/rfkill1/soft")" = 0 ] && [ ! -s "$LOG" ] \
	&& ok "down: exit 0, state stays absent, the rfkill is not touched" || bad "down (absent): exit $rc, $(cat "$R/bt.state"), soft=$(cat "$S/class/rfkill/rfkill1/soft")"
btsh status | grep -q '^state=absent' && ok "status: state=absent" || bad "status (absent): $(btsh status)"
# A hw.conf with an empty REASON, or with no REASON line: the chip file gives the short text
for variant in 'BT=no\nREASON=\n' 'BT=no\n'; do
	printf "$variant" > "$R/hw.conf"; rm -f "$R/bt.state"
	btsh status > "$W/abs4.log" 2>&1; rc=$?
	[ $rc = 0 ] && grep -qx 'reason=no Bluetooth module on this panel' "$W/abs4.log" \
		&& ok "BT=no with no REASON text: the reason is the short text, no brackets" || bad "no REASON: exit $rc, $(cat "$W/abs4.log")"
done
# The script reads hw.conf, not the command line
rm -f "$R/hw.conf" "$R/bt.state"; echo 'console=ttyAML0 androidboot.government=1' > "$W/proc/cmdline"
btsh up > "$W/abs3.log" 2>&1
[ "$(st state)" = up ] && ok "no hw.conf: the bring-up runs (tsx-bt reads hw.conf, not /proc/cmdline)" || bad "no hw.conf: $(cat "$R/bt.state")"

echo "== tsx-bt with the chip file and the real csr_psload.py against a fake BlueCore =="
# The chip file runs csr_psload.py on the pty of the fake BlueCore. The fake
# plays the chip until tsx-bt ends. hciattach, btscan.py and the rfkill are fakes.
rm -rf "$S/class/bluetooth/hci0" "$R/bt.state" "$R/bt.mac"; : > "$LOG"
echo 0 > "$S/class/rfkill/rfkill1/soft"
cp "$LIB/csr_psload.py" "$W/lib/csr_psload.py"
printf '#!/bin/sh\necho "hciattach $*" >> "%s"\nmkdir -p "%s/class/bluetooth/hci0"\n' "$LOG" "$S" > "$B/hciattach"
cp "$W/base.psr" "$W/vendor.psr"
python3 "$HERE/bt-fake-bluecore.py" csr8811 "$W/res-tsxbt.json" -- \
	env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_TTY=@TTY@ TSX_BT_PSR="$W/vendor.psr" \
	TSX_BT_LIB="$W/lib" TSX_BT_MODDIR="$W/nomod" TSX_BT_WAIT=1 TSX_BT_SETTLE=0 TSX_PROC="$W/proc" busybox sh "$BT" up > "$W/tsxbt-fake.log" 2>&1
python3 - "$W/res-tsxbt.json" <<'EOF' && ok "tsx-bt up: the chip gets the 4 PS keys of the PSR, then the address key 0x0001 with the eth0 MAC, then one warm reset" || { bad "tsx-bt up against the fake chip"; cat "$W/tsxbt-fake.log"; }
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rc"] == 0 and r["link"] and r["resets"] == 1, r
keys = r["keys"]
assert [k[0] for k in keys] == [0x003c, 0x212c, 0x01f9, 0x01ea, 0x0001], keys
assert keys[-1] == [0x0001, 8, [0x00ab, 0xcdef, 0x007f, 0x0010]], keys[-1]
EOF
[ "$(st state)" = up ] && [ "$(st hci)" = hci0 ] && grep -q 'PSR upload: csr_psload: done' "$W/tsxbt-fake.log" \
	&& ok "tsx-bt up: state=up and the log has the PSR upload line" || { bad "tsx-bt up (fake chip): $(cat "$R/bt.state" 2>/dev/null)"; cat "$W/tsxbt-fake.log"; }

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS common/test-bt-csr8811 || echo FAIL common/test-bt-csr8811
exit $F
