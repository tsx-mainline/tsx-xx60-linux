#!/bin/bash
# Host test for the Bluetooth bring-up of the panel (docs/hardware.md
# "Bluetooth (CSR8811)", docs/ha.md "Bluetooth proxy"). No hardware, no
# compile, Python standard library and busybox only:
#  - csr_psload.py (the PSR upload over BCSP) against a fake BlueCore on a
#    pty (bt-fake-bluecore.py): key order, words, PSRAM store, warm reset, a
#    lost packet, a refused key, a silent chip.
#  - tsx-bt (the bring-up script) with a fake sysfs and fake tools: the
#    order of the steps, the Bluetooth address and its PSR line, the state
#    file, and a soft failure with a reason for each broken step.
#  - btscan.py (the passive scanner) against a fake controller
#    (bt-fake-hci.py): passive scan parameters, the scan only while a client
#    is connected, and the record format.
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
btsh() { env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_TTY="$W/ttyAML1" TSX_BT_PSR="$W/vendor.psr" \
	TSX_BT_LIB="$W/lib" TSX_BT_SETTLE=0 TSX_PROC="$W/proc" busybox sh "$BT" "$@"; }
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
[ "$order" = "psload hciattach hciconfig hciconfig " ] && ok "order: reset, psload, hciattach, hciconfig up" || bad "order: $order"
grep -q "^psload rfkill=0 --device $W/ttyAML1 --baud 115200 $W/vendor.psr $R/bt-bdaddr.psr" "$LOG" && ok "psload: unblocked chip, 115200, the vendor PSR first" || bad "psload call: $(grep psload "$LOG")"
grep -q "^hciattach -s 115200 $W/ttyAML1 bcsp 115200" "$LOG" && ok "hciattach -s 115200 TTY bcsp 115200 (the vendor command)" || bad "hciattach call"

echo 02:11:11:11:11:11 > "$W/bd"; rm -rf "$S/class/bluetooth/hci0"
btsh up > "$W/up2.log" 2>&1
grep -q 'reports BD address 02:11:11:11:11:11, not 00:10:7F:AB:CD:EF' "$W/up2.log" && [ "$(st state)" = up ] \
	&& ok "a different BD address from the chip is a warning, not a failure" || bad "address mismatch: $(cat "$W/up2.log")"
echo 00:10:7F:AB:CD:EF > "$W/bd"

failcase() {  # failcase TITLE EXPECTED-REASON-PART
	rm -rf "$S/class/bluetooth/hci0"
	btsh up > "$W/fail.log" 2>&1; rc=$?
	[ $rc = 1 ] && [ "$(st state)" = failed ] && st reason | grep -q "$2" \
		&& ok "$1: exit 1, state=failed, reason '$(st reason)'" || { bad "$1: exit $rc, $(cat "$R/bt.state")"; cat "$W/fail.log"; }
}
echo fail > "$W/psload-mode"; failcase "PSR upload fails" "PSR upload: csr_psload: no BCSP answer"; echo ok > "$W/psload-mode"
echo fail > "$W/attach-mode"; failcase "hciattach fails" "hciattach: BCSP initialization timed out"
echo nodev > "$W/attach-mode"; failcase "no hci device" "no new hci device"; echo ok > "$W/attach-mode"
echo down > "$W/up-mode"; failcase "hci0 stays down" "does not come up"; echo up > "$W/up-mode"
mv "$W/ttyAML1" "$W/ttyAML1.x"; failcase "no UART node" "does not exist"; mv "$W/ttyAML1.x" "$W/ttyAML1"
mv "$S/class/net/eth0" "$W/eth0.x"; failcase "no MAC at all" "no Bluetooth address"; mv "$W/eth0.x" "$S/class/net/eth0"

rm -f "$W/vendor.psr"; rm -rf "$S/class/bluetooth/hci0"
btsh up > "$W/up3.log" 2>&1
[ "$(st state)" = up ] && [ "$(st psr)" = bdaddr-only ] && grep -q 'no vendor PSR file' "$W/up3.log" \
	&& ok "no vendor PSR: only the address loads, the bring-up goes on" || bad "no vendor PSR: $(cat "$R/bt.state")"
printf 'bad\n' > "$W/vendor.psr.bad"; cp "$W/vendor.psr.bad" "$W/bad"
env PATH="$B:$PATH" TSX_RUN_DIR="$R" TSX_SYSFS="$S" TSX_BT_TTY="$W/ttyAML1" TSX_BT_PSR="$W/bad" TSX_BT_LIB="$W/lib" TSX_BT_SETTLE=0 TSX_PROC="$W/proc" \
	busybox sh "$BT" up > "$W/up4.log" 2>&1
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
cmds = [l.split()[1:] for l in open(sys.argv[1]) if l.startswith("cmd ")]
assert cmds[:3] == [["200c", "0000"], ["200b", "00a000a0000000"], ["200c", "0100"]], cmds
assert cmds[-1] == ["200c", "0000"], cmds
EOF
kill "$SCAN" 2>/dev/null; wait "$SCAN" 2>/dev/null
[ ! -e "$W/adv.sock" ] && grep -q 'stopped' "$W/btscan.log" && ok "SIGTERM: clean stop, socket removed" || bad "stop: $(tail -3 "$W/btscan.log")"

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
cmds = [" ".join(l.split()[1:]) for l in open(sys.argv[1]) if l.startswith("cmd ")]
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
