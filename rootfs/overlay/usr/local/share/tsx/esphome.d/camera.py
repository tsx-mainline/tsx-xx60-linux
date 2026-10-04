"""The panel camera as a camera entity of Home Assistant (ESPHome native API).

This file is a plugin of the folder esphome.d (tsx-linux-common, docs/esphome.md
"Plugins"). Both ESPHome services load it: tsx-esphome (VOICE=off) and the
voice satellite (VOICE=on). So the device has the same camera entities in both
modes. The plugin defines entities(), handle_message() and connection_lost().

The camera has three modes. CAMERA in camera.conf (written by tsx-config
apply from CAMERA in panel.conf, with the plugin config.d/camera.sh) sets the
mode:
- off (the default): no camera entity, and nothing opens the video device.
  The kernel driver keeps the sensor in power-down with its clock off.
- snapshot: a camera entity, a "Take snapshot" button and a "Last snapshot"
  time sensor. Each press of the button opens the video device, takes one
  image and closes the device again. An image request of Home Assistant
  gets the last snapshot and never opens the device.
- live: a camera entity with a live image (see below).
"on" is the old name of live. A panel with CAMERA=no in hw.conf (tsx-hw) is
always off. Home Assistant cannot change the mode.

Live: Home Assistant sends CameraImageRequest (single for a still, stream
for each frame of its MJPEG stream). A worker thread opens the video device
at the first request, captures UYVY frames and encodes the newest frame as a
JPEG with libturbojpeg. Each request gets one image, sent only to the
connection that asked, in chunks below the frame limit of the API. The
worker sends at most FPS images per second. It closes the device IDLE_CLOSE
seconds after the last request.

Snapshot: the same worker thread takes the snapshots and answers the image
requests. A still request gets the last snapshot at once. A stream request
gets it at once when the connection has not had it yet, else after
SNAPSHOT_REPEAT seconds (the MJPEG proxy of Home Assistant asks again after
each image). A new snapshot goes at once to each connection that waits.
Before the first snapshot, each request gets an empty image. The snapshot
is kept in memory only.

After each connect, Home Assistant gets one empty image, so that the camera
entity has a state (see CameraEntity).

The capture uses the V4L2 media controller pipeline of the board: pad 0 of
every subdevice gets the capture size, then the video device. On the xx60
these are "ov5640 3-003c", "meson8-csi2" and the video device
"meson8-csi2-capture".

camera.conf keys: CAMERA (off|snapshot|live, "on" = live), SIZE
(WIDTHxHEIGHT, default 1280x720), QUALITY (JPEG quality 1..100, default 80),
FPS (the live stream limit, default 2). tsx-config apply writes only
CAMERA, so the other three keep their defaults.
Test hooks: TSX_RUN_DIR, TSX_CAMERA_CONF, TSX_HW_CONF, TSX_CAMERA_DEVICE
(the video device path), TSX_CAMERA_FAKE (a file with one UYVY frame of the
configured size: no V4L2 device is used).

The plugin imports tsx_panel with absolute names. The folder esphome.d is not
a package, and the loader runs the file under the module name
tsx_esphome_plugin_camera.

Command line (on the panel, as root or a member of group video):
  python3 /usr/local/share/tsx/esphome.d/camera.py snapshot FILE.jpg [--size WxH] [--quality Q]
  python3 /usr/local/share/tsx/esphome.d/camera.py bench [--size WxH] [--frames N]
The command line finds tsx_panel in /opt/lva/shim (TSX_SHIM_DIR changes the
folder) when PYTHONPATH does not name it.
"""

import ctypes
import errno
import fcntl
import logging
import mmap
import os
import select
import sys
import threading
import time
from datetime import datetime, timezone

try:
    from tsx_panel import hw
except ImportError:  # the command line: tsx_panel is in the shim folder of the voice install
    sys.path.append(os.environ.get("TSX_SHIM_DIR", "/opt/lva/shim"))
    from tsx_panel import hw

_LOGGER = logging.getLogger("tsx_panel.camera")

MODES = ("off", "snapshot", "live")
DEFAULT_SIZE = (1280, 720)
DEFAULT_QUALITY = 80
DEFAULT_FPS = 2.0
IDLE_CLOSE = 10.0       # live: seconds without a request before the device closes
SNAPSHOT_REPEAT = 5.0   # snapshot: a stream gets the same snapshot again after this many seconds
REQUEST_TIMEOUT = 20.0  # seconds after which an unanswered request is dropped
WARMUP_FRAMES = 3       # frames to skip after a start, at least
SETTLE_MAX = 20         # frames to skip after a start, at most (the exposure settles)
SETTLE_LUMA = 3         # three frames with a mean luma within this range: settled
FRAME_TIMEOUT = 2.0     # seconds to wait for one frame
START_TIMEOUT = 6.0     # seconds to wait for the first frame (2592x1944: up to 3.5 s seen)
CHUNK = 32768           # JPEG bytes per CameraImageResponse (API frame limit 65515)
NUM_BUFFERS = 4
KNOWN_CAPTURE = ("meson8-csi2-capture",)
SIZES = ((640, 480), (1024, 768), (1280, 720), (1920, 1080), (2592, 1944))


# ---- V4L2 (linux/videodev2.h, linux/v4l2-subdev.h) ---------------------------

def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord("V") << 8) | nr


class _PixFormat(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in (
        "width", "height", "pixelformat", "field", "bytesperline", "sizeimage",
        "colorspace", "priv", "flags", "ycbcr_enc", "quantization", "xfer_func")]


class _FormatUnion(ctypes.Union):
    _fields_ = [("pix", _PixFormat), ("raw", ctypes.c_uint8 * 200), ("_align", ctypes.c_void_p)]


class _Format(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("fmt", _FormatUnion)]


class _RequestBuffers(ctypes.Structure):
    _fields_ = [("count", ctypes.c_uint32), ("type", ctypes.c_uint32), ("memory", ctypes.c_uint32),
                ("capabilities", ctypes.c_uint32), ("flags", ctypes.c_uint8), ("reserved", ctypes.c_uint8 * 3)]


class _Timecode(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("flags", ctypes.c_uint32), ("frames", ctypes.c_uint8),
                ("seconds", ctypes.c_uint8), ("minutes", ctypes.c_uint8), ("hours", ctypes.c_uint8),
                ("userbits", ctypes.c_uint8 * 4)]


class _BufferM(ctypes.Union):
    _fields_ = [("offset", ctypes.c_uint32), ("userptr", ctypes.c_ulong),
                ("planes", ctypes.c_void_p), ("fd", ctypes.c_int32)]


class _Buffer(ctypes.Structure):
    # The timestamp is two 64-bit values: the kernel layout for 64-bit time,
    # also on 32-bit ARM with musl (time64).
    _fields_ = [("index", ctypes.c_uint32), ("type", ctypes.c_uint32), ("bytesused", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("field", ctypes.c_uint32), ("ts_sec", ctypes.c_int64),
                ("ts_usec", ctypes.c_int64), ("timecode", _Timecode), ("sequence", ctypes.c_uint32),
                ("memory", ctypes.c_uint32), ("m", _BufferM), ("length", ctypes.c_uint32),
                ("reserved2", ctypes.c_uint32), ("request_fd", ctypes.c_int32)]


class _MbusFormat(ctypes.Structure):
    _fields_ = [("width", ctypes.c_uint32), ("height", ctypes.c_uint32), ("code", ctypes.c_uint32),
                ("field", ctypes.c_uint32), ("colorspace", ctypes.c_uint32), ("ycbcr_enc", ctypes.c_uint16),
                ("quantization", ctypes.c_uint16), ("xfer_func", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("reserved", ctypes.c_uint16 * 10)]


class _SubdevFormat(ctypes.Structure):
    _fields_ = [("which", ctypes.c_uint32), ("pad", ctypes.c_uint32), ("format", _MbusFormat),
                ("stream", ctypes.c_uint32), ("reserved", ctypes.c_uint32 * 7)]


VIDIOC_S_FMT = _ioc(3, 5, ctypes.sizeof(_Format))
VIDIOC_REQBUFS = _ioc(3, 8, ctypes.sizeof(_RequestBuffers))
VIDIOC_QUERYBUF = _ioc(3, 9, ctypes.sizeof(_Buffer))
VIDIOC_QBUF = _ioc(3, 15, ctypes.sizeof(_Buffer))
VIDIOC_DQBUF = _ioc(3, 17, ctypes.sizeof(_Buffer))
VIDIOC_STREAMON = _ioc(1, 18, ctypes.sizeof(ctypes.c_int))
VIDIOC_STREAMOFF = _ioc(1, 19, ctypes.sizeof(ctypes.c_int))
VIDIOC_SUBDEV_S_FMT = _ioc(3, 5, ctypes.sizeof(_SubdevFormat))
BUF_TYPE_VIDEO_CAPTURE = 1
MEMORY_MMAP = 1
FIELD_NONE = 1
SUBDEV_FORMAT_ACTIVE = 1
MBUS_FMT_UYVY8_1X16 = 0x200F
PIX_FMT_UYVY = int.from_bytes(b"UYVY", "little")


def _sys_name(path):
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            return fobj.read().strip()
    except OSError:
        return ""


def find_device(sysfs="/sys/class/video4linux"):
    """The path of the capture video device, or "" if there is none."""
    forced = os.environ.get("TSX_CAMERA_DEVICE")
    if forced:
        return forced
    try:
        names = sorted(os.listdir(sysfs))
    except OSError:
        return ""
    for node in names:
        if node.startswith("video") and _sys_name(os.path.join(sysfs, node, "name")) in KNOWN_CAPTURE:
            return "/dev/" + node
    return ""


def _subdevs(sysfs="/sys/class/video4linux"):
    """All subdevice nodes. The xx60 has one pipeline: the sensor and the
    CSI-2 receiver."""
    try:
        return ["/dev/" + n for n in sorted(os.listdir(sysfs)) if n.startswith("v4l-subdev")]
    except OSError:
        return []


class V4L2Capture:
    """UYVY capture from a media controller pipeline with mmap buffers.

    While the stream runs, poll() takes each new frame out of the queue and
    holds it, and gives the one it held before back to the driver. So the
    driver always has free buffers, and the held frame is at most one frame
    period old. frame() copies the held frame."""

    def __init__(self, device, width, height):
        self.device, self.width, self.height = device, width, height
        self.fd = -1
        self.maps = []
        self.frame_bytes = width * height * 2
        self.frames = 0
        self.held = None

    def _setup_subdevs(self):
        for node in _subdevs():
            fmt = _SubdevFormat(which=SUBDEV_FORMAT_ACTIVE, pad=0)
            fmt.format.width, fmt.format.height = self.width, self.height
            fmt.format.code, fmt.format.field = MBUS_FMT_UYVY8_1X16, FIELD_NONE
            fd = os.open(node, os.O_RDWR)
            try:
                fcntl.ioctl(fd, VIDIOC_SUBDEV_S_FMT, fmt)
            finally:
                os.close(fd)
            if (fmt.format.width, fmt.format.height) != (self.width, self.height):
                raise OSError(errno.EINVAL, "%s: size %dx%d not supported (got %dx%d)" % (
                    node, self.width, self.height, fmt.format.width, fmt.format.height))

    def start(self):
        self._setup_subdevs()
        self.fd = os.open(self.device, os.O_RDWR | os.O_NONBLOCK)
        try:
            fmt = _Format(type=BUF_TYPE_VIDEO_CAPTURE)
            fmt.fmt.pix.width, fmt.fmt.pix.height = self.width, self.height
            fmt.fmt.pix.pixelformat, fmt.fmt.pix.field = PIX_FMT_UYVY, FIELD_NONE
            fcntl.ioctl(self.fd, VIDIOC_S_FMT, fmt)
            if (fmt.fmt.pix.width, fmt.fmt.pix.height) != (self.width, self.height):
                raise OSError(errno.EINVAL, "video size %dx%d not supported" % (self.width, self.height))
            self.frame_bytes = fmt.fmt.pix.sizeimage or self.frame_bytes
            req = _RequestBuffers(count=NUM_BUFFERS, type=BUF_TYPE_VIDEO_CAPTURE, memory=MEMORY_MMAP)
            fcntl.ioctl(self.fd, VIDIOC_REQBUFS, req)
            for index in range(req.count):
                buf = _Buffer(index=index, type=BUF_TYPE_VIDEO_CAPTURE, memory=MEMORY_MMAP)
                fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, buf)
                self.maps.append(mmap.mmap(self.fd, buf.length, mmap.MAP_SHARED, mmap.PROT_READ,
                                           offset=buf.m.offset))
                fcntl.ioctl(self.fd, VIDIOC_QBUF, buf)
            fcntl.ioctl(self.fd, VIDIOC_STREAMON, ctypes.c_int(BUF_TYPE_VIDEO_CAPTURE))
        except BaseException:
            self.close()
            raise

    def poll(self, timeout):
        """Wait up to timeout seconds for frames. Return True if a new frame
        is held."""
        ready, _w, _x = select.select([self.fd], [], [], timeout)
        if not ready:
            return False
        new = False
        while True:
            buf = _Buffer(type=BUF_TYPE_VIDEO_CAPTURE, memory=MEMORY_MMAP)
            try:
                fcntl.ioctl(self.fd, VIDIOC_DQBUF, buf)
            except OSError as err:
                if err.errno == errno.EAGAIN:
                    return new
                raise
            if self.held is not None:
                fcntl.ioctl(self.fd, VIDIOC_QBUF, self.held)
            self.held = buf
            self.frames += 1
            new = True

    def frame(self):
        """A copy of the held frame (one bulk copy: the buffers are uncached
        DMA memory)."""
        if self.held is None:
            return None
        return self.maps[self.held.index][:self.held.bytesused or self.frame_bytes]

    def latest(self, timeout=FRAME_TIMEOUT):
        """A copy of the next new frame. Raises TimeoutError if no frame
        comes in time."""
        deadline = time.monotonic() + timeout
        while not self.poll(max(0.0, deadline - time.monotonic())):
            if time.monotonic() >= deadline:
                raise TimeoutError("no frame from %s in %.1f s" % (self.device, timeout))
        return self.frame()

    def close(self):
        if self.fd < 0:
            return
        try:
            fcntl.ioctl(self.fd, VIDIOC_STREAMOFF, ctypes.c_int(BUF_TYPE_VIDEO_CAPTURE))
        except OSError:
            pass
        self.held = None
        for m in self.maps:
            m.close()
        self.maps = []
        try:
            fcntl.ioctl(self.fd, VIDIOC_REQBUFS, _RequestBuffers(count=0, type=BUF_TYPE_VIDEO_CAPTURE,
                                                                 memory=MEMORY_MMAP))
        except OSError:
            pass
        os.close(self.fd)
        self.fd = -1


class FakeCapture:
    """Test source: the same UYVY frame from a file, at about 30 frames per
    second."""

    def __init__(self, path, width, height):
        self.path, self.width, self.height = path, width, height
        self.frames = 0
        self.data = b""

    def start(self):
        with open(self.path, "rb") as fobj:
            self.data = fobj.read(self.width * self.height * 2)
        if len(self.data) != self.width * self.height * 2:
            raise OSError(errno.EINVAL, "%s: not one %dx%d UYVY frame" % (self.path, self.width, self.height))

    def poll(self, timeout):
        time.sleep(min(timeout, 1.0 / 30))
        self.frames += 1
        return True

    def frame(self):
        return self.data

    def latest(self, timeout=FRAME_TIMEOUT):
        self.poll(timeout)
        return self.frame()

    def close(self):
        self.data = b""


def mean_luma(frame):
    """The mean luma of a UYVY frame, from a sample of the pixels."""
    import numpy as np

    return float(np.frombuffer(frame, dtype=np.uint8)[1::2][::61].mean())


def settle(cap):
    """Skip the first frames after a start until the auto exposure is
    stable. On a cold start the exposure can swing for about ten frames.
    Return the number of frames skipped."""
    lumas = []
    for count in range(1, SETTLE_MAX + 1):
        lumas.append(mean_luma(cap.latest(START_TIMEOUT if count == 1 else FRAME_TIMEOUT)))
        last = lumas[-3:]
        if count >= WARMUP_FRAMES and len(last) == 3 and max(last) - min(last) <= SETTLE_LUMA:
            return count
    return SETTLE_MAX


# ---- JPEG (libturbojpeg, TurboJPEG 3 API) -------------------------------------

TJINIT_COMPRESS = 0
TJPARAM_QUALITY = 3
TJPARAM_SUBSAMP = 4
TJPARAM_FASTDCT = 10
TJSAMP_420 = 2


class JpegEncoder:
    """UYVY (4:2:2) to a 4:2:0 baseline JPEG. Needs libturbojpeg and numpy."""

    def __init__(self, quality=DEFAULT_QUALITY):
        import numpy  # noqa: F401 - fail early when numpy is missing

        self.lib = ctypes.CDLL(os.environ.get("TSX_TURBOJPEG", "libturbojpeg.so.0"))
        lib = self.lib
        lib.tj3Init.restype = ctypes.c_void_p
        lib.tj3Init.argtypes = [ctypes.c_int]
        lib.tj3Set.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        lib.tj3Destroy.argtypes = [ctypes.c_void_p]
        lib.tj3Free.argtypes = [ctypes.c_void_p]
        lib.tj3GetErrorStr.restype = ctypes.c_char_p
        lib.tj3GetErrorStr.argtypes = [ctypes.c_void_p]
        lib.tj3CompressFromYUVPlanes8.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_int, ctypes.POINTER(ctypes.c_int),
            ctypes.c_int, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
        self.handle = lib.tj3Init(TJINIT_COMPRESS)
        if not self.handle:
            raise OSError("tj3Init failed")
        for param, value in ((TJPARAM_QUALITY, quality), (TJPARAM_SUBSAMP, TJSAMP_420), (TJPARAM_FASTDCT, 1)):
            if lib.tj3Set(self.handle, param, value) != 0:
                raise OSError("tj3Set %d: %s" % (param, lib.tj3GetErrorStr(self.handle).decode()))

    def encode_uyvy(self, frame, width, height):
        import numpy as np

        data = np.frombuffer(frame, dtype=np.uint8, count=width * height * 2).reshape(height, width * 2)
        planes = (np.ascontiguousarray(data[:, 1::2]),        # Y
                  np.ascontiguousarray(data[0::2, 0::4]),     # U, every second line (4:2:0)
                  np.ascontiguousarray(data[0::2, 2::4]))     # V
        ptrs = (ctypes.c_void_p * 3)(*(p.ctypes.data for p in planes))
        strides = (ctypes.c_int * 3)(width, width // 2, width // 2)
        out = ctypes.c_void_p()
        size = ctypes.c_size_t()
        if self.lib.tj3CompressFromYUVPlanes8(self.handle, ptrs, width, strides, height,
                                              ctypes.byref(out), ctypes.byref(size)) != 0:
            msg = self.lib.tj3GetErrorStr(self.handle).decode()
            if out:
                self.lib.tj3Free(out)
            raise OSError("JPEG encode failed: " + msg)
        try:
            return ctypes.string_at(out, size.value)
        finally:
            self.lib.tj3Free(out)

    def close(self):
        if self.handle:
            self.lib.tj3Destroy(self.handle)
            self.handle = None


def encoder_missing():
    """Why the JPEG encoder cannot run, or "" when it can."""
    try:
        import numpy  # noqa: F401
    except ImportError:
        return "numpy is missing (package py3-numpy)"
    try:
        lib = ctypes.CDLL(os.environ.get("TSX_TURBOJPEG", "libturbojpeg.so.0"))
    except OSError:
        return "libturbojpeg is missing (package libturbojpeg)"
    if not hasattr(lib, "tj3Init"):
        return "libturbojpeg is too old: it has no TurboJPEG 3 API (package libturbojpeg 3 or later)"
    return ""


# ---- configuration -------------------------------------------------------------

def _conf_value(path, key):
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            for line in fobj:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


def parse_size(text):
    """'1280x720' -> (1280, 720) if it is a supported size, else None."""
    try:
        width, height = (int(v) for v in text.lower().split("x"))
    except ValueError:
        return None
    return (width, height) if (width, height) in SIZES else None


def parse_mode(text):
    """The mode of a CAMERA value: off, snapshot or live. "on" is the old
    name of live. An empty or unknown value is off."""
    text = (text or "").strip().lower()
    if text in ("live", "on"):
        return "live"
    return text if text in MODES else "off"


class Config:
    def __init__(self, run_dir=None):
        run = run_dir or os.environ.get("TSX_RUN_DIR", "/run/tsx")
        self.path = os.environ.get("TSX_CAMERA_CONF", os.path.join(run, "camera.conf"))
        self.hw_path = os.environ.get("TSX_HW_CONF", os.path.join(run, "hw.conf"))
        self.mode = parse_mode(_conf_value(self.path, "CAMERA"))
        self.size = parse_size(_conf_value(self.path, "SIZE")) or DEFAULT_SIZE
        try:
            self.quality = min(100, max(1, int(_conf_value(self.path, "QUALITY") or DEFAULT_QUALITY)))
        except ValueError:
            self.quality = DEFAULT_QUALITY
        try:
            self.fps = min(10.0, max(0.2, float(_conf_value(self.path, "FPS") or DEFAULT_FPS)))
        except ValueError:
            self.fps = DEFAULT_FPS
        self.present = hw.present("CAMERA", self.hw_path)


# ---- the service: one worker thread for all connections --------------------------

class Snapshot:
    """One image of the snapshot mode: the JPEG, its number (1, 2, ...) and
    the wall time when the frame came."""

    def __init__(self, jpeg, number, taken):
        self.jpeg, self.number, self.taken = jpeg, number, taken

    def iso_time(self):
        """The time as ISO 8601 in UTC, the state of a timestamp sensor."""
        return datetime.fromtimestamp(self.taken, timezone.utc).isoformat(timespec="seconds")


class CameraService:
    """One worker thread serves all connections. It starts at the first
    request or button press.

    Live: it sleeps until a request comes, keeps the stream open while
    requests come, and closes the device IDLE_CLOSE seconds after the last
    request.

    Snapshot: it opens the device only for a press of the button, takes one
    image and closes the device at once. It answers the image requests with
    the last snapshot."""

    def __init__(self, config=None):
        self.config = config or Config()
        self.fake = os.environ.get("TSX_CAMERA_FAKE", "")
        self.device = "" if self.fake else find_device()
        self.key = None
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._waiting = {}          # live: connection -> time of its oldest open request
        self._last_request = 0.0
        self._asks = {}             # snapshot: connection -> (time of its oldest request, a still?, a stream?)
        self._sent = {}             # snapshot: connection -> (number, time) of the last snapshot sent to its stream
        self._press_at = 0.0        # snapshot: time of the newest press that no snapshot has served
        self._number = 0
        self.snapshot = None        # snapshot: the last Snapshot (memory only)
        self._thread = None
        self.capturing = False
        self.stats = {"images": 0, "starts": 0, "errors": 0, "snapshots": 0}

    @property
    def mode(self):
        return self.config.mode

    def enabled(self):
        return not self.why_off()

    def why_off(self):
        """Why the camera is off, or "" when it is on."""
        if not self.config.present:
            return "this panel has no camera" + hw.reason_tail(self.config.hw_path)
        if self.config.mode == "off":
            return "CAMERA is off in panel.conf"
        if not (self.fake or self.device):
            return "no camera video device (kernel driver not loaded?)"
        return encoder_missing()

    def _start_locked(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="tsx-camera", daemon=True)
            self._thread.start()

    def request(self, conn, single=False):
        """Called on the event loop: CONN wants the next image. single: a
        still (in snapshot mode answered at once)."""
        now = time.monotonic()
        with self._lock:
            if self.config.mode == "snapshot":
                since, was_single, was_stream = self._asks.get(conn, (now, False, False))
                self._asks[conn] = (since, was_single or single, was_stream or not single)
            else:
                self._waiting.setdefault(conn, now)
                self._last_request = now
            self._start_locked()
        self._wake.set()

    def press(self):
        """Called on the event loop: the "Take snapshot" button. The worker
        takes one snapshot. A press that comes before the frame of a running
        snapshot is served by that snapshot."""
        if self.config.mode != "snapshot":
            return
        with self._lock:
            self._press_at = time.monotonic()
            self._start_locked()
        self._wake.set()

    def last_snapshot_time(self):
        """The time of the last snapshot (ISO 8601, UTC), or None."""
        snap = self.snapshot
        return snap.iso_time() if snap is not None else None

    def connection_lost(self, conn):
        with self._lock:
            self._waiting.pop(conn, None)
            self._asks.pop(conn, None)
            self._sent.pop(conn, None)

    def _prune(self):
        """Forget requests older than REQUEST_TIMEOUT (Home Assistant gave
        up on them). Return True if a request is open."""
        limit = time.monotonic() - REQUEST_TIMEOUT
        with self._lock:
            for conn in [c for c, t in self._waiting.items() if t < limit]:
                del self._waiting[conn]
            return bool(self._waiting)

    def _open(self):
        width, height = self.config.size
        if self.fake:
            cap = FakeCapture(self.fake, width, height)
        else:
            cap = V4L2Capture(self.device, width, height)
        cap.start()
        self.stats["starts"] += 1
        try:
            skipped = settle(cap)
        except BaseException:
            cap.close()
            raise
        _LOGGER.info("camera: capture started (%dx%d, %d frames to settle)", width, height, skipped)
        return cap

    def _send(self, conns, jpeg):
        from aioesphomeapi.api_pb2 import CameraImageResponse  # pylint: disable=no-name-in-module

        msgs = []
        for pos in range(0, len(jpeg), CHUNK):
            msgs.append(CameraImageResponse(key=self.key, data=jpeg[pos:pos + CHUNK],
                                            done=pos + CHUNK >= len(jpeg)))
        if not msgs:
            msgs = [CameraImageResponse(key=self.key, data=b"", done=True)]
        for conn in conns:
            try:
                conn.send_messages(msgs)
            except Exception:  # noqa: BLE001 - a closed connection must not stop the others
                _LOGGER.debug("camera: send failed", exc_info=True)

    # ---- live ----

    def _serve(self, enc):
        """Run one capture session: from the first request until the device
        is idle for IDLE_CLOSE seconds."""
        cap = None
        last_sent = 0.0
        width, height = self.config.size
        try:
            while True:
                waiting = self._prune()
                with self._lock:
                    idle = time.monotonic() - self._last_request
                if not waiting and idle > IDLE_CLOSE:
                    return
                if cap is None:
                    cap = self._open()
                    self.capturing = True
                if not cap.poll(FRAME_TIMEOUT):
                    raise TimeoutError("no frame from the camera in %.1f s" % FRAME_TIMEOUT)
                now = time.monotonic()
                if not waiting or now < last_sent + 1.0 / self.config.fps:
                    continue
                last_sent = now      # the time of the frame: the limit includes the encode time
                jpeg = enc.encode_uyvy(cap.frame(), width, height)
                with self._lock:
                    conns, self._waiting = list(self._waiting), {}
                self._send(conns, jpeg)
                self.stats["images"] += 1
        finally:
            if cap is not None:
                cap.close()
                self.capturing = False
                _LOGGER.info("camera: capture stopped")

    def _run_live(self, enc):
        failures = 0
        while True:
            self._wake.wait()
            self._wake.clear()
            if not self._prune():
                continue
            try:
                self._serve(enc)
                failures = 0
            except (OSError, TimeoutError) as err:
                # Home Assistant waits (a still times out after 10 s). The
                # connections stay in the list for the next try.
                self.stats["errors"] += 1
                failures += 1
                _LOGGER.warning("camera: capture failed (%d): %s", failures, err)
                time.sleep(min(30.0, float(failures)))
                self._wake.set()
            except Exception:  # noqa: BLE001 - keep the thread for the next request
                self.stats["errors"] += 1
                _LOGGER.warning("camera: capture failed", exc_info=True)
                time.sleep(5.0)
                self._wake.set()

    # ---- snapshot ----

    def _take_snapshot(self, enc):
        """Open the device, wait for a stable exposure, keep one frame, close
        the device, then encode the frame. A failure keeps the last
        snapshot."""
        if enc is None:
            with self._lock:
                self._press_at = 0.0
            _LOGGER.error("camera: no snapshot: no JPEG encoder")
            return
        width, height = self.config.size
        self.capturing = True
        try:
            cap = self._open()
            try:
                frame = cap.frame()
                taken_at, taken = time.monotonic(), time.time()
            finally:
                cap.close()
                _LOGGER.info("camera: capture stopped")
            jpeg = enc.encode_uyvy(frame, width, height)
        except Exception as err:  # noqa: BLE001 - keep the thread for the next press
            self.stats["errors"] += 1
            _LOGGER.warning("camera: snapshot failed: %s", err)
            with self._lock:
                self._press_at = 0.0
            return
        finally:
            self.capturing = False
        with self._lock:
            self._number += 1
            self.snapshot = Snapshot(jpeg, self._number, taken)
            if self._press_at <= taken_at:
                self._press_at = 0.0
        self.stats["snapshots"] += 1
        _LOGGER.info("camera: snapshot %d (%dx%d, %d bytes)", self._number, width, height, len(jpeg))

    def _snapshot_due(self):
        """Seconds until the next waiting stream request is due, or None
        when no request waits."""
        now = time.monotonic()
        with self._lock:
            if not self._asks:
                return None
            return max(0.0, min(self._sent.get(c, (0, -SNAPSHOT_REPEAT))[1] + SNAPSHOT_REPEAT - now
                                for c in self._asks))

    def _answer_snapshot(self):
        """Answer each request that is due: a still, a stream that has not
        had the last snapshot, or a stream after SNAPSHOT_REPEAT. A still
        does not count for the stream: a stream that starts after a still
        gets the snapshot at once."""
        now = time.monotonic()
        with self._lock:
            snap = self.snapshot
            due = []
            for conn, (_since, single, stream) in list(self._asks.items()):
                number, sent_at = self._sent.get(conn, (0, -SNAPSHOT_REPEAT))
                if snap is None or single or number != snap.number or now >= sent_at + SNAPSHOT_REPEAT - 0.01:
                    due.append(conn)
                    del self._asks[conn]
                    if snap is not None and stream:
                        self._sent[conn] = (snap.number, now)
        if due:
            self._send(due, snap.jpeg if snap is not None else b"")
            if snap is not None:
                self.stats["images"] += 1

    def _run_snapshot(self, enc):
        while True:
            self._wake.wait(self._snapshot_due())
            self._wake.clear()
            with self._lock:
                pressed = self._press_at
            if pressed:
                self._take_snapshot(enc)
            try:
                self._answer_snapshot()
            except Exception:  # noqa: BLE001 - keep the thread for the next request
                _LOGGER.warning("camera: answer failed", exc_info=True)

    def _run(self):
        enc = None
        try:
            enc = JpegEncoder(self.config.quality)
        except (OSError, ImportError) as err:
            _LOGGER.error("camera: no JPEG encoder: %s", err)
        if self.config.mode == "snapshot":
            self._run_snapshot(enc)      # without an encoder it still answers with empty images
        elif enc is not None:
            self._run_live(enc)
        else:
            with self._lock:
                self._thread = None
                self._waiting = {}


SERVICE = None


def service():
    """The one camera service of the process (made at the first use)."""
    global SERVICE  # pylint: disable=global-statement
    if SERVICE is None:
        SERVICE = CameraService()
    return SERVICE


def make_entities(server, key_for):
    """The entities of the camera: (camera, button, time sensor). Only the
    snapshot mode has the button and the time sensor (else None). Call it
    only when service().enabled() is True. key_for(object_id) gives the fixed
    key of an entity (keys.Keys)."""
    svc = service()
    svc.key = key_for("camera")
    cam = CameraEntity(server, svc.key, object_id="camera")
    if svc.mode != "snapshot":
        return cam, None, None
    from tsx_panel.entities import ButtonEntity, TextSensorEntity  # noqa: WPS433 - the command line needs no entities

    button = ButtonEntity(server, key_for("take_snapshot"), "Take snapshot", "take_snapshot", press=svc.press,
                          icon="mdi:camera-iris")
    taken = TextSensorEntity(server, key_for("last_snapshot"), "Last snapshot", "last_snapshot",
                             get_state=svc.last_snapshot_time, icon="mdi:camera-timer", device_class="timestamp")
    return cam, button, taken


def entities(server, key_for):
    """The plugin function of the loader (tsx_panel/plugins.py): the camera
    entities of the mode in camera.conf, or none. The log says why there is no
    camera entity."""
    svc = service()
    if not svc.enabled():
        _LOGGER.info("no camera entity: %s", svc.why_off())
        return []
    _LOGGER.info("camera: mode %s", svc.mode)
    return [e for e in make_entities(server, key_for) if e is not None]


def handle_message(conn, msg):
    """Handle CameraImageRequest. Return True if msg was one."""
    from aioesphomeapi.api_pb2 import CameraImageRequest  # pylint: disable=no-name-in-module

    if not isinstance(msg, CameraImageRequest):
        return False
    svc = service()
    if svc.key is not None and (msg.single or msg.stream):
        svc.request(conn, single=bool(msg.single))
    return True


def connection_lost(conn):
    if SERVICE is not None:
        SERVICE.connection_lost(conn)


try:
    from linux_voice_assistant.entity import ESPHomeEntity
except ImportError:  # the command line runs without the voice satellite
    ESPHomeEntity = object


class CameraEntity(ESPHomeEntity):
    def __init__(self, server, key, name="Camera", object_id="camera", icon="mdi:camera"):
        if ESPHomeEntity is not object:
            ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id, self.icon = key, name, object_id, icon

    def handle_message(self, msg):
        from aioesphomeapi.api_pb2 import (  # pylint: disable=no-name-in-module
            CameraImageResponse,
            ListEntitiesCameraResponse,
            ListEntitiesRequest,
            SubscribeHomeAssistantStatesRequest,
        )

        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesCameraResponse(object_id=self.object_id, key=self.key, name=self.name, icon=self.icon)
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            # Home Assistant writes the state of a camera entity only when an
            # image comes. Without one, the entity stays "unavailable" after
            # each reconnect, and the dashboard asks for no image. An empty
            # image gives the entity a state without a capture. Each request
            # of Home Assistant waits for the next image, so it never gets
            # this empty one.
            yield CameraImageResponse(key=self.key, data=b"", done=True)


# ---- command line ------------------------------------------------------------------

def _main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(prog="python3 /usr/local/share/tsx/esphome.d/camera.py")
    parser.add_argument("command", choices=("snapshot", "bench"))
    parser.add_argument("file", nargs="?", default="")
    parser.add_argument("--size", default="%dx%d" % DEFAULT_SIZE)
    parser.add_argument("--quality", type=int, default=DEFAULT_QUALITY)
    parser.add_argument("--frames", type=int, default=30)
    args = parser.parse_args(argv)
    size = parse_size(args.size)
    if size is None:
        parser.error("size must be one of " + ", ".join("%dx%d" % s for s in SIZES))
    width, height = size
    device = find_device()
    fake = os.environ.get("TSX_CAMERA_FAKE", "")
    if not (device or fake):
        parser.error("no camera video device")
    cap = FakeCapture(fake, width, height) if fake else V4L2Capture(device, width, height)
    enc = JpegEncoder(args.quality)
    t_start = time.monotonic()
    cap.start()
    try:
        skipped = settle(cap)
        t_ready = time.monotonic()
        if args.command == "snapshot":
            if not args.file:
                parser.error("snapshot needs a file name")
            jpeg = enc.encode_uyvy(cap.latest(), width, height)
            with open(args.file, "wb") as fobj:
                fobj.write(jpeg)
            print("%s: %d bytes, %dx%d, start to first frame %.2f s (%d frames to settle)" % (
                args.file, len(jpeg), width, height, t_ready - t_start, skipped))
            return 0
        t_cap = t_enc = 0.0
        total = 0
        cpu0 = os.times()
        t0 = time.monotonic()
        for _ in range(args.frames):
            t1 = time.monotonic()
            frame = cap.latest()
            t2 = time.monotonic()
            jpeg = enc.encode_uyvy(frame, width, height)
            t3 = time.monotonic()
            t_cap += t2 - t1
            t_enc += t3 - t2
            total += len(jpeg)
        wall = time.monotonic() - t0
        cpu1 = os.times()
        cpu = (cpu1.user - cpu0.user) + (cpu1.system - cpu0.system)
        print("%dx%d q%d: %d frames in %.2f s = %.1f fps, wait+copy %.1f ms, encode %.1f ms, "
              "JPEG %.0f KiB, CPU %.0f %% of one core, start %.2f s" % (
                  width, height, args.quality, args.frames, wall, args.frames / wall,
                  1000 * t_cap / args.frames, 1000 * t_enc / args.frames, total / args.frames / 1024,
                  100 * cpu / wall, t_ready - t_start))
        return 0
    finally:
        cap.close()
        enc.close()


if __name__ == "__main__":
    raise SystemExit(_main())
