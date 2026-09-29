#!/bin/bash
# Host test for the panel's ESPHome device (see rootfs/voice/shim/tsx_panel/
# and PLAN.md section 18), through both front ends: tsx-esphome (the
# standalone server used when VOICE=off) and the voice satellite's code path
# (linux-voice-assistant's own VoiceSatelliteProtocol with the tsx_lva
# patches, esphome-lva-harness.py, VOICE=on). Fake sysfs/state-file fixtures
# + a fake Chromium DevTools endpoint, the real tsx_panel code, and a real
# Home Assistant ESPHome client (aioesphomeapi, the version Home Assistant
# 2026.9 pins) checking the entity list, a light toggle, a text (kiosk URL)
# set and a front-key press event -- exactly the "one HA device" this
# feature adds -- plaintext and with ESPHome's noise encryption (HA_API_KEY:
# right key works, wrong key and plaintext clients are refused), the same
# device name in both modes, a key file that cannot be used (refuse to
# start), and HA_ALLOW_FROM. Only needs network to fetch pinned, public
# packages (same ones rootfs/voice/install-lva.sh fetches for the panel
# image); nothing here compiles anything.
#
# tsx_panel reuses linux_voice_assistant.entity.LEDLightEntity (the LED bar
# and key-LED lights), which imports python-mpv even though this test never
# plays audio -- so a system libmpv is a real, if easy to miss, dependency;
# see ci/lint.sh / .github/workflows/tests.yml for the apt-get package name.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SHIM=$HERE/../voice/shim
T=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT

# ---- pinned linux-voice-assistant source (same as install-lva.sh; we only
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

# ---- python venv with the (loosely-versioned; this is a host test, not the
# panel image) client + server dependencies -----------------------------
python3 -m venv "$T/venv"
"$T/venv/bin/pip" -q install --disable-pip-version-check --only-binary :all: \
	"aioesphomeapi==46.2.0" getmac netifaces2 zeroconf "websockets==12.0" python-mpv

# ---- fixtures ------------------------------------------------------------
F=$T/fixture
mkdir -p "$F/run/tsx" "$F/etc/tsx" "$F/sys/thermal" "$F/proc/asound" "$F/bin"
echo "want 50 60 70" > "$F/run/tsx/ledbar.state"
printf 'led 128 unknown\nlast power short\n' > "$F/run/tsx/buttons.state"
echo "on 17" > "$F/run/tsx-idled.state"
# tsx-autoupdate's own status (write_ha_json's shape; PLAN.md section 21)
cat > "$F/run/tsx/update-ha-state.json" <<'EOF'
{"installed_version":"abc123","latest_version":"abc123+1pending","title":"TSX test-panel packages","release_summary":"pkg1 (1.0 -> 1.1)","in_progress":false}
EOF
cat > "$F/etc/kiosk.conf" <<'EOF'
BACKLIGHT_MAX=23
KIOSK_URL="https://ha.example.org/default"
EOF
# tsx-config's override wins; the fake DevTools page shows yet another URL
# (https://ha.example.org/), which the Kiosk URL entity must NOT report
echo 'KIOSK_URL="https://ha.example.org/configured"' > "$F/run/tsx/kiosk.conf"
cat > "$F/etc/tsx/buttons.conf" <<'EOF'
button power  KEY_F13 led=1
button home   KEY_F14 led=2
EOF
echo 40000 > "$F/sys/thermal/temp"
for b in tsx-ledbar tsx-keypad tsx-blank tsx-config tsx-als tsx-autoupdate; do
	cat > "$F/bin/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "$F/cmds.log"
EOF
	chmod +x "$F/bin/$b"
done

DT_HTTP=$((20000 + RANDOM % 5000)); DT_WS=$((DT_HTTP + 1)); API_PORT=$((DT_HTTP + 2))

"$T/venv/bin/python3" "$HERE/esphome-fake-devtools.py" "$DT_HTTP" "$DT_WS" > "$T/devtools.log" 2>&1 &
PIDS="$PIDS $!"

# ESPHome API encryption key for the encrypted runs (HA_API_KEY, generated
# the way the installer does) and a second one that must be refused
KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
BADKEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

# start_server KIND LOG PORT PANEL_NAME [ENV=VALUE...]: KIND is standalone
# (tsx-esphome, VOICE=off) or voice (the voice satellite's code path,
# esphome-lva-harness.py, VOICE=on). Every instance gets its own
# PANEL_NAME: they all announce themselves over mDNS on this host, and the
# name is now the same in both modes (tsx_panel/naming.py), so two with
# one name would collide. Nothing is read from this host's /run/tsx.
start_server() {
	local kind=$1 log=$2 port=$3 pname=$4; shift 4
	local cmd
	case $kind in
	standalone) cmd=(-m tsx_panel.esphome_server --name "$pname-host" --port "$port" --host 127.0.0.1);;
	voice) cmd=("$HERE/esphome-lva-harness.py" "$port");;
	esac
	env PATH="$F/bin:$PATH" \
	PYTHONPATH="$SHIM:$LVA_SRC" \
	TSX_RUN_DIR="$F/run/tsx" TSX_IDLED_STATE="$F/run/tsx-idled.state" \
	TSX_BUTTONS_CONF="$F/etc/tsx/buttons.conf" TSX_KIOSK_CONF="$F/etc/kiosk.conf" \
	TSX_ALS_CONF="$F/etc/tsx/als.conf.missing" TSX_ASOUND_DIR="$F/proc/asound" \
	TSX_THERMAL_ZONE="$F/sys/thermal/temp" TSX_DEVTOOLS="127.0.0.1:$DT_HTTP" \
	TSX_BOOT_VERBOSE_FLAG="$F/etc/tsx/boot-verbose" \
	TSX_PANEL_DIRECT=1 TSX_HA_TRANSPORT=esphome \
	TSX_ESPHOME_RUN_CONF="$F/run/tsx/esphome.conf.missing" TSX_ESPHOME_KEY_FILE="$F/run/tsx/esphome.key.missing" \
	TSX_PANEL_NAME="$pname" \
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
print("OK: PANEL_NAME -> lowercase name + PANEL_NAME friendly name; fallback tsx-<mac> + --name")
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

# ---- the same, encrypted (HA_API_KEY; tsx_panel/noise.py) -----------------
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

# ---- the voice satellite's code path (VOICE=on), encrypted and not --------
# Same entity check through linux-voice-assistant's own VoiceSatelliteProtocol
# with the tsx_lva patches, plus the satellite's own entities (--voice); the
# device name must come out the same as tsx-esphome's (not lva-<mac>).
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
# (rootfs/voice/shim/tsx_panel/security.py; defence in depth on top of
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
