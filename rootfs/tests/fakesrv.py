#!/usr/bin/env python3
"""Fake Home Assistant REST API + fake Chromium DevTools endpoint for
test-buttons.sh. Usage: fakesrv.py HA_PORT CDP_PORT LOGDIR
HA:  every POST is appended to LOGDIR/ha.log as "PATH|AUTH|BODY".
CDP: GET /json/list returns one page target; the websocket accepts one text
     frame, logs it to LOGDIR/cdp.log and answers {"id":1,...}."""
import base64, hashlib, json, os, socket, struct, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ha_port, cdp_port, logdir = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

class HA(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        with open(os.path.join(logdir, 'ha.log'), 'a') as f:
            f.write('%s|%s|%s\n' % (self.path, self.headers.get('Authorization'), body))
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.end_headers(); self.wfile.write(b'[]')
    def log_message(self, *a): pass

def cdp_conn(c):
    data = b''
    while b'\r\n\r\n' not in data:
        d = c.recv(4096)
        if not d: return
        data += d
    head = data.split(b'\r\n\r\n')[0].decode()
    line = head.split('\r\n')[0]
    if line.startswith('GET /json/list'):
        body = json.dumps([
            {"description": "", "id": "SW", "title": "Service Worker {x}", "type": "service_worker",
             "url": "https://ha/sw.js", "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/page/SW" % cdp_port},
            {"description": "", "devtoolsFrontendUrl": "/devtools/inspector.html?ws=x", "id": "P1",
             "title": "Home \"Assistant\"", "type": "page", "url": "https://ha/lovelace/0",
             "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/page/P1" % cdp_port}], indent=3)
        c.sendall(('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s'
                   % (len(body), body)).encode()); c.close(); return
    if line.startswith('GET /devtools/page/P1'):
        key = [l.split(':', 1)[1].strip() for l in head.split('\r\n') if l.lower().startswith('sec-websocket-key')][0]
        acc = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        c.sendall(('HTTP/1.1 101 WebSocket Protocol Handshake\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n'
                   'Sec-WebSocket-Accept: %s\r\n\r\n' % acc).encode())
        buf = b''
        def need(n):
            nonlocal buf
            while len(buf) < n:
                d = c.recv(4096)
                if not d: raise EOFError
                buf += d
            r, buf = buf[:n], buf[n:]; return r
        b0, b1 = need(2)
        ln = b1 & 0x7f
        if ln == 126: ln = struct.unpack('>H', need(2))[0]
        mask = need(4); pl = bytes(x ^ mask[i % 4] for i, x in enumerate(need(ln)))
        msg = pl.decode()
        with open(os.path.join(logdir, 'cdp.log'), 'a') as f: f.write(msg + '\n')
        # an unrelated event first, then the reply
        for out in ('{"method":"Page.frameNavigated","params":{}}',
                    json.dumps({"id": 1, "result": {"result": {"type": "string", "value": "spa /test"}}})):
            o = out.encode(); c.sendall(bytes([0x81, len(o)]) + o if len(o) < 126 else bytes([0x81, 126]) + struct.pack('>H', len(o)) + o)
        try: need(2)
        except EOFError: pass
    c.close()

def cdp_server():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', cdp_port)); s.listen(8)
    while True:
        c, _ = s.accept(); threading.Thread(target=cdp_conn, args=(c,), daemon=True).start()

threading.Thread(target=cdp_server, daemon=True).start()
ThreadingHTTPServer(('127.0.0.1', ha_port), HA).serve_forever()
