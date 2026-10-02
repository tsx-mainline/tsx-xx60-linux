#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Checks of tsx_brightness.py: the curve, the user points, the monotone
correction, the file, the reset and the Learner (docs/adaptive-brightness.md).
Usage: brightness-learn-check.py PATH-TO-tsx_brightness.py"""
import importlib.util
import json
import os
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location("tsx_brightness", sys.argv[1])
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)

fails = 0


def check(name, cond, extra=""):
    global fails
    print("  %s: %s %s" % ("ok" if cond else "FAIL", name, "" if cond else extra))
    if not cond:
        fails += 1


def monotone(curve, top=200000):
    prev = -1.0
    for i in range(0, 400):
        lux = (top + 1.0) ** (i / 399.0) - 1.0
        lvl = curve.level_for_lux(lux)
        if lvl < prev - 1e-9:
            return False
        prev = lvl
    return True


def wide():
    return tb.Curve(tb.log_ramp(600, 2400, 500), 123, 4095)


XX60_BASE = [(0, 3), (5, 5), (20, 8), (80, 12), (300, 17), (1000, 21), (3000, 23)]

print("== the start curve")
c = wide()
check("0 lux is the night level", round(c.level_for_lux(0)) == 600)
check("500 lux and more is the day level", round(c.level_for_lux(500)) == 2400 and round(c.level_for_lux(50000)) == 2400)
check("the start curve is monotone", monotone(c))
x = tb.lux_to_x(40)
expect = 600 + (2400 - 600) * x / tb.lux_to_x(500)
check("the start curve is the log curve of tsx-sensord", abs(c.level_at(x) - expect) < 1.0, "%.1f vs %.1f" % (c.level_at(x), expect))

print("== user points")
c = wide()
c.add_user_point(tb.lux_to_x(50), 400, 1)
check("the curve passes the user point", round(c.level_for_lux(50)) == 400)
check("the curve stays monotone after a darker point", monotone(c))
check("a darker point pulls the points on its left down", c.level_for_lux(0) <= 400 + 1e-6, c.level_for_lux(0))
check("the bright end stays bright", c.level_for_lux(500) > 1500, c.level_for_lux(500))
c.add_user_point(tb.lux_to_x(300), 1200, 2)
check("two points: both hold", round(c.level_for_lux(50)) == 400 and round(c.level_for_lux(300)) == 1200)
check("two points: monotone", monotone(c))
c2 = wide()
c2.add_user_point(tb.lux_to_x(20), 2300, 1)
check("a brighter point lifts the points on its right", c2.level_for_lux(500) >= 2300 and c2.level_for_lux(100) >= 2300)
check("a brighter point: monotone", monotone(c2))
check("a brighter point: the level never exceeds the cap", max(c2.level_for_lux(l) for l in (0, 20, 500, 9999)) <= 4095)
c3 = wide()
c3.add_user_point(tb.lux_to_x(100), 1, 1)
check("a point below the floor is raised to the floor", round(c3.level_for_lux(100)) == 123)
c3.add_user_point(tb.lux_to_x(100), 99999, 2)
check("a point above the top is cut to the top", round(c3.level_for_lux(100)) == 4095)

print("== a new point replaces the points near it")
c = wide()
c.add_user_point(tb.lux_to_x(100), 1500, 1)
c.add_user_point(tb.lux_to_x(110), 1000, 2)
check("one point stays for two close points", len(c.user) == 1 and round(c.level_for_lux(110)) == 1000)
check("the newest point wins", round(c.level_for_lux(100)) in range(995, 1010))
c = wide()
for i in range(30):
    c.add_user_point(tb.lux_to_x(3.0 * (1.9 ** i)), 700 + 20 * i, i)
check("at most MAX_POINTS user points stay", len(c.user) <= tb.MAX_POINTS, len(c.user))
check("many points: monotone", monotone(c))
check("the oldest point goes first", min(u[2] for u in c.user) > 0)

print("== file")
c = wide()
c.add_user_point(tb.lux_to_x(50), 400, 10)
c.add_user_point(tb.lux_to_x(300), 1200, 20)
text = c.to_json()
data = json.loads(text)
check("the file has version 1 and 2 points", data["version"] == 1 and len(data["points"]) == 2)
check("the file is small", len(text) < 1024, len(text))
d = wide()
n = d.load_json(text)
check("load: 2 points", n == 2)
check("load: the same curve", all(abs(c.level_for_lux(l) - d.level_for_lux(l)) < 0.6 for l in (0, 10, 50, 100, 300, 500)))
e = tb.Curve(tb.log_ramp(300, 1200, 500), 61, 2047)
e.load_json(text)
check("load: the levels scale with the top level", abs(e.level_for_lux(50) - 400 * 2047 / 4095) < 1.0, e.level_for_lux(50))
f = wide()
check("a file that is not JSON is ignored", f.load_json("{nope") == 0 and not f.user)
check("an unknown version is ignored", f.load_json('{"version": 9, "points": []}') == 0)
check("a bad row is skipped", f.load_json('{"version": 1, "points": [{"lux": "x", "frac": 1}]}') == 0)
check("a point with a level of 0 is skipped", f.load_json('{"version": 1, "points": [{"lux": 5, "frac": 0, "t": 1}]}') == 0 and not f.user)

print("== reset")
d.reset()
g = wide()
check("reset: the start curve again", all(abs(d.level_for_lux(l) - g.level_for_lux(l)) < 1e-9 for l in (0, 10, 100, 500)) and not d.user)

print("== 24 steps (xx60)")
c = tb.Curve(XX60_BASE, 1, 23)
levels = [round(c.level_for_lux(l)) for l in (0, 5, 20, 80, 300, 1000, 3000)]
check("the start curve is ALS_CURVE", levels == [3, 5, 8, 12, 17, 21, 23], levels)
c.add_user_point(tb.lux_to_x(150), 9, 1)
check("the point holds in whole steps", round(c.level_for_lux(150)) == 9)
sweep = [round(c.level_for_lux((3001.0) ** (i / 199.0) - 1)) for i in range(200)]
check("levels are whole steps from 1 to 23", all(1 <= v <= 23 for v in sweep))
check("the sweep up never goes down", all(b >= a for a, b in zip(sweep, sweep[1:])))
down = [round(c.level_for_lux((3001.0) ** ((199 - i) / 199.0) - 1)) for i in range(200)]
check("the sweep down is the sweep up reversed (no hysteresis loop in the curve)", down == sweep[::-1])
text = tb.curve_text(c)
check("curve_text is whole numbers", all(p.split(":")[0].isdigit() and p.split(":")[1].isdigit() for p in text.split()), text)
check("curve_text is ascending in lux", [int(p.split(":")[0]) for p in text.split()] == sorted(int(p.split(":")[0]) for p in text.split()))

print("== Learner")
tmp = tempfile.mkdtemp()
run = os.path.join(tmp, "run")
os.makedirs(run)
path = os.path.join(tmp, "data", "tsx", "brightness-learn.json")


def put(name, text):
    with open(os.path.join(run, name), "w") as fobj:
        fobj.write(text)


def state(level, base, offset, override=0):
    put("brightness.state", "level %d\nbase %d\noffset %d\noverride %d\nmax 4095\nmin 123\n" % (level, base, offset, override))


c = wide()
L = tb.Learner(c, path, run, hold_s=8.0, grace_s=0, backlight_dir=os.path.join(tmp, "no-backlight"))
time.sleep(0.05)
x = tb.lux_to_x(80)
put("brightness-offset", "-500\n")
state(1200, 1700, -500)
check("no change before the hold", not L.poll(100.0, x, True) and not L.poll(104.0, x, True))
check("no change just before the hold ends", not L.poll(107.9, x, True))
check("a held offset becomes a point", L.poll(108.1, x, True) and len(c.user) == 1)
check("the point has the level of the glass", round(c.level_for_lux(80)) == 1200)
check("the points are saved", os.path.exists(path) and json.loads(open(path).read())["points"][0]["frac"] > 0)
check("the offset stays until release", os.path.exists(os.path.join(run, "brightness-offset")))
L.release()
check("release removes the offset", not os.path.exists(os.path.join(run, "brightness-offset")))
check("no point without an offset", not L.poll(200.0, x, True) and not L.poll(300.0, x, True) and len(c.user) == 1)
put("brightness-offset", "-300\n")
check("a changed offset restarts the hold", not L.poll(400.0, x, True))
put("brightness-offset", "-250\n")
check("a changed offset restarts the hold again", not L.poll(405.0, x, True) and not L.poll(412.0, x, True))
check("a blank screen does not learn", not L.poll(500.0, x, False) and not L.poll(520.0, x, False) and len(c.user) == 1)
put("brightness-offset", "-250\n")
state(1500, 1700, 0)
L.pending = None
L.poll(600.0, tb.lux_to_x(300), True)
check("tsx-idled has not used the offset yet: no point", not L.poll(610.0, tb.lux_to_x(300), True) and len(c.user) == 1)
state(1450, 1700, -250)
check("the state agrees: the hold starts, then a point", not L.poll(611.0, tb.lux_to_x(300), True) and not L.poll(618.0, tb.lux_to_x(300), True) and L.poll(619.5, tb.lux_to_x(300), True) and len(c.user) == 2)
L.release()
put("brightness-offset", "-100\n")
put("brightness", "900\n")
state(900, 1700, -100, 900)
L.poll(700.0, x, True)
check("a fixed level (override) does not learn", not L.poll(720.0, x, True) and len(c.user) == 2)
os.unlink(os.path.join(run, "brightness"))
c_new = wide()
L2 = tb.Learner(c_new, path, run, grace_s=0)
check("a new Learner loads the points", L2.load() == 2 and round(c_new.level_for_lux(80)) == 1200)
put("brightness-learn.reset", "")
check("reset flag: the points go", L2.reset_requested() and not c_new.user and not os.path.exists(path)
      and not os.path.exists(os.path.join(run, "brightness-learn.reset")))
check("no flag: no reset", not L2.reset_requested())

print("== no learning without a real manual change")
bl = os.path.join(tmp, "bl", "dev"); os.makedirs(bl)


def glass(v):
    with open(os.path.join(bl, "brightness"), "w") as fobj:
        fobj.write("%d\n" % v)


def fresh(grace=20.0, hold=8.0):
    for n in ("brightness-offset", "brightness"):
        try:
            os.unlink(os.path.join(run, n))
        except OSError:
            pass
    return tb.Learner(wide(), path, run, hold_s=hold, grace_s=grace, backlight_dir=os.path.join(tmp, "bl"))


# the restart sequence: an offset file is already there (written before the
# daemon started, state and backlight in flux), the daemon starts, then the
# other services restart one after the other
put("brightness-offset", "-594\n")
old = time.time() - 3600
os.utime(os.path.join(run, "brightness-offset"), (old, old))
L = fresh()
x = tb.lux_to_x(15.8)
res = []
for t, lvl, g in ((0, 1196, 1196), (1, 1196, 1196), (3, 602, 1196), (5, 602, 700), (9, 602, 602), (20, 602, 602), (40, 602, 602), (80, 602, 602)):
    state(lvl, 1196, -594 if lvl == 602 else 0)
    glass(g)
    res.append(L.poll(1000.0 + t, x, True))
check("a stale offset (there before the start) never learns", not any(res) and not L.curve.user and not os.path.exists(path))
# the offset was written after the start, but within the grace time
L = fresh()
put("brightness-offset", "-594\n")
state(602, 1196, -594); glass(602)
check("an offset inside the grace time never learns", not L.poll(1000.0, x, True) and not L.poll(1010.0, x, True) and not L.poll(1030.0, x, True) and not L.curve.user)
# a ramp: the backlight is not yet at the level of the state
L = fresh(grace=0, hold=8.0)
time.sleep(0.05)
put("brightness-offset", "-594\n")
state(602, 1196, -594); glass(900)
check("a backlight that has not reached the level (a ramp) does not learn", not any(L.poll(2000.0 + t, x, True) for t in (0, 5, 9, 12, 20)) and not L.curve.user)
glass(602)
check("when the backlight is there, the hold starts and then it learns", not L.poll(2030.0, x, True) and not L.poll(2037.0, x, True) and L.poll(2038.5, x, True) and len(L.curve.user) == 1)
# a level that changes during the hold restarts the hold
L = fresh(grace=0, hold=8.0)
time.sleep(0.05)
put("brightness-offset", "-594\n")
glass(602); state(602, 1196, -594)
L.poll(3000.0, x, True)
state(650, 1196, -594); glass(650)
check("a level change during the hold restarts it", not L.poll(3009.0, x, True) and not L.poll(3016.0, x, True) and L.poll(3017.5, x, True))
# no offset file at all: base and level may differ (a restart of tsx-idled)
L = fresh(grace=0)
state(602, 1196, 0); glass(602)
check("level differs from base but there is no offset file: nothing", not any(L.poll(4000.0 + t, x, True) for t in range(0, 100, 5)))
# the state says offset 0 while the file says -594 (tsx-idled does not use it yet)
L = fresh(grace=0)
time.sleep(0.05)
put("brightness-offset", "-594\n")
state(1196, 1196, 0); glass(1196)
check("tsx-idled has not used the file: nothing", not any(L.poll(5000.0 + t, x, True) for t in range(0, 100, 5)))

print("== results: %d failure(s)" % fails)
sys.exit(1 if fails else 0)
