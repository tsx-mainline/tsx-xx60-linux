"""Access control for the ESPHome API: encryption (HA_API_KEY) and a peer
allow-list (HA_ALLOW_FROM), both from panel.conf.

HA_API_KEY: ESPHome's own "noise" encryption (noise.py), the same thing
as `api: encryption: key:` on a real ESPHome device. With a key, every
connection must complete the Noise handshake with that key before any
message is parsed; a plaintext client is refused with ESPHome's "requires
encryption" answer, a client with the wrong key with "Invalid encryption
key". Empty (the default) keeps the original zero-config plaintext API.

HA_ALLOW_FROM: defence in depth on top of (or, without a key, instead of)
encryption. Empty (the default) = any peer; otherwise any other peer's
connection is closed immediately.

Both are enforced in exactly one place for both front ends: enforce()
patches linux_voice_assistant.api_server.APIServer (connection_made,
data_received, send_messages), the base class BOTH tsx-esphome's
PanelAPIServer and the voice satellite's VoiceSatelliteProtocol subclass --
see esphome_server.py's and tsx_lva/__init__.py's calls to enforce(). A
denied peer's connection is closed immediately and a `_tsx_denied` flag
makes the patched data_received a no-op for it too, so a few bytes that
raced in before the close() completes are never parsed/dispatched either.

The key comes from /run/tsx/esphome.key (tsx-config apply writes it, mode
640 group kiosk: the voice satellite runs as kiosk and cannot read
panel.conf, mode 600). If that file exists but cannot be read or holds a
bad key, enforce() raises: the server must not silently fall back to
plaintext.
"""

import ipaddress
import logging
import os
import threading

from . import noise

_LOGGER = logging.getLogger("tsx_panel.security")
_PATCHED = False
_PSK = None  # 32 raw bytes once enforce() found a key
NOISE_TXT = "Noise_NNpsk0_25519_ChaChaPoly_SHA256"


def _run_conf_value(key):
    path = os.environ.get("TSX_ESPHOME_RUN_CONF", "/run/tsx/esphome.conf")
    value = ""
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            for line in fobj:
                line = line.strip()
                if line.startswith(key + "="):
                    value = line.split("=", 1)[1].strip('"')
    except OSError:
        pass
    return value


def allow_list():
    """[ip_network, ...] from HA_ALLOW_FROM, via the same world-readable
    override tsx_lva/__init__.py's _ha_transport() reads (panel.conf itself
    is mode 600; the voice satellite runs as kiosk and cannot open it).
    Test override: TSX_HA_ALLOW_FROM. Invalid entries are ignored (logged),
    not fatal -- tsx-config's own validator is the first line of defense,
    this is the authoritative one.
    """
    override = os.environ.get("TSX_HA_ALLOW_FROM")
    raw = override if override is not None else _run_conf_value("ALLOW_FROM")
    nets = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            nets.append(ipaddress.ip_network(item, strict=False))
        except ValueError:
            _LOGGER.warning("HA_ALLOW_FROM: ignoring invalid entry %r", item)
    return nets


def peer_allowed(host) -> bool:
    nets = allow_list()
    if not nets:
        return True  # empty = allow any (the zero-config default)
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(addr in net for net in nets)


def load_psk():
    """32 raw bytes, or None for plaintext. Test override: TSX_HA_API_KEY
    (the base64 text; empty = no key). Raises RuntimeError when a key is
    configured but unusable (fail closed)."""
    override = os.environ.get("TSX_HA_API_KEY")
    if override is not None:
        text, where = override, "TSX_HA_API_KEY"
    else:
        path = os.environ.get("TSX_ESPHOME_KEY_FILE", "/run/tsx/esphome.key")
        if not os.path.lexists(path):
            return None
        try:
            with open(path, "r", encoding="ascii") as fobj:
                text = fobj.read()
        except (OSError, UnicodeDecodeError) as err:
            raise RuntimeError(f"HA_API_KEY: cannot read {path}: {err}") from err
        where = path
    if not text.strip():
        return None
    try:
        return noise.decode_psk(text)
    except ValueError as err:
        raise RuntimeError(f"HA_API_KEY in {where} is not a base64 32-byte key: {err}") from err


def _mac_of(server):
    """The MAC the server hello carries: PanelAPIServer.mac_address, or the
    voice satellite's state.mac_address."""
    mac = getattr(server, "mac_address", None)
    if not mac:
        mac = getattr(getattr(server, "state", None), "mac_address", None)
    return mac or ""


def encryption_enabled() -> bool:
    return _PSK is not None


def enforce() -> None:
    """Idempotent per process: safe to call from both tsx-esphome and the
    voice satellite plugin (tsx_lva always calls it; esphome_server.py
    always calls it too), and safe to call more than once. Raises
    RuntimeError if a key is configured but unusable.
    """
    global _PATCHED, _PSK  # noqa: PLW0603
    if _PATCHED:
        return
    psk = load_psk()
    _PATCHED = True
    _PSK = psk
    _LOGGER.info("tsx_panel: ESPHome API %s", "encrypted (noise, HA_API_KEY)" if psk else "NOT encrypted (no HA_API_KEY)")

    from linux_voice_assistant import api_server  # noqa: WPS433

    APIServer = api_server.APIServer
    to_type = api_server.PROTO_TO_MESSAGE_TYPE
    orig_connection_made = APIServer.connection_made
    orig_data_received = APIServer.data_received
    orig_send_messages = APIServer.send_messages

    def connection_made(self, transport):
        orig_connection_made(self, transport)
        self._tsx_denied = False  # pylint: disable=protected-access
        self._tsx_noise = None  # pylint: disable=protected-access
        self._tsx_first = True  # pylint: disable=protected-access
        peer = transport.get_extra_info("peername")
        host = peer[0] if peer else None
        if host is not None and not peer_allowed(host):
            _LOGGER.warning("tsx_panel: closing connection from %s (not in HA_ALLOW_FROM)", host)
            self._tsx_denied = True  # pylint: disable=protected-access
            transport.close()
            return
        if _PSK is not None:
            self._tsx_noise = noise.NoiseServerConnection(  # pylint: disable=protected-access
                _PSK, self.name, _mac_of(self),
                write=transport.writelines,
                on_packet=lambda msg_type, payload: self.process_packet(msg_type, payload),
                close=transport.close,
                peer=str(host))

    def data_received(self, data):
        if getattr(self, "_tsx_denied", False):
            return
        conn = getattr(self, "_tsx_noise", None)
        if conn is not None:
            conn.data_received(bytes(data))
            return
        if getattr(self, "_tsx_first", False) and data:
            self._tsx_first = False  # pylint: disable=protected-access
            if data[0] == noise.FRAME_INDICATOR:
                # an encrypting client, no key here: answer like an ESPHome
                # device without encryption (the client then reports "the
                # device is using plaintext protocol") instead of hanging
                _LOGGER.warning("tsx_panel: encrypted client but no HA_API_KEY set: closing")
                if self._transport is not None:  # pylint: disable=protected-access
                    self._transport.write(b"\x00Bad indicator byte")  # pylint: disable=protected-access
                    self._transport.close()  # pylint: disable=protected-access
                self._tsx_denied = True  # pylint: disable=protected-access
                return
        orig_data_received(self, data)

    def send_messages(self, msgs):
        conn = getattr(self, "_tsx_noise", None)
        if conn is None:
            return orig_send_messages(self, msgs)
        if self._writelines is None or not msgs:  # pylint: disable=protected-access
            return None
        msgs = list(msgs)
        loop = self._loop  # pylint: disable=protected-access
        if loop is not None and self._loop_thread_id is not None and threading.get_ident() != self._loop_thread_id:  # pylint: disable=protected-access
            # encrypt on the loop thread only: the nonce counter must match
            # the order frames reach the socket
            loop.call_soon_threadsafe(send_messages, self, msgs)
            return None
        conn.send_packets([(to_type[msg.__class__], msg.SerializeToString()) for msg in msgs])
        return None

    APIServer.connection_made = connection_made
    APIServer.data_received = data_received
    APIServer.send_messages = send_messages

    _patch_zeroconf()


def _patch_zeroconf():
    """Advertise encryption in the mDNS TXT record like ESPHome does
    (`api_encryption=Noise_NNpsk0_25519_ChaChaPoly_SHA256`): Home Assistant's
    discovery flow then asks for the key up front. Plus `friendly_name`
    (naming.py), which HA uses as the discovered device's title."""
    from linux_voice_assistant import zeroconf as lva_zeroconf  # noqa: WPS433

    from . import naming  # noqa: WPS433

    orig_info = lva_zeroconf.AsyncServiceInfo

    def service_info(*args, properties=None, **kwargs):
        props = dict(properties or {})
        if _PSK is not None:
            props["api_encryption"] = NOISE_TXT
        if naming.FRIENDLY_NAME:
            props["friendly_name"] = naming.FRIENDLY_NAME
        return orig_info(*args, properties=props, **kwargs)

    lva_zeroconf.AsyncServiceInfo = service_info
