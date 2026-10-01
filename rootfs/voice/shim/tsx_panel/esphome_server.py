#!/usr/bin/env python3
"""tsx-esphome: standalone ESPHome native API server for the panel entities
(PLAN.md section 18), used when VOICE=off. When VOICE=on the same entities
live inside the voice satellite's own process instead (tsx_lva's plugin) so
Home Assistant only ever sees one device -- see docs/ha.md "One Home
Assistant device". Reuses linux_voice_assistant's low-level frame parser
(APIServer) and its zeroconf helper; only the entity set and the message
router are the panel's own (satellite.py's router is voice-specific and, for
two message types, narrower than we need -- see entities.py's module
docstring).
"""

import argparse
import asyncio
import errno
import logging
import sys
import threading
import time
from typing import Iterable, List, Optional

from aioesphomeapi.api_pb2 import (  # pylint: disable=no-name-in-module
    ButtonCommandRequest,
    DeviceInfoRequest,
    DeviceInfoResponse,
    LightCommandRequest,
    ListEntitiesDoneResponse,
    ListEntitiesRequest,
    NumberCommandRequest,
    SelectCommandRequest,
    SubscribeHomeAssistantStatesRequest,
    SubscribeStatesRequest,
    SwitchCommandRequest,
    TextCommandRequest,
    UpdateCommandRequest,
)
from getmac import get_mac_address
from google.protobuf import message
from linux_voice_assistant.api_server import APIServer
from linux_voice_assistant.util import get_default_interface, get_default_ipv4, get_esphome_version, get_version
from linux_voice_assistant.zeroconf import HomeAssistantZeroconf

from . import bluetooth, naming, security
from .backend import PanelBackend
from .device import build_entities, poll

_LOGGER = logging.getLogger("tsx_esphome")

COMMAND_TYPES = (
    ListEntitiesRequest,
    SubscribeHomeAssistantStatesRequest,
    SwitchCommandRequest,
    NumberCommandRequest,
    LightCommandRequest,
    ButtonCommandRequest,
    TextCommandRequest,
    UpdateCommandRequest,
    SelectCommandRequest,
)


class PanelAPIServer(APIServer):
    """One connected Home Assistant client. All connections share the same
    `device` (entities + backend); see connection_made/connection_lost.
    """

    connections: List["PanelAPIServer"] = []
    device = None  # set once in main() before the TCP server starts
    name = "tsx-panel"
    friendly_name = "tsx-panel"
    mac_address = ""
    version = get_version()
    esphome_version = get_esphome_version()

    def __init__(self) -> None:
        # asyncio.create_server's protocol_factory takes no arguments. The
        # device name is fixed (class attribute, set once in main() before
        # the TCP server starts) for every connection.
        super().__init__(PanelAPIServer.name)

    def connection_made(self, transport) -> None:
        super().connection_made(transport)  # security.enforce()'s patch: sets self._tsx_denied
        peer = transport.get_extra_info("peername")
        self._tsx_peer = peer[0] if peer else "?"
        if getattr(self, "_tsx_denied", False):
            return  # already logged (and closed) by security.py; not a served connection
        PanelAPIServer.connections.append(self)
        _LOGGER.info("connection accepted: %s (%s)", self._tsx_peer,
                     "encrypted" if security.encryption_enabled() else "plaintext")

    def connection_lost(self, exc) -> None:
        super().connection_lost(exc)
        bluetooth.PROXY.connection_lost(self)
        if self in PanelAPIServer.connections:
            PanelAPIServer.connections.remove(self)
            _LOGGER.info("connection closed: %s (%s)", getattr(self, "_tsx_peer", "?"),
                         "encrypted" if security.encryption_enabled() else "plaintext")

    @classmethod
    def broadcast(cls, msgs: Iterable[message.Message]) -> None:
        msgs = list(msgs)
        if not msgs:
            return
        for conn in list(cls.connections):
            conn.send_messages(msgs)

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, DeviceInfoRequest):
            # BT_PROXY=on adds the Bluetooth proxy feature flags (bluetooth.py)
            yield bluetooth.PROXY.apply_device_info(DeviceInfoResponse(
                uses_password=False,
                name=self.name,
                friendly_name=self.friendly_name,
                project_name="tsx-mainline.tsx-esphome",
                project_version=self.version,
                esphome_version=self.esphome_version,
                mac_address=self.mac_address,
                manufacturer="Crestron (mainline Linux)",
                model="xx60 panel",
            ))
            return
        if bluetooth.handle_message(self, msg):
            return
        if isinstance(msg, SubscribeStatesRequest):
            for entity in self.device.entities:
                yield from entity.handle_message(SubscribeHomeAssistantStatesRequest())
            return
        if isinstance(msg, COMMAND_TYPES):
            for entity in self.device.entities:
                yield from entity.handle_message(msg)
            if isinstance(msg, ListEntitiesRequest):
                yield ListEntitiesDoneResponse()
            return
        _LOGGER.debug("unhandled message: %s", type(msg))


def _poll_loop(device, interval: float) -> None:
    while True:
        try:
            poll(device, PanelAPIServer.broadcast)
        except Exception:  # noqa: BLE001 - one bad read must not kill the loop
            _LOGGER.warning("poll failed", exc_info=True)
        time.sleep(interval)


async def async_main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", help="Friendly name when PANEL_NAME is unset (default: hostname); see naming.py")
    parser.add_argument("--port", type=int, default=6053)
    parser.add_argument("--network-interface")
    parser.add_argument("--host")
    parser.add_argument("--poll-interval", type=float, default=1.0)
    parser.add_argument("--no-zeroconf", action="store_true",
                        help="do not announce the device over mDNS (a test instance that Home Assistant must not discover)")
    args = parser.parse_args()

    import socket as _socket

    iface = args.network_interface or get_default_interface()
    host_ip = args.host or (get_default_ipv4(iface) if iface else None) or "0.0.0.0"
    mac = get_mac_address(interface=iface) or "00:00:00:00:00:00"
    # same name/friendly name the voice satellite uses (naming.py), so
    # switching VOICE does not rename the device in Home Assistant
    device_name, friendly_name = naming.resolve(mac, args.name or _socket.gethostname())

    PanelAPIServer.name = device_name
    PanelAPIServer.friendly_name = friendly_name
    PanelAPIServer.mac_address = mac

    backend = PanelBackend()
    device = build_entities(None, backend, key_base=0)
    PanelAPIServer.device = device

    try:
        security.enforce()  # HA_API_KEY + HA_ALLOW_FROM (panel.conf); see security.py
    except RuntimeError as err:
        _LOGGER.critical("%s -- not serving the ESPHome API unencrypted", err)
        sys.exit(1)

    loop = asyncio.get_running_loop()
    attempt = 1
    while True:
        try:
            await loop.create_server(PanelAPIServer, host=host_ip, port=args.port)
            break
        except OSError as err:
            if err.errno != errno.EADDRINUSE or attempt >= 15:
                _LOGGER.critical("could not bind %s:%s: %s", host_ip, args.port, err)
                sys.exit(1)
            attempt += 1
            await asyncio.sleep(1)

    threading.Thread(target=_poll_loop, args=(device, args.poll_interval), daemon=True).start()

    if args.no_zeroconf:
        _LOGGER.info("no mDNS announcement (--no-zeroconf)")
    else:
        discovery = HomeAssistantZeroconf(port=args.port, name=device_name, mac_address=mac, host_ip_address=host_ip)
        await discovery.register_server()

    _LOGGER.info("Bluetooth proxy: %s", "off" if not bluetooth.PROXY.enabled() else
                 "on, active connections (BT_ACTIVE)" if bluetooth.PROXY.active() else "on (BT_PROXY)")
    _LOGGER.info("tsx-esphome: %s (%s) listening on %s:%s (%d entities, %s)", device_name, friendly_name, host_ip, args.port,
                 len(device.entities), "encrypted" if security.encryption_enabled() else "plaintext")
    await asyncio.Future()  # run forever


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
