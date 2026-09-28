#!/usr/bin/env python3
"""Fake Chromium DevTools endpoint for rootfs/tests/test-esphome.sh: the
/json HTTP list tsx_panel.backend.PanelBackend polls for the current tab, and
a websocket that answers any DevTools command with an empty result (enough
to exercise Page.navigate / Page.reload without a real Chromium)."""
import asyncio
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import websockets

http_port, ws_port = int(sys.argv[1]), int(sys.argv[2])


async def ws_handler(ws):
    async for raw in ws:
        msg = json.loads(raw)
        print(f"devtools: {msg.get('method')} {msg.get('params')}", flush=True)
        await ws.send(json.dumps({"id": msg["id"], "result": {}}))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/json":
            body = json.dumps([
                {"type": "page", "url": "https://ha.example.org/", "webSocketDebuggerUrl": f"ws://127.0.0.1:{ws_port}/page"},
            ]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args):  # silence the default access log
        pass


def run_http():
    HTTPServer(("127.0.0.1", http_port), Handler).serve_forever()


def run_ws():
    async def main():
        async with websockets.serve(ws_handler, "127.0.0.1", ws_port):
            await asyncio.Future()

    asyncio.run(main())


threading.Thread(target=run_http, daemon=True).start()
threading.Thread(target=run_ws, daemon=True).start()
threading.Event().wait()
