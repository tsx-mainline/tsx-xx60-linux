#!/usr/bin/env python3
"""ha-provision.py: Home Assistant credentials for the TSW-1060 panel.

Python 3 standard library only. Every secret goes to provision/secrets/
(dir 0700, files 0600). The script never prints a secret. It prints only
file names and lengths.

Subcommands (run them in this order, and each one is safe to run again):

  create-user   One time only. It needs an admin token that you create and
                delete yourself: HA profile -> Security -> Long-lived access
                tokens -> Create ("tsx-provision-temp"). Put the token in
                secrets/admin-token (0600).
                The script generates a 32-character random password in
                secrets/tsw1060.password (unless the file exists). Then it
                calls the WebSocket API:
                  config/auth/create                     (name "TSW-1060 Panel",
                                                          group system-users,
                                                          local_only false)
                  config/auth_provider/homeassistant/create (username tsw1060)
                It writes secrets/user.json (user_id and username, not secret).
                Afterwards, delete the temporary admin token in HA (the script
                reminds you) and run `rm secrets/admin-token`.
                You can also skip the admin token. Create the user in the HA UI
                (Settings -> People -> Users -> Add user, username tsw1060, NOT
                administrator) with the password from secrets/tsw1060.password.
                Make the password with: ./ha-provision.py genpass

  genpass       Write secrets/tsw1060.password (only if it is absent).

  mint          Log in as the panel user. No admin session is involved:
                POST /auth/login_flow (client_id = kiosk origin + "/",
                handler ["homeassistant", null]) -> username/password step ->
                POST /auth/token (authorization_code) -> access + refresh token.
                Then open a WebSocket as that user:
                  auth/current_user                  (asserts is_admin == false)
                  auth/long_lived_access_token "tsw1060-buttons" 3650 days
                     -> secrets/ha-token   (tsx-buttons HA_TOKEN_FILE)
                  auth/long_lived_access_token "tsw1060-kiosk" 3650 days
                     -> secrets/kiosk-token (kiosk-set-token --file)
                  frontend/set_user_data core.default_panel = DASHBOARD
                The script also writes secrets/hassTokens.json. It has the
                localStorage format of the frontend for this login
                (access_token, refresh_token, expires, hassUrl, clientId, ...).
                It is a normal refreshable session for tools that seed it as is.
                The script keeps an existing token with the same client name,
                because HA refuses duplicates. With --rotate, it deletes the
                old token first.

  verify        Check secrets/ha-token and secrets/kiosk-token with GET /api/
                and GET /api/states/<light>. Also check the MQTT login (below).

  wait-event    As the panel user, wait for one tsx_button event (panel check).
  states-grep   List the entities that the panel user can see and that match
                --pattern (tsx).
  light-state   Print the state of --light as the panel user.

  mqtt-test     Send an MQTT 3.1.1 CONNECT as the panel user (Mosquitto app with
                HA user auth) and SUBSCRIBE to tsx/test. PUBLISH a harmless
                message to tsx/test and wait for it to come back. The client
                uses a stdlib socket.

Options: --url (default https://ha.example.org), --user (tsw1060),
--broker (default: none, required for mqtt-test), --port (1883),
--dashboard (tsw-1060), --light (default: light.example_light), --rotate.
"""
import argparse, base64, datetime, json, os, secrets, socket, ssl, stat, string, struct, sys, time
import urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SECRETS = os.path.join(HERE, "secrets")


# ---------------------------------------------------------------- secret files
def sdir():
    os.makedirs(SECRETS, mode=0o700, exist_ok=True)
    os.chmod(SECRETS, 0o700)
    return SECRETS


def spath(name):
    return os.path.join(sdir(), name)


def swrite(name, data):
    p = spath(name)
    fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(data)
    os.chmod(p + ".tmp", 0o600)
    os.replace(p + ".tmp", p)
    print(f"  wrote secrets/{name} ({len(data)} bytes, mode 0600)")


def sread(name, required=True):
    p = spath(name)
    if not os.path.exists(p):
        if required:
            sys.exit(f"missing secrets/{name}")
        return None
    mode = stat.S_IMODE(os.stat(p).st_mode)
    if mode & 0o077:
        os.chmod(p, 0o600)
        print(f"  (fixed mode of secrets/{name} to 0600)")
    with open(p) as f:
        return f.read().strip()


# ---------------------------------------------------------------- HTTP helpers
def http(method, url, data=None, token=None, form=False):
    headers = {"User-Agent": "tsw1060-provision"}
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw[:1] in "{[" else raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw[:200]


# ---------------------------------------------------------------- tiny WebSocket client (RFC 6455)
class WS:
    def __init__(self, base):
        u = urllib.parse.urlparse(base)
        tls = u.scheme == "https"
        host, port = u.hostname, u.port or (443 if tls else 80)
        s = socket.create_connection((host, port), timeout=20)
        if tls:
            s = ssl.create_default_context().wrap_socket(s, server_hostname=host)
        self.s = s
        key = base64.b64encode(os.urandom(16)).decode()
        hosthdr = host if u.port is None else f"{host}:{port}"
        s.sendall((f"GET /api/websocket HTTP/1.1\r\nHost: {hosthdr}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   f"User-Agent: tsw1060-provision\r\n\r\n").encode())
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            c = s.recv(1)
            if not c:
                raise IOError("websocket handshake: connection closed")
            hdr += c
        if b" 101 " not in hdr.split(b"\r\n")[0]:
            raise IOError("websocket handshake failed: " + hdr.split(b"\r\n")[0].decode())
        self.id = 0

    def _recvn(self, n):
        b = b""
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c:
                raise IOError("websocket closed")
            b += c
        return b

    def send(self, obj):
        data = json.dumps(obj).encode()
        n = len(data)
        head = bytes([0x81])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        msg = b""
        while True:
            b0, b1 = self._recvn(2)
            op, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recvn(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recvn(8))[0]
            if b1 & 0x80:
                self._recvn(4)  # servers do not mask. Ignore the mask if one is present.
            payload = self._recvn(n)
            if op == 0x9:  # ping -> pong
                self.s.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                continue
            if op == 0x8:
                raise IOError("websocket closed by server")
            msg += payload
            if b0 & 0x80:
                return json.loads(msg)

    def auth(self, token):
        m = self.recv()
        if m.get("type") != "auth_required":
            raise IOError("unexpected hello: %r" % m.get("type"))
        self.send({"type": "auth", "access_token": token})
        m = self.recv()
        if m.get("type") != "auth_ok":
            raise IOError("websocket auth failed: %s" % m.get("message", m.get("type")))
        return m.get("ha_version")

    def cmd(self, type_, **kw):
        self.id += 1
        self.send(dict(id=self.id, type=type_, **kw))
        while True:
            m = self.recv()
            if m.get("id") == self.id and m.get("type") == "result":
                if not m.get("success"):
                    e = m.get("error", {})
                    raise RuntimeError(f"{type_}: {e.get('code')}: {e.get('message')}")
                return m.get("result")

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


# ---------------------------------------------------------------- subcommands
def genpass(_a=None):
    if sread("tsw1060.password", required=False):
        print("  secrets/tsw1060.password exists, kept")
        return
    alphabet = string.ascii_letters + string.digits
    swrite("tsw1060.password", "".join(secrets.choice(alphabet) for _ in range(32)) + "\n")


def create_user(a):
    admin = sread("admin-token")
    genpass()
    pw = sread("tsw1060.password")
    ws = WS(a.url)
    try:
        print("  HA", ws.auth(admin))
        users = ws.cmd("config/auth/list")
        for u in users:
            if u.get("username") == a.user:
                print(f"  user {a.user} already exists: id {u['id']}, groups {u['group_ids']}")
                swrite_user(u["id"], a.user)
                return
        u = ws.cmd("config/auth/create", name="TSW-1060 Panel", group_ids=["system-users"], local_only=False)
        uid = u["user"]["id"]
        print(f"  created user 'TSW-1060 Panel' id {uid} (system-users, local_only false)")
        ws.cmd("config/auth_provider/homeassistant/create", user_id=uid, username=a.user, password=pw)
        print(f"  created homeassistant credential username {a.user}")
        swrite_user(uid, a.user)
    finally:
        ws.close()
    print("  NOW delete the temporary admin token in HA (profile -> Security) and: rm secrets/admin-token")


def swrite_user(uid, user):
    p = os.path.join(HERE, "user.json")
    with open(p, "w") as f:
        json.dump({"user_id": uid, "username": user, "name": "TSW-1060 Panel"}, f, indent=1)
        f.write("\n")
    print(f"  wrote {os.path.relpath(p, HERE)} (user id, not secret)")


def login(a, pw):
    """HA login flow as the panel user; returns the /auth/token response."""
    origin = a.url.rstrip("/")
    client_id = origin + "/"
    st, r = http("POST", origin + "/auth/login_flow",
                 {"client_id": client_id, "handler": ["homeassistant", None],
                  "redirect_uri": client_id + "?auth_callback=1"})
    if st != 200 or r.get("type") != "form":
        sys.exit(f"login_flow start failed: HTTP {st}: {r}")
    st, r = http("POST", f"{origin}/auth/login_flow/{r['flow_id']}",
                 {"client_id": client_id, "username": a.user, "password": pw})
    if st != 200 or r.get("type") != "create_entry":
        err = r.get("errors") if isinstance(r, dict) else r
        sys.exit(f"login failed: HTTP {st}: {err}")
    st, tok = http("POST", origin + "/auth/token",
                   {"grant_type": "authorization_code", "code": r["result"], "client_id": client_id}, form=True)
    if st != 200 or "access_token" not in tok:
        sys.exit(f"/auth/token failed: HTTP {st}: {tok if not isinstance(tok, dict) else tok.get('error')}")
    return tok, origin, client_id


def mint(a):
    pw = sread("tsw1060.password")
    tok, origin, client_id = login(a, pw)
    print(f"  logged in as {a.user} (access token {len(tok['access_token'])} chars, "
          f"refresh token {len(tok['refresh_token'])} chars, expires_in {tok['expires_in']} s)")
    ht = {"access_token": tok["access_token"], "token_type": "Bearer", "expires_in": tok["expires_in"],
          "hassUrl": origin, "clientId": client_id,
          "expires": int(time.time() * 1000) + tok["expires_in"] * 1000,
          "refresh_token": tok["refresh_token"]}
    swrite("hassTokens.json", json.dumps(ht) + "\n")

    ws = WS(origin)
    try:
        print("  HA", ws.auth(tok["access_token"]))
        me = ws.cmd("auth/current_user")
        print(f"  current user: {me['name']} id {me['id']} is_admin={me['is_admin']} is_owner={me['is_owner']}")
        if me["is_admin"] or me["is_owner"]:
            sys.exit("REFUSING: the panel user is an administrator; make it a normal user first")
        swrite_user(me["id"], a.user)
        have = {t["client_name"]: t for t in ws.cmd("auth/refresh_tokens")
                if t.get("type") == "long_lived_access_token"}
        for name, fname in (("tsw1060-buttons", "ha-token"), ("tsw1060-kiosk", "kiosk-token")):
            if name in have:
                if not a.rotate and sread(fname, required=False):
                    print(f"  token {name} exists in HA and secrets/{fname} is present: kept (--rotate replaces)")
                    continue
                ws.cmd("auth/delete_refresh_token", refresh_token_id=have[name]["id"])
                print(f"  deleted old token {name} ({have[name]['id']})")
            llat = ws.cmd("auth/long_lived_access_token", client_name=name, lifespan=3650)
            swrite(fname, llat + "\n")
        try:
            ws.cmd("frontend/set_user_data", key="core", value={"default_panel": a.dashboard})
            print(f"  default dashboard of {a.user} = {a.dashboard}")
        except RuntimeError as e:
            print(f"  could not set the default dashboard: {e}")
    finally:
        ws.close()
    # The refresh token of the login session stays valid (and stays in
    # hassTokens.json). It expires after 90 days without use. You can also
    # delete it in the profile of the user.


def verify(a):
    origin = a.url.rstrip("/")
    ok = True
    for fname in ("ha-token", "kiosk-token"):
        t = sread(fname, required=False)
        if not t:
            print(f"  secrets/{fname}: missing"); ok = False; continue
        st, r = http("GET", origin + "/api/", token=t)
        st2, s = http("GET", f"{origin}/api/states/{a.light}", token=t)
        state = s.get("state") if isinstance(s, dict) else s
        print(f"  secrets/{fname} ({len(t)} chars): /api/ -> {st} {r if st != 200 else r.get('message')}; "
              f"{a.light} -> {st2} {state}")
        ok &= st == 200 and st2 == 200
    ok &= mqtt_test(a)
    print("VERIFY", "OK" if ok else "FAILED")
    return ok


# ---------------------------------------------------------------- minimal MQTT 3.1.1
def _mstr(s):
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def _mpkt(t, body):
    n, rl = len(body), b""
    while True:
        d, n = n % 128, n // 128
        rl += bytes([d | (0x80 if n else 0)])
        if not n:
            break
    return bytes([t]) + rl + body


def _mread(s):
    t = s.recv(1)
    if not t:
        raise IOError("broker closed the connection")
    mult, n = 1, 0
    while True:
        d = s.recv(1)[0]
        n += (d & 127) * mult
        mult *= 128
        if not d & 128:
            break
    body = b""
    while len(body) < n:
        body += s.recv(n - len(body))
    return t[0], body


def mqtt_test(a):
    if not a.broker:
        sys.exit("mqtt-test: --broker is required")
    pw = sread("tsw1060.password")
    try:
        s = socket.create_connection((a.broker, a.port), timeout=10)
    except OSError as e:
        print(f"  MQTT {a.broker}:{a.port}: cannot connect: {e}"); return False
    cid = "tsw1060-provision-%d" % os.getpid()
    s.sendall(_mpkt(0x10, _mstr("MQTT") + bytes([4, 0xC2]) + struct.pack(">H", 30)
                    + _mstr(cid) + _mstr(a.user) + _mstr(pw)))
    t, body = _mread(s)
    rc = body[1] if t >> 4 == 2 and len(body) > 1 else -1
    names = {0: "accepted", 4: "bad user name or password", 5: "not authorized"}
    print(f"  MQTT {a.broker}:{a.port} CONNECT as {a.user}: rc={rc} ({names.get(rc, '?')})")
    if rc != 0:
        s.close(); return False
    s.sendall(_mpkt(0x82, struct.pack(">H", 1) + _mstr("tsx/test") + b"\x00"))
    t, body = _mread(s)
    granted = body[2] if len(body) > 2 else None
    msg = "provision test %s" % datetime.datetime.now().isoformat(timespec="seconds")
    s.sendall(_mpkt(0x30, _mstr("tsx/test") + msg.encode()))
    got = False
    end = time.time() + 5
    while time.time() < end:
        try:
            t, body = _mread(s)
        except socket.timeout:
            break
        if t >> 4 == 3:
            tl = struct.unpack(">H", body[:2])[0]
            if body[2 + tl:].decode(errors="replace") == msg:
                got = True
                break
    s.sendall(bytes([0xE0, 0]))
    s.close()
    print(f"  MQTT SUBSCRIBE tsx/test granted qos={granted}. PUBLISH '{msg}' "
          f"{'came back' if got else 'did NOT come back'}")
    return got


def wait_event(a):
    """Subscribe (as the panel user) to the tsx_button event; print the first one."""
    t = sread(a.token_file)
    ws = WS(a.url.rstrip("/"))
    try:
        ws.auth(t)
        how = None
        for type_, kw in (("subscribe_events", {"event_type": "tsx_button"}),
                          ("subscribe_trigger", {"trigger": {"platform": "event", "event_type": "tsx_button"}})):
            try:
                ws.cmd(type_, **kw); how = type_; break
            except RuntimeError as e:
                print(f"  {type_}: {e}")
        if not how:
            print("  cannot subscribe as the panel user (non-admin). Check the event in HA instead")
            sys.exit(2)
        print(f"  listening ({how}) for tsx_button, {a.timeout} s", flush=True)
        ws.s.settimeout(a.timeout)
        try:
            while True:
                m = ws.recv()
                if m.get("type") == "event":
                    ev = m["event"]
                    data = ev.get("data") or ev.get("variables", {}).get("trigger", {}).get("event", {}).get("data")
                    print("  EVENT tsx_button", json.dumps(data))
                    return
        except (socket.timeout, TimeoutError):
            print("  no tsx_button event within the timeout"); sys.exit(1)
    finally:
        ws.close()


def states_grep(a):
    """List entity ids (visible to the panel user) that contain PATTERN."""
    t = sread(a.token_file)
    st, r = http("GET", a.url.rstrip("/") + "/api/states", token=t)
    if st != 200:
        sys.exit(f"/api/states -> {st}")
    hits = [f"{x['entity_id']} = {x['state']}" for x in r if a.pattern in x["entity_id"]
            or a.pattern in str(x.get("attributes", {}).get("friendly_name", "")).lower()]
    print("\n".join("  " + h for h in hits) or "  (none)")
    sys.exit(0 if hits else 1)


def light_state(a):
    t = sread(a.token_file)
    st, r = http("GET", f"{a.url.rstrip('/')}/api/states/{a.light}", token=t)
    print(r.get("state") if st == 200 else f"HTTP {st}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["genpass", "create-user", "mint", "verify", "mqtt-test", "wait-event", "states-grep", "light-state"])
    p.add_argument("--url", default="https://ha.example.org")
    p.add_argument("--user", default="tsw1060")
    p.add_argument("--broker", default="")
    p.add_argument("--port", type=int, default=1883)
    p.add_argument("--dashboard", default="tsw-1060")
    p.add_argument("--light", default="light.example_light")
    p.add_argument("--rotate", action="store_true")
    p.add_argument("--token-file", default="ha-token", help="secrets/ file for wait-event/states-grep/light-state")
    p.add_argument("--timeout", type=int, default=30)
    p.add_argument("--pattern", default="tsx")
    a = p.parse_args()
    os.umask(0o077)
    {"genpass": genpass, "create-user": create_user, "mint": mint,
     "verify": lambda x: sys.exit(0 if verify(x) else 1),
     "mqtt-test": lambda x: sys.exit(0 if mqtt_test(x) else 1),
     "wait-event": wait_event, "states-grep": states_grep, "light-state": light_state}[a.cmd](a)


if __name__ == "__main__":
    main()
