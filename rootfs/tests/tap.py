#!/usr/bin/env python3
"""Inject real touch taps on the panel: writes multitouch (type B) events to
/dev/input/event1 (ft5x06) over ssh. The input core forwards them exactly like
driver events, so they go through libinput and the compositor to whatever
surface is under the point (browser or keyboard layer).
Usage: tap.py [--ip IP] [--hold MS] [--gap MS] x,y [x,y ...]   (screen pixels,
       one tap after the other)
       tap.py --together x1,y1 x2,y2   (one tap with several fingers at once,
       e.g. the three-finger tap that toggles the on-screen keyboard)"""
import argparse, os, struct, subprocess, time

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN_TOUCH, ABS_X, ABS_Y = 330, 0, 1
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 47, 53, 54, 57

def ev(t, c, v):  # armv7: struct input_event = 2 x u32 time, u16 type, u16 code, s32 value
    return struct.pack('<IIHHi', 0, 0, t, c, v)

def sh_bytes(b):
    return "printf '" + ''.join('\\%03o' % x for x in b) + "' > /dev/input/event1"

ap = argparse.ArgumentParser()
ap.add_argument('--ip', default=os.environ.get('PANEL_IP'))
ap.add_argument('--hold', type=int, default=60)
ap.add_argument('--gap', type=int, default=250)
ap.add_argument('--together', action='store_true')
ap.add_argument('points', nargs='*')
a = ap.parse_args()
if not a.ip:
    ap.error("--ip or $PANEL_IP is required")
tid = int(time.time()) & 0x7fff
lines = ['set -e']
if a.together:
    pts = [tuple(int(v) for v in p.split(',')) for p in a.points]
    down = b''.join(ev(EV_ABS, ABS_MT_SLOT, k) + ev(EV_ABS, ABS_MT_TRACKING_ID, tid + k) +
                    ev(EV_ABS, ABS_MT_POSITION_X, x) + ev(EV_ABS, ABS_MT_POSITION_Y, y) for k, (x, y) in enumerate(pts))
    down += ev(EV_KEY, BTN_TOUCH, 1) + ev(EV_ABS, ABS_X, pts[0][0]) + ev(EV_ABS, ABS_Y, pts[0][1]) + ev(EV_SYN, 0, 0)
    up = b''.join(ev(EV_ABS, ABS_MT_SLOT, k) + ev(EV_ABS, ABS_MT_TRACKING_ID, -1) for k in range(len(pts)))
    up += ev(EV_KEY, BTN_TOUCH, 0) + ev(EV_SYN, 0, 0) + ev(EV_ABS, ABS_MT_SLOT, 0)
    lines += [sh_bytes(down), 'usleep %d' % (a.hold * 1000), sh_bytes(up)]
    a.points = []
for i, p in enumerate(a.points):
    x, y = (int(v) for v in p.split(','))
    down = (ev(EV_ABS, ABS_MT_SLOT, 0) + ev(EV_ABS, ABS_MT_TRACKING_ID, tid + i) +
            ev(EV_ABS, ABS_MT_POSITION_X, x) + ev(EV_ABS, ABS_MT_POSITION_Y, y) +
            ev(EV_KEY, BTN_TOUCH, 1) + ev(EV_ABS, ABS_X, x) + ev(EV_ABS, ABS_Y, y) + ev(EV_SYN, 0, 0))
    up = ev(EV_ABS, ABS_MT_SLOT, 0) + ev(EV_ABS, ABS_MT_TRACKING_ID, -1) + ev(EV_KEY, BTN_TOUCH, 0) + ev(EV_SYN, 0, 0)
    lines += [sh_bytes(down), 'usleep %d' % (a.hold * 1000), sh_bytes(up), 'usleep %d' % (a.gap * 1000)]
subprocess.run(['sshpass', '-p', 'tsx', 'ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                '-o', 'LogLevel=ERROR', 'root@' + a.ip, 'sh -s'], input='\n'.join(lines).encode(), check=True)
print('tapped', ' '.join(ap.parse_args().points))
