"""tsx_panel: the xx60 panel as one Home Assistant device over the ESPHome
native API (PLAN.md section 18). Shared by two front ends that never run at
the same time (see docs/ha.md "One Home Assistant device"):

  tsx-esphome           standalone server, used when VOICE=off
  tsx_lva (the voice satellite's shim) appends these same entities into its
                        own ESPHomeAPI server when VOICE=on, so Home
                        Assistant only ever sees one device.

Modules:
  backend.py   reads panel state (sysfs, tsx-idled, tsx-buttons, ALSA) the
               same way tsx-mqtt does, and issues commands -- directly if
               running as root (tsx-esphome), else through the tsx-panelctl
               FIFO (the voice satellite runs unprivileged as kiosk:audio;
               see backend.py's module docstring for why).
  entities.py  small ESPHomeEntity subclasses for the entity types
               linux_voice_assistant.entity does not already provide
               (switch/number/text/button/sensor/binary_sensor/text_sensor).
  device.py    builds the full entity list from a PanelBackend and runs the
               polling loop that pushes state changes to Home Assistant.
  esphome_server.py   the standalone tsx-esphome entry point.
  security.py  HA_API_KEY (encryption) + HA_ALLOW_FROM, patched into the
               shared linux_voice_assistant APIServer for both front ends.
  noise.py     the server side of ESPHome's "noise" API encryption.
  naming.py    the one ESPHome device name both front ends present.
"""
