"""The camera field of the setup page (plugin of the xx60 board).

tsx-setupd loads every *.py file in /usr/local/share/tsx/setup.d. The contract
is in the docstring of ha.py in tsx-linux-common (the plugin of tsx-ha). This
file adds one field to the page, the camera mode for Home Assistant (off,
snapshot or live). The key CAMERA is in config.d/camera.sh, and the camera
entities are in esphome.d/camera.py.

On a panel with CAMERA=no in hw.conf (tsx-hw), the page shows the field as
not available, with the REASON text of hw.conf. A save then leaves CAMERA as
it is.

The page script of this file does not depend on another plugin. The plugins
load in name order, so the script of this file runs before the script of ha.py.
"""

NAME = "camera"

SIMPLE_KEYS = ["CAMERA"]
UNAVAILABLE_DROPS = {"CAMERA": ("CAMERA",)}


def unavailable(hw):
    """The settings that this panel cannot use, with the reason (hw is the
    content of hw.conf from tsx-hw)."""
    out = {}
    if hw.get("CAMERA") == "no":
        why = hw.get("REASON")
        out["CAMERA"] = "no camera on this panel" + (" (%s)" % why if why else "")
    return out


HTML = {
    "details": """
    <details id="camera-wrap"><summary id="camera-summary">Camera</summary>
      <div class="card">
        <label for="f-camera">Camera for Home Assistant</label>
        <select id="f-camera" name="CAMERA">
          <option value="off">Off (default)</option>
          <option value="snapshot">Snapshot: one image for each press of a button in Home Assistant</option>
          <option value="live">Live: a live image while Home Assistant shows it</option>
        </select>
        <div class="hint" id="camera-hint">Off: the camera stays closed and Home Assistant has no camera. Only this panel can change this setting.</div>
      </div>
    </details>
""",
}

JS = {
    "apply": """
    $("f-camera").value = fields.CAMERA === "on" ? "live" : (fields.CAMERA || "off");
""",
    "unavailable": """
    if (u.CAMERA) {
      $("f-camera").disabled = true;
      $("camera-summary").textContent = "Camera (not available)";
      $("camera-hint").textContent = "Camera: not available, " + u.CAMERA + ".";
    }
""",
}
