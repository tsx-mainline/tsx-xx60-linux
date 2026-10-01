#!/bin/bash
# Host test for the Bluetooth bring-up of the panel (docs/hardware.md
# "Bluetooth (CSR8811)", docs/ha.md "Bluetooth proxy"). No hardware, no
# compile, Python standard library and busybox only:
#  - csr_psload.py (the PSR upload over BCSP) against a fake BlueCore on a
#    pty (bt-fake-bluecore.py): key order, words, PSRAM store, warm reset, a
#    lost packet, a refused key, a silent chip.
#  - tsx-bt (the bring-up script) with a fake sysfs and fake tools: the
#    order of the steps, the Bluetooth address and its PSR line, the state
#    file, and a soft failure with a reason for each broken step. Also: no
#    address source, no Bluetooth in the kernel, a board with no chip file
#    and a kernel driver that registers hci0 late (the wait and its limit).
#    On a panel without a Bluetooth module (hw.conf BT=no, government=1):
#    state absent, exit 0, and no rfkill, UART or tool call.
#  - btscan.py (the passive scanner) against a fake controller
#    (bt-fake-hci.py): passive scan parameters, the scan only while a client
#    is connected, and the record format.
#  - btscan.py: HCIDEVUP (--up), the controller address (Read BD_ADDR to
#    bt.mac), the scan mode and the state messages. bluetooth.py: the
#    advertisement queue cap, the feature flags and the mode of a connection.
#  - btscan.py + btgatt.py (the active connections) against fake peers
#    (bt-gatt-peer.py): links, GATT, the slot count, timeouts, drops
#    (bt-gatt-check.py), the pause of the passive scan around a connect,
#    and the BT_ACTIVE switch.
# The PSR files here are made up. They are not the vendor file.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$HERE/../overlay/usr/local/lib/tsx
BT=$HERE/../overlay/usr/local/sbin/tsx-bt
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-bt: no busybox on this host"; exit 0; }
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

echo "== tsx-bt: bring-up with a fake sysfs and fake tools =="
S=$W/sys; R=$W/run; B=$W/bin
mkdir -p "$S/class/net/eth0" "$S/class/net/lo" "$S/class/rfkill/rfkill0" "$S/class/rfkill/rfkill1" "$S/class/bluetooth" "$R" "$B" "$W/lib"
echo 00:00:00:00:00:00 > "$S/class/net/lo/address"
echo 00:10:7f:ab:cd:ef > "$S/class/net/eth0/address"
echo wlan > "$S/class/rfkill/rfkill0/type"; echo phy0 > "$S/class/rfkill/rfkill0/name"; echo 0 > "$S/class/rfkill/rfkill0/soft"
echo bluetooth > "$S/class/rfkill/rfkill1/type"; echo bt-dev > "$S/class/rfkill/rfkill1/name"; echo 0 > "$S/class/rfkill/rfkill1/soft"
: > "$W/ttyAML1"
LOG=$W/calls.log
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
if open("$W/up-mode").read().strip() == "down":
    print("HCIDEVUP on hci0: Operation not possible due to RF-kill (blocked by rfkill?)", file=sys.stderr)
    sys.exit(1)
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
[ \$# = 1 ] || exit 0
[ "\$(cat "$W/up-mode")" = down ] && { printf 'hci0:\tType: Primary  Bus: UART\n\tBD Address: 00:00:00:00:00:00  ACL MTU: 0:0\n\tDOWN\n'; exit 0; }
printf 'hci0:\tType: Primary  Bus: UART\n\tBD Address: %s  ACL MTU: 310:10\n\tUP RUNNING\n' "\$(cat "$W/bd")"
EOF
echo up > "$W/up-mode"; echo 00:10:7F:AB:CD:EF > "$W/bd"
mkdir -p "$W/proc/1"; printf 'init\0' > "$W/proc/1/cmdline"
printf '#!/bin/sh\nexit 0\n' > "$B/logger"
chmod +x "$B"/*
cp "$W/base.psr" "$W/vendor.psr"
btsh() { env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_TTY="$W/ttyAML1" TSX_BT_PSR="${PSRF:-$W/vendor.psr}" \
	TSX_BT_LIB="$W/lib" TSX_BT_CHIP="$LIB/bt-chip-csr8811.sh" TSX_BT_MODDIR="$W/nomod" \
	TSX_BT_WAIT=1 TSX_BT_SETTLE=0 TSX_PROC="$W/proc" busybox sh "$BT" "$@"; }
st() { sed -n "s/^$1=//p" "$R/bt.state"; }

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
printf 'GOVERNMENT=0\nMIC=yes\nBT=yes\nCAMERA=yes\nREASON=\n' > "$R/hw.conf"
failcase "PSR upload fails on a government=0 panel" "this panel has government=0. A panel with government=1 has no Bluetooth module"
rm -f "$R/hw.conf"; echo ok > "$W/psload-mode"
echo fail > "$W/attach-mode"; failcase "hciattach fails" "hciattach: BCSP initialization timed out"
echo nodev > "$W/attach-mode"; failcase "no hci device" "no new hci device"; echo ok > "$W/attach-mode"
echo down > "$W/up-mode"; failcase "HCIDEVUP fails" "hci0 does not come up: HCIDEVUP on hci0"; echo up > "$W/up-mode"
mv "$W/ttyAML1" "$W/ttyAML1.x"; failcase "no UART node" "does not exist"; mv "$W/ttyAML1.x" "$W/ttyAML1"
echo 'MAC="zz"' > "$R/bt.conf"; failcase "BT_MAC is not an address" "BT_MAC is not a valid address"; rm -f "$R/bt.conf"

# no address source: no BT_MAC and no network MAC. The controller keeps its
# own address: no PSKEY_BDADDR line, no bt.mac (tsx-btscan writes it then)
mv "$S/class/net/eth0" "$W/eth0.x"; rm -rf "$S/class/bluetooth/hci0" "$R/bt.mac"; : > "$LOG"
btsh up > "$W/nomac.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = up ] && [ -z "$(st mac)" ] && [ ! -e "$R/bt.mac" ] \
	&& grep -q 'the controller keeps its own address' "$W/nomac.log" && ! grep -q 'bt-bdaddr.psr' "$LOG" \
	&& ok "no address source: the bring-up goes on, no address is loaded, no bt.mac (the daemon reads it from the controller)" \
	|| { bad "no address source: exit $rc, $(cat "$R/bt.state")"; cat "$W/nomac.log"; }
[ "$(btsh mac)" = "none: the controller keeps its own address" ] && ok "tsx-bt mac: says that the controller keeps its address" || bad "mac without a source: $(btsh mac)"
mv "$W/eth0.x" "$S/class/net/eth0"

# the start rules: no Bluetooth in the kernel
mv "$S/class/bluetooth" "$W/btclass.x"; rm -f "$R/bt.state"; : > "$LOG"
btsh up > "$W/nokernel.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = absent ] && [ "$(st reason)" = "the kernel has no Bluetooth" ] && [ ! -s "$LOG" ] \
	&& ok "the kernel has no Bluetooth: state=absent, exit 0, no chip step" || { bad "no kernel Bluetooth: exit $rc, $(cat "$R/bt.state"), $(cat "$LOG")"; cat "$W/nokernel.log"; }
mkdir -p "$W/nomod/kernel/net/bluetooth"; : > "$W/nomod/kernel/net/bluetooth/bluetooth.ko.gz"
btsh up > "$W/modkernel.log" 2>&1
[ "$(st state)" = up ] && ok "Bluetooth as a module on the disk counts as Bluetooth in the kernel" || bad "module on disk: $(cat "$R/bt.state")"
rm -rf "$W/nomod"; mkdir -p "$S/class/bluetooth"; rm -rf "$W/btclass.x" "$S/class/bluetooth/hci0"

# a board with no chip file: the kernel driver registers hci0 late
nochip() { env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_LIB="$W/lib" TSX_BT_CHIP=none TSX_PROC="$W/proc" \
	TSX_BT_MODDIR="$W/nomod" "$@" busybox sh "$BT" up; }
: > "$LOG"; rm -f "$R/bt.state"
( sleep 1; mkdir -p "$S/class/bluetooth/hci0" ) &
t0=$(date +%s)
nochip TSX_BT_WAIT=10 > "$W/late.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = up ] && [ "$(st hci)" = hci0 ] && [ $(($(date +%s) - t0)) -ge 1 ] \
	&& ok "no chip file: tsx-bt waits for hci0, which the kernel driver registers after 1 s" || { bad "late hci0: exit $rc, $(cat "$R/bt.state")"; cat "$W/late.log"; }
[ "$(sed 's/ .*//' "$LOG" | tr '\n' ' ')" = "hcidevup " ] && ok "no chip file: no rfkill pulse, no PSR, no hciattach, only HCIDEVUP" || bad "no chip file calls: $(cat "$LOG")"
rm -rf "$S/class/bluetooth/hci0"; rm -f "$R/bt.state"
t0=$(date +%s)
nochip TSX_BT_WAIT=1 > "$W/never.log" 2>&1; rc=$?
[ $rc = 1 ] && [ "$(st state)" = failed ] && st reason | grep -q 'hci0 did not show up in 1 s' && [ $(($(date +%s) - t0)) -lt 5 ] \
	&& ok "no chip file, no hci0: the wait ends at the limit (1 s), state=failed with the reason" || { bad "hci0 never shows up: exit $rc, $(cat "$R/bt.state")"; cat "$W/never.log"; }
mkdir -p "$S/class/bluetooth/hci1"; rm -f "$R/bt.state"
nochip TSX_BT_HCI=hci1 > "$W/hci1.log" 2>&1
[ "$(st hci)" = hci1 ] && grep -q '^hcidevup --hci hci1 --up$' "$LOG" && ok "TSX_BT_HCI names the device that tsx-bt waits for and brings up" || bad "TSX_BT_HCI: $(cat "$R/bt.state")"
rm -rf "$S/class/bluetooth/hci1"; mkdir -p "$S/class/bluetooth/hci0"
echo 'MAC="02:11:22:33:44:55"' > "$R/bt.conf"; nochip > "$W/nochipmac.log" 2>&1
grep -q 'BT_MAC does not apply on this board' "$W/nochipmac.log" && [ ! -e "$R/bt.mac" ] && ok "no chip file: BT_MAC cannot apply, a warning, no bt.mac" || bad "BT_MAC without a chip file: $(cat "$W/nochipmac.log")"
rm -f "$R/bt.conf" "$R/bt.state"; rm -rf "$S/class/bluetooth/hci0"
env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_LIB="$W/lib" TSX_BT_CHIP=none TSX_PROC="$W/proc" busybox sh "$BT" down > "$W/nochipdown.log" 2>&1
[ "$(st state)" = down ] && ok "no chip file: down only records the state" || bad "no chip file down: $(cat "$R/bt.state")"

echo "== tsx-bt: a panel without a Bluetooth module (hw.conf BT=no) =="
rm -rf "$S/class/bluetooth/hci0" "$R/bt.state" "$R/bt-bdaddr.psr"; : > "$LOG"
echo 0 > "$S/class/rfkill/rfkill1/soft"
printf 'GOVERNMENT=1\nMIC=no\nBT=no\nCAMERA=no\nREASON=government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module\n' > "$R/hw.conf"
btsh status > "$W/abs0.log" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^state=absent' "$W/abs0.log" && grep -q '^reason=no Bluetooth module on this panel (government=1)$' "$W/abs0.log" \
	&& ok "status before any run: state=absent with the reason, exit 0" || bad "status (absent, no state file): exit $rc, $(cat "$W/abs0.log")"
btsh up > "$W/abs.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = absent ] && st reason | grep -q 'no Bluetooth module on this panel (government=1)' \
	&& ok "up: exit 0, state=absent, reason '$(st reason)'" || { bad "up (absent): exit $rc, $(cat "$R/bt.state" 2>/dev/null)"; cat "$W/abs.log"; }
[ ! -s "$LOG" ] && [ "$(cat "$S/class/rfkill/rfkill1/soft")" = 0 ] && [ ! -e "$R/bt-bdaddr.psr" ] \
	&& ok "up: no rfkill pulse, no PSR upload, no hciattach" || bad "up (absent) touched the chip: $(cat "$LOG"), soft=$(cat "$S/class/rfkill/rfkill1/soft")"
btsh down > "$W/abs2.log" 2>&1; rc=$?
[ $rc = 0 ] && [ "$(st state)" = absent ] && [ "$(cat "$S/class/rfkill/rfkill1/soft")" = 0 ] && [ ! -s "$LOG" ] \
	&& ok "down: exit 0, state stays absent, the rfkill is not touched" || bad "down (absent): exit $rc, $(cat "$R/bt.state"), soft=$(cat "$S/class/rfkill/rfkill1/soft")"
btsh status | grep -q '^state=absent' && ok "status: state=absent" || bad "status (absent): $(btsh status)"
# The script reads hw.conf, not the command line
rm -f "$R/hw.conf" "$R/bt.state"; echo 'console=ttyAML0 androidboot.government=1' > "$W/proc/cmdline"
btsh up > "$W/abs3.log" 2>&1
[ "$(st state)" = up ] && ok "no hw.conf: the bring-up runs (tsx-bt reads hw.conf, not /proc/cmdline)" || bad "no hw.conf: $(cat "$R/bt.state")"
rm -f "$W/proc/cmdline"

rm -f "$W/vendor.psr"; rm -rf "$S/class/bluetooth/hci0"
btsh up > "$W/up3.log" 2>&1
[ "$(st state)" = up ] && [ "$(st psr)" = bdaddr-only ] && grep -q 'no vendor PSR file' "$W/up3.log" \
	&& ok "no vendor PSR: only the address loads, the bring-up goes on" || bad "no vendor PSR: $(cat "$R/bt.state")"
printf 'bad\n' > "$W/vendor.psr.bad"; cp "$W/vendor.psr.bad" "$W/bad"
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

echo "== btscan.py: passive scan against a fake controller =="
python3 - "$LIB" <<'EOF' && ok "HCI_FILTER option is 16 bytes (struct hci_ufilter with padding; the kernel refuses 14)" || bad "hci_filter size"
import sys; sys.path.insert(0, sys.argv[1]); import btscan
assert len(btscan.hci_filter()) == 16, len(btscan.hci_filter())
EOF
python3 "$HERE/bt-fake-hci.py" "$W/hci.sock" "$W/hci.log" > "$W/fakehci.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do [ -S "$W/hci.sock" ] && break; sleep 0.1; done
TSX_BTSCAN_FAKE_HCI="$W/hci.sock" python3 "$LIB/btscan.py" --socket "$W/adv.sock" --group "" > "$W/btscan.log" 2>&1 &
SCAN=$!; PIDS="$PIDS $SCAN"
for _ in $(seq 1 50); do [ -S "$W/adv.sock" ] && grep -q 'HCI socket open' "$W/btscan.log" && break; sleep 0.1; done
[ "$(stat -c '%a' "$W/adv.sock" 2>/dev/null)" = 660 ] && ok "the socket is mode 660 (group kiosk on the panel)" || bad "socket mode $(stat -c '%a' "$W/adv.sock" 2>/dev/null)"
sleep 0.5
grep -q '^cmd 200c' "$W/hci.log" && bad "the scan started with no client" || ok "no scan while no client is connected"
python3 - "$W/adv.sock" <<'EOF' && ok "a client gets each report as one record (address, type, RSSI, event type, data)" || bad "records: see above"
import socket, struct, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.connect(sys.argv[1]); s.settimeout(5)
seen = {}
end = time.time() + 5
while len(seen) < 3 and time.time() < end:
    m = s.recv(128)
    if len(m) < 9:
        assert m[:1] == b"S", m   # a scanner state message
        continue
    addr = ":".join("%02X" % b for b in reversed(m[:6]))
    atype, rssi, etype = struct.unpack_from("BbB", m, 6)
    seen[addr] = (atype, rssi, etype, m[9:].hex())
want = {"C0:FF:EE:00:00:01": (1, -60, 0, "0201060aff4c001005031c000001"),
        "12:34:56:78:9A:BC": (0, -75, 3, "0303aafe1116aafe10f403676f6f676c6507"),
        "00:11:22:33:44:55": (3, -90, 0, "")}
assert seen == want, seen
s.close()
EOF
sleep 1.5
python3 - "$W/hci.log" <<'EOF' && ok "passive scan: disable, parameters (type passive, 100 ms/100 ms, public, no filter), enable without duplicate filter. Disable after the last client left" || { bad "HCI commands"; cat "$W/hci.log"; }
import sys
cmds = [l.split()[1:] for l in open(sys.argv[1]) if l.startswith("cmd ") and not l.startswith("cmd 1009")]
assert cmds[:3] == [["200c", "0000"], ["200b", "00a000a0000000"], ["200c", "0100"]], cmds
assert cmds[-1] == ["200c", "0000"], cmds
EOF
kill "$SCAN" 2>/dev/null; wait "$SCAN" 2>/dev/null
[ ! -e "$W/adv.sock" ] && grep -q 'stopped' "$W/btscan.log" && ok "SIGTERM: clean stop, socket removed" || bad "stop: $(tail -3 "$W/btscan.log")"

echo "== btscan.py: HCIDEVUP, controller address, scan mode and state =="
BS="python3 $LIB/btscan.py"
TSX_BTSCAN_FAKE_HCI=x $BS --hci hci0 --up && ok "--up: HCIDEVUP done (the fake controller), exit 0" || bad "--up with the fake controller"
TSX_BTSCAN_FAKE_UP_ERRNO=114 $BS --hci hci0 --up && ok "--up: EALREADY (already up) is not an error" || bad "--up with EALREADY"
TSX_BTSCAN_FAKE_UP_ERRNO=16 $BS --hci hci0 --up > "$W/up-err.log" 2>&1; rc=$?
[ $rc = 1 ] && grep -q 'HCIDEVUP on hci0: ' "$W/up-err.log" && ok "--up: another error gives exit 1 and the reason" || bad "--up with EBUSY: exit $rc, $(cat "$W/up-err.log")"
M=$W/mode; mkdir -p "$M"
python3 "$HERE/bt-fake-hci.py" "$M/hci.sock" "$M/hci.log" 02:AA:BB:CC:DD:01 > "$M/fakehci.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do [ -S "$M/hci.sock" ] && break; sleep 0.1; done
printf 'PROXY="on"\nACTIVE="off"\n' > "$M/bt.conf"
rm -f "$M/bt.mac"
TSX_BT_CONF="$M/bt.conf" TSX_BT_MAC_FILE="$M/bt.mac" TSX_BTSCAN_FAKE_HCI="$M/hci.sock" python3 "$LIB/btscan.py" \
	--socket "$M/adv.sock" --gatt-socket "" --group "" > "$M/btscan.log" 2>&1 &
SCAN=$!; PIDS="$PIDS $SCAN"
for _ in $(seq 1 50); do [ -S "$M/adv.sock" ] && [ -s "$M/bt.mac" ] && break; sleep 0.1; done
[ "$(cat "$M/bt.mac" 2>/dev/null)" = 02:AA:BB:CC:DD:01 ] && [ "$(stat -c '%a' "$M/bt.mac")" = 644 ] \
	&& ok "no bt.mac: the daemon reads BD_ADDR from the controller and writes it to bt.mac (mode 644)" || bad "bt.mac from the controller: $(cat "$M/bt.mac" 2>/dev/null), $(tail -3 "$M/btscan.log")"
python3 - "$M/adv.sock" "$M/bt.conf" "$M/hci.log" <<'PYEOF' && ok "scan mode and state: state message first, passive with BT_ACTIVE off, active after BT_ACTIVE=on, passive again on request" || bad "scan mode: see above"
import re, socket, sys, time
sock, conf, hcilog = sys.argv[1:4]
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); s.connect(sock); s.settimeout(0.3); return s
def states(s, secs):
    """The 'S' messages that arrive in secs seconds: (state, mode)."""
    out = []; end = time.time() + secs
    while time.time() < end:
        try:
            m = s.recv(128)
        except socket.timeout:
            continue
        if len(m) == 3 and m[:1] == b"S":
            out.append((m[1], m[2]))
    return out
def scan_types():
    return [l.split()[2][:2] for l in open(hcilog) if l.startswith("cmd 200b")]
s = conn()
st = states(s, 1.0)
assert st and st[0][0] in (1, 2) and st[-1] == (2, 0), st   # starting or running, then running, passive
s.send(b"m\x01")           # the front end asks for the active scan
st = states(s, 1.0)
assert not st or st[-1] == (2, 0), st       # BT_ACTIVE is off: no change, still passive
assert set(scan_types()) == {"00"}, scan_types()
open(conf, "w").write('PROXY="on"\nACTIVE="on"\n')
st = states(s, 1.5)
assert st and st[-1] == (2, 1), st    # BT_ACTIVE on: the scan restarts as active
assert scan_types()[-1] == "01", scan_types()
s.send(b"m\x00")
st = states(s, 1.5)
assert st and st[-1] == (2, 0), st
assert scan_types()[-1] == "00", scan_types()
s.close()
# a second client gets the state at once
s2 = conn(); st = states(s2, 0.6); assert st and st[0][1] == 0, st
s2.close()
PYEOF
grep -q 'active scan on' "$M/btscan.log" && ok "the log names the scan mode" || bad "no 'active scan on' in the log"
kill "$SCAN" 2>/dev/null; wait "$SCAN" 2>/dev/null
echo 02:99:99:99:99:99 > "$M/bt.mac"
TSX_BT_CONF="$M/bt.conf" TSX_BT_MAC_FILE="$M/bt.mac" TSX_BTSCAN_FAKE_HCI="$M/hci.sock" python3 "$LIB/btscan.py" \
	--socket "$M/adv.sock" --gatt-socket "" --group "" > "$M/btscan2.log" 2>&1 &
SCAN=$!; PIDS="$PIDS $SCAN"
for _ in $(seq 1 50); do grep -q 'HCI socket open' "$M/btscan2.log" && break; sleep 0.1; done
sleep 0.3
[ "$(cat "$M/bt.mac")" = 02:99:99:99:99:99 ] && grep -q 'reports address 02:AA:BB:CC:DD:01, not 02:99:99:99:99:99' "$M/btscan2.log" \
	&& ok "a bt.mac that tsx-bt wrote stays. A different controller address is a warning" || bad "bt.mac kept: $(cat "$M/bt.mac"), $(cat "$M/btscan2.log")"
kill "$SCAN" 2>/dev/null; wait "$SCAN" 2>/dev/null
python3 "$HERE/bt-fake-hci.py" "$M/hci0.sock" "$M/hci0.log" 00:00:00:00:00:00 > "$M/fakehci0.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do [ -S "$M/hci0.sock" ] && break; sleep 0.1; done
rm -f "$M/bt.mac"
TSX_BT_CONF="$M/bt.conf" TSX_BT_MAC_FILE="$M/bt.mac" TSX_BTSCAN_FAKE_HCI="$M/hci0.sock" python3 "$LIB/btscan.py" \
	--socket "$M/adv.sock" --gatt-socket "" --group "" > "$M/btscan3.log" 2>&1 &
SCAN=$!; PIDS="$PIDS $SCAN"
for _ in $(seq 1 50); do grep -q 'HCI socket open' "$M/btscan3.log" && break; sleep 0.1; done
sleep 0.3
[ ! -e "$M/bt.mac" ] && grep -q 'not used' "$M/btscan3.log" && ok "an all-zero controller address is not written to bt.mac" || bad "zero address: $(cat "$M/btscan3.log")"
kill "$SCAN" 2>/dev/null; wait "$SCAN" 2>/dev/null

echo "== bluetooth.py (the ESPHome side): queue cap, flags, state =="
python3 - "$HERE/../voice/shim" "$W" <<'PYEOF' && ok "bluetooth.py: advertisement queue cap, feature flags, bt.state absent turns the proxy off, mode of each connection" || bad "bluetooth.py unit checks"
import os, sys
sys.path.insert(0, sys.argv[1])
w = sys.argv[2]
from tsx_panel import bluetooth as bt
# the queue holds at most QUEUE_MAX and drops the oldest
q = bt.AdvQueue()
for i in range(bt.QUEUE_MAX + 100):
    q.push((i, 0, -50, b""))
assert len(q) == bt.QUEUE_MAX and q.dropped == 100 and q.items[0][0] == 100, (len(q), q.dropped)
# a flush sends at most BATCHES_PER_TICK batches of BATCH_MAX
b = q.pop_batches()
assert len(b) == bt.BATCHES_PER_TICK and all(len(x) == bt.BATCH_MAX for x in b), [len(x) for x in b]
assert len(q) == bt.QUEUE_MAX - bt.BATCHES_PER_TICK * bt.BATCH_MAX
assert [x[0] for x in b[0]] == list(range(100, 100 + bt.BATCH_MAX))    # oldest first, in order
rest = q.pop_batches(limit=99)
assert sum(len(x) for x in rest) == bt.QUEUE_MAX - bt.BATCHES_PER_TICK * bt.BATCH_MAX and len(q) == 0
# feature flags: passive 97 (with state and mode), active 119
run = os.path.join(w, "shimrun"); os.makedirs(run, exist_ok=True)
open(os.path.join(run, "bt.conf"), "w").write('PROXY="on"\nACTIVE="off"\n')
p = bt.BtProxy(run)
assert p.device_info_fields()["bluetooth_proxy_feature_flags"] == 97, p.device_info_fields()
open(os.path.join(run, "bt.conf"), "w").write('PROXY="on"\nACTIVE="on"\n')
assert p.device_info_fields()["bluetooth_proxy_feature_flags"] == 119
# tsx-bt says the kernel has no Bluetooth: the proxy is off
open(os.path.join(run, "bt.state"), "w").write("state=absent\nreason=the kernel has no Bluetooth\n")
assert not p.enabled() and p.device_info_fields() == {}
open(os.path.join(run, "bt.state"), "w").write("state=up\n")
assert p.enabled()
# the mode of a connection counts only while it is subscribed
class C:
    def __init__(self): self.sent = []
    def send_messages(self, m): self.sent.extend(m)
c = C()
p.set_mode(c, bt.MODE_ACTIVE)
assert p._wanted_mode() == bt.MODE_PASSIVE      # not subscribed yet
p._subscribers.append(c)
assert p._wanted_mode() == bt.MODE_ACTIVE
p.unsubscribe(c)
assert p._wanted_mode() == bt.MODE_PASSIVE
PYEOF

echo "== btscan.py + btgatt.py: active connections against fake peers =="
G=$W/gatt; mkdir -p "$G"
python3 "$HERE/bt-fake-hci.py" "$G/hci.sock" "$G/hci.log" > "$G/fakehci.out" 2>&1 &
PIDS="$PIDS $!"
python3 "$HERE/bt-gatt-peer.py" fake "$G/peer.sock" "$G/peer.log" > "$G/peer.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do [ -S "$G/hci.sock" ] && [ -S "$G/peer.sock" ] && break; sleep 0.1; done
printf 'PROXY="on"\nACTIVE="on"\n' > "$G/bt.conf"
TSX_BT_CONF="$G/bt.conf" TSX_BTSCAN_FAKE_HCI="$G/hci.sock" TSX_BTSCAN_FAKE_L2CAP="$G/peer.sock" TSX_BT_CONNECT_TIMEOUT=2 \
	python3 "$LIB/btscan.py" --socket "$G/adv.sock" --group "" --max-connections 2 > "$G/btscan.log" 2>&1 &
SCAN=$!; PIDS="$PIDS $SCAN"
for _ in $(seq 1 50); do [ -S "$G/bt-gatt.sock" ] && grep -q 'HCI socket open' "$G/btscan.log" && break; sleep 0.1; done
[ "$(stat -c '%a' "$G/bt-gatt.sock" 2>/dev/null)" = 660 ] && ok "the GATT socket is next to the advertisement socket, mode 660" || bad "GATT socket: $(ls -l "$G" | grep sock)"
python3 "$HERE/bt-gatt-check.py" "$G/bt-gatt.sock" "$G/peer.log" > "$G/check.out" 2>&1; rc=$?
sed 's/^/  /' "$G/check.out" | grep -v '^    ok:' || true
[ $rc = 0 ] && ok "the GATT socket protocol: $(grep -c '  ok:' "$G/check.out") checks (bt-gatt-check.py)" || bad "bt-gatt-check.py: $rc failure(s)"
# the passive scan pauses while a link comes up and starts again after it
python3 - "$G/adv.sock" "$G/bt-gatt.sock" <<'PYEOF' && ok "advertisements flow again after a link came up" || bad "no advertisements after a connect: $(grep '^cmd' "$G/hci.log" | tail -12 | tr '\n' ' ')"
import json, socket, sys, time
adv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); adv.connect(sys.argv[1])
time.sleep(0.5)
g = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); g.connect(sys.argv[2]); g.settimeout(3)
g.recv(4096)
g.send(json.dumps({"op": "connect", "addr": 0xC0FFEE000003, "atype": 0}).encode())
while True:
    m = json.loads(g.recv(4096))
    if m.get("ev") == "conn":
        assert m["connected"], m
        break
time.sleep(0.6)
n0 = 0
end = time.time() + 1
adv.settimeout(0.3)
while time.time() < end:
    try:
        adv.recv(128); n0 += 1
    except socket.timeout:
        pass
assert n0 > 0, "no advertisements after the connect"
g.close(); adv.close()
PYEOF
python3 - "$G/hci.log" <<'PYEOF' && ok "HCI order: LE host support once, the scan pauses for the connect and starts again after it" || bad "HCI order: $(grep '^cmd' "$G/hci.log" | tail -12 | tr '\n' ' ')"
import sys
cmds = [" ".join(l.split()[1:]) for l in open(sys.argv[1]) if l.startswith("cmd ") and not l.startswith("cmd 1009")]
# LE Host Supported once for the HCI socket (before the first link)
assert cmds.count("0c6d 0100") == 1 and cmds[0] == "0c6d 0100", cmds
# the check above: scan on, off for the connect (pause), then disable,
# parameters, enable again. After that the stop disconnects the link.
last_on = max(i for i, c in enumerate(cmds) if c == "200c 0100")
assert cmds[last_on - 4:last_on + 1] == ["200c 0100", "200c 0000", "200c 0000", "200b 00a000a0000000", "200c 0100"], cmds
PYEOF
sed -i 's/ACTIVE="on"/ACTIVE="off"/' "$G/bt.conf"
python3 - "$G/bt-gatt.sock" <<'PYEOF' && ok "BT_ACTIVE off (bt.conf ACTIVE): a connect is refused at once" || bad "ACTIVE off: see btscan.log"
import json, socket, sys
g = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); g.connect(sys.argv[1]); g.settimeout(2)
g.recv(4096)
g.send(json.dumps({"op": "connect", "addr": 0xC0FFEE000001, "atype": 0}).encode())
m = json.loads(g.recv(4096))
assert m == {"ev": "conn", "addr": 0xC0FFEE000001, "connected": False, "mtu": 0, "error": 0}, m
PYEOF
grep -q 'connect refused: BT_ACTIVE is off' "$G/btscan.log" || bad "no log line for the refused connect"
kill "$SCAN" 2>/dev/null; wait "$SCAN" 2>/dev/null
[ ! -e "$G/bt-gatt.sock" ] && ok "SIGTERM: the GATT socket is removed" || bad "GATT socket left after the stop"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-bt || echo FAIL test-bt
exit $F
