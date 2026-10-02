# SPDX-License-Identifier: GPL-2.0-or-later
"""tsx_brightness: the learning brightness curve of the panels.

The curve maps the ambient light to a backlight level. It is a list of
control points in (x, level). x is log10(1 + lux). The level between two
points is linear in x, and it stays flat before the first and after the
last point. The curve starts as the fixed curve of the board. A manual
change of the brightness that the user holds for a while becomes a user
point of the curve, so the panel remembers it.

The method follows the Android mapping strategy (frameworks/base,
BrightnessMappingStrategy: addUserDataPoint, insertControlPoint,
smoothCurve), which is Apache-2.0. This file reimplements the idea from its
description and copies no code. The rule that a new point replaces the old
points near it follows wluma (ISC). See docs/adaptive-brightness.md.

Rules:
- A new user point replaces every point within MERGE_DIST of it (a share of
  the x range of the curve). The first and the last base point stay.
- The base points near the new point move by a part of the change, so the
  curve bends in a smooth way (SPREAD).
- The curve never goes down when the light goes up. A darker point pulls
  the points on its left down to its level. A brighter point lifts the
  points on its right up to its level.
- At most MAX_POINTS user points stay. The oldest one goes first.
- The user points are in a file (a share of the maximum level and the lux),
  so they survive a reboot. The curve is rebuilt from the base and the
  points in their time order.

The Learner class watches the files of tsx-idled in /run/tsx. It turns a
slider offset that stays unchanged for HOLD_S seconds into a user point. Only
a real manual change counts. The offset file must be written after the daemon
started plus GRACE_S (so an offset that was there before a restart never
counts), the level in brightness.state and the backlight must stay the same
during the hold (so a ramp or a restart of tsx-idled never counts), and the
screen must be lit.
"""

import json
import math
import os
import sys
import time

MERGE_DIST = 0.12     # share of the x range: a new point replaces points this close
SPREAD = 3.0          # base points within SPREAD * MERGE_DIST move by a part of the change
MAX_POINTS = 12       # user points kept
HOLD_S = 8.0          # seconds that a slider offset must stay unchanged
GRACE_S = 20.0        # no learning in the first seconds after the daemon starts
SAVE_VERSION = 1


def lux_to_x(lux):
    return math.log10(1.0 + max(0.0, lux))


def x_to_lux(x):
    return 10.0 ** x - 1.0


def log_ramp(lo, hi, full_lux, steps=4):
    """The base curve of tsx-sensord: lo at 0 lux, hi at full_lux, linear in
    x. Returns (lux, level) pairs with `steps` + 1 points."""
    top = lux_to_x(full_lux)
    return [(x_to_lux(top * i / steps), lo + (hi - lo) * i / steps) for i in range(steps + 1)]


class Curve:
    """Base points plus user points. All levels are floats. level_at() gives
    the level for an x. The caller rounds it."""

    def __init__(self, base, lmin, lmax, max_points=MAX_POINTS):
        """base: (lux, level) pairs, lux ascending. lmin, lmax: level limits."""
        if not base:
            raise ValueError("no base points")
        self.lmin, self.lmax = float(lmin), float(max(lmax, lmin))
        self.base = sorted((lux_to_x(lux), float(lvl)) for lux, lvl in base)
        self.span = max(self.base[-1][0] - self.base[0][0], 0.5)
        self.max_points = max_points
        self.user = []        # [x, level, time], oldest first
        self.pts = []
        self.rebuild()

    # -- evaluate
    def level_at(self, x):
        return self._eval(self.pts, x)

    def level_for_lux(self, lux):
        return self.level_at(lux_to_x(lux))

    def control_points(self):
        """The curve as (lux, level) pairs."""
        return [(x_to_lux(x), lvl) for x, lvl in self.pts]

    # -- change
    def _clamp(self, lvl):
        return min(self.lmax, max(self.lmin, lvl))

    def _insert(self, pts, x, level):
        """Put one user point into the point list `pts` (a list of
        [x, level, is_user]) with the rules of the module header."""
        prior = self._eval(pts, x)
        dist = MERGE_DIST * self.span
        # The first and the last base point stay: they hold the ends.
        pts[:] = [p for i, p in enumerate(pts)
                  if abs(p[0] - x) >= dist or (not p[2] and i in (0, len(pts) - 1))]
        delta = level - prior
        reach = SPREAD * dist
        for p in pts:
            if not p[2]:
                w = max(0.0, 1.0 - abs(p[0] - x) / reach)
                p[1] += delta * w
        pts.append([x, level, True])
        pts.sort(key=lambda p: p[0])
        for p in pts:
            p[1] = self._clamp(p[1])
        idx = next(i for i, p in enumerate(pts) if p[2] and p[0] == x)
        for i in range(idx + 1, len(pts)):
            pts[i][1] = max(pts[i][1], pts[i - 1][1])
        for i in range(idx - 1, -1, -1):
            pts[i][1] = min(pts[i][1], pts[i + 1][1])

    @staticmethod
    def _eval(pts, x):
        if x <= pts[0][0]:
            return pts[0][1]
        if x >= pts[-1][0]:
            return pts[-1][1]
        for i in range(1, len(pts)):
            if x <= pts[i][0]:
                x0, y0 = pts[i - 1][0], pts[i - 1][1]
                x1, y1 = pts[i][0], pts[i][1]
                return y0 if x1 <= x0 else y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        return pts[-1][1]

    def rebuild(self):
        """Replay the user points on the base points."""
        pts = [[x, self._clamp(lvl), False] for x, lvl in self.base]
        for x, lvl, _t in self.user:
            self._insert(pts, x, self._clamp(lvl))
        self.pts = [(p[0], p[1]) for p in pts]

    def add_user_point(self, x, level, when=None):
        """Learn: at x the user wants `level`."""
        level = self._clamp(float(level))
        dist = MERGE_DIST * self.span
        self.user = [u for u in self.user if abs(u[0] - x) >= dist]
        self.user.append([x, level, time.time() if when is None else when])
        while len(self.user) > self.max_points:
            self.user.pop(0)
        self.rebuild()

    def reset(self):
        self.user = []
        self.rebuild()

    # -- save and load
    def to_json(self):
        span = self.lmax if self.lmax > 0 else 1.0
        return json.dumps({"version": SAVE_VERSION, "points": [
            {"lux": round(x_to_lux(x), 3), "frac": round(lvl / span, 5), "t": int(t)}
            for x, lvl, t in self.user]}, indent=1) + "\n"

    def load_json(self, text):
        """Read the points of to_json(). A file that does not parse, or an
        unknown version, leaves the curve as it is. Returns the count."""
        try:
            data = json.loads(text)
            if data.get("version") != SAVE_VERSION:
                return 0
            rows = []
            for row in data["points"]:
                lux, frac, when = float(row["lux"]), float(row["frac"]), float(row.get("t", 0))
                if not (0 <= lux <= 1e6 and 0 < frac <= 1.0):
                    continue
                rows.append([lux_to_x(lux), frac * self.lmax, when])
        except (ValueError, KeyError, TypeError, AttributeError):
            return 0
        rows.sort(key=lambda r: r[2])
        self.user = rows[-self.max_points:]
        self.rebuild()
        return len(self.user)


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fobj:
            return fobj.read()
    except OSError:
        return None


def read_int(path):
    raw = read_text(path)
    try:
        return int(raw.split()[0]) if raw else None
    except (ValueError, IndexError):
        return None


def state_fields(path):
    out = {}
    for line in (read_text(path) or "").splitlines():
        key, _, val = line.partition(" ")
        try:
            out[key] = int(val.strip())
        except ValueError:
            pass
    return out


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fobj:
            fobj.write(text)
        os.replace(tmp, path)
        return True
    except OSError as err:
        print("tsx-brightness: cannot write %s: %s" % (path, err), file=sys.stderr, flush=True)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


class Learner:
    """Turns held slider changes into user points of a Curve and keeps them
    in a file. poll() runs from the loop of a daemon that owns the curve."""

    def __init__(self, curve, path, run_dir, hold_s=HOLD_S, grace_s=None, backlight_dir=None):
        self.curve, self.path, self.run, self.hold_s = curve, path, run_dir, hold_s
        if grace_s is None:
            grace_s = float(os.environ.get("TSX_LEARN_GRACE_S", GRACE_S))
        self.grace_until = time.time() + grace_s    # wall clock, as the file times are
        self.bl_dir = backlight_dir or os.environ.get("TSX_BACKLIGHT_DIR", "/sys/class/backlight")
        self.pending = None          # (offset, first seen, level)
        self.release_offset = False
        self.info = ""

    def backlight_level(self):
        """The level now on the backlight device, or None when unknown."""
        try:
            names = sorted(os.listdir(self.bl_dir))
        except OSError:
            return None
        for name in names:
            val = read_int(os.path.join(self.bl_dir, name, "brightness"))
            if val is not None:
                return val
        return None

    def load(self):
        text = read_text(self.path)
        n = self.curve.load_json(text) if text else 0
        if n:
            print("tsx-brightness: %d learned point(s) from %s" % (n, self.path), file=sys.stderr, flush=True)
        return n

    def save(self):
        return write_atomic(self.path, self.curve.to_json())

    def reset_requested(self):
        flag = os.path.join(self.run, "brightness-learn.reset")
        if not os.path.exists(flag):
            return False
        self.curve.reset()
        try:
            os.unlink(self.path)
        except OSError:
            pass
        try:
            os.unlink(flag)
        except OSError:
            pass
        self.pending = None
        print("tsx-brightness: learned points removed", file=sys.stderr, flush=True)
        return True

    def poll(self, now, x, learning):
        """now: a monotonic time in seconds. x: the smoothed x of the light.
        learning: false while auto brightness is off or the screen is blank.
        Returns True when the curve changed."""
        offset_path = os.path.join(self.run, "brightness-offset")
        off = read_int(offset_path)
        if not learning or not off or os.path.exists(os.path.join(self.run, "brightness")):
            self.pending = None
            return False
        try:
            written = os.stat(offset_path).st_mtime
        except OSError:
            self.pending = None
            return False
        if written < self.grace_until:
            self.pending = None      # there before the daemon started, or too early
            return False
        st = state_fields(os.path.join(self.run, "brightness.state"))
        level = st.get("level", 0)
        on_glass = self.backlight_level()
        steady = on_glass is None or on_glass == level
        if not steady or st.get("offset") != off:
            # a ramp, a restart of tsx-idled, or tsx-idled has not used the
            # offset yet: the hold starts when all agree
            self.pending = None
            return False
        if self.pending is None or self.pending[0] != off or self.pending[2] != level:
            self.pending = (off, now, level)
            return False
        if now - self.pending[1] < self.hold_s:
            return False
        if st.get("override", 0) != 0 or level <= 0:
            return False
        self.info = "offset %d, level %d, base %d" % (off, level, st.get("base", 0))
        self.curve.add_user_point(x, st["level"])
        self.save()
        self.pending = None
        self.release_offset = True
        return True

    def release(self):
        """Remove the offset after the new base level is in place."""
        if not self.release_offset:
            return
        self.release_offset = False
        try:
            os.unlink(os.path.join(self.run, "brightness-offset"))
        except OSError:
            pass


# ---- the xx60 daemon -----------------------------------------------------------
# tsx-als (a shell script) owns the xx60 light curve. This part learns for it:
#   python3 tsx_brightness.py als-daemon
# It reads the curve ALS_CURVE of als.conf, learns user points, and writes the
# whole curve to /run/tsx/als-curve ("lux:level" pairs, whole numbers). tsx-als
# uses that file in place of ALS_CURVE while it exists.

def shell_value(path, key):
    """The value of KEY="value" in a shell-style file, or None."""
    for line in (read_text(path) or "").splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            val = line.split("=", 1)[1].split(" #", 1)[0].strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            return val
    return None


def curve_text(curve):
    """The curve as the whole-number pairs that tsx-als reads."""
    out = {}
    for lux, lvl in curve.control_points():
        key = int(round(lux))
        out[key] = max(out.get(key, 0), int(round(lvl)))
    return " ".join("%d:%d" % (k, out[k]) for k in sorted(out))


def als_daemon():
    env = os.environ.get
    run = env("TSX_RUN_DIR", "/run/tsx")
    als_conf = env("TSX_ALS_CONF", "/etc/tsx/als.conf")
    kiosk_conf = env("TSX_KIOSK_CONF", "/etc/kiosk.conf")
    board_conf = env("TSX_PANEL_BOARD_CONF", "/etc/tsx/panel-board.conf")
    idled = env("TSX_IDLED_STATE", "/run/tsx-idled.state")
    tick = float(env("TSX_LEARN_TICK", "1.0"))
    release_s = float(env("TSX_LEARN_RELEASE_S", "3.0"))

    def kiosk(key, default):
        for path in (board_conf, kiosk_conf):
            val = shell_value(path, key)
            if val and val.isdigit():
                return int(val)
        return default

    lmax = kiosk("BACKLIGHT_MAX", 23)
    lmin = kiosk("BACKLIGHT_MIN", 1)
    base = []
    for pair in (shell_value(als_conf, "ALS_CURVE") or "0:3 5:5 20:8 80:12 300:17 1000:21 3000:23").split():
        try:
            lux, lvl = pair.split(":")
            base.append((float(lux), float(lvl)))
        except ValueError:
            pass
    curve = Curve(base, lmin, lmax)
    learner = Learner(curve, env("TSX_LEARN_FILE", "/data/tsx/brightness-learn.json"), run,
                      float(env("TSX_LEARN_HOLD_S", str(HOLD_S))))
    out = os.path.join(run, "als-curve")
    learn_on = shell_value(kiosk_conf, "BRIGHTNESS_LEARN") != "off"
    if learn_on:
        learner.load()

    def publish():
        if curve.user:
            write_atomic(out, curve_text(curve) + "\n")
        else:
            try:
                os.unlink(out)
            except OSError:
                pass
    publish()
    release_at = None
    stop = []
    import signal
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.append(1))
    loops = int(env("TSX_LEARN_LOOPS", "0"))
    n = 0
    while not stop and (loops == 0 or n < loops):
        n += 1
        now = time.monotonic()
        st = state_fields(os.path.join(run, "als.state"))
        auto = (read_text(os.path.join(run, "als.state")) or "").find("auto on") >= 0
        if learner.reset_requested():
            publish()
        if learn_on and auto and "lux" in st:
            screen_on = (read_text(idled) or "").split()[:1] == ["on"]
            if learner.poll(now, lux_to_x(st["lux"]), screen_on):
                publish()
                release_at = now + release_s
        if release_at is not None and now >= release_at:
            learner.release()
            release_at = None
        time.sleep(tick)
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["als-daemon"]:
        sys.exit(als_daemon())
    print("usage: tsx_brightness.py als-daemon", file=sys.stderr)
    sys.exit(2)
