# camera.sh: the key CAMERA of tsx-config, for the camera of the xx60.
#
# tsx-config reads this file with `.` (the plugin folder config.d, see
# docs/layout.md "Plugin folders" in tsx-linux-common). The camera entities
# themselves are in /usr/local/share/tsx/esphome.d/camera.py, and the field
# of the setup page is in /usr/local/share/tsx/setup.d/camera.py.
#
# CAMERA (off|snapshot|live, default off): the camera in Home Assistant, on
#   the ESPHome device. off: no camera entities, and nothing opens the
#   camera, so the sensor stays in power-down. snapshot: a camera entity, a
#   "Take snapshot" button and a "Last snapshot" time. The camera opens only
#   for one image at each press. live: a camera entity with a live image
#   while Home Assistant asks for one. "on" is the old name of live. Home
#   Assistant cannot change this key. Apply writes /run/tsx/camera.conf
#   (world-readable, no secret) and restarts the ESPHome front end when the
#   value changes, so that Home Assistant reads the new entity list.
#
# A panel with CAMERA=no in hw.conf (tsx-hw) has no camera. It accepts each
# mode, so that a panel.conf from another panel still loads. set and show
# print a warning with the REASON text of hw.conf, and apply writes off.

CFG_CAMERA_KEYS="CAMERA"

cfg_camera_valid() {
	[ "$1" = CAMERA ] || return 1
	case "$2" in off|snapshot|live|on) return 0;; esac
	return 1
}

# The reason that the camera is missing, or fail when the panel has a camera.
# hw_why adds the REASON text of hw.conf in brackets, as for the other parts.
cfg_camera_missing() {
	[ "$(hw_get CAMERA)" = no ] || return 1
	echo "this panel has no camera$(hw_why)"
}

# /run/tsx/camera.conf is for the camera plugin of both ESPHome front ends.
# It holds off, snapshot or live. "on" is the old name of live. A panel
# without a camera always gets off. The signature is the mode, so a change
# restarts tsx-esphome and tsx-voice.
cfg_camera_apply() {
	_cam_v=$(cfg_get CAMERA) || _cam_v=
	case "$_cam_v" in snapshot|live) _cam_mode=$_cam_v;; on) _cam_mode=live;; *) _cam_mode=off;; esac
	if cfg_camera_missing CAMERA >/dev/null; then hw_warn CAMERA "$_cam_v"; _cam_mode=off; fi
	printf 'CAMERA="%s"\n' "$_cam_mode" | write_override "$RUN/camera.conf" 644
	CFG_CAMERA_SIG=$_cam_mode
}
