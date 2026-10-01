"""Generic ESPHomeEntity subclasses for the panel device.

linux_voice_assistant.entity already has Light, Switch (as two fixed
entities), Number/Select (as one fixed entity), Event and MediaPlayer classes
tied to voice-satellite specifics. These are the same shapes but generic and
reusable, plus the three read-only "diagnostic" types (sensor, binary_sensor,
text_sensor) and the two LVA does not need at all (button, text), and a
generic select (screen orientation).

Each entity is deliberately dumb: it stores get()/set() callables and only
knows how to answer ListEntitiesRequest / SubscribeHomeAssistantStatesRequest
/ its own *CommandRequest, exactly like linux_voice_assistant.entity's
classes. device.py wires them to a PanelBackend.

IMPORTANT (see satellite.py's handle_message, linux-voice-assistant 1.1.15):
the voice satellite's message router only forwards
(ListEntitiesRequest, SubscribeHomeAssistantStatesRequest,
MediaPlayerCommandRequest, SwitchCommandRequest, NumberCommandRequest,
SelectCommandRequest, LightCommandRequest) to state.entities -- NOT
ButtonCommandRequest or TextCommandRequest. tsx_lva/__init__.py's plugin
patches VoiceSatelliteProtocol.handle_message to add those two; the
standalone esphome_server.py handles the full set itself. If a future LVA
version adds Button/Text to that tuple, the patch becomes a harmless no-op
duplicate dispatch (entities are idempotent: they only act on msg.key ==
self.key).
"""

import logging
from collections.abc import Iterable
from typing import Callable, List, Optional

# pylint: disable=no-name-in-module
from aioesphomeapi.api_pb2 import (
    BinarySensorStateResponse,
    ButtonCommandRequest,
    EventResponse,
    ListEntitiesBinarySensorResponse,
    ListEntitiesButtonResponse,
    ListEntitiesEventResponse,
    ListEntitiesNumberResponse,
    ListEntitiesRequest,
    ListEntitiesSelectResponse,
    ListEntitiesSensorResponse,
    ListEntitiesSwitchResponse,
    ListEntitiesTextResponse,
    ListEntitiesTextSensorResponse,
    ListEntitiesUpdateResponse,
    NumberCommandRequest,
    NumberStateResponse,
    SelectCommandRequest,
    SelectStateResponse,
    SensorStateResponse,
    SubscribeHomeAssistantStatesRequest,
    SwitchCommandRequest,
    SwitchStateResponse,
    TextCommandRequest,
    TextSensorStateResponse,
    TextStateResponse,
    UpdateCommand,
    UpdateCommandRequest,
    UpdateStateResponse,
)
from google.protobuf import message

from linux_voice_assistant.entity import ESPHomeEntity  # noqa: F401  (re-exported)

_LOGGER = logging.getLogger("tsx_panel.entities")


class SwitchEntity(ESPHomeEntity):
    """A generic on/off switch (screen, auto-brightness, ...)."""

    def __init__(self, server, key, name, object_id, get_state, set_state, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state, self._set_state, self.icon = get_state, set_state, icon
        self._state = False
        try:
            self._state = bool(get_state())
        except Exception:  # noqa: BLE001 - hardware not ready yet is not fatal
            _LOGGER.debug("%s: initial read failed", name, exc_info=True)

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, SwitchCommandRequest) and msg.key == self.key:
            self._state = bool(msg.state)
            try:
                self._set_state(self._state)
            except Exception:  # noqa: BLE001
                _LOGGER.warning("%s: set failed", self.name, exc_info=True)
            yield SwitchStateResponse(key=self.key, state=self._state)
        elif isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesSwitchResponse(
                object_id=self.object_id, key=self.key, name=self.name, icon=self.icon,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            self._state = bool(self._get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        return SwitchStateResponse(key=self.key, state=self._state)

    def poll(self):
        """Return the current state response if it should be (re)published."""
        return self._state_msg()


class NumberEntity(ESPHomeEntity):
    """A generic slider (backlight, volume, ...)."""

    def __init__(self, server, key, name, object_id, get_state, set_state,
                 min_value=0.0, max_value=100.0, step=1.0, unit="", icon="", mode=0):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state, self._set_state = get_state, set_state
        self.min_value, self.max_value, self.step, self.unit, self.icon = min_value, max_value, step, unit, icon
        self.mode = mode  # NumberMode: 0 auto, 1 box, 2 slider
        self._state = min_value
        try:
            self._state = float(get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: initial read failed", name, exc_info=True)

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, NumberCommandRequest) and msg.key == self.key:
            self._state = float(msg.state)
            try:
                self._set_state(self._state)
            except Exception:  # noqa: BLE001
                _LOGGER.warning("%s: set failed", self.name, exc_info=True)
            yield NumberStateResponse(key=self.key, state=self._state)
        elif isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesNumberResponse(
                object_id=self.object_id, key=self.key, name=self.name,
                min_value=self.min_value, max_value=self.max_value, step=self.step,
                unit_of_measurement=self.unit, icon=self.icon, mode=self.mode,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            self._state = float(self._get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        return NumberStateResponse(key=self.key, state=self._state)

    def poll(self):
        return self._state_msg()


class TextEntity(ESPHomeEntity):
    """A generic free-text field (kiosk URL)."""

    def __init__(self, server, key, name, object_id, get_state, set_state, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state, self._set_state, self.icon = get_state, set_state, icon
        self._state = ""
        try:
            self._state = str(get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: initial read failed", name, exc_info=True)

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, TextCommandRequest) and msg.key == self.key:
            self._state = str(msg.state)
            try:
                self._set_state(self._state)
            except Exception:  # noqa: BLE001
                _LOGGER.warning("%s: set failed", self.name, exc_info=True)
            yield TextStateResponse(key=self.key, state=self._state)
        elif isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesTextResponse(
                object_id=self.object_id, key=self.key, name=self.name, icon=self.icon,
                min_length=0, max_length=255,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            self._state = str(self._get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        return TextStateResponse(key=self.key, state=self._state)

    def poll(self):
        return self._state_msg()


class SelectEntity(ESPHomeEntity):
    """A generic choice from a fixed list (screen orientation). A value
    outside `options` is refused (logged, the state is re-sent)."""

    def __init__(self, server, key, name, object_id, options, get_state, set_state, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self.options = list(options)
        self._get_state, self._set_state, self.icon = get_state, set_state, icon
        self._state = self.options[0] if self.options else ""
        try:
            self._state = str(get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: initial read failed", name, exc_info=True)

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, SelectCommandRequest) and msg.key == self.key:
            if msg.state in self.options:
                self._state = str(msg.state)
                try:
                    self._set_state(self._state)
                except Exception:  # noqa: BLE001
                    _LOGGER.warning("%s: set failed", self.name, exc_info=True)
            else:
                _LOGGER.warning("%s: %r is not one of %s", self.name, msg.state, self.options)
            yield SelectStateResponse(key=self.key, state=self._state)
        elif isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesSelectResponse(
                object_id=self.object_id, key=self.key, name=self.name, icon=self.icon,
                options=self.options,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            self._state = str(self._get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        return SelectStateResponse(key=self.key, state=self._state)

    def poll(self):
        return self._state_msg()


class ButtonEntity(ESPHomeEntity):
    """A generic momentary action (reload page, reboot)."""

    def __init__(self, server, key, name, object_id, press, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._press, self.icon = press, icon

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, ButtonCommandRequest) and msg.key == self.key:
            try:
                self._press()
            except Exception:  # noqa: BLE001
                _LOGGER.warning("%s: press failed", self.name, exc_info=True)
            return
        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesButtonResponse(
                object_id=self.object_id, key=self.key, name=self.name, icon=self.icon,
            )


ENTITY_CATEGORY_DIAGNOSTIC = 2


class SensorEntity(ESPHomeEntity):
    """A generic read-only numeric sensor (lux, CPU temp, uptime). A
    get_state that returns None means "no value" (the distance sensor with
    no target): Home Assistant shows it as unknown."""

    def __init__(self, server, key, name, object_id, get_state, unit="",
                 device_class="", accuracy_decimals=0, icon="", entity_category=0):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state = get_state
        self.unit, self.device_class, self.accuracy_decimals, self.icon = unit, device_class, accuracy_decimals, icon
        self.entity_category = entity_category
        self._state = 0.0

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesSensorResponse(
                object_id=self.object_id, key=self.key, name=self.name,
                unit_of_measurement=self.unit, device_class=self.device_class,
                accuracy_decimals=self.accuracy_decimals, icon=self.icon, state_class=1,  # STATE_CLASS_MEASUREMENT
                entity_category=self.entity_category,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            value = self._get_state()
            self._state = None if value is None else float(value)
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        if self._state is None:
            return SensorStateResponse(key=self.key, missing_state=True)
        return SensorStateResponse(key=self.key, state=self._state)

    def poll(self):
        return self._state_msg()


class TextSensorEntity(ESPHomeEntity):
    """A generic read-only text sensor (IP address)."""

    def __init__(self, server, key, name, object_id, get_state, icon="", entity_category=0):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state, self.icon = get_state, icon
        self.entity_category = entity_category
        self._state = ""

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesTextSensorResponse(
                object_id=self.object_id, key=self.key, name=self.name, icon=self.icon,
                entity_category=self.entity_category,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            self._state = str(self._get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        return TextSensorStateResponse(key=self.key, state=self._state)

    def poll(self):
        return self._state_msg()


class BinarySensorEntity(ESPHomeEntity):
    """A generic read-only on/off sensor ("touched recently": tsx-idled's
    last-input timestamp, see backend.get_touched_recently)."""

    def __init__(self, server, key, name, object_id, get_state, device_class="", icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state, self.device_class, self.icon = get_state, device_class, icon
        self._state = False

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesBinarySensorResponse(
                object_id=self.object_id, key=self.key, name=self.name,
                device_class=self.device_class, icon=self.icon,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            self._state = bool(self._get_state())
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
        return BinarySensorStateResponse(key=self.key, state=self._state)

    def poll(self):
        return self._state_msg()


class UpdateEntity(ESPHomeEntity):
    """tsx-autoupdate's status (docs/rootfs.md "Updates") as a generic HA `update`
    entity: the same status tsx-mqtt already publishes
    (docs/ha.md "Update entity"), now also on the ESPHome device. get_state
    returns tsx-autoupdate's own update-ha-state.json shape --
    installed_version/latest_version/title/release_summary/in_progress (see
    backend.py's get_update_status) -- with no numeric progress field, so
    has_progress is always False. UPDATE_COMMAND_UPDATE runs the install
    (backend.py's install_update -> the same "tsx-autoupdate now" tsx-mqtt's
    Install button runs, through tsx-panelctl when unprivileged);
    UPDATE_COMMAND_CHECK/NONE are not acted on (tsx-autoupdate checks on its
    own schedule).
    """

    def __init__(self, server, key, name, object_id, get_state, install, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self._get_state, self._install, self.icon = get_state, install, icon
        self._state = {}

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, UpdateCommandRequest) and msg.key == self.key:
            if msg.command == UpdateCommand.UPDATE_COMMAND_UPDATE:
                try:
                    self._install()
                except Exception:  # noqa: BLE001
                    _LOGGER.warning("%s: install failed", self.name, exc_info=True)
            yield self._state_msg()
        elif isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesUpdateResponse(
                object_id=self.object_id, key=self.key, name=self.name, icon=self.icon,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield self._state_msg()

    def _state_msg(self):
        try:
            st = self._get_state() or {}
        except Exception:  # noqa: BLE001
            _LOGGER.debug("%s: read failed", self.name, exc_info=True)
            st = {}
        self._state = st
        current = str(st.get("installed_version") or "")
        latest = str(st.get("latest_version") or current)
        return UpdateStateResponse(
            key=self.key,
            missing_state=current in ("", "unknown"),
            in_progress=bool(st.get("in_progress")),
            has_progress=False,
            current_version=current,
            latest_version=latest,
            title=str(st.get("title") or ""),
            release_summary=str(st.get("release_summary") or ""),
        )

    def poll(self):
        return self._state_msg()


class KeyEventEntity(ESPHomeEntity):
    """One front-panel key as an HA `event` entity (press/long/double), the
    same shape as linux_voice_assistant.entity.ButtonEventSensorEntity but
    with our own event_types (tsx-buttons only ever reports short/long/hold;
    "double" is listed for parity with the MQTT bridge's evt_typ but tsx-buttons
    does not detect double-press today -- see docs/ha.md open questions).
    """

    def __init__(self, server, key, name, object_id):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self.event_types = ["press", "long", "double"]
        self._current: Optional[str] = None

    def fire(self, event_type: str) -> Optional[EventResponse]:
        if event_type not in self.event_types:
            return None
        self._current = event_type
        return EventResponse(key=self.key, event_type=event_type)

    def handle_message(self, msg: message.Message) -> Iterable[message.Message]:
        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesEventResponse(
                object_id=self.object_id, key=self.key, name=self.name,
                device_class="button", event_types=self.event_types,
            )
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            if self._current:
                yield EventResponse(key=self.key, event_type=self._current)
