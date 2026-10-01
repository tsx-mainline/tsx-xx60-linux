"""Builds the panel's Home Assistant entity list
from a PanelBackend, and polls it for state changes to push to Home
Assistant. Shared by tsx-esphome (standalone) and the voice satellite's
plugin (tsx_lva) so there is exactly one entity list, one poll loop.

LEDLightEntity (light bar, key LEDs) is reused as-is from
linux_voice_assistant.entity: it already implements the full RGB/brightness/
effects Light protocol. It only tracks state HA has told it about (a
LightCommandRequest); it does not read hardware back on its own. This module
closes that loop: on_changed pushes an HA change to the backend, and
poll_and_broadcast() pulls the backend's own state (which can also change
locally -- a front-key press, the boot color, tsx-idled's screen-blank
dimming) back into the entity and broadcasts it when it moves.
"""

import logging
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from linux_voice_assistant.entity import LEDLightEntity

from .backend import PanelBackend
from .entities import (
    ENTITY_CATEGORY_DIAGNOSTIC,
    BinarySensorEntity,
    ButtonEntity,
    KeyEventEntity,
    NumberEntity,
    SelectEntity,
    SensorEntity,
    SwitchEntity,
    TextEntity,
    TextSensorEntity,
    UpdateEntity,
)

_LOGGER = logging.getLogger("tsx_panel.device")

LEDBAR_EFFECTS = ["None", "Pulse"]
POLL_INTERVAL = 1.0
PULSE_PERIOD = 2.0  # seconds per breath, 20%..100% of the set brightness


class KeyCounter:
    def __init__(self, start: int):
        self._next = start

    def __call__(self) -> int:
        value = self._next
        self._next += 1
        return value


@dataclass
class PanelDevice:
    backend: PanelBackend
    entities: List
    ledbar: Optional[LEDLightEntity]
    keypad: Optional[LEDLightEntity]
    screen: SwitchEntity
    backlight: NumberEntity
    blank_timeout: NumberEntity
    orientation: SelectEntity
    als_auto: Optional[SwitchEntity]
    illuminance: Optional[SensorEntity]
    volume: Optional[NumberEntity]
    verbose_boot: SwitchEntity
    kiosk_url: TextEntity
    reload_button: ButtonEntity
    reboot_button: ButtonEntity
    cpu_temp: SensorEntity
    uptime: SensorEntity
    ip_address: TextSensorEntity
    touched_recently: BinarySensorEntity
    update: UpdateEntity
    keys: List[KeyEventEntity]
    emmc_life_a: Optional[SensorEntity] = None
    emmc_life_b: Optional[SensorEntity] = None
    emmc_eol: Optional[TextSensorEntity] = None
    _last_ledbar: Optional[tuple] = field(default=None, repr=False)
    _last_keypad: Optional[tuple] = field(default=None, repr=False)
    _pulse_since: float = field(default=0.0, repr=False)


def build_entities(server, backend: PanelBackend, key_base: int = 0) -> PanelDevice:
    """server: the connection/protocol instance entities are constructed
    against (ESPHomeEntity.server; our entities never call back into it).
    key_base: the next free entity key -- 0 for the standalone server,
    len(state.entities) when appending to the voice satellite's own list, so
    keys never collide with its built-in entities.
    """
    next_key = KeyCounter(key_base)
    entities: List = []

    # ---- LED bar (RGB light, + a cheap software "Pulse" effect) ------------
    # only where the panel has one (backend.ledbar_present)
    ledbar = None
    if backend.ledbar_present():
        on, bri, r, g, b = backend.get_ledbar()
        ledbar = LEDLightEntity(
            server, next_key(), "LED bar", "ledbar",
            effects=LEDBAR_EFFECTS, supports_rgb=True, supports_brightness=True,
            icon="mdi:led-strip-variant",
        )
        ledbar.is_on, ledbar.brightness = on, bri / 255.0
        if r or g or b:
            ledbar.red, ledbar.green, ledbar.blue = r / 255.0, g / 255.0, b / 255.0

        def ledbar_changed(_ledbar=ledbar):
            backend.set_ledbar(
                _ledbar.is_on, round(_ledbar.brightness * 255),
                round(_ledbar.red * 255), round(_ledbar.green * 255), round(_ledbar.blue * 255),
            )

        ledbar.update_on_changed(ledbar_changed)
        entities.append(ledbar)

    # ---- key LEDs (brightness-only light; only with front keys) --------------
    keypad = None
    if backend.keypad_present():
        kp_on, kp_bri = backend.get_keypad()
        keypad = LEDLightEntity(
            server, next_key(), "Key LEDs", "keypad",
            supports_rgb=False, supports_brightness=True, icon="mdi:gesture-tap-button",
        )
        keypad.is_on, keypad.brightness = kp_on, kp_bri / 255.0

        def keypad_changed(_keypad=keypad):
            backend.set_keypad(_keypad.is_on, round(_keypad.brightness * 255))

        keypad.update_on_changed(keypad_changed)
        entities.append(keypad)

    # ---- screen + backlight --------------------------------------------------
    screen = SwitchEntity(
        server, next_key(), "Screen", "screen",
        get_state=lambda: backend.get_screen()[0],
        set_state=backend.set_screen, icon="mdi:monitor",
    )
    entities.append(screen)

    def get_backlight():
        _, level = backend.get_screen()
        return level if level is not None else 0

    backlight = NumberEntity(
        server, next_key(), "Backlight", "backlight",
        get_state=get_backlight, set_state=backend.set_backlight,
        min_value=1, max_value=backend.get_backlight_max(), step=1, icon="mdi:brightness-6",
    )
    entities.append(backlight)
    # seconds without input before the screen goes dark, 0 = never. Persisted
    # in panel.conf (BLANK_TIMEOUT) and applied by tsx-idled at once
    blank_timeout = NumberEntity(
        server, next_key(), "Blank timeout", "blank_timeout",
        get_state=backend.get_blank_timeout, set_state=backend.set_blank_timeout,
        min_value=0, max_value=86400, step=10, unit="s", icon="mdi:timer-outline", mode=1,
    )
    entities.append(blank_timeout)
    # screen orientation (panel.conf ORIENTATION): the kiosk turns at once,
    # the boot splash from the next boot on
    orientation = SelectEntity(
        server, next_key(), "Orientation", "orientation", options=backend.ORIENTATIONS,
        get_state=backend.get_orientation, set_state=backend.set_orientation, icon="mdi:screen-rotation",
    )
    entities.append(orientation)

    # ---- ambient light / auto-brightness (only with als.conf, like tsx-mqtt) --
    als_auto = illuminance = None
    if backend.als_present():
        illuminance = SensorEntity(
            server, next_key(), "Illuminance", "illuminance",
            get_state=backend.get_lux, unit="lx", device_class="illuminance",
        )
        entities.append(illuminance)
        als_auto = SwitchEntity(
            server, next_key(), "Auto brightness", "als_auto",
            get_state=backend.get_als_auto, set_state=backend.set_als_auto, icon="mdi:brightness-auto",
        )
        entities.append(als_auto)

    # ---- volume (only with the TSW1060 sound card, like tsx-mqtt) -------------
    volume = None
    if backend.sound_card_present():
        volume = NumberEntity(
            server, next_key(), "Volume", "volume",
            get_state=backend.get_volume, set_state=backend.set_volume,
            min_value=0, max_value=100, step=1, unit="%", icon="mdi:volume-high",
        )
        entities.append(volume)

    # ---- verbose boot (BOOT_VERBOSE, panel.conf) ------------------------------
    verbose_boot = SwitchEntity(
        server, next_key(), "Verbose boot", "verbose_boot",
        get_state=backend.get_verbose_boot, set_state=backend.set_verbose_boot, icon="mdi:console-line",
    )
    entities.append(verbose_boot)

    # ---- kiosk: URL (persists through tsx-config), reload, reboot -------------
    kiosk_url = TextEntity(
        server, next_key(), "Kiosk URL", "kiosk_url",
        get_state=backend.get_kiosk_url, set_state=backend.set_kiosk_url, icon="mdi:web",
    )
    entities.append(kiosk_url)
    reload_button = ButtonEntity(
        server, next_key(), "Reload page", "reload_page", press=backend.reload_page, icon="mdi:refresh",
    )
    entities.append(reload_button)
    reboot_button = ButtonEntity(
        server, next_key(), "Reboot", "reboot", press=backend.reboot, icon="mdi:restart",
    )
    entities.append(reboot_button)

    # ---- sensors --------------------------------------------------------------
    cpu_temp = SensorEntity(
        server, next_key(), "CPU temperature", "cpu_temp",
        get_state=backend.get_cpu_temp, unit="°C", device_class="temperature", accuracy_decimals=1,
    )
    entities.append(cpu_temp)
    uptime = SensorEntity(
        server, next_key(), "Uptime", "uptime",
        get_state=backend.get_uptime, unit="s", device_class="duration", icon="mdi:clock-outline",
    )
    entities.append(uptime)
    ip_address = TextSensorEntity(
        server, next_key(), "IP address", "ip_address", get_state=backend.get_ip, icon="mdi:ip-network",
    )
    entities.append(ip_address)
    touched_recently = BinarySensorEntity(
        server, next_key(), "Touched recently", "touched_recently",
        get_state=backend.get_touched_recently, device_class="motion", icon="mdi:gesture-tap",
    )
    entities.append(touched_recently)

    # ---- update (tsx-autoupdate status. docs/rootfs.md "Updates") -------------------
    update = UpdateEntity(
        server, next_key(), "Update", "update",
        get_state=backend.get_update_status, install=backend.install_update, icon="mdi:package-up",
    )
    entities.append(update)

    # ---- eMMC health: only where the eMMC reports it (tsx-emmc-state writes the file; docs/ha.md "Sensors")
    emmc_life_a = emmc_life_b = emmc_eol = None
    if backend.emmc_present():
        emmc_life_a = SensorEntity(
            server, next_key(), "eMMC life used A", "emmc_life_a",
            get_state=lambda: backend.get_emmc_life("a"), unit="%", icon="mdi:harddisk",
            entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
        )
        emmc_life_b = SensorEntity(
            server, next_key(), "eMMC life used B", "emmc_life_b",
            get_state=lambda: backend.get_emmc_life("b"), unit="%", icon="mdi:harddisk",
            entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
        )
        emmc_eol = TextSensorEntity(
            server, next_key(), "eMMC end of life", "emmc_eol",
            get_state=backend.get_emmc_eol, icon="mdi:harddisk-remove", entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
        )
        entities += [emmc_life_a, emmc_life_b, emmc_eol]

    # ---- front-key events (one HA `event` entity per key, like tsx-mqtt) -------
    keys = []
    for name in backend.key_names():
        key_entity = KeyEventEntity(server, next_key(), f"Key {name}", f"key_{name}")
        entities.append(key_entity)
        keys.append(key_entity)

    return PanelDevice(
        backend=backend, entities=entities, ledbar=ledbar, keypad=keypad, screen=screen,
        backlight=backlight, blank_timeout=blank_timeout, als_auto=als_auto, illuminance=illuminance, volume=volume,
        verbose_boot=verbose_boot, kiosk_url=kiosk_url, reload_button=reload_button, reboot_button=reboot_button,
        cpu_temp=cpu_temp, uptime=uptime, ip_address=ip_address, touched_recently=touched_recently,
        update=update, keys=keys, orientation=orientation, _pulse_since=time.time(),
        emmc_life_a=emmc_life_a, emmc_life_b=emmc_life_b, emmc_eol=emmc_eol,
    )


def _light_tuple(light: LEDLightEntity) -> tuple:
    return (light.is_on, round(light.brightness, 3), round(light.red, 3), round(light.green, 3), round(light.blue, 3))


def poll(device: PanelDevice, broadcast: Callable[[list], None]) -> None:
    """Call about once a second. Pushes to `broadcast(messages)` only the
    entities whose value moved (the same change-only discipline tsx-mqtt
    uses), plus any new front-key press as an Event.
    """
    backend = device.backend
    msgs = []

    # LED bar: apply the "Pulse" software effect (cheap: just breathes the
    # brightness the user set. No new hardware/firmware support needed),
    # else read back the hardware in case something else changed it (a
    # front-key action, the boot color, tsx-idled's blank dimming).
    if device.ledbar is not None and device.ledbar.effect == "Pulse" and device.ledbar.is_on:
        phase = (time.time() % PULSE_PERIOD) / PULSE_PERIOD
        level = 0.2 + 0.8 * abs(1 - 2 * phase)  # 20%..100%..20% triangle wave
        peak_bri = device._last_ledbar[1] if device._last_ledbar else device.ledbar.brightness
        backend.set_ledbar(True, round(peak_bri * 255 * level),
                            round(device.ledbar.red * 255), round(device.ledbar.green * 255), round(device.ledbar.blue * 255))
    elif device.ledbar is not None:
        on, bri, r, g, b = backend.get_ledbar()
        cur = (on, round(bri / 255.0, 3), round(r / 255.0, 3), round(g / 255.0, 3), round(b / 255.0, 3))
        if cur != device._last_ledbar:
            device._last_ledbar = cur
            device.ledbar.is_on, device.ledbar.brightness = on, bri / 255.0
            if on:
                device.ledbar.red, device.ledbar.green, device.ledbar.blue = r / 255.0, g / 255.0, b / 255.0
            msgs.append(device.ledbar._state_response())  # pylint: disable=protected-access

    if device.keypad is not None:
        kp_on, kp_bri = backend.get_keypad()
        kp_cur = (kp_on, round(kp_bri / 255.0, 3))
        if kp_cur != device._last_keypad:
            device._last_keypad = kp_cur
            device.keypad.is_on, device.keypad.brightness = kp_on, kp_bri / 255.0
            msgs.append(device.keypad._state_response())  # pylint: disable=protected-access

    for entity in (device.screen, device.backlight, device.blank_timeout, device.als_auto, device.illuminance,
                   device.volume, device.verbose_boot, device.cpu_temp, device.uptime, device.ip_address,
                   device.touched_recently, device.update, device.emmc_life_a, device.emmc_life_b, device.emmc_eol):
        if entity is None:
            continue
        before = getattr(entity, "_state", None)
        msg = entity.poll()
        if getattr(entity, "_state", None) != before:
            msgs.append(msg)

    before = device.orientation._state  # pylint: disable=protected-access
    msg = device.orientation.poll()
    if device.orientation._state != before:  # pylint: disable=protected-access
        msgs.append(msg)

    event = backend.poll_key_event()
    if event:
        name, event_type = event
        for key_entity in device.keys:
            if key_entity.object_id == f"key_{name}":
                resp = key_entity.fire(event_type)
                if resp is not None:
                    msgs.append(resp)
                break

    if msgs:
        broadcast(msgs)
