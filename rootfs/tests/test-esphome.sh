#!/bin/bash
# Host test for the ESPHome device of the panel (see rootfs/voice/shim/tsx_panel/
# and docs/ha.md "One Home Assistant device"). The test uses both front ends:
#  - tsx-esphome, the standalone server that runs when VOICE=off.
#  - The code path of the voice satellite: the VoiceSatelliteProtocol of
#    linux-voice-assistant with the tsx_lva patches (esphome-lva-harness.py,
#    VOICE=on).
# The fixtures are fake sysfs and state files, and a fake Chromium DevTools
# endpoint. The test runs the real tsx_panel code. A real Home Assistant
# ESPHome client (aioesphomeapi, the version that Home Assistant 2026.9 pins)
# checks the "one HA device" that this feature adds:
#  - the entity list, a light toggle, a text (kiosk URL) set and a front-key
#    press event
#  - plaintext and ESPHome noise encryption (HA_API_KEY): the right key works,
#    and a wrong key or a plaintext client is refused
#  - the same device name in both modes
#  - a key file that the server cannot use (the server refuses to start)
#  - HA_ALLOW_FROM
# The test needs the network only to fetch pinned, public packages. These are
# the packages that rootfs/voice/install-lva.sh fetches for the panel image.
# The test compiles nothing.
#
# tsx_panel reuses linux_voice_assistant.entity.LEDLightEntity (the LED bar
# and key-LED lights). That module imports python-mpv, although this test never
# plays audio. So the test needs a system libmpv, and this is easy to miss.
# See ci/lint.sh and .github/workflows/tests.yml for the apt-get package name.
set -euo pipefail
# The board file (rootfs/overlay/usr/local/lib/tsx/board.sh) for the scripts that read it.
export TSX_BOARD_CONF=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/lib/tsx/board.sh
export TSX_BOARD_BIN=$(cd "$(dirname "$0")/.." && pwd)/overlay/usr/local/bin/tsx-board
HERE=$(cd "$(dirname "$0")" && pwd)
SHIM=$HERE/../voice/shim
T=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT

# ---- pinned linux-voice-assistant source (same as install-lva.sh. We only
# need the linux_voice_assistant/ package tree, not its wake-word/audio deps)
LVA=1.1.15
LVA_SHA256=077696e60b57ae3a98aca3d49d1b9f9971ffd36d62f5c23b8603ccc4c9fcdbd8
CACHE=${TSX_TEST_CACHE:-/tmp/tsx-esphome-test-cache}
mkdir -p "$CACHE"
if [ ! -s "$CACHE/lva-$LVA.tar.gz" ]; then
	curl -fsSL -o "$CACHE/lva-$LVA.tar.gz" "https://github.com/OHF-Voice/linux-voice-assistant/archive/refs/tags/v$LVA.tar.gz"
fi
echo "$LVA_SHA256  $CACHE/lva-$LVA.tar.gz" | sha256sum -c - >/dev/null
tar -C "$T" -xzf "$CACHE/lva-$LVA.tar.gz"
LVA_SRC=$T/linux-voice-assistant-$LVA

# ---- python venv with the (loosely-versioned. This is a host test, not the
# panel image) client + server dependencies -----------------------------
python3 -m venv "$T/venv"
# bleak-esphome is the bleak backend of Home Assistant for an ESPHome proxy
# (the active Bluetooth proxy check). One of its dependencies (PyRIC) has no
# wheel. Its source package is pure Python, so pip builds it without a
# compiler.
"$T/venv/bin/pip" -q install --disable-pip-version-check --only-binary :all: --no-binary pyric \
	"aioesphomeapi==46.2.0" "bleak-esphome==4.1.0" getmac netifaces2 zeroconf "websockets==12.0" python-mpv

# ---- fixtures ------------------------------------------------------------
F=$T/fixture
mkdir -p "$F/run/tsx" "$F/etc/tsx" "$F/sys/thermal" "$F/proc/asound" "$F/bin"
echo "want 50 60 70" > "$F/run/tsx/ledbar.state"
printf 'led 128 unknown\nlast power short\n' > "$F/run/tsx/buttons.state"
echo "on 17" > "$F/run/tsx-idled.state"
# the own status of tsx-autoupdate (the shape of write_ha_json, docs/rootfs.md "Updates")
cat > "$F/run/tsx/update-ha-state.json" <<'EOF'
{"installed_version":"abc123","latest_version":"abc123+1pending","title":"TSX test-panel packages","release_summary":"pkg1 (1.0 -> 1.1)","in_progress":false}
EOF
cat > "$F/etc/kiosk.conf" <<'EOF'
BACKLIGHT_MAX=23
KIOSK_URL="https://ha.example.org/default"
EOF
# tsx-config's override wins. The fake DevTools page shows yet another URL
# (https://ha.example.org/), which the Kiosk URL entity must NOT report
echo 'KIOSK_URL="https://ha.example.org/configured"' > "$F/run/tsx/kiosk.conf"
cat > "$F/etc/tsx/buttons.conf" <<'EOF'
button power  KEY_F13 led=1
button home   KEY_F14 led=2
EOF
printf 'life_a 0x01\nlife_b 0x02\neol 0x01\n' > "$F/run/tsx/emmc.state"
echo 40000 > "$F/sys/thermal/temp"
for b in tsx-ledbar tsx-keypad tsx-blank tsx-config tsx-als tsx-autoupdate; do
	cat > "$F/bin/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "$F/cmds.log"
EOF
	chmod +x "$F/bin/$b"
done

# The base system's tsx-panelctl: the backend sends every command to its FIFO
# and gets the volume from it. It runs the fake tools above.
cat > "$F/bin/reboot" <<EOF
#!/bin/sh
echo "reboot" >> "$F/cmds.log"
EOF
cat > "$F/bin/amixer" <<EOF
#!/bin/sh
echo "amixer \$*" >> "$F/cmds.log"
EOF
cat > "$F/bin/tsx-panelctl" <<EOF
#!/bin/sh
exec sh "$HERE/../overlay/usr/local/sbin/tsx-panelctl" "\$@"
EOF
chmod +x "$F/bin/reboot" "$F/bin/amixer" "$F/bin/tsx-panelctl"
env PATH="$F/bin:$PATH" TSX_RUN_DIR="$F/run/tsx" TSX_REBOOT_BIN="$F/bin/reboot" TSX_IDLED_STATE="$F/run/tsx-idled.state" \
	TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf" TSX_ALS_CONF="$F/etc/tsx/als.conf.missing" TSX_ASOUND_DIR="$F/proc/asound" \
	sh "$HERE/../overlay/usr/local/sbin/tsx-panelctl" > "$T/panelctl.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 30); do grep -q "listening on" "$T/panelctl.log" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on" "$T/panelctl.log" || { echo "FAIL: tsx-panelctl did not start"; cat "$T/panelctl.log"; exit 1; }

DT_HTTP=$((20000 + RANDOM % 5000)); DT_WS=$((DT_HTTP + 1)); API_PORT=$((DT_HTTP + 2))

"$T/venv/bin/python3" "$HERE/esphome-fake-devtools.py" "$DT_HTTP" "$DT_WS" > "$T/devtools.log" 2>&1 &
PIDS="$PIDS $!"

# ESPHome API encryption key for the encrypted runs (HA_API_KEY, generated
# the way the installer does) and a second one that must be refused
KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
BADKEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

# start_server KIND LOG PORT PANEL_NAME [ENV=VALUE...]
# KIND is standalone (tsx-esphome, VOICE=off) or voice (the voice satellite
# code path, esphome-lva-harness.py, VOICE=on). Every instance gets its own
# PANEL_NAME. All instances announce themselves over mDNS on this host, and
# the name is the same in both modes (tsx_panel/naming.py). Two instances
# with one name would collide. The test reads nothing from /run/tsx on this host.
start_server() {
	local kind=$1 log=$2 port=$3 pname=$4; shift 4
	local cmd
	case $kind in
	standalone) cmd=(-m tsx_panel.esphome_server --name "$pname-host" --port "$port" --host 127.0.0.1 ${TSX_TEST_SERVER_ARGS:-});;
	voice) cmd=("$HERE/esphome-lva-harness.py" "$port");;
	esac
	env PATH="$F/bin:$PATH" \
	PYTHONPATH="$SHIM:$LVA_SRC" \
	TSX_RUN_DIR="$F/run/tsx" TSX_IDLED_STATE="$F/run/tsx-idled.state" \
	TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf" TSX_KIOSK_CONF="$F/etc/kiosk.conf" \
	TSX_ALS_CONF="$F/etc/tsx/als.conf.missing" TSX_ASOUND_DIR="$F/proc/asound" \
	TSX_THERMAL_ZONE="$F/sys/thermal/temp" TSX_DEVTOOLS="127.0.0.1:$DT_HTTP" \
	TSX_BOOT_VERBOSE_FLAG="$F/etc/tsx/boot-verbose" \
	TSX_HA_TRANSPORT=esphome \
	TSX_ESPHOME_RUN_CONF="$F/run/tsx/esphome.conf.missing" TSX_ESPHOME_KEY_FILE="$F/run/tsx/esphome.key.missing" \
	TSX_PANEL_NAME="$pname" \
	TSX_ORIENTATION_FILE="$F/etc/tsx/orientation.missing" \
	"$@" \
	"$T/venv/bin/python3" "${cmd[@]}" > "$log" 2>&1 &
	PIDS="$PIDS $!"
	LAST_PID=$!
}
wait_listening() {  # wait_listening LOG...
	local log ok
	for _ in $(seq 1 60); do
		ok=1
		for log in "$@"; do grep -q "listening on" "$log" 2>/dev/null || ok=0; done
		[ $ok = 1 ] && return 0
		sleep 0.25
	done
	for log in "$@"; do grep -q "listening on" "$log" || { echo "FAIL: $log: server did not start"; cat "$log"; exit 1; }; done
}

rc=0
echo "== ESPHome device name rules (tsx_panel/naming.py) =="
PYTHONPATH="$SHIM" TSX_PANEL_NAME_FILE=/nonexistent "$T/venv/bin/python3" -c '
import os
from tsx_panel import naming as n
assert n.esphome_name("TSS-10-ABCDEF", "02:00:00:00:00:01") == "tss-10-abcdef"
assert n.esphome_name("", "02:AA:bb:cc:dd:ee") == "tsx-02aabbccddee"
assert n.esphome_name("--Odd--Name--", "") == "odd-name"
os.environ.pop("TSX_PANEL_NAME", None)
assert n.resolve("02:aa:bb:cc:dd:ee", "TSW-1060-HOST") == ("tsx-02aabbccddee", "TSW-1060-HOST")
os.environ["TSX_PANEL_NAME"] = "TSS-10-ABCDEF"
assert n.resolve("02:aa:bb:cc:dd:ee", "TSW-1060-HOST") == ("tss-10-abcdef", "TSS-10-ABCDEF")
print("OK: PANEL_NAME -> lowercase name + PANEL_NAME friendly name, with the fallback tsx-<mac> and --name")
' || rc=1

# full_check TITLE PORT [esphome-check.py args...]: the whole entity check
# (list, LED bar, kiosk URL, backlight, a front-key event) plus the backend
# side effects it must cause
full_check() {
	local title=$1 port=$2; shift 2
	echo "== $title =="
	: > "$F/cmds.log"; rm -f "$F/run/tsx/brightness" "$F/etc/tsx/boot-verbose"
	echo 120 > "$F/run/tsx/blank-timeout"      # tsx-config apply's file (panel.conf BLANK_TIMEOUT)
	date +%s > "$F/run/tsx/last-input"        # tsx-idled: a touch just now
	printf 'led 128 unknown\nlast power short\n' > "$F/run/tsx/buttons.state"
	# simulate a front-key long-press partway through the client check
	# (which polls for it for up to 10 s)
	( sleep 3; printf 'led 128 unknown\nlast home long\n' > "$F/run/tsx/buttons.state" ) &
	PIDS="$PIDS $!"
	"$T/venv/bin/python3" "$HERE/esphome-check.py" "$port" "$@" || rc=1
	sleep 0.5   # tsx-panelctl runs the commands a moment after the backend sent them
	echo "-- backend commands issued --"
	cat "$F/cmds.log" 2>/dev/null || echo "(none)"
	grep -q '^tsx-ledbar set 100 0 0$' "$F/cmds.log" 2>/dev/null && echo "OK: ledbar command reached the backend" || { echo "FAIL: ledbar command missing/wrong"; rc=1; }
	grep -q '^tsx-config set KIOSK_URL https://ha.example.org/lovelace/0$' "$F/cmds.log" 2>/dev/null && echo "OK: kiosk URL persisted through tsx-config" || { echo "FAIL: tsx-config set KIOSK_URL missing"; rc=1; }
	[ "$(cat "$F/run/tsx/brightness" 2>/dev/null)" = 5 ] && echo "OK: backlight written as an integer (5)" || { echo "FAIL: brightness file is '$(cat "$F/run/tsx/brightness" 2>/dev/null)', want 5"; rc=1; }
	grep -q '^tsx-config set BLANK_TIMEOUT 600$' "$F/cmds.log" 2>/dev/null && grep -q '^tsx-config apply$' "$F/cmds.log" \
		&& echo "OK: blank timeout persisted through tsx-config (set + apply)" || { echo "FAIL: tsx-config set BLANK_TIMEOUT 600 missing"; rc=1; }
	grep -q '^tsx-config set BOOT_VERBOSE 1$' "$F/cmds.log" 2>/dev/null \
		&& echo "OK: verbose boot persisted through tsx-config (set BOOT_VERBOSE 1 + apply)" || { echo "FAIL: tsx-config set BOOT_VERBOSE 1 missing"; rc=1; }
	grep -q '^tsx-autoupdate now$' "$F/cmds.log" 2>/dev/null && echo "OK: update entity Install ran tsx-autoupdate now" || { echo "FAIL: tsx-autoupdate now missing"; rc=1; }
	grep -q '^tsx-config set ORIENTATION portrait$' "$F/cmds.log" 2>/dev/null && ! grep -q 'ORIENTATION sideways' "$F/cmds.log" \
		&& echo "OK: orientation persisted through tsx-config (portrait, and the bad option never reached it)" || { echo "FAIL: tsx-config set ORIENTATION portrait missing"; rc=1; }
}
noise_check() {  # noise_check PORT MODE [KEY]
	"$T/venv/bin/python3" "$HERE/esphome-noise-check.py" "$@" || rc=1
}

# ---- standalone tsx-esphome, plaintext (no HA_API_KEY: zero-config) -------
start_server standalone "$T/server.log" "$API_PORT" Test-Panel TSX_HA_API_KEY=
wait_listening "$T/server.log"
full_check "tsx-esphome, plaintext" "$API_PORT"
grep -q 'Page.navigate' "$T/devtools.log" 2>/dev/null && echo "OK: kiosk URL navigated live via DevTools" || { echo "FAIL: no Page.navigate seen"; rc=1; }
sleep 0.3
grep -q 'connection accepted: 127.0.0.1 (plaintext)' "$T/server.log" && echo "OK: accepted connection logged (plaintext)" || { echo "FAIL: no accepted-connection log line"; rc=1; }
grep -q 'connection closed: 127.0.0.1 (plaintext)' "$T/server.log" && echo "OK: closed connection logged (plaintext)" || { echo "FAIL: no closed-connection log line"; rc=1; }
noise_check "$API_PORT" noise-on-plain "$KEY"

# ---- the same, encrypted (HA_API_KEY. tsx_panel/noise.py) -----------------
ENC_PORT=$((API_PORT + 20))
start_server standalone "$T/server-enc.log" "$ENC_PORT" Enc-Panel TSX_HA_API_KEY="$KEY"
wait_listening "$T/server-enc.log"
full_check "tsx-esphome, noise-encrypted" "$ENC_PORT" --key "$KEY" --name enc-panel --friendly Enc-Panel
sleep 0.3
grep -q 'connection accepted: 127.0.0.1 (encrypted)' "$T/server-enc.log" && echo "OK: accepted connection logged (encrypted)" || { echo "FAIL: no accepted-connection log line"; rc=1; }
grep -q 'connection closed: 127.0.0.1 (encrypted)' "$T/server-enc.log" && echo "OK: closed connection logged (encrypted)" || { echo "FAIL: no closed-connection log line"; rc=1; }
echo "== tsx-esphome, encrypted: refusals =="
noise_check "$ENC_PORT" wrong-key "$BADKEY"
noise_check "$ENC_PORT" plaintext
grep -q 'handshake rejected: Handshake MAC failure' "$T/server-enc.log" && echo "OK: wrong key logged" || { echo "FAIL: wrong key not logged"; rc=1; }

# ---- the voice satellite code path (VOICE=on), encrypted and not ----------
# This is the same entity check, through the VoiceSatelliteProtocol of
# linux-voice-assistant with the tsx_lva patches. It also checks the entities
# of the satellite itself (--voice). The device name must match the name of
# tsx-esphome (not lva-<mac>).
VENC_PORT=$((API_PORT + 30)); VPLAIN_PORT=$((API_PORT + 31))
start_server voice "$T/voice-enc.log" "$VENC_PORT" Voice-Enc TSX_HA_API_KEY="$KEY"
start_server voice "$T/voice-plain.log" "$VPLAIN_PORT" Voice-Plain TSX_HA_API_KEY=
wait_listening "$T/voice-enc.log" "$T/voice-plain.log"
grep -q "tsx_lva: ESPHome API encrypted" "$T/voice-enc.log" && grep -q "tsx_lva: ESPHome API NOT encrypted" "$T/voice-plain.log" \
	&& echo "OK: the voice satellite logs its API mode" || { echo "FAIL: the voice satellite does not log its API mode"; rc=1; }
full_check "voice satellite, noise-encrypted" "$VENC_PORT" --key "$KEY" --name voice-enc --friendly Voice-Enc --voice
grep -q 'Unknown message type' "$T/voice-enc.log" && { echo "FAIL: MediaPlayerEntity logged Unknown message type noise (voice-enc.log)"; rc=1; } \
	|| echo "OK: no Unknown message type noise for panel-entity commands (voice-enc.log)"
echo "== voice satellite, encrypted: refusals and mDNS =="
noise_check "$VENC_PORT" wrong-key "$BADKEY"
noise_check "$VENC_PORT" plaintext
grep -q "('api_encryption', 'Noise_NNpsk0_25519_ChaChaPoly_SHA256')" "$T/voice-enc.log" && echo "OK: mDNS TXT advertises api_encryption" || { echo "FAIL: no api_encryption in the mDNS TXT"; rc=1; }
grep -q "('friendly_name', 'Voice-Enc')" "$T/voice-enc.log" && echo "OK: mDNS TXT carries friendly_name" || { echo "FAIL: no friendly_name in the mDNS TXT"; rc=1; }
full_check "voice satellite, plaintext" "$VPLAIN_PORT" --name voice-plain --friendly Voice-Plain --voice
grep -q "api_encryption" "$T/voice-plain.log" && { echo "FAIL: plaintext satellite advertises api_encryption"; rc=1; } || echo "OK: no api_encryption in the plaintext mDNS TXT"
grep -q 'Unknown message type' "$T/voice-plain.log" && { echo "FAIL: MediaPlayerEntity logged Unknown message type noise (voice-plain.log)"; rc=1; } \
	|| echo "OK: no Unknown message type noise for panel-entity commands (voice-plain.log)"

# ---- the Bluetooth proxy (BT_PROXY, BT_ACTIVE, tsx_panel/bluetooth.py) -----
# A fake controller (bt-fake-hci.py) feeds the real scanner daemon
# (btscan.py). Both front ends take the advertisements from its socket. A
# third server has BT_PROXY off. The other servers above have no bt.conf,
# which also means off. The BLE links of the active proxy go to fake peers
# (bt-gatt-peer.py) instead of L2CAP sockets.
echo "== Bluetooth proxy: feature flags, raw advertisements, the off switch =="
python3 "$HERE/bt-fake-hci.py" "$T/hci.sock" "$T/hci.log" > "$T/fakehci.out" 2>&1 &
PIDS="$PIDS $!"
python3 "$HERE/bt-gatt-peer.py" fake "$T/peer.sock" "$T/peer.log" > "$T/peer.out" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do [ -S "$T/hci.sock" ] && [ -S "$T/peer.sock" ] && break; sleep 0.1; done
printf 'PROXY="on"\nMAC=""\n' > "$F/run/tsx/bt-on.conf"
printf 'PROXY="off"\nMAC=""\n' > "$F/run/tsx/bt-off.conf"
printf 'PROXY="on"\nACTIVE="on"\nMAC=""\n' > "$F/run/tsx/bt-active.conf"
start_btscan() {
	TSX_BTSCAN_FAKE_HCI="$T/hci.sock" TSX_BTSCAN_FAKE_L2CAP="$T/peer.sock" TSX_BT_CONF="$F/run/tsx/bt-active.conf" \
		TSX_BT_CONNECT_TIMEOUT=2 python3 "$HERE/../overlay/usr/local/lib/tsx/btscan.py" \
		--socket "$F/run/tsx/bt-adv.sock" --group "" >> "$T/btscan.log" 2>&1 &
	BTSCAN_PID=$!
	PIDS="$PIDS $!"
}
start_btscan
echo 02:AA:BB:CC:DD:EE > "$F/run/tsx/bt.mac"
BT_PORT=$((API_PORT + 50)); VBT_PORT=$((API_PORT + 51)); NOBT_PORT=$((API_PORT + 52))
start_server standalone "$T/server-bt.log" "$BT_PORT" Bt-Panel TSX_HA_API_KEY= TSX_BT_CONF="$F/run/tsx/bt-on.conf"
start_server voice "$T/voice-bt.log" "$VBT_PORT" Bt-Voice TSX_HA_API_KEY="$KEY" TSX_BT_CONF="$F/run/tsx/bt-on.conf"
TSX_TEST_SERVER_ARGS=--no-zeroconf start_server standalone "$T/server-nobt.log" "$NOBT_PORT" NoBt-Panel TSX_HA_API_KEY= TSX_BT_CONF="$F/run/tsx/bt-off.conf"
wait_listening "$T/server-bt.log" "$T/voice-bt.log" "$T/server-nobt.log"
grep -q 'no mDNS announcement (--no-zeroconf)' "$T/server-nobt.log" && ! grep -q 'no mDNS announcement' "$T/server-bt.log" \
	&& echo "OK: --no-zeroconf: a test instance serves without an mDNS announcement" || { echo "FAIL: --no-zeroconf"; rc=1; }
"$T/venv/bin/python3" "$HERE/esphome-bt-check.py" "$BT_PORT" on || rc=1
"$T/venv/bin/python3" "$HERE/esphome-bt-check.py" "$VBT_PORT" on --key "$KEY" || rc=1
grep -q 'tsx_lva: Bluetooth proxy on' "$T/voice-bt.log" && echo "OK: the voice satellite logs the proxy state" || { echo "FAIL: no proxy state line in voice-bt.log"; rc=1; }
grep -q 'Unknown message type' "$T/voice-bt.log" && { echo "FAIL: Bluetooth messages reached satellite.py (voice-bt.log)"; rc=1; } \
	|| echo "OK: the Bluetooth messages never reach satellite.py"
"$T/venv/bin/python3" "$HERE/esphome-bt-check.py" "$NOBT_PORT" off || rc=1
sleep 1
python3 - "$T/hci.log" <<'PYEOF' && echo "OK: the scanner ran only while a front end was subscribed (enable/disable pairs, off at the end)" || { echo "FAIL: scan enable/disable"; cat "$T/hci.log"; rc=1; }
import sys
en = [l.split()[2] for l in open(sys.argv[1]) if l.startswith("cmd 200c")]
on = [e for e in en if e == "0100"]
assert len(on) == 2, en        # two subscribed checks, none for the off one
assert en[-1] == "0000", en
PYEOF

# The active proxy (BT_ACTIVE=on): the bleak backend of Home Assistant
# (bleak-esphome ESPHomeClient) connects to a fake peer through each front
# end. C0:FF:EE:00:00:EE never answers (a connect timeout).
echo "== Bluetooth proxy: active connections (GATT) =="
ACT_PORT=$((API_PORT + 53)); VACT_PORT=$((API_PORT + 54))
TSX_TEST_SERVER_ARGS=--no-zeroconf start_server standalone "$T/server-act.log" "$ACT_PORT" Act-Panel TSX_HA_API_KEY= TSX_BT_CONF="$F/run/tsx/bt-active.conf"
start_server voice "$T/voice-act.log" "$VACT_PORT" Act-Voice TSX_HA_API_KEY="$KEY" TSX_BT_CONF="$F/run/tsx/bt-active.conf"
wait_listening "$T/server-act.log" "$T/voice-act.log"
"$T/venv/bin/python3" "$HERE/esphome-btactive-check.py" 127.0.0.1 "$ACT_PORT" --addr C0:FF:EE:00:00:01 --atype 1 \
	--silent C0:FF:EE:00:00:EE --cycles 5 --adv || { rc=1; tail -20 "$T/btscan.log"; }
"$T/venv/bin/python3" "$HERE/esphome-btactive-check.py" 127.0.0.1 "$VACT_PORT" --key "$KEY" --addr C0:FF:EE:00:00:02 \
	--cycles 2 || { rc=1; tail -20 "$T/btscan.log"; }
grep -q '^cmd 200b 01a000a0' "$T/hci.log" && echo "OK: the active scan mode of Home Assistant reached the controller (scan type 1)" \
	|| { echo "FAIL: no active scan parameters in hci.log"; rc=1; }
grep -q 'tsx_lva: Bluetooth proxy on, active connections' "$T/voice-act.log" && echo "OK: the voice satellite logs the active proxy" \
	|| { echo "FAIL: no active proxy line in voice-act.log"; rc=1; }
grep -q 'Unknown message type' "$T/voice-act.log" && { echo "FAIL: Bluetooth messages reached satellite.py (voice-act.log)"; rc=1; } \
	|| echo "OK: the GATT messages never reach satellite.py"
# tsx-bt restarts (tsx-btscan goes away and comes back): Home Assistant sees
# no free slot while it is away, and 3 free slots again after
"$T/venv/bin/python3" - "$ACT_PORT" > "$T/slots.out" 2>&1 <<'PYEOF' &
import asyncio, sys
from aioesphomeapi import APIClient
async def main():
    cli = APIClient("127.0.0.1", int(sys.argv[1]), None)
    await cli.connect(login=False)
    seen = []
    cli.subscribe_bluetooth_connections_free(lambda free, limit, alloc: seen.append((free, limit)))
    for _ in range(80):
        await asyncio.sleep(0.1)
        if (0, 0) in seen and seen[-1] == (3, 3):
            break
    print(seen)
    await cli.disconnect()
    assert seen[0] == (3, 3) and (0, 0) in seen and seen[-1] == (3, 3), seen
asyncio.run(main())
PYEOF
SLOTS_PID=$!
sleep 1.5
kill "$BTSCAN_PID"; wait "$BTSCAN_PID" 2>/dev/null
sleep 0.5
start_btscan
wait "$SLOTS_PID" && echo "OK: a restart of tsx-btscan: 0 slots while it is away, 3 again after ($(cat "$T/slots.out"))" \
	|| { echo "FAIL: slots across a tsx-btscan restart: $(cat "$T/slots.out")"; rc=1; }

# ---- a panel without a microphone or a Bluetooth module (hw.conf of tsx-hw,
# government=1): bt.conf says on, but the device offers no Bluetooth proxy
# and no voice features. The voice satellite does not start. The entity
# list is the same as on a panel with all parts (no entity goes away).
echo "== government=1 (hw.conf): no Bluetooth proxy, no voice features, the same entities =="
printf 'GOVERNMENT=1\nMIC=no\nBT=no\nCAMERA=no\nREASON=government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module\n' > "$F/run/tsx/hw-gov.conf"
GOV_PORT=$((API_PORT + 55))
TSX_TEST_SERVER_ARGS=--no-zeroconf start_server standalone "$T/server-gov.log" "$GOV_PORT" Gov-Panel TSX_HA_API_KEY= \
	TSX_BT_CONF="$F/run/tsx/bt-active.conf" TSX_HW_CONF="$F/run/tsx/hw-gov.conf"
start_server voice "$T/voice-gov.log" $((API_PORT + 56)) Gov-Voice TSX_HA_API_KEY= TSX_HW_CONF="$F/run/tsx/hw-gov.conf"
GOVV_PID=$LAST_PID
wait_listening "$T/server-gov.log"
"$T/venv/bin/python3" "$HERE/esphome-bt-check.py" "$GOV_PORT" off || rc=1
grep -q 'Bluetooth proxy: off' "$T/server-gov.log" && echo "OK: tsx-esphome logs the proxy as off (no Bluetooth module)" \
	|| { echo "FAIL: no 'Bluetooth proxy: off' in server-gov.log"; rc=1; }
"$T/venv/bin/python3" - "$GOV_PORT" "$BT_PORT" <<'PYEOF' || rc=1
import asyncio, sys
from aioesphomeapi import APIClient
async def info(port):
    cli = APIClient("127.0.0.1", int(port), None)
    await cli.connect(login=False)
    try:
        dev = await cli.device_info()
        ents, _ = await cli.list_entities_services()
        return dev.voice_assistant_feature_flags_compat(cli.api_version), sorted(e.object_id for e in ents)
    finally:
        await cli.disconnect()
async def main():
    gflags, gents = await info(sys.argv[1])
    _, nents = await info(sys.argv[2])
    assert gflags == 0, gflags
    assert gents == nents, (gents, nents)
    print(f"OK: government=1: no voice assistant features, the same {len(gents)} entities as on a panel with all parts")
asyncio.run(main())
PYEOF
st=0; wait "$GOVV_PID" || st=$?
[ "$st" != 0 ] && grep -q 'no microphone on this panel (government=1 (TSW-760-NC)' "$T/voice-gov.log" \
	&& echo "OK: the voice satellite does not start without a microphone ($st)" || { echo "FAIL: the voice satellite started without a microphone"; cat "$T/voice-gov.log"; rc=1; }

# ---- a panel without front keys, LED bar and eMMC health: those entities are not announced
BARE_PORT=$((API_PORT + 60))
mkdir -p "$F/bare/run"
cp -r "$F/run/tsx/." "$F/bare/run/"
rm -f "$F/bare/run/emmc.state"
date +%s > "$F/bare/run/last-input"
start_server standalone "$T/server-bare.log" "$BARE_PORT" Bare-Panel TSX_HA_API_KEY= \
	TSX_RUN_DIR="$F/bare/run" TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf.missing" TSX_LEDBAR=tsx-ledbar-not-installed
wait_listening "$T/server-bare.log"
echo "== tsx-esphome, no front keys, no LED bar, no eMMC health =="
"$T/venv/bin/python3" "$HERE/esphome-check.py" "$BARE_PORT" --name bare-panel --friendly Bare-Panel --bare || rc=1

# ---- a configured key that cannot be used: refuse to start, never plaintext
echo "== unusable key file: fail closed =="
echo "not-a-key" > "$F/run/tsx/esphome.key.bad"
start_server standalone "$T/server-badkey.log" $((API_PORT + 40)) Bad-Key TSX_ESPHOME_KEY_FILE="$F/run/tsx/esphome.key.bad"
BADKEY_PID=$LAST_PID
start_server voice "$T/voice-badkey.log" $((API_PORT + 41)) Bad-Key-Voice TSX_ESPHOME_KEY_FILE="$F/run/tsx/esphome.key.bad"
VBADKEY_PID=$LAST_PID
st=0; wait "$BADKEY_PID" || st=$?
[ "$st" != 0 ] && grep -q 'not serving the ESPHome API unencrypted' "$T/server-badkey.log" && echo "OK: tsx-esphome exits ($st) on a bad key file" || { echo "FAIL: tsx-esphome did not refuse a bad key file"; cat "$T/server-badkey.log"; rc=1; }
st=0; wait "$VBADKEY_PID" || st=$?
[ "$st" != 0 ] && grep -q 'not serving the ESPHome API unencrypted' "$T/voice-badkey.log" && echo "OK: the voice satellite exits ($st) on a bad key file" || { echo "FAIL: the voice satellite did not refuse a bad key file"; cat "$T/voice-badkey.log"; rc=1; }

# ---- HA_ALLOW_FROM: an allowed peer connects, a denied one is closed ------
# (rootfs/voice/shim/tsx_panel/security.py. Defence in depth on top of
# HA_API_KEY, or the only access control without one)
echo "== HA_ALLOW_FROM =="
ALLOW_PORT=$((API_PORT + 10)); DENY_PORT=$((API_PORT + 11))
start_server standalone "$T/server-allow.log" "$ALLOW_PORT" Allow-Test TSX_HA_API_KEY= TSX_HA_ALLOW_FROM="127.0.0.1/32,10.0.0.0/8"
start_server standalone "$T/server-deny.log" "$DENY_PORT" Deny-Test TSX_HA_API_KEY= TSX_HA_ALLOW_FROM="10.0.0.99"
wait_listening "$T/server-allow.log" "$T/server-deny.log"

"$T/venv/bin/python3" "$HERE/esphome-allowlist-check.py" "$ALLOW_PORT" allow || rc=1
"$T/venv/bin/python3" "$HERE/esphome-allowlist-check.py" "$DENY_PORT" deny || rc=1
grep -q 'closing connection from 127.0.0.1' "$T/server-deny.log" 2>/dev/null && echo "OK: denial was logged" || { echo "FAIL: no denial logged"; rc=1; }

[ "$rc" = 0 ] && echo "PASS test-esphome" || echo "FAIL test-esphome"
exit "$rc"
