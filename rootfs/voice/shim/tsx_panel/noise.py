"""Server side of the ESPHome native API "noise" transport (encryption).

ESPHome encrypts its native API with Noise_NNpsk0_25519_ChaChaPoly_SHA256
and a 32-byte pre-shared key (`api: encryption: key:` in a device's YAML;
HA_API_KEY in panel.conf here). aioesphomeapi (Home Assistant's client) has
the initiator side; linux-voice-assistant 1.1.15 only has a plaintext
server. This module is the responder, built on py3-cryptography primitives
(X25519, ChaCha20-Poly1305) plus hashlib/hmac, so it needs nothing that
Alpine does not ship. security.py wires it into the shared
linux_voice_assistant.api_server.APIServer base class, so tsx-esphome and
the voice satellite both use it.

Wire format, checked against aioesphomeapi 45.3.1
(aioesphomeapi/_frame_helper/noise.py, packets.py) and ESPHome 2026.9.0
(esphome/components/api/api_frame_helper_noise.cpp, components/noise/):

  frame           0x01, 16-bit big-endian payload length, payload
  client hello    one frame, empty payload today (contents ignored, but
                  they go into the prologue:
                  "NoiseAPIInit" + len16(payload) + payload)
  server hello    one frame: 0x01 (chosen protocol) + node name + 0x00 +
                  MAC (12 lowercase hex digits, no separators) + 0x00
  handshake       one frame each way: 0x00 (status OK) + Noise message.
                  Client: psk, e (+ empty payload). Server: e, ee.
  reject          one frame: 0x01 + reason text, then close. The reason
                  "Handshake MAC failure" is a wire contract: the client
                  turns it into InvalidEncryptionKeyAPIError (wrong key)
  data            one frame per message; payload = ChaCha20-Poly1305 of
                  type16 + len16 + protobuf bytes, nonce = 4 zero bytes +
                  64-bit little-endian counter per direction

A plaintext client (first byte 0x00) gets the reject frame "Bad indicator
byte" like ESPHome sends; aioesphomeapi's plaintext helper sees the 0x01
and raises RequiresEncryptionAPIError ("requires encryption") instead of
waiting for a reply.
"""

import binascii
import hashlib
import hmac
import logging
import struct
from typing import Callable, Iterable, List, Optional, Tuple

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

_LOGGER = logging.getLogger("tsx_panel.noise")

PROTOCOL_NAME = b"Noise_NNpsk0_25519_ChaChaPoly_SHA256"
PROLOGUE_INIT = b"NoiseAPIInit"
FRAME_INDICATOR = 0x01
HANDSHAKE_STATUS_OK = 0x00
HANDSHAKE_STATUS_REJECT = 0x01
MAX_HANDSHAKE_SIZE = 128  # ESPHome noise.h
DHLEN = 32
TAGLEN = 16
MAC_FAILURE = "Handshake MAC failure"

_HELLO, _HANDSHAKE, _DATA, _CLOSED = range(4)


def decode_psk(text: str) -> bytes:
    """Base64 text -> 32 raw bytes (ValueError otherwise), the same check
    aioesphomeapi's _decode_noise_psk makes on the client side."""
    try:
        raw = binascii.a2b_base64(text.strip().encode("ascii"))
    except (binascii.Error, UnicodeEncodeError) as err:
        raise ValueError("not base64") from err
    if len(raw) != 32:
        raise ValueError(f"decodes to {len(raw)} bytes, want 32")
    return raw


def _hkdf(chaining_key: bytes, ikm: bytes, outputs: int) -> List[bytes]:
    """Noise HKDF (spec section 4.3) with HMAC-SHA256."""
    temp = hmac.new(chaining_key, ikm, hashlib.sha256).digest()
    out, prev = [], b""
    for i in range(1, outputs + 1):
        prev = hmac.new(temp, prev + bytes((i,)), hashlib.sha256).digest()
        out.append(prev)
    return out


def _nonce(n: int) -> bytes:
    return b"\x00\x00\x00\x00" + struct.pack("<Q", n)


class CipherState:
    """One direction of the transport (Noise CipherState, ChaChaPoly)."""

    def __init__(self, key: bytes) -> None:
        self._aead = ChaCha20Poly1305(key)
        self.n = 0

    def encrypt(self, ad: bytes, plaintext: bytes) -> bytes:
        out = self._aead.encrypt(_nonce(self.n), plaintext, ad or None)
        self.n += 1
        return out

    def decrypt(self, ad: bytes, ciphertext: bytes) -> bytes:
        out = self._aead.decrypt(_nonce(self.n), ciphertext, ad or None)  # InvalidTag on failure
        self.n += 1
        return out


class ResponderHandshake:
    """Noise_NNpsk0 responder: read  (psk, e), write (e, ee), split."""

    def __init__(self, psk: bytes, prologue: bytes) -> None:
        # protocol name is longer than HASHLEN: h = HASH(name)
        self.h = hashlib.sha256(PROTOCOL_NAME).digest()
        self.ck = self.h
        self.k: Optional[CipherState] = None
        self._psk = psk
        self._re: Optional[bytes] = None
        self._mix_hash(prologue)

    def _mix_hash(self, data: bytes) -> None:
        self.h = hashlib.sha256(self.h + data).digest()

    def _mix_key(self, ikm: bytes) -> None:
        self.ck, temp_k = _hkdf(self.ck, ikm, 2)
        self.k = CipherState(temp_k)

    def _mix_key_and_hash(self, ikm: bytes) -> None:
        self.ck, temp_h, temp_k = _hkdf(self.ck, ikm, 3)
        self._mix_hash(temp_h)
        self.k = CipherState(temp_k)

    def read_message(self, message: bytes) -> bytes:
        """Client -> server: psk, e, encrypted payload. Raises InvalidTag
        on a wrong PSK (the payload's AEAD tag is keyed by it)."""
        if len(message) < DHLEN + TAGLEN:
            raise ValueError(f"handshake message too short ({len(message)} bytes)")
        self._mix_key_and_hash(self._psk)
        self._re = message[:DHLEN]
        self._mix_hash(self._re)
        self._mix_key(self._re)  # "e" in a PSK handshake also does MixKey
        ciphertext = message[DHLEN:]
        payload = self.k.decrypt(self.h, ciphertext)
        self._mix_hash(ciphertext)
        return payload

    def write_message(self, payload: bytes = b"") -> bytes:
        """Server -> client: e, ee, encrypted payload."""
        e = X25519PrivateKey.generate()
        e_pub = e.public_key().public_bytes_raw()
        self._mix_hash(e_pub)
        self._mix_key(e_pub)
        self._mix_key(e.exchange(X25519PublicKey.from_public_bytes(self._re)))
        ciphertext = self.k.encrypt(self.h, payload)
        self._mix_hash(ciphertext)
        return e_pub + ciphertext

    def split(self) -> Tuple[CipherState, CipherState]:
        """(receive, send) for the responder: the initiator sends with the
        first key, the responder with the second."""
        k1, k2 = _hkdf(self.ck, b"", 2)
        return CipherState(k1), CipherState(k2)


class NoiseServerConnection:
    """ESPHome's noise frame helper, server side, for one TCP connection.

    write(list_of_bytes) sends raw bytes, on_packet(msg_type, payload)
    receives each decrypted message, close() drops the connection. All
    three are called from data_received / send_packets, i.e. on the event
    loop thread only (nonces must stay in order).
    """

    def __init__(self, psk: bytes, name: str, mac: str,
                 write: Callable[[List[bytes]], None],
                 on_packet: Callable[[int, bytes], None],
                 close: Callable[[], None],
                 peer: str = "?") -> None:
        self._psk = psk
        self._name = name.encode("utf-8")
        self._mac = mac.replace(":", "").replace("-", "").lower().encode("ascii")
        self._write = write
        self._on_packet = on_packet
        self._close = close
        self._peer = peer
        self._state = _HELLO
        self._buf = b""
        self._hs: Optional[ResponderHandshake] = None
        self._recv: Optional[CipherState] = None
        self._send: Optional[CipherState] = None

    @property
    def ready(self) -> bool:
        return self._state == _DATA

    # --- output -------------------------------------------------------------
    @staticmethod
    def _frame(payload: bytes) -> bytes:
        return bytes((FRAME_INDICATOR, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF)) + payload

    def _reject(self, reason: str) -> None:
        _LOGGER.warning("noise: %s: handshake rejected: %s", self._peer, reason)
        self._write([self._frame(bytes((HANDSHAKE_STATUS_REJECT,)) + reason.encode("ascii"))])
        self._fail()

    def _fail(self) -> None:
        self._state = _CLOSED
        self._buf = b""
        self._close()

    def send_packets(self, packets: Iterable[Tuple[int, bytes]]) -> None:
        if self._state != _DATA:
            return  # nothing may go out before the handshake (or after a failure)
        out = []
        for msg_type, data in packets:
            if len(data) > 0xFFFF - 4 - TAGLEN:
                _LOGGER.error("noise: dropping a %d-byte message (type %d): too big for one frame", len(data), msg_type)
                continue
            plain = struct.pack(">HH", msg_type, len(data)) + data
            out.append(self._frame(self._send.encrypt(b"", plain)))
        if out:
            self._write(out)

    # --- input --------------------------------------------------------------
    def data_received(self, data: bytes) -> None:
        if self._state == _CLOSED:
            return
        self._buf += data
        while self._state != _CLOSED and len(self._buf) >= 3:
            if self._buf[0] != FRAME_INDICATOR:
                if self._state == _DATA:
                    _LOGGER.warning("noise: %s: bad frame indicator %d", self._peer, self._buf[0])
                    self._fail()
                else:
                    # a plaintext client (0x00) lands here: ESPHome answers
                    # with this reject, the client reports "requires encryption"
                    self._reject("Bad indicator byte")
                return
            size = (self._buf[1] << 8) | self._buf[2]
            if self._state != _DATA and size > MAX_HANDSHAKE_SIZE:
                self._reject("Bad handshake packet len")
                return
            if len(self._buf) < 3 + size:
                return  # wait for the rest of the frame
            frame, self._buf = self._buf[3:3 + size], self._buf[3 + size:]
            if self._state == _HELLO:
                self._client_hello(frame)
            elif self._state == _HANDSHAKE:
                self._handshake(frame)
            else:
                self._data(frame)

    def _client_hello(self, frame: bytes) -> None:
        prologue = PROLOGUE_INIT + struct.pack(">H", len(frame)) + frame
        self._write([self._frame(b"\x01" + self._name + b"\x00" + self._mac + b"\x00")])
        self._hs = ResponderHandshake(self._psk, prologue)
        self._state = _HANDSHAKE

    def _handshake(self, frame: bytes) -> None:
        if not frame:
            self._reject("Empty handshake message")
            return
        if frame[0] != HANDSHAKE_STATUS_OK:
            self._reject("Bad handshake error byte")
            return
        try:
            self._hs.read_message(frame[1:])
        except InvalidTag:
            self._reject(MAC_FAILURE)  # wrong key: the client names it so
            return
        except ValueError as err:
            _LOGGER.warning("noise: %s: %s", self._peer, err)
            self._reject("Handshake error")
            return
        try:
            reply = self._hs.write_message()
        except ValueError as err:  # e.g. a low-order client key (all-zero DH)
            _LOGGER.warning("noise: %s: %s", self._peer, err)
            self._reject("Handshake error")
            return
        self._write([self._frame(bytes((HANDSHAKE_STATUS_OK,)) + reply)])
        self._recv, self._send = self._hs.split()
        self._hs = None
        self._state = _DATA

    def _data(self, frame: bytes) -> None:
        try:
            msg = self._recv.decrypt(b"", frame)
        except InvalidTag:
            _LOGGER.warning("noise: %s: decryption failed, closing", self._peer)
            self._fail()
            return
        if len(msg) < 4:
            _LOGGER.warning("noise: %s: message too short (%d bytes)", self._peer, len(msg))
            self._fail()
            return
        msg_type, data_len = struct.unpack(">HH", msg[:4])
        if data_len > len(msg) - 4:
            _LOGGER.warning("noise: %s: bad data length %d > %d", self._peer, data_len, len(msg) - 4)
            self._fail()
            return
        self._on_packet(msg_type, msg[4:4 + data_len])
