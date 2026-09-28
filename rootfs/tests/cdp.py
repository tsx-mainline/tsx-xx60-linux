#!/usr/bin/env python3
"""Tiny CDP client for the kiosk (host side, via ssh -L to the panel's or the
VM's 127.0.0.1:9222).
Usage: cdp.py PORT state | shot FILE.png | eval 'JS'
       cdp.py PORT gpu [FILE]            chrome://gpu text (navigates the kiosk page
                                          there and back) + SystemInfo.getInfo
       cdp.py PORT sysinfo               SystemInfo.getInfo gpu summary (no navigation)
       cdp.py PORT procinfo              SystemInfo.getProcessInfo (type pid cpuTime)
       cdp.py PORT nav URL               load URL, print navigation timing (JSON)
       cdp.py PORT scroll [--distance PX] [--speed PX/S] [--repeat N]
                                          synthetic touch scroll with tracing: frames
                                          drawn, dropped, fps, renderer/GPU CPU (JSON)
       cdp.py PORT idle SECONDS          CPU time per Chromium process over SECONDS
browser added gpu/sysinfo/procinfo/nav/scroll/idle (perf-bench.sh uses them)."""
import asyncio, base64, itertools, json, sys, time, urllib.request
import websockets

port = int(sys.argv[1]); cmd = sys.argv[2]
import os; GEST = os.environ.get("CDP_GESTURE", "auto")   # auto (touch, else mouse) | touch | mouse
DEBUG = os.environ.get("CDP_DEBUG")
tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
page = next(t for t in tabs if t["type"] == "page")
browser = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))["webSocketDebuggerUrl"]

async def call(url, method, params=None):
    async with websockets.connect(url, max_size=64 << 20) as ws:
        await ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        while True:
            m = json.loads(await ws.recv())
            if m.get("id") == 1:
                return m


class Session:
    """One websocket, many calls, events collected per method."""
    def __init__(self, ws):
        self.ws, self.ids, self.events, self.waiters = ws, itertools.count(1), [], {}
        self.task = asyncio.create_task(self._reader())

    @classmethod
    async def open(cls, url):
        return cls(await websockets.connect(url, max_size=256 << 20, ping_interval=None))

    async def _reader(self):
        async for raw in self.ws:
            m = json.loads(raw)
            if "id" in m and m["id"] in self.waiters:
                self.waiters.pop(m["id"]).set_result(m)
            elif "method" in m:
                self.events.append(m)

    async def send(self, method, params=None, timeout=60):
        i = next(self.ids)
        fut = asyncio.get_running_loop().create_future()
        self.waiters[i] = fut
        await self.ws.send(json.dumps({"id": i, "method": method, "params": params or {}}))
        m = await asyncio.wait_for(fut, timeout)
        if "error" in m:
            raise RuntimeError(f"{method}: {m['error']}")
        return m["result"]

    async def wait_event(self, method, timeout=60, since=0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            for e in self.events[since:]:
                if e["method"] == method:
                    return e
            await asyncio.sleep(0.05)
        raise TimeoutError(method)

    async def eval(self, expr, timeout=60):
        r = await self.send("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True}, timeout)
        return r["result"].get("value")

    async def close(self):
        await self.ws.close()
        self.task.cancel()


async def procinfo():
    b = await Session.open(browser)
    try:
        r = await b.send("SystemInfo.getProcessInfo")
    finally:
        await b.close()
    return {f"{p['type']}:{p['id']}": p["cpuTime"] for p in r["processInfo"]}


def cpu_delta(a, b, dt):
    """per process type: CPU seconds and % of one core over dt"""
    out = {}
    for k, v in b.items():
        t = k.split(":")[0]
        d = v - a.get(k, 0.0)
        out[t] = out.get(t, 0.0) + d
    return {t: {"cpu_s": round(v, 3), "pct_core": round(100 * v / dt, 1)} for t, v in out.items()}


async def gpu_summary():
    b = await Session.open(browser)
    try:
        r = await b.send("SystemInfo.getInfo")
    finally:
        await b.close()
    g = r["gpu"]
    aux = g.get("auxAttributes", {})
    keep = ("glRenderer", "glVersion", "glVendor", "glImplementationParts", "displayType", "passthroughCmdDecoder",
            "sandboxed", "initializationTime", "inProcessGpu", "glExtensions")
    return {"featureStatus": g.get("featureStatus", {}), "driverBugWorkarounds": g.get("driverBugWorkarounds", []),
            "aux": {k: (aux[k][:160] if isinstance(aux.get(k), str) else aux.get(k)) for k in keep if k in aux},
            "devices": g.get("devices", [])}


async def main():
    if cmd == "state":
        r = await call(browser, "Browser.getWindowForTarget", {"targetId": page["id"]})
        print("url:", page["url"][:100]); print("window:", r.get("result", r))
        r = await call(page["webSocketDebuggerUrl"], "Runtime.evaluate", {"expression": "[document.readyState, innerWidth, innerHeight, document.title, !!localStorage.getItem('hassTokens')].join(' ')", "returnByValue": True})
        print("page:", r["result"]["result"].get("value"))
    elif cmd == "shot":
        r = await call(page["webSocketDebuggerUrl"], "Page.captureScreenshot", {"format": "png"})
        open(sys.argv[3], "wb").write(base64.b64decode(r["result"]["data"])); print("saved", sys.argv[3])
    elif cmd == "eval":
        r = await call(page["webSocketDebuggerUrl"], "Runtime.evaluate", {"expression": sys.argv[3], "returnByValue": True, "awaitPromise": True})
        print(json.dumps(r.get("result", r))[:2000])
    elif cmd == "sysinfo":
        print(json.dumps(await gpu_summary(), indent=1))
    elif cmd == "procinfo":
        print(json.dumps(await procinfo(), indent=1))
    elif cmd == "idle":
        dt = float(sys.argv[3])
        a = await procinfo(); t0 = time.time(); await asyncio.sleep(dt); b = await procinfo()
        print(json.dumps(cpu_delta(a, b, time.time() - t0)))
    elif cmd == "gpu":
        s = await Session.open(page["webSocketDebuggerUrl"])
        try:
            await s.send("Page.enable")
            back = await s.eval("location.href")
            await s.send("Page.navigate", {"url": "chrome://gpu"})
            await asyncio.sleep(4)
            txt = await s.eval("""(()=>{const v=document.querySelector('info-view');const r=v&&v.shadowRoot;
                if(!r) return document.body.innerText;
                return [...r.querySelectorAll('h3,li,tr,div.feature-status-list')].map(e=>e.innerText.replace(/\\n+/g,' ')).join('\\n')})()""")
            await s.send("Page.navigate", {"url": back})
        finally:
            await s.close()
        summ = await gpu_summary()
        out = txt + "\n\n=== SystemInfo.getInfo (gpu) ===\n" + json.dumps(summ, indent=1)
        if len(sys.argv) > 3:
            open(sys.argv[3], "w").write(out); print("saved", sys.argv[3])
        else:
            print(out)
    elif cmd == "nav":
        url = sys.argv[3]
        s = await Session.open(page["webSocketDebuggerUrl"])
        try:
            await s.send("Page.enable")
            n0 = len(s.events); t0 = time.time()
            await s.send("Page.navigate", {"url": url})
            await s.wait_event("Page.loadEventFired", 180, n0)
            wall = time.time() - t0
            await asyncio.sleep(1.5)       # let FCP/LCP entries settle
            t = await s.eval("""JSON.stringify((()=>{const n=performance.getEntriesByType('navigation')[0]||{};
                const p={};for(const e of performance.getEntriesByType('paint'))p[e.name]=Math.round(e.startTime);
                return {url:location.href.slice(0,120),ttfb:Math.round(n.responseStart||0),dcl:Math.round(n.domContentLoadedEventEnd||0),
                load:Math.round(n.loadEventEnd||0),fp:p['first-paint'],fcp:p['first-contentful-paint'],
                transfer:n.transferSize,nodes:document.getElementsByTagName('*').length}})())""")
        finally:
            await s.close()
        r = json.loads(t); r["wall_ms"] = round(wall * 1000)
        print(json.dumps(r))
    elif cmd == "scroll":
        args = sys.argv[3:]
        opt = lambda k, d: float(args[args.index(k) + 1]) if k in args else d
        dist, speed, rep = int(opt("--distance", 6000)), int(opt("--speed", 1500)), int(opt("--repeat", 1))
        s = await Session.open(page["webSocketDebuggerUrl"])
        b = await Session.open(browser)
        try:
            y = await s.eval("innerHeight") // 2
            gest = "touch" if GEST == "auto" else GEST
            if GEST == "auto":       # probe: touch input works? (not in headless)
                await s.eval("window.scrollTo(0,0)")
                await s.send("Input.synthesizeScrollGesture", {"x": 640, "y": y, "yDistance": -200, "speed": 2000,
                                                               "gestureSourceType": "touch", "preventFling": True}, timeout=60)
                if await s.eval("scrollY") == 0:
                    gest = "mouse"
            await s.eval("window.scrollTo(0,0)")
            await asyncio.sleep(1)
            # rAF counter in the page (main-thread frames)
            await s.eval("window.__f=0;window.__run=true;(function t(){if(!window.__run)return;window.__f++;requestAnimationFrame(t)})();0")
            cats = ["disabled-by-default-devtools.timeline.frame", "devtools.timeline", "benchmark", "cc", "viz"]
            await b.send("Tracing.start", {"traceConfig": {"includedCategories": cats, "recordMode": "recordAsMuchAsPossible"},
                                            "transferMode": "ReportEvents"})
            pa = await b.send("SystemInfo.getProcessInfo")
            f0 = await s.eval("window.__f"); t0 = time.time()
            for i in range(rep):
                d = dist if i % 2 == 0 else -dist
                # yDistance < 0: content scrolls down (a finger dragging upwards)
                await s.send("Input.synthesizeScrollGesture", {"x": 640, "y": y, "yDistance": -d, "speed": speed,
                                                               "gestureSourceType": gest, "preventFling": True}, timeout=300)
            dt = time.time() - t0
            f1 = await s.eval("window.__f"); sy = await s.eval("scrollY")
            await s.eval("window.__run=false")
            pb = await b.send("SystemInfo.getProcessInfo")
            n0 = len(b.events)
            await b.send("Tracing.end")
            await b.wait_event("Tracing.tracingComplete", 120, n0)
            ev = [e for m in b.events if m["method"] == "Tracing.dataCollected" for e in m["params"]["value"]]
        finally:
            await s.close(); await b.close()
        ts0 = min((e["ts"] for e in ev if e.get("ph") == "X" and e.get("name") == "SyntheticGestureController::DispatchNextEvent"), default=None)
        cnt = lambda n: sum(1 for e in ev if e.get("name") == n)
        # presented / dropped frames from the frame reporter (cc)
        states = {}
        for e in ev:
            if e.get("name") == "PipelineReporter" and e.get("ph") in ("b", "X"):
                if DEBUG and not states:
                    print("PipelineReporter sample:", json.dumps(e)[:600], file=sys.stderr)
                fr = e.get("args", {}).get("frame_reporter") or e.get("args", {}).get("chrome_frame_reporter") or {}
                if fr.get("scroll_state", "SCROLL_NONE") == "SCROLL_NONE":
                    continue           # only frames that belong to the scroll
                st = fr.get("state", "?").replace("STATE_", "").lower()
                states[st] = states.get(st, 0) + 1
        a = {f"{p['type']}:{p['id']}": p["cpuTime"] for p in pa["processInfo"]}
        bb = {f"{p['type']}:{p['id']}": p["cpuTime"] for p in pb["processInfo"]}
        r = {"gesture": gest, "distance": dist, "speed": speed, "repeat": rep, "duration_s": round(dt, 2), "scrollY_end": sy,
             "raf_frames": f1 - f0, "raf_fps": round((f1 - f0) / dt, 1),
             "draw_frames": cnt("DrawFrame"), "draw_fps": round(cnt("DrawFrame") / dt, 1),
             "begin_frames": cnt("BeginFrame"), "dropped_frames": cnt("DroppedFrame"),
             "scroll_frames": states,
             "scroll_presented_pct": round(100 * sum(v for k, v in states.items() if k.startswith("presented")) / max(1, sum(v for k, v in states.items() if k != "no_update_desired")), 1), "trace_events": len(ev), "cpu": cpu_delta(a, bb, dt)}
        print(json.dumps(r))
    else:
        print(__doc__); sys.exit(2)
asyncio.run(main())
