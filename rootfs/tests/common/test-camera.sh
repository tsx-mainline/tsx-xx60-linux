#!/bin/bash
# Host test: the camera of the xx60. The camera is a set of three plugins in
# the overlay of this repository. The shared software of tsx-linux-common
# loads them from its plugin folders:
#   config.d/camera.sh   the key CAMERA of tsx-config (set, validate, show, apply)
#   setup.d/camera.py    the camera field of the setup page
#   esphome.d/camera.py  the camera entities and the image requests of Home
#                        Assistant, in tsx-esphome (VOICE=off) and in the voice
#                        satellite (VOICE=on)
# The test runs the real plugins of this repository against the tree of
# tsx-linux-common (TSX_COMMON). The plugin folders are copies with fixed
# modes. TSX_PLUGIN_OWNER_UID is the user id of the test. The ESPHome part uses
# small stand-ins for aioesphomeapi, protobuf and linux_voice_assistant, and a
# fake frame source (TSX_CAMERA_FAKE), so it needs no network and no camera.
# The JPEG part needs numpy and libturbojpeg on the host (TSX_TURBOJPEG names
# the library). Without them the test checks that the camera stays off and says
# why, and it prints "skip".
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
. "$(dirname "$0")/lib.sh"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED common/test-camera: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED common/test-camera: no python3 on this host"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
ME=$(id -u)
# run_py ARGS: run the Python script on the standard input, show its lines and count the "ok:" and "FAIL:" lines
run_py() {
	local rc f
	python3 - "$@" > "$T/py.out" 2>&1; rc=$?
	cat "$T/py.out"
	N=$((N + $(grep -c '^  ok:' "$T/py.out")))
	f=$(grep -c '^  FAIL:' "$T/py.out"); F=$((F + f))
	if [ $rc != 0 ] && [ "$f" = 0 ]; then bad "the Python script stopped with exit code $rc"; fi
}

# the plugin folders: copies with fixed modes, so that a checkout with another umask does not matter
PD=$T/plugins
mkdir -p "$PD/esphome.d" "$PD/config.d" "$PD/setup.d" "$PD/empty"
cp "$XX60_ESPHOME_D/camera.py" "$PD/esphome.d/"
cp "$XX60_CONFIG_D/camera.sh" "$PD/config.d/"
cp "$XX60_SETUP_D/camera.py" "$PD/setup.d/"
cp "$COMMON/ha/usr/local/share/tsx/setup.d/ha.py" "$PD/setup.d/"
chmod 755 "$PD" "$PD"/*; chmod 644 "$PD"/*/*.py "$PD"/*/*.sh

# ---- tsx-config: the key CAMERA ------------------------------------------------------------------
SCRIPT="$COMMON/base/usr/local/sbin/tsx-config"
W=$T/cfg; mkdir -p "$W/bin" "$W/proc"
CFG="$W/panel.conf"; FX="$W/fixture"; FX3="$W/fx-hw"; CFG3="$W/panel-hw.conf"
mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk" "$FX3/run/tsx" "$FX3/etc"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
printf '#!/bin/sh\necho "rc-service $*" >> "%s/rc.log"\nexit 0\n' "$W" > "$W/bin/rc-service"
printf '#!/bin/sh\necho "tsx-audio $*" >> "%s/audio.log"\nexit 0\n' "$W" > "$W/bin/tsx-audio"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"
chmod +x "$W/bin/rc-service" "$W/bin/tsx-audio" "$W/bin/logger"
export TSX_PLUGIN_OWNER_UID=$ME
cfg() { TSX_CONFIG_PLUGIN_DIR="$PD/config.d" TSX_CONF="$CFG" busybox sh "$SCRIPT" "$@"; }
apply_() { env TSX_CONFIG_PLUGIN_DIR="$PD/config.d" TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 PATH="$W/bin:$PATH" busybox sh "$SCRIPT" apply; }
applyp() { apply_ >/dev/null 2>&1; }
restarts() { grep -c 'tsx-esphome restart' "$W/rc.log" 2>/dev/null || true; }
vrestarts() { grep -c 'tsx-voice restart' "$W/rc.log" 2>/dev/null || true; }

echo "== config.d/camera.sh: the plugin loads and CAMERA is a key of tsx-config =="
busybox sh -n "$PD/config.d/camera.sh" && ok "busybox sh -n" || bad "busybox sh -n"
out=$(cfg show 2>&1 >/dev/null)
case "$out" in *plugin*) bad "tsx-config logged about the plugin: $out";; *) ok "tsx-config loads the plugin with no log line about it";; esac
for v in off snapshot live on; do cfg validate CAMERA "$v" && ok "CAMERA=$v valid" || bad "CAMERA=$v rejected"; done
for v in yes "" 1 Snapshot stream; do cfg validate CAMERA "$v" && bad "CAMERA='$v' accepted" || ok "CAMERA='$v' rejected"; done
cfg set CAMERA snapshot >/dev/null 2>&1 && [ "$(cfg get CAMERA)" = snapshot ] && ok "set and get CAMERA" || bad "set and get CAMERA"
cfg show 2>/dev/null | grep -qx 'CAMERA=snapshot' && ok "show lists CAMERA" || bad "show lacks CAMERA"
cfg unset CAMERA >/dev/null 2>&1; cfg get CAMERA >/dev/null 2>&1 && bad "CAMERA is still set after unset" || ok "unset CAMERA"

echo "== apply: /run/tsx/camera.conf, the ESPHome front ends follow the key =="
cfg set PANEL_NAME TSS-10-ABCDEF >/dev/null
cfg set KIOSK_URL "https://ha.example.org/lovelace/default_view" >/dev/null
applyp; applyp
grep -qx 'CAMERA="off"' "$FX/run/tsx/camera.conf" 2>/dev/null && ok "camera.conf: CAMERA off by default" || bad "camera.conf default: $(cat "$FX/run/tsx/camera.conf" 2>/dev/null)"
[ "$(stat -c '%a' "$FX/run/tsx/camera.conf" 2>/dev/null)" = 644 ] && ok "camera.conf is world-readable (the voice satellite reads it)" || bad "camera.conf mode $(stat -c '%a' "$FX/run/tsx/camera.conf" 2>/dev/null)"
r0=$(restarts); v0=$(vrestarts)
applyp; [ "$(restarts)/$(vrestarts)" = "$r0/$v0" ] && ok "an unchanged apply restarts nothing" || bad "unchanged apply: $(restarts)/$(vrestarts) restarts (was $r0/$v0)"
cfg set CAMERA on >/dev/null; applyp
grep -qx 'CAMERA="live"' "$FX/run/tsx/camera.conf" && ok "CAMERA=on (the old name of live) reaches camera.conf as live" || bad "camera.conf after CAMERA=on: $(cat "$FX/run/tsx/camera.conf")"
[ "$(restarts)/$(vrestarts)" = "$((r0 + 1))/$((v0 + 1))" ] && ok "CAMERA=on restarts tsx-esphome and tsx-voice (new entity list)" || bad "CAMERA=on: $(restarts)/$(vrestarts) restarts (was $r0/$v0)"
applyp; [ "$(restarts)/$(vrestarts)" = "$((r0 + 1))/$((v0 + 1))" ] && ok "an unchanged CAMERA restarts nothing" || bad "unchanged CAMERA: $(restarts)/$(vrestarts) restarts"
cfg set CAMERA off >/dev/null; applyp
grep -qx 'CAMERA="off"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 2))/$((v0 + 2))" ] \
	&& ok "CAMERA=off: camera.conf off, both front ends restart" || bad "CAMERA=off: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
cfg set CAMERA snapshot >/dev/null; applyp
grep -qx 'CAMERA="snapshot"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 3))/$((v0 + 3))" ] \
	&& ok "CAMERA=snapshot reaches camera.conf, both front ends restart" || bad "CAMERA=snapshot: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
cfg set CAMERA live >/dev/null; applyp
grep -qx 'CAMERA="live"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 4))/$((v0 + 4))" ] \
	&& ok "CAMERA=live reaches camera.conf, both front ends restart" || bad "CAMERA=live: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
cfg set CAMERA on >/dev/null; applyp
grep -qx 'CAMERA="live"' "$FX/run/tsx/camera.conf" && [ "$(restarts)/$(vrestarts)" = "$((r0 + 4))/$((v0 + 4))" ] \
	&& ok "CAMERA=on is the old name of live: camera.conf live, no restart" || bad "CAMERA=on after live: $(cat "$FX/run/tsx/camera.conf"), $(restarts)/$(vrestarts) restarts"
printf 'CAMERA="bogus"\n' >> "$CFG"; applyp
grep -qx 'CAMERA="off"' "$FX/run/tsx/camera.conf" && ok "an unknown CAMERA value in panel.conf is off" || bad "CAMERA=bogus: $(cat "$FX/run/tsx/camera.conf")"
cfg set CAMERA off >/dev/null; applyp

echo "== a panel without the plugin: CAMERA is an unknown key =="
out=$(TSX_CONFIG_PLUGIN_DIR="$PD/empty" TSX_CONF="$CFG" busybox sh "$SCRIPT" set CAMERA live 2>&1); rc=$?
[ $rc != 0 ] && case "$out" in *"unknown key: CAMERA"*) true;; *) false;; esac && ok "set CAMERA is refused" || bad "set CAMERA without the plugin: exit $rc, '$out'"
cfg set CAMERA live >/dev/null; rm -f "$FX/run/tsx/camera.conf"
out=$(env TSX_CONFIG_PLUGIN_DIR="$PD/empty" TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 PATH="$W/bin:$PATH" busybox sh "$SCRIPT" apply 2>&1)
[ "$(printf '%s\n' "$out" | grep -c 'has the key CAMERA')" = 1 ] && [ ! -e "$FX/run/tsx/camera.conf" ] \
	&& ok "apply logs one warning for CAMERA in panel.conf, ignores it and writes no camera.conf" || bad "apply without the plugin: '$out', camera.conf $(cat "$FX/run/tsx/camera.conf" 2>/dev/null)"
cfg set CAMERA off >/dev/null

echo "== a panel without a camera (hw.conf of the real tsx-hw of the xx60) =="
printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"
hw_detect() {  # hw_detect CMDLINE: write hw.conf with the real tsx-hw
	echo "$1" > "$W/proc/cmdline"
	env PATH="$W/bin:$PATH" TSX_RUN_DIR="$FX3/run/tsx" TSX_PROC="$W/proc" busybox sh "$XX60_HW" detect >/dev/null
}
cfg3() { env PATH="$W/bin:$PATH" TSX_CONFIG_PLUGIN_DIR="$PD/config.d" TSX_CONF="$CFG3" TSX_RUN="$FX3/run" TSX_STATE_DIR="$FX3/var/lib/tsx" TSX_APPLY_PREFIX="$FX3" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$SCRIPT" "$@"; }
REASON='government=1 (TSW-760-NC): no microphone, no camera, no Bluetooth module'
hw_detect "console=tty0 androidboot.government=1"
grep -qx "REASON=$REASON" "$FX3/run/tsx/hw.conf" && grep -qx 'CAMERA=no' "$FX3/run/tsx/hw.conf" \
	&& ok "tsx-hw of the xx60: hw.conf says CAMERA=no with the REASON text" || bad "hw.conf: $(cat "$FX3/run/tsx/hw.conf")"
out=$(cfg3 set CAMERA live 2>&1); rc=$?
[ $rc = 0 ] && [ "$(cfg3 get CAMERA)" = live ] && [ "$out" = "tsx-config: WARNING: CAMERA=live is saved, but this panel has no camera ($REASON). apply leaves it out" ] \
	&& ok "set CAMERA live: saved (a panel.conf from another panel loads), with a warning that has the REASON text" || bad "set CAMERA live: exit $rc, '$out'"
out=$(cfg3 set CAMERA snapshot 2>&1)
case "$out" in *"WARNING: CAMERA=snapshot is saved, but this panel has no camera ($REASON)"*) ok "set CAMERA snapshot: saved, with a warning";; *) bad "set CAMERA snapshot on a panel without a camera: '$out'";; esac
out=$(cfg3 set CAMERA off 2>&1); [ -z "$out" ] && ok "set CAMERA off: no warning" || bad "set CAMERA off warns: $out"
cfg3 set CAMERA on >/dev/null 2>&1
out=$(cfg3 show 2>&1 >/dev/null)
case "$out" in *"# WARNING: CAMERA=on is set, but this panel has no camera ($REASON)"*) ok "show: a warning for CAMERA";; *) bad "show warnings: $out";; esac
out=$(cfg3 apply 2>&1); rc=$?
grep -qx 'CAMERA="off"' "$FX3/run/tsx/camera.conf" && case "$out" in *"WARNING: CAMERA=on is set, but this panel has no camera"*) true;; *) false;; esac \
	&& ok "apply: CAMERA=on is treated as off, with a warning" || bad "apply camera: exit $rc, $(cat "$FX3/run/tsx/camera.conf" 2>/dev/null), '$out'"
printf 'CAMERA=no\n' > "$FX3/run/tsx/hw.conf"
out=$(cfg3 set CAMERA live 2>&1)
[ "$out" = "tsx-config: WARNING: CAMERA=live is saved, but this panel has no camera. apply leaves it out" ] \
	&& ok "no REASON in hw.conf: the warning has the short text, with no empty brackets" || bad "no REASON: '$out'"
hw_detect "console=tty0 androidboot.government=0"
out=$(cfg3 set CAMERA live 2>&1); [ -z "$out" ] && ok "government=0: set CAMERA live gives no warning" || bad "government=0 set CAMERA warns: $out"
cfg3 apply >/dev/null 2>&1
grep -qx 'CAMERA="live"' "$FX3/run/tsx/camera.conf" && ok "government=0: CAMERA=live reaches camera.conf" || bad "government=0: camera $(cat "$FX3/run/tsx/camera.conf" 2>/dev/null)"
rm -f "$FX3/run/tsx/hw.conf"; cfg3 set CAMERA snapshot >/dev/null 2>&1; cfg3 apply >/dev/null 2>&1
grep -qx 'CAMERA="snapshot"' "$FX3/run/tsx/camera.conf" && ok "no hw.conf: a panel with all parts, CAMERA=snapshot works" || bad "no hw.conf: camera $(cat "$FX3/run/tsx/camera.conf" 2>/dev/null)"
hw_detect "console=tty0 androidboot.government=0"; cp "$FX3/run/tsx/hw.conf" "$T/hw-all.conf"
hw_detect "console=tty0 androidboot.government=1"; cp "$FX3/run/tsx/hw.conf" "$T/hw-nc.conf"

# ---- the setup page ------------------------------------------------------------------------------
echo "== setup.d/camera.py: the camera field of the setup page =="
printf '#!/bin/sh\nexec busybox sh "%s" "$@"\n' "$SCRIPT" > "$T/tsx-config"; chmod +x "$T/tsx-config"
mkdir -p "$T/run"
run_py "$COMMON/setup/usr/local/sbin/tsx-setupd" "$T" "$PD/setup.d/camera.py" <<'PY'
import importlib.machinery, json, os, subprocess, sys
setupd, t, plugin = sys.argv[1:4]
os.environ.update(TSX_SETUP_CONF=t + "/none.conf", TSX_RUN_DIR=t + "/run", TSX_HW_CONF=t + "/run/hw.conf",
                  TSX_SETUP_NO_ZEROCONF="1", TSX_SETUP_PLUGIN_DIR=t + "/plugins/setup.d", TSX_CONFIG_BIN=t + "/tsx-config",
                  TSX_CONFIG_PLUGIN_DIR=t + "/plugins/config.d")
d = importlib.machinery.SourceFileLoader("setupd", setupd).load_module()

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("  ok:", name)
    else:
        print("  FAIL:", name, "got", repr(got), "want", repr(want)); fails += 1

def hw(text):
    with open(t + "/run/hw.conf", "w") as fobj:
        fobj.write(text)

check("the plugin loads before the plugin of tsx-ha", [p.NAME for p in d.PLUGINS], ["camera", "ha"])
check("CAMERA is a key of the page, with the state", ("CAMERA" in d.SIMPLE_KEYS, "CAMERA" in d.STATE_KEYS), (True, True))
check("a panel without a camera drops CAMERA from a save", d.UNAVAILABLE_DROPS.get("CAMERA"), ("CAMERA",))
check("... and the drops of tsx-ha stay", (d.UNAVAILABLE_DROPS.get("VOICE"), d.UNAVAILABLE_DROPS.get("BT_PROXY")),
      (("VOICE", "WAKE_WORD"), ("BT_PROXY",)))
page = d.PAGE
want = ['id="camera-wrap"', 'id="f-camera" name="CAMERA"', '<option value="off">', '<option value="snapshot">', '<option value="live">',
        'id="camera-hint"', 'id="camera-summary"', 'id="f-btproxy"', 'id="f-mqtt-host"']
check("the page has the camera field with the three modes, and the fields of tsx-ha", [w for w in want if w not in page], [])
check("the page script sets the field and handles u.CAMERA",
      ('$("f-camera").value = fields.CAMERA === "on" ? "live"' in page, 'if (u.CAMERA)' in page), (True, True))
check("the page sends no disabled field", "if (el.disabled) return;" in page, True)

# what the page reports as not available
if os.path.exists(t + "/run/hw.conf"):
    os.remove(t + "/run/hw.conf")
check("no hw.conf: the camera is available", "CAMERA" in d.hw_unavailable(), False)
hw(open(t + "/hw-all.conf").read())
check("hw.conf of a panel with all parts: the camera is available", "CAMERA" in d.hw_unavailable(), False)
nc = open(t + "/hw-nc.conf").read()
reason = [l.split("=", 1)[1].strip() for l in nc.splitlines() if l.startswith("REASON=")][0]
hw(nc)
check("hw.conf of a TSW-760-NC: the camera is not available, with the REASON text",
      d.hw_unavailable().get("CAMERA"), "no camera on this panel (%s)" % reason)
hw("CAMERA=no\n")
check("CAMERA=no and no REASON: the short text", d.hw_unavailable().get("CAMERA"), "no camera on this panel")
hw("CAMERA=no\nREASON=\n")
check("CAMERA=no and an empty REASON: the short text", d.hw_unavailable().get("CAMERA"), "no camera on this panel")

# the page script of the plugin, in node when the host has it
def run_node(script):
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, timeout=30)
    return out.returncode, out.stdout.strip() + out.stderr.strip()

plugin_mod = [p for p in d.PLUGINS if p.NAME == "camera"][0]
if subprocess.run(["sh", "-c", "command -v node"], capture_output=True).returncode == 0:
    js = "const JS = %s;\n" % json.dumps(plugin_mod.JS) + """
const els = {};
const $ = id => (els[id] = els[id] || {style: {}, value: "", disabled: false, textContent: ""});
const run = (code, args) => new Function("$", ...Object.keys(args), code)($, ...Object.values(args));
const out = [];
run(JS.apply, {fields: {CAMERA: "snapshot"}}); out.push($("f-camera").value);
run(JS.apply, {fields: {CAMERA: "on"}}); out.push($("f-camera").value);
run(JS.apply, {fields: {}}); out.push($("f-camera").value);
run(JS.unavailable, {u: {}}); out.push(String($("f-camera").disabled));
run(JS.unavailable, {u: {CAMERA: "no camera on this panel (R)"}});
out.push(String($("f-camera").disabled), $("camera-summary").textContent, $("camera-hint").textContent);
console.log(JSON.stringify(out));
"""
    rc, got = run_node(js)
    try:
        got = json.loads(got)
    except ValueError:
        pass
    check("the page script: the field shows the mode (on is live, empty is off), and a panel without a camera disables it",
          (rc, got), (0, ["snapshot", "live", "off", "false", "true", "Camera (not available)",
                          "Camera: not available, no camera on this panel (R)."]))
else:
    print("  skip: the page script (no node on this host)")

# a save, with the real tsx-config for the check of the value (config.d/camera.sh)
writes = []
stored = {"KIOSK_URL": "https://ha.example.org/lovelace/0"}
d.tcfg_rev = lambda: "r1"
d.tcfg_show = lambda: dict(stored)
d.tcfg_set = lambda k, v: (writes.append((k, v)), (True, ""))[1]
d.tcfg_unset = lambda k: None
d.tcfg_apply = lambda: (True, "")
d.restart_kiosk = lambda: None
d.clear_setup_open = lambda: None
d._invalidate_configured_cache = lambda: None
submit = {"KIOSK_URL": "https://ha.example.org/lovelace/0", "CAMERA": "live"}
os.remove(t + "/run/hw.conf")
status, body = d.handle_submit(dict(submit), "r1")
check("a save with CAMERA=live on a panel with a camera writes CAMERA", (status, writes), (200, [("CAMERA", "live")]))
writes.clear()
status, body = d.handle_submit({"KIOSK_URL": "https://ha.example.org/lovelace/0", "CAMERA": "bogus"}, "r1")
check("a bad CAMERA value is refused (tsx-config validate with the plugin)", (status, sorted(body.get("errors", {})), writes), (400, ["CAMERA"], []))
status, body = d.handle_submit({"KIOSK_URL": "https://ha.example.org/lovelace/0", "CAMERA": "on"}, "r1")
check("CAMERA=on is a valid value", (status, writes), (200, [("CAMERA", "on")]))
writes.clear()
hw(nc)
status, body = d.handle_submit(dict(submit), "r1")
check("a save on a panel without a camera leaves CAMERA as it is", (status, writes), (200, []))
sys.exit(1 if fails else 0)
PY

# ---- the ESPHome device --------------------------------------------------------------------------
echo "== esphome.d/camera.py: the camera entities and the image requests =="
mkdir -p "$T/run2" "$T/state" "$T/bl" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant" "$T/stub/getmac"
# the stand-ins: every protobuf name is a class that keeps its keyword arguments
: > "$T/stub/aioesphomeapi/__init__.py"
cat > "$T/stub/aioesphomeapi/api_pb2.py" <<'PY'
_classes = {}
def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if name not in _classes:
        _classes[name] = type(name, (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    return _classes[name]
PY
cat > "$T/stub/aioesphomeapi/model.py" <<'PY'
class VoiceAssistantFeature:
    VOICE_ASSISTANT = 1
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
echo "def get_mac_address(interface=None): return '02:00:00:00:00:01'" > "$T/stub/getmac/__init__.py"
: > "$T/stub/linux_voice_assistant/__init__.py"
cat > "$T/stub/linux_voice_assistant/entity.py" <<'PY'
class ESPHomeEntity:
    def __init__(self, server):
        self.server = server

class LEDLightEntity(ESPHomeEntity):
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self.effects_list = list(effects) if effects else []
        self.is_on, self.brightness, self.red, self.green, self.blue, self.effect = False, 1.0, 1.0, 1.0, 1.0, ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed
PY
cat > "$T/stub/linux_voice_assistant/api_server.py" <<'PY'
class APIServer:
    """One client connection. send_messages() keeps what the server sends."""
    def __init__(self, name):
        self.name, self.sent = name, []

    def connection_made(self, transport):
        self._tsx_denied = False

    def connection_lost(self, exc):
        pass

    def send_messages(self, msgs):
        self.sent.extend(msgs)
PY
cat > "$T/stub/linux_voice_assistant/util.py" <<'PY'
def get_default_interface(): return "lo"
def get_default_ipv4(iface): return "127.0.0.1"
PY
echo "class HomeAssistantZeroconf: pass" > "$T/stub/linux_voice_assistant/zeroconf.py"
cat > "$T/stub/linux_voice_assistant/satellite.py" <<'PY'
from aioesphomeapi import api_pb2 as pb

class VoiceSatelliteProtocol:
    """The satellite of linux-voice-assistant, reduced to what tsx_lva patches."""
    def __init__(self, state):
        self.state, self.sent = state, []

    def handle_message(self, msg):
        if isinstance(msg, pb.ListEntitiesRequest):
            for entity in self.state.entities:
                yield from entity.handle_message(msg)

    def connection_lost(self, exc):
        pass

    def send_messages(self, msgs):
        self.sent.extend(msgs)

class ServerState:
    def __init__(self):
        self.entities = []
        self.connections = []

    def broadcast(self, msgs):
        pass
PY

run_py "$COMMON/ha/voice/shim" "$T" <<'PY'
import contextlib, ctypes, hashlib, io, logging, os, re, struct, subprocess, sys, time, types
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run2", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_BUTTONS_CONF=t + "/none", TSX_ALS_CONF=t + "/none",
                  TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none", TSX_PANELCTL_BIN="/nonexistent",
                  TSX_THERMAL_ZONE=t + "/none", TSX_HA_TRANSPORT="esphome", TSX_PLUGIN_OWNER_UID=str(os.getuid()),
                  TSX_ESPHOME_PLUGIN_DIR=t + "/plugins/esphome.d")

# tsx-esphome needs the encryption module, which needs the cryptography package: a stand-in for security
import tsx_panel
security = types.ModuleType("tsx_panel.security")
security.enforce, security.encryption_enabled = (lambda: None), (lambda: False)
sys.modules["tsx_panel.security"] = tsx_panel.security = security

from aioesphomeapi import api_pb2 as pb
from tsx_panel import backend as backend_mod
from tsx_panel import device as dev
from tsx_panel import esphome_server, plugins
from tsx_panel.backend import PanelBackend
from tsx_panel.keys import stable_key

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("  ok:", name)
    else:
        print("  FAIL:", name, "got", repr(got), "want", repr(want)); fails += 1

class Cap(logging.Handler):
    """The log lines of the camera and the loader, so that a test can read them."""
    def __init__(self):
        super().__init__()
        self.lines = []
    def emit(self, record):
        self.lines.append((record.levelno, record.getMessage()))

cap = Cap()
for name in ("tsx_panel.camera", "tsx_panel.plugins"):
    lg = logging.getLogger(name)
    lg.addHandler(cap); lg.setLevel(logging.INFO); lg.propagate = False

def write(path, text):
    with open(path, "w") as f:
        f.write(text)

class Backend(PanelBackend):
    def _panelctl(self, *args, timeout=5):
        return False, ""

# ---- the loader finds the plugin -------------------------------------------------------------
plugins.reset()
check("the loader loads camera.py of the folder esphome.d", plugins.names(), ["camera.py"])
camera = plugins.loaded()[0]
check("... as the module tsx_esphome_plugin_camera, with the three functions of the contract",
      (camera.__name__, [callable(getattr(camera, n, None)) for n in ("entities", "handle_message", "connection_lost")]),
      ("tsx_esphome_plugin_camera", [True, True, True]))

def fresh(conf=None, hw=None):
    """A new camera service for the files of this test."""
    for name, text in (("camera.conf", conf), ("hw.conf", hw)):
        path = t + "/run2/" + name
        if text is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            write(path, text)
    camera.SERVICE = None
    cap.lines.clear()
    return camera.service()

def parts(d):
    """(camera, button, time sensor) of the plugin entities of a device, or None."""
    by = {e.object_id: e for e in d.plugin_entities}
    return by.get("camera"), by.get("take_snapshot"), by.get("last_snapshot")

# ---- the V4L2 structures: the sizes of the kernel headers ---------------------
ptr = ctypes.sizeof(ctypes.c_void_p)
check("v4l2_buffer size", ctypes.sizeof(camera._Buffer), 88 if ptr == 8 else 80)
check("v4l2_format size", ctypes.sizeof(camera._Format), 208 if ptr == 8 else 204)
check("v4l2_requestbuffers size", ctypes.sizeof(camera._RequestBuffers), 20)
check("v4l2_subdev_format size", ctypes.sizeof(camera._SubdevFormat), 88)
check("VIDIOC_DQBUF", hex(camera.VIDIOC_DQBUF), hex(0xc0585611 if ptr == 8 else 0xc0505611))
check("VIDIOC_SUBDEV_S_FMT", hex(camera.VIDIOC_SUBDEV_S_FMT), "0xc0585605")
check("UYVY fourcc", hex(camera.PIX_FMT_UYVY), "0x59565955")

# ---- the setting: off by default --------------------------------------------------
frame = t + "/frame.uyvy"
w, h = 640, 480
row = bytes(v for x in range(w // 2) for v in (128, (x * 2) % 256, 128, (x * 2 + 1) % 256))
with open(frame, "wb") as f:
    f.write(row * h)
os.environ["TSX_CAMERA_FAKE"] = frame

svc = fresh()
check("no camera.conf: off", (svc.enabled(), svc.why_off()), (False, "CAMERA is off in panel.conf"))
for text, want in (("on", "live"), ("live", "live"), ("snapshot", "snapshot"), ("off", "off"), ("", "off"),
                   ("yes", "off"), (" Snapshot ", "snapshot")):
    check("mode: CAMERA=%r is %s" % (text, want), camera.parse_mode(text), want)
check("mode: from camera.conf", fresh('CAMERA="snapshot"\n').mode, "snapshot")
svc = fresh('CAMERA="off"\n')
check("CAMERA=off: off", svc.enabled(), False)
svc = fresh('CAMERA="on"\n', "GOVERNMENT=1\nCAMERA=no\nREASON=government=1 (TSW-760-NC)\n")
check("hw.conf CAMERA=no: off, with the reason", (svc.enabled(), svc.why_off()),
      (False, "this panel has no camera (government=1 (TSW-760-NC))"))
svc = fresh('CAMERA="on"\n', "CAMERA=no\nREASON=\n")
check("hw.conf CAMERA=no and an empty REASON: the short reason", svc.why_off(), "this panel has no camera")
svc = fresh('CAMERA="on"\n', "GOVERNMENT=1\nCAMERA=no\nREASON=government=1 (TSW-760-NC)\n")
d = dev.build_entities(None, Backend())
check("camera off: no camera entity", (d.plugin_entities, [e for e in d.entities if isinstance(e, camera.CameraEntity)]), ([], []))
check("camera off: the log says why", [m for _l, m in cap.lines if m.startswith("no camera entity")],
      ["no camera entity: this panel has no camera (government=1 (TSW-760-NC))"])
check("size: the default", fresh('CAMERA="on"\n').config.size, (1280, 720))
check("size: from camera.conf", fresh('CAMERA="on"\nSIZE="640x480"\n').config.size, (640, 480))
check("size: an unknown size is the default", fresh('SIZE="641x480"\n').config.size, (1280, 720))
check("fps: limited to 10", fresh('FPS="50"\n').config.fps, 10.0)
check("quality: limited to 100", fresh('QUALITY="500"\n').config.quality, 100)

# The checks of the encoder, with stand-ins for numpy and for the library. The result is the
# same on every host, with or without numpy and a real libturbojpeg.
real_cdll = camera.ctypes.CDLL
had_numpy = "numpy" in sys.modules
saved_numpy = sys.modules.get("numpy")
try:
    sys.modules["numpy"] = None
    check("no numpy: the encoder is missing, with the reason", camera.encoder_missing(), "numpy is missing (package py3-numpy)")
    sys.modules["numpy"] = types.ModuleType("numpy")
    def no_library(_name):
        raise OSError("no such library")
    camera.ctypes.CDLL = no_library
    check("no libturbojpeg: the encoder is missing, with the reason", camera.encoder_missing(),
          "libturbojpeg is missing (package libturbojpeg)")
    camera.ctypes.CDLL = lambda _name: types.SimpleNamespace()    # loads, but has no tj3Init
    check("a libturbojpeg without the TurboJPEG 3 API: the encoder is missing, with the reason",
          camera.encoder_missing().startswith("libturbojpeg is too old"), True)
    camera.ctypes.CDLL = lambda _name: types.SimpleNamespace(tj3Init=None)
    check("a libturbojpeg with the TurboJPEG 3 API: the encoder is there", camera.encoder_missing(), "")
finally:
    camera.ctypes.CDLL = real_cdll
    if had_numpy:
        sys.modules["numpy"] = saved_numpy
    else:
        sys.modules.pop("numpy", None)

missing = camera.encoder_missing()
if missing:
    svc = fresh('CAMERA="on"\nSIZE="640x480"\n')
    check("no JPEG encoder: off, with the reason", (svc.enabled(), svc.why_off()), (False, missing))
    print("  skip: the image tests: " + missing)
    sys.exit(1 if fails else 0)

# ---- on: the entity and the images ------------------------------------------------
svc = fresh('CAMERA="on"\nSIZE="640x480"\nFPS="5"\n', "GOVERNMENT=0\nCAMERA=yes\n")
check("CAMERA=on: on", (svc.enabled(), svc.why_off()), (True, ""))
d = dev.build_entities(None, Backend())
cam, button, taken = parts(d)
check("camera on: one camera entity, the last entity", (len(d.plugin_entities), d.entities[-1] is cam), (1, True))
check("camera on: the log has the mode", [m for _l, m in cap.lines if m.startswith("camera: mode")], ["camera: mode live"])
check("camera on: the fixed key of \"camera\"", (cam.key, camera.service().key), (stable_key("camera"),) * 2)
check("live: no button and no time sensor", (button, taken), (None, None))
live_key = cam.key
listed = list(cam.handle_message(pb.ListEntitiesRequest()))
check("ListEntitiesCameraResponse", [(type(m).__name__, m.object_id, m.key, m.name, m.icon) for m in listed],
      [("ListEntitiesCameraResponse", "camera", cam.key, "Camera", "mdi:camera")])
sub = list(cam.handle_message(pb.SubscribeHomeAssistantStatesRequest()))
check("subscribe: one empty image (a state without a capture)",
      [(type(m).__name__, m.key, m.data, m.done) for m in sub], [("CameraImageResponse", cam.key, b"", True)])
check("subscribe: no capture", svc.stats["starts"], 0)

class Conn:
    def __init__(self):
        self.msgs = []
    def send_messages(self, msgs):
        self.msgs.extend(msgs)

def wait_images(conn, count, limit=5.0):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if sum(1 for m in conn.msgs if m.done) >= count:
            break
        time.sleep(0.02)
    images, cur = [], b""
    for m in conn.msgs:
        cur += m.data
        if m.done:
            images.append(cur); cur = b""
    return images

check("another message is not for the camera", camera.handle_message(Conn(), pb.PingRequest()), False)
check("plugins.handle_message: a message that is not for the camera is not taken", plugins.handle_message(Conn(), pb.PingRequest()), False)
a = Conn()
check("CameraImageRequest single: handled", camera.handle_message(a, pb.CameraImageRequest(single=True, stream=False)), True)
img = wait_images(a, 1)
check("single: one image", len(img), 1)
check("single: a JPEG (SOI and EOI)", (img[0][:2], img[0][-2:]) if img else None, (b"\xff\xd8", b"\xff\xd9"))
sof = img[0].find(b"\xff\xc0") if img else -1
check("single: 640x480 baseline", struct.unpack(">HH", img[0][sof + 5:sof + 9])[::-1] if sof > 0 else None, (640, 480))
check("single: the chunks carry the key of the entity", {m.key for m in a.msgs}, {cam.key})
check("single: only the last chunk says done", [m.done for m in a.msgs][-1:], [True])

# a big image: more than one chunk, none above the API limit
svc.config.size = (1280, 720)
big = t + "/big.uyvy"
with open(big, "wb") as f:
    f.write(os.urandom(1280 * 720 * 2))
os.environ["TSX_CAMERA_FAKE"] = big
svc.fake = big
camera.IDLE_CLOSE = 0.3
time.sleep(0.5)          # the session of the small frame closes
end = time.monotonic() + 3
while svc.capturing and time.monotonic() < end:
    time.sleep(0.05)
check("idle: the capture stops after IDLE_CLOSE", svc.capturing, False)
b = Conn()
camera.handle_message(b, pb.CameraImageRequest(single=True, stream=False))
img = wait_images(b, 1)
check("big: one image in several chunks", (len(img), len(b.msgs) > 1), (1, True))
check("big: every chunk at most CHUNK bytes", max(len(m.data) for m in b.msgs) <= camera.CHUNK, True)
check("big: done only on the last chunk", [m.done for m in b.msgs], [False] * (len(b.msgs) - 1) + [True])

# the stream: one image per request, at most FPS images per second
c = Conn()
times = []
for _ in range(4):
    camera.handle_message(c, pb.CameraImageRequest(single=False, stream=True))
    wait_images(c, len(times) + 1)
    times.append(time.monotonic())
gaps = [round(b - a, 2) for a, b in zip(times, times[1:])]
check("stream: four images for four requests", len(wait_images(c, 4)), 4)
check("stream: at most FPS images per second", all(g >= 1.0 / svc.config.fps - 0.02 for g in gaps), True)

# two connections wait at the same time: one image for each
x, y = Conn(), Conn()
camera.handle_message(x, pb.CameraImageRequest(single=True, stream=False))
camera.handle_message(y, pb.CameraImageRequest(single=True, stream=False))
check("two connections: one image each", (len(wait_images(x, 1)), len(wait_images(y, 1))), (1, 1))
# a closed connection gets nothing
z = Conn()
with svc._lock:          # hold the worker, so the request is still open
    svc._waiting[z] = time.monotonic()
camera.connection_lost(z)
check("connection lost: its open request is dropped", z in svc._waiting, False)
check("stats: images were sent", svc.stats["images"] >= 7, True)
check("live: the button does nothing", (svc.press(), svc._press_at), (None, 0.0))

# ---- snapshot: the button, the time sensor, the image requests ------------------------
def hashes(images):
    """Short hashes: a failed check prints these, not the JPEG bytes."""
    return [hashlib.sha256(i).hexdigest()[:8] for i in images]

os.environ["TSX_CAMERA_FAKE"] = frame
camera.SNAPSHOT_REPEAT = 1.0
svc = fresh('CAMERA="snapshot"\nSIZE="640x480"\n', "GOVERNMENT=0\nCAMERA=yes\n")
check("snapshot: on", (svc.enabled(), svc.mode), (True, "snapshot"))
d = dev.build_entities(None, Backend())
cam, button, taken = parts(d)
check("snapshot: camera, button and time sensor are the plugin entities, in this order",
      (d.plugin_entities == [cam, button, taken], None in (cam, button, taken)), (True, False))
check("snapshot: they are the last three entities", d.entities[-3:] == [cam, button, taken], True)
check("snapshot: the camera has the key of live mode", cam.key, live_key)
check("snapshot: the fixed keys of the button and the time sensor", (button.key, taken.key),
      (stable_key("take_snapshot"), stable_key("last_snapshot")))
listed = [m for e in (cam, button, taken) for m in e.handle_message(pb.ListEntitiesRequest())]
check("snapshot: the entity list", [(type(m).__name__, m.object_id, m.name) for m in listed],
      [("ListEntitiesCameraResponse", "camera", "Camera"), ("ListEntitiesButtonResponse", "take_snapshot", "Take snapshot"),
       ("ListEntitiesTextSensorResponse", "last_snapshot", "Last snapshot")])
check("snapshot: the time sensor is a timestamp", listed[2].device_class, "timestamp")
st = list(taken.handle_message(pb.SubscribeHomeAssistantStatesRequest()))
check("snapshot: no snapshot yet: the time is unknown", [getattr(m, "missing_state", False) for m in st], [True])

def images_of(conn):
    return wait_images(conn, 0, 0)

e = Conn()
camera.handle_message(e, pb.CameraImageRequest(single=True, stream=False))
camera.handle_message(e, pb.CameraImageRequest(single=False, stream=True))
img = wait_images(e, 1, 2)
check("snapshot: before the first snapshot a request gets an empty image", img[:1], [b""])
check("snapshot: requests never open the camera", (svc.stats["starts"], svc.capturing), (0, False))

sent = []
def broadcast(msgs):
    sent.extend(msgs)

dev.poll(d, broadcast)
sent.clear()
t0 = time.monotonic()
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))    # a second press during the snapshot
end = time.monotonic() + 5
while svc.snapshot is None and time.monotonic() < end:
    time.sleep(0.02)
time.sleep(0.3)
snap1 = svc.snapshot
check("snapshot: a press takes one snapshot (two quick presses: one)", (svc.stats["snapshots"], svc.stats["starts"]), (1, 1))
check("snapshot: the camera is closed after the snapshot", svc.capturing, False)
sof = snap1.jpeg.find(b"\xff\xc0") if snap1 else -1
check("snapshot: a 640x480 JPEG", struct.unpack(">HH", snap1.jpeg[sof + 5:sof + 9])[::-1] if sof > 0 else None, (640, 480))
iso = svc.last_snapshot_time() or ""
check("snapshot: the time is ISO 8601 in UTC", bool(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$", iso)), True)
dev.poll(d, broadcast)
check("snapshot: the poll of the device sends the new time once",
      [(type(m).__name__, m.state) for m in sent if getattr(m, "key", None) == taken.key], [("TextSensorStateResponse", iso)])

f = Conn()
for _ in range(3):
    camera.handle_message(f, pb.CameraImageRequest(single=True, stream=False))
    wait_images(f, len(images_of(f)) + 1, 2)
check("snapshot: three stills get the snapshot", hashes(images_of(f)), hashes([snap1.jpeg]) * 3)
check("snapshot: stills do not open the camera", svc.stats["starts"], 1)

h1 = hashes([snap1.jpeg])[0]
g = Conn()
camera.handle_message(g, pb.CameraImageRequest(single=True, stream=False))
check("snapshot: a still on the stream connection", hashes(wait_images(g, 1, 0.5)), [h1])
camera.handle_message(g, pb.CameraImageRequest(single=False, stream=True))
check("snapshot: a stream after a still gets the snapshot at once", hashes(wait_images(g, 2, 0.5)), [h1] * 2)
t1 = time.monotonic()
camera.handle_message(g, pb.CameraImageRequest(single=False, stream=True))
check("snapshot: the next stream request waits", hashes(wait_images(g, 3, 0.5)), [h1] * 2)
img = wait_images(g, 3, 3)
check("snapshot: after SNAPSHOT_REPEAT the stream gets the same snapshot again",
      (hashes(img), time.monotonic() - t1 >= camera.SNAPSHOT_REPEAT - 0.1), ([h1] * 3, True))
check("snapshot: the stream does not open the camera", svc.stats["starts"], 1)

# a new snapshot goes at once to the stream that waits
frame2 = t + "/frame2.uyvy"
with open(frame2, "wb") as fobj:
    fobj.write(bytes(v for x in range(w // 2) for v in (90, (x * 3) % 256, 170, (x * 3 + 1) % 256)) * h)
svc.fake = frame2
camera.handle_message(g, pb.CameraImageRequest(single=False, stream=True))
time.sleep(0.2)
t2 = time.monotonic()
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
img = wait_images(g, 4, 3)
snap2 = svc.snapshot
check("snapshot: a second press: a new image", (svc.stats["snapshots"], snap2.number, snap2.jpeg != snap1.jpeg), (2, 2, True))
check("snapshot: the waiting stream gets the new snapshot at once",
      (hashes(img[3:]), time.monotonic() - t2 < camera.SNAPSHOT_REPEAT), (hashes([snap2.jpeg]), True))
check("snapshot: the camera is closed again", (svc.stats["starts"], svc.capturing), (2, False))

# a failed snapshot keeps the last one
svc.fake = t + "/missing.uyvy"
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
end = time.monotonic() + 3
while svc.stats["errors"] == 0 and time.monotonic() < end:
    time.sleep(0.02)
time.sleep(0.1)
check("snapshot: a failed snapshot keeps the last one", (svc.stats["errors"], svc.snapshot is snap2, svc._press_at), (1, True, 0.0))
camera.connection_lost(g)
check("snapshot: connection lost: the connection is forgotten", (g in svc._asks, g in svc._sent), (False, False))

# ---- both front ends load the same plugin: the same camera entities, the same keys -----------
print("== both ESPHome services: tsx-esphome (VOICE=off) and the voice satellite (VOICE=on) ==")
os.environ["TSX_CAMERA_FAKE"] = frame
camera.IDLE_CLOSE = 10.0

class Transport:
    def get_extra_info(self, name):
        return ("192.0.2.9", 40000)

def standalone_list(mode_conf):
    """The entity list and a connection of tsx-esphome, as a new process would make them."""
    plugins.reset()
    cam_mod = plugins.loaded()[0]
    cam_mod.SERVICE = None
    fresh_conf(mode_conf)
    d = dev.build_entities(None, Backend())
    esphome_server.PanelAPIServer.device = d
    srv = esphome_server.PanelAPIServer()
    srv.connection_made(Transport())
    listed = [m for m in srv.handle_message(pb.ListEntitiesRequest()) if hasattr(m, "object_id")]
    return cam_mod, d, srv, [(type(m).__name__, m.object_id, m.key) for m in listed]

def fresh_conf(conf):
    write(t + "/run2/camera.conf", conf)
    write(t + "/run2/hw.conf", "GOVERNMENT=0\nCAMERA=yes\n")

voice_ready = False
def voice_list(mode_conf):
    """The entity list and a connection of the voice satellite."""
    global voice_ready
    import tsx_lva
    from linux_voice_assistant import satellite as lva
    backend_mod.PanelBackend = Backend
    plugins.reset()
    cam_mod = plugins.loaded()[0]
    cam_mod.SERVICE = None
    fresh_conf(mode_conf)
    if not voice_ready:
        with contextlib.redirect_stderr(io.StringIO()) as err:
            tsx_lva._patch_panel()
        voice_ready = True
        check("voice: the patch loads the plugins and says so", "tsx_lva: ESPHome plugins camera.py" in err.getvalue(), True)
    state = lva.ServerState()
    sat = lva.VoiceSatelliteProtocol(state)
    listed = [m for m in sat.handle_message(pb.ListEntitiesRequest()) if hasattr(m, "object_id")]
    return cam_mod, state, sat, [(type(m).__name__, m.object_id, m.key) for m in listed]

CAMERA_IDS = ("camera", "take_snapshot", "last_snapshot")

def requests(label, mode, mod, conn):
    """An image request on a connection of a front end, and the closed connection."""
    conn.sent.clear()
    out = list(conn.handle_message(pb.CameraImageRequest(single=True, stream=False)))
    if mode == "live":
        imgs = wait_images(types.SimpleNamespace(msgs=conn.sent), 1)
        check("%s, live: an image request is handled by the plugin and answered on the connection" % label,
              (out, len(imgs), imgs[0][:2] if imgs else None), ([], 1, b"\xff\xd8"))
    else:
        imgs = wait_images(types.SimpleNamespace(msgs=conn.sent), 1, 2)
        check("%s, snapshot: an image request gets an empty image before the first snapshot" % label,
              (out, imgs[:1]), ([], [b""]))
        # the worker waits with no open request, so this entry stays until the connection closes
        mod.service()._asks[conn] = (time.monotonic(), True, False)
        conn.connection_lost(None)
        check("%s: connection_lost reaches the plugin, which forgets the open request" % label,
              conn in mod.service()._asks, False)

for mode, conf, count in (("off", 'CAMERA="off"\n', 0), ("live", 'CAMERA="live"\nSIZE="640x480"\nFPS="5"\n', 1),
                          ("snapshot", 'CAMERA="snapshot"\nSIZE="640x480"\n', 3)):
    mod, _d, srv, lst = standalone_list(conf)
    ours = [x for x in lst if x[1] in CAMERA_IDS]
    check("%s: tsx-esphome lists %d camera entities" % (mode, count), len(ours), count)
    check("%s: each key is the fixed key of its object id" % mode, [x for x in ours if x[2] != stable_key(x[1])], [])
    if mode != "off":
        # the order: the plugin entities come after the entities of the device
        check("%s: the camera entities are the last entities of tsx-esphome" % mode, [x[1] for x in lst][-count:], list(CAMERA_IDS)[:count])
        requests("tsx-esphome", mode, mod, srv)
    mod2, _s, sat, vlst = voice_list(conf)
    theirs = [x for x in vlst if x[1] in CAMERA_IDS]
    check("%s: the voice satellite lists the same entities with the same keys" % mode, theirs, ours)
    if mode != "off":
        requests("voice", mode, mod2, sat)

# the key of a camera entity does not depend on the mode or on the front end: the same value everywhere
check("the keys of the camera entities", {i: stable_key(i) for i in CAMERA_IDS},
      {"camera": live_key, "take_snapshot": stable_key("take_snapshot"), "last_snapshot": stable_key("last_snapshot")})

# ---- the command line of the plugin file ------------------------------------------------------
out_jpg = t + "/cli.jpg"
env = dict(os.environ, TSX_CAMERA_FAKE=frame)
env.pop("PYTHONPATH", None)
env["TSX_SHIM_DIR"] = shim
run = subprocess.run([sys.executable, t + "/plugins/esphome.d/camera.py", "snapshot", out_jpg, "--size", "640x480"],
                     capture_output=True, text=True, env=env, timeout=60)
data = open(out_jpg, "rb").read() if os.path.exists(out_jpg) else b""
check("command line: snapshot FILE.jpg writes a JPEG (tsx_panel found in the shim folder)",
      (run.returncode, data[:2], data[-2:]), (0, b"\xff\xd8", b"\xff\xd9"))
check("command line: it prints the size", "640x480" in run.stdout, True)
os.remove(out_jpg)
env.pop("TSX_SHIM_DIR"); env["PYTHONPATH"] = shim
run = subprocess.run([sys.executable, t + "/plugins/esphome.d/camera.py", "snapshot", out_jpg, "--size", "640x480"],
                     capture_output=True, text=True, env=env, timeout=60)
check("command line: PYTHONPATH with the shim folder works too", (run.returncode, os.path.exists(out_jpg)), (0, True))

sys.exit(1 if fails else 0)
PY

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS common/test-camera || echo FAIL common/test-camera
exit $F
