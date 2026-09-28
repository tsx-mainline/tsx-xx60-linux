"""One ESPHome device name for the panel, whichever process serves it.

tsx-esphome (VOICE=off) and the voice satellite (VOICE=on) must present the
same device to Home Assistant, or switching VOICE renames it:

  name           PANEL_NAME lowercased, anything but [a-z0-9-] -> "-"
                 (e.g. TSS-10-ABCDEF -> tss-10-abcdef); without a
                 PANEL_NAME, tsx-<mac> (12 lowercase hex digits)
  friendly_name  PANEL_NAME as typed; without one, the process's --name
                 (NAME in /etc/tsx/esphome.conf or voice.conf, default the
                 hostname)

linux-voice-assistant itself would use lva-<mac> (hard-coded in its
__main__.py) -- tsx_lva/__init__.py replaces that through
ServerState.__init__. PANEL_NAME comes from /run/tsx/panel-name (tsx-config
apply writes it, world-readable); test override TSX_PANEL_NAME.
"""

import os
import re

FRIENDLY_NAME = ""  # set by resolve(); security.py adds it to the mDNS TXT record


def panel_name() -> str:
    override = os.environ.get("TSX_PANEL_NAME")
    if override is not None:
        return override.strip()
    path = os.environ.get("TSX_PANEL_NAME_FILE", "/run/tsx/panel-name")
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            return fobj.readline().strip()
    except OSError:
        return ""


def esphome_name(pname: str, mac: str) -> str:
    slug = re.sub(r"-{2,}", "-", re.sub(r"[^a-z0-9-]", "-", pname.lower())).strip("-")[:63].strip("-")
    if slug:
        return slug
    return "tsx-" + re.sub(r"[^0-9a-f]", "", (mac or "").lower())


def resolve(mac: str, fallback_friendly: str):
    """(name, friendly_name) for this panel; see the module docstring."""
    global FRIENDLY_NAME  # noqa: PLW0603
    pname = panel_name()
    name = esphome_name(pname, mac)
    FRIENDLY_NAME = pname or fallback_friendly or name
    return name, FRIENDLY_NAME
