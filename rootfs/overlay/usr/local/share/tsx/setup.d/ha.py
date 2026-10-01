"""The Home Assistant part of the setup page (package tsx-ha).

tsx-setupd (the setup page of the kiosk) loads every *.py file in
/usr/local/share/tsx/setup.d. This file is the one of tsx-ha. Without it, the
page has only the fields of the base system: the page URL, the panel name,
the time zone, the display, the root login and the updates. With it, the page
adds these fields:

  * the Home Assistant URL, with "Find it automatically" and "Check"
  * how the panel logs in (login form, long-lived token, trusted network)
  * the voice assistant and its wake word
  * MQTT (broker, port, user, password)

and these checks: the settings that this panel cannot use (no microphone, no
Bluetooth module), and the Home Assistant URL check. The page code of
tsx-setupd never names Home Assistant, MQTT or voice.

What a plugin gives to tsx-setupd (all names are optional except NAME):

  NAME               the name of the plugin
  init(ctx)          called once. ctx.validate(key, value) runs the check of
                     tsx-config. ctx.show() returns the panel.conf values
                     (secrets masked). ctx.no_zeroconf is the test switch.
  SIMPLE_KEYS        panel.conf keys that the page sets with the same rules as
                     the keys of the base page
  CLEARABLE_BLANK    the keys among them that an empty value removes
  STATE_KEYS         the keys that the state API reports to the page
  UNAVAILABLE_DROPS  {name: (keys...)}: when unavailable(hw) reports the name,
                     a save leaves these keys as they are
  unavailable(hw)    {name: reason} for the settings that this panel cannot use
  submit(fields)     (to_set, to_unset, errors, post_unset) for the fields that
                     the generic rules do not cover
  TEXT               {"url_label", "url_placeholder", "url_required",
                     "submit_label", "done_text"}: words of the page
  HTML               {slot: html} for the slots url_buttons, after_url, panel
                     and details of the page
  JS                 {slot: js} for the slots apply, unavailable, payload and
                     init (the script of the page)
  GET_ROUTES, POST_ROUTES  {path: function(handler[, data])} for more API paths
"""
import json
import re
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

NAME = "ha"

_ctx = None


def init(ctx):
    global _ctx
    _ctx = ctx


SIMPLE_KEYS = ["VOICE", "WAKE_WORD", "MQTT_HOST", "MQTT_PORT", "MQTT_USER", "MQTT_PASSWORD"]
# Empty = cleared. The page pre-fills these keys, so an empty one was cleared
# on purpose. MQTT_PASSWORD is not one of them: the page never pre-fills it.
CLEARABLE_BLANK = {"MQTT_HOST", "MQTT_PORT", "MQTT_USER"}
STATE_KEYS = SIMPLE_KEYS + ["HA_LOGIN_METHOD", "HA_TOKEN"]
UNAVAILABLE_DROPS = {"VOICE": ("VOICE", "WAKE_WORD")}

TEXT = {
    "url_label": "Home Assistant URL",
    "url_placeholder": "https://homeassistant.local:8123",
    "url_required": "the Home Assistant URL is required",
    "submit_label": "Save and open Home Assistant",
    "done_text": "Saved. This panel will load Home Assistant now.",
}


def unavailable(hw):
    """The settings that this panel cannot use, with the reason (hw is the
    content of hw.conf from tsx-hw)."""
    gov = hw.get("GOVERNMENT", "unknown")
    out = {}
    if hw.get("MIC") == "no":
        out["VOICE"] = "no microphone on this panel (government=%s)" % gov
    if hw.get("BT") == "no":
        out["BT_PROXY"] = "no Bluetooth module on this panel (government=%s)" % gov
    return out


def submit(fields):
    """The login method and the token. Returns (to_set, to_unset, errors, post_unset)."""
    to_set, errors, post_unset = {}, {}, []
    method = fields.get("HA_LOGIN_METHOD")
    if method not in ("form", "token", "trusted"):
        errors["HA_LOGIN_METHOD"] = "choose a login method"
    elif method in ("token", "trusted"):
        to_set["HA_LOGIN_METHOD"] = method
        if method == "token":
            tok = fields.get("HA_TOKEN") or ""
            if tok:
                if _ctx.validate("HA_TOKEN", tok):
                    to_set["HA_TOKEN"] = tok
                else:
                    errors["HA_TOKEN"] = "does not look like a long-lived access token"
            elif not _ctx.show().get("HA_TOKEN"):
                errors["HA_TOKEN"] = "a long-lived access token is required for this login method"
    else:
        # the login form: the panel keeps no method and no token
        post_unset = ["HA_LOGIN_METHOD", "HA_TOKEN"]
    return to_set, [], errors, post_unset


HTML = {
    "url_buttons": """
      <div class="row" style="margin-top:8px">
        <button type="button" id="discover-btn" class="secondary">Find it automatically</button>
        <button type="button" id="check-btn" class="secondary">Check</button>
      </div>""",
    "after_url": """
    <h2>How this panel logs in</h2>
    <div class="card">
      <label class="choice"><input type="radio" name="HA_LOGIN_METHOD" value="form" checked>
        <div><b>Show the Home Assistant login form</b>
        <span>Log in on the panel once with the on-screen keyboard, like any browser.</span></div></label>
      <label class="choice"><input type="radio" name="HA_LOGIN_METHOD" value="token">
        <div><b>Long-lived access token</b>
        <span>Paste a token from your Home Assistant profile; the panel logs in by itself.</span></div></label>
      <label class="choice"><input type="radio" name="HA_LOGIN_METHOD" value="trusted">
        <div><b>Trusted network</b>
        <span>No password: Home Assistant must have this panel's address in its trusted_networks.</span></div></label>
      <div id="token-wrap" style="display:none">
        <label for="f-token">Long-lived access token</label>
        <input id="f-token" name="HA_TOKEN" type="password" autocomplete="off">
        <div class="hint">Never shown again once saved.</div>
      </div>
    </div>
""",
    "panel": """
      <div class="toggle" style="margin-top:14px">
        <input id="f-voice" name="VOICE" type="checkbox">
        <label for="f-voice" style="margin:0">Voice assistant</label>
      </div>
      <div id="wake-wrap" style="display:none">
        <label for="f-wake">Wake word</label>
        <input id="f-wake" name="WAKE_WORD" type="text" placeholder="okay_nabu" maxlength="32">
      </div>
      <div class="hint" id="hw-hint" style="display:none"></div>
""",
    "details": """
    <details><summary>MQTT (optional)</summary>
      <div class="card">
        <label for="f-mqtt-host">Broker host</label>
        <input id="f-mqtt-host" name="MQTT_HOST" type="text">
        <label for="f-mqtt-port">Broker port</label>
        <input id="f-mqtt-port" name="MQTT_PORT" type="number" min="0" max="65535" placeholder="1883">
        <label for="f-mqtt-user">User</label>
        <input id="f-mqtt-user" name="MQTT_USER" type="text" autocomplete="off">
        <label for="f-mqtt-pass">Password</label>
        <input id="f-mqtt-pass" name="MQTT_PASSWORD" type="password" autocomplete="off">
      </div>
    </details>
""",
}

JS = {
    "apply": """
    if (fields.VOICE === "on") { $("f-voice").checked = true; $("wake-wrap").style.display = "block"; }
    if (fields.WAKE_WORD) $("f-wake").value = fields.WAKE_WORD;
    if (fields.MQTT_HOST) $("f-mqtt-host").value = fields.MQTT_HOST;
    if (fields.MQTT_PORT) $("f-mqtt-port").value = fields.MQTT_PORT;
    if (fields.MQTT_USER) $("f-mqtt-user").value = fields.MQTT_USER;
    if (fields.MQTT_PASSWORD__set) $("f-mqtt-pass").placeholder = "(already set; leave blank to keep)";
    if (fields.HA_TOKEN__set) $("f-token").placeholder = "(already set; leave blank to keep)";
    if (fields.HA_LOGIN_METHOD) {
      var r = document.querySelector('input[name=HA_LOGIN_METHOD][value="' + fields.HA_LOGIN_METHOD + '"]');
      if (r) { r.checked = true; }
    }
    $("token-wrap").style.display =
      (document.querySelector('input[name=HA_LOGIN_METHOD]:checked') || {}).value === "token" ? "block" : "none";
""",
    "unavailable": """
    var notes = [];
    if (u.VOICE) {
      $("f-voice").checked = false; $("f-voice").disabled = true;
      $("wake-wrap").style.display = "none";
      notes.push("Voice assistant: not available, " + u.VOICE + ".");
    }
    if (u.BT_PROXY) notes.push("Bluetooth proxy: not available, " + u.BT_PROXY + ".");
    if (notes.length) { $("hw-hint").textContent = notes.join(" "); $("hw-hint").style.display = "block"; }
""",
    "payload": """
    payload.HA_LOGIN_METHOD = (document.querySelector('input[name=HA_LOGIN_METHOD]:checked') || {}).value;
    payload.HA_TOKEN = $("f-token").value;
    payload.VOICE = $("f-voice").disabled ? undefined : ($("f-voice").checked ? "on" : "off");
    payload.WAKE_WORD = $("f-voice").disabled ? undefined : $("f-wake").value.trim();
    payload.MQTT_HOST = $("f-mqtt-host").value.trim();
    payload.MQTT_PORT = $("f-mqtt-port").value.trim();
    payload.MQTT_USER = $("f-mqtt-user").value.trim();
    payload.MQTT_PASSWORD = $("f-mqtt-pass").value;
""",
    "init": """
  document.querySelectorAll('input[name=HA_LOGIN_METHOD]').forEach(function(r){
    r.addEventListener("change", function(){
      $("token-wrap").style.display = r.value === "token" && r.checked ? "block" : "none";
    });
  });
  $("f-voice").addEventListener("change", function(){
    $("wake-wrap").style.display = $("f-voice").checked ? "block" : "none";
  });

  $("discover-btn").addEventListener("click", function(){
    setUrlStatus("", "Looking on the network...");
    api("GET", "/setup/api/discover").then(function(r){
      if (r.body && r.body.url) {
        $("f-url").value = r.body.url;
        setUrlStatus("ok", "Found " + r.body.url);
      } else {
        setUrlStatus("warn", "Nothing found automatically; type the URL.");
      }
    });
  });

  $("check-btn").addEventListener("click", function(){
    var url = $("f-url").value.trim();
    if (!url) { setUrlStatus("bad", "enter a URL first"); return; }
    setUrlStatus("", "Checking...");
    api("POST", "/setup/api/check-url", {url: url}).then(function(r){
      var b = r.body || {};
      setUrlStatus(b.ok ? "ok" : "bad", b.message || "unknown error");
    });
  });
""",
}


# ---- Home Assistant discovery (best effort) --------------------------

def discover_ha(timeout=1.8):
    if _ctx.no_zeroconf:
        return None
    try:
        from zeroconf import Zeroconf, ServiceBrowser
    except ImportError:
        return None
    found = {}

    class _Listener:
        def add_service(self, zc, type_, name):
            try:
                info = zc.get_service_info(type_, name, timeout=1200)
            except Exception:
                info = None
            if info is not None:
                found["info"] = info

        def remove_service(self, *a, **k):
            pass

        def update_service(self, *a, **k):
            pass

    zc = None
    try:
        zc = Zeroconf()
        ServiceBrowser(zc, "_home-assistant._tcp.local.", _Listener())
        time.sleep(timeout)
    except Exception:
        return None
    finally:
        if zc is not None:
            try:
                zc.close()
            except Exception:
                pass
    info = found.get("info")
    if info is None:
        return None
    props = {}
    try:
        for k, v in (info.properties or {}).items():
            k = k.decode(errors="replace") if isinstance(k, bytes) else k
            v = v.decode(errors="replace") if isinstance(v, bytes) else v
            props[k] = v
    except Exception:
        pass
    base = props.get("base_url") or props.get("internal_url") or props.get("external_url")
    if base:
        return base
    try:
        addr = None
        if hasattr(info, "parsed_addresses"):
            addrs = info.parsed_addresses()
            addr = addrs[0] if addrs else None
        if not addr and getattr(info, "addresses", None):
            addr = socket.inet_ntoa(info.addresses[0])
        if addr:
            return "http://%s:%s" % (addr, info.port)
    except Exception:
        pass
    return None


# ---- checking a Home Assistant URL from the panel ----------------------

class _SchemeLockedRedirect(urllib.request.HTTPRedirectHandler):
    """Follow at most a few redirects, and never to a scheme other than
    http/https (a plain urllib opener has no handler installed for
    file:/ftp:/etc. anyway, so those already fail -- this also refuses a
    redirect to something like data: or a custom scheme some server might
    offer, and caps the hop count tighter than urllib's default of 10)."""
    max_redirections = 4

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        scheme = urllib.parse.urlsplit(newurl).scheme.lower()
        if scheme not in ("http", "https"):
            raise urllib.error.HTTPError(newurl, code, "refusing a redirect to a non-http(s) URL", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_HA_CHECK_OPENER = urllib.request.build_opener(_SchemeLockedRedirect)


def check_ha_url(url):
    url = (url or "").strip()
    if not re.match(r"^https?://[^\s]+$", url):
        return {"ok": False, "kind": "invalid", "message": "must start with http:// or https://"}
    target = url.rstrip("/") + "/manifest.json"
    req = urllib.request.Request(target, headers={"User-Agent": "tsx-setupd"})
    try:
        with _HA_CHECK_OPENER.open(req, timeout=5) as resp:
            # Use a small cap, whatever Content-Length claims. read() on an
            # HTTPResponse stops at n bytes even if the server keeps sending.
            # So a server cannot trick this code into buffering more.
            body = resp.read(4096)
            looks_like_ha = b"Home Assistant" in body
            msg = "Reachable" if looks_like_ha else \
                "Reachable, but the response did not look like Home Assistant's manifest"
            return {"ok": True, "kind": "ok", "matched_ha": looks_like_ha, "message": msg}
    except ssl.SSLError as e:
        return {"ok": False, "kind": "tls", "message": "TLS error: %s" % e}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {"ok": True, "kind": "ok", "matched_ha": False,
                    "message": "Reachable (HTTP %d); it asked for auth, which is normal" % e.code}
        return {"ok": False, "kind": "http", "message": "HTTP %d from the server" % e.code}
    except urllib.error.URLError as e:
        reason = e.reason
        if isinstance(reason, ssl.SSLError):
            return {"ok": False, "kind": "tls", "message": "TLS error: %s" % reason}
        if isinstance(reason, socket.gaierror):
            return {"ok": False, "kind": "dns", "message": "could not resolve that host name"}
        if isinstance(reason, socket.timeout):
            return {"ok": False, "kind": "timeout", "message": "timed out waiting for a response"}
        if isinstance(reason, ConnectionRefusedError) or "refused" in str(reason).lower():
            return {"ok": False, "kind": "refused", "message": "connection refused: nothing is listening there"}
        return {"ok": False, "kind": "network", "message": str(reason)[:200]}
    except socket.timeout:
        return {"ok": False, "kind": "timeout", "message": "timed out waiting for a response"}
    except ValueError as e:
        return {"ok": False, "kind": "invalid", "message": str(e)[:200]}
    except Exception as e:  # never let a check crash the request handler
        return {"ok": False, "kind": "error", "message": str(e)[:200]}


def _api_discover(handler):
    if not handler._authorized():
        handler._send_json(403, {"error": "not authorized"})
        return
    try:
        url = discover_ha()
    except Exception:
        url = None
    handler._send_json(200, {"url": url})


def _api_check_url(handler, data):
    if not handler._authorized():
        handler._send_json(403, {"error": "not authorized"})
        return
    handler._send_json(200, check_ha_url(str(data.get("url", ""))))


GET_ROUTES = {"/setup/api/discover": _api_discover}
POST_ROUTES = {"/setup/api/check-url": _api_check_url}
