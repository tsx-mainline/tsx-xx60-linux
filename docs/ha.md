# Home Assistant integration

The panel shows a Home Assistant dashboard. It also acts as a media player, a voice satellite and a Bluetooth proxy. This page shows how to add the panel to Home Assistant and lists its entities, actions and settings. For the kiosk browser and its daemons see [rootfs.md](rootfs.md). For the install see [install.md](install.md).

## Tasks

### Add the panel to Home Assistant

The panel is one device over the **ESPHome native API** (zeroconf `_esphomelib._tcp`, port 6053, no broker). This is the default (`HA_TRANSPORT=esphome` in `panel.conf`, see [rootfs.md](rootfs.md) "Panel configuration").

1. Open **Settings → Devices & services**. The panel shows as a discovered ESPHome device.
2. Select **Add**. If discovery does not show the panel, add the ESPHome integration by host and port 6053.
3. If `HA_API_KEY` is set on the panel, enter the key when Home Assistant asks for the encryption key.
4. Wait for the entities to appear (see "Entities").

Discovery needs mDNS multicast between the panel and Home Assistant. If a switch or VLAN blocks multicast, add the panel by host and port 6053. This needs no mDNS.

The panel announces an entity only when it has the part. The LED bar, key LEDs, front keys, ambient light sensor, sound card and eMMC health each have a check at start. `tsx-mqtt` clears the discovery topic of an LED bar or key LED entity that the panel does not have.

### Log the kiosk in without a keyboard

The panel has no keyboard. Use one of these methods. You can combine either one with the on-screen keyboard.

**Long-lived access token (recommended).**

1. In Home Assistant, create a long-lived access token (**Profile → Long-Lived Access Tokens**).
2. On the panel, run `kiosk-set-token <token>`. It stops the kiosk and starts Chromium headless against the persistent profile. Chromium opens a same-origin page that runs no Home Assistant code. The command writes the token in the frontend `localStorage` format with a far expiry, so the frontend never refreshes it. Then it restarts the kiosk.

To seed the token with the panel configuration, set `HA_LOGIN_METHOD=token` and `HA_TOKEN` in `panel.conf`. Use the setup page, a `--config` file or `tsx-config set`. `tsx-config apply` stages the token, and the kiosk seeds it at the next start. A changed `HA_TOKEN` seeds again.

**DevTools tunnel (one time).** `KIOSK_DEVTOOLS` is on by default. Chromium listens on `127.0.0.1:9222` only.

1. Run `ssh -L 9222:127.0.0.1:9222 root@<panel-ip>`.
2. Open `chrome://inspect` in a desktop Chrome. Under "Configure", add `localhost:9222`.
3. Inspect the panel page and type the login into the screencast of the panel window.

Keep `KIOSK_DEVTOOLS` on. The front keys, the kiosk URL entity and the reload entity need it (see "Troubleshooting").

**Trusted networks (not the default).** With `HA_LOGIN_METHOD=trusted`, the Home Assistant `trusted_networks` auth provider trusts a client by its source IP address. Behind a reverse proxy or tunnel, Home Assistant sees the proxy address for every client. Use this method only if `KIOSK_URL` is a direct LAN address that bypasses any proxy. Limit the trusted range to the panel address, and give the panel a dashboard-only, non-admin user.

### Provision the panel

Provisioning creates a non-admin Home Assistant user for the panel, mints its long-lived tokens and writes the panel configuration. Run it from a workstation that reaches both Home Assistant and the panel. You need your own Home Assistant server, your own MQTT broker (if you use MQTT) and your own credentials. `ha-provision.py` has the defaults `--user tsw1060` and `--dashboard tsw-1060`. They fit the TSW-1060 example dashboard. The scripts write secrets only to `provision/secrets/` with mode 0600 (Git ignores it) and never print them.

1. Run `provision/ha-provision.py` against Home Assistant. Subcommands:

   | Subcommand | Does |
   |---|---|
   | `genpass` | Generates a local password for the panel user (use it if you create the user by hand). |
   | `create-user` | Creates the panel user. Needs a temporary admin token. |
   | `mint` | Creates the long-lived tokens (`--rotate` replaces them). Refuses an administrator or owner account. |
   | `verify` | Checks that the tokens work and that MQTT accepts the panel credentials. |
   | `mqtt-test` | Tests the MQTT connection. |
   | `wait-event`, `states-grep`, `light-state` | Read as the panel user: wait for one button event, list the visible entities, print the state of one light. |

   The script uses the WebSocket API and the Python standard library only.
2. Run `provision/panel-provision.sh` with the panel, your Home Assistant URL and your login:

   ```sh
   provision/panel-provision.sh --panel <panel-ip> --ha-url https://ha.example.org \
     --broker <mqtt-host> --key ~/.ssh/panel_key
   ```

   The script first prints the panel, the login method and the Home Assistant URL, and tests the login. It writes nothing to the panel before the login test passes. Use `--check` to stop after this preflight. Then the script does these steps over ssh:
   - It writes the token file `/etc/tsx/ha-token` for the front-key event.
   - It sets the MQTT broker, user and password and the `KIOSK_URL`.
   - It seeds the kiosk login token with `kiosk-set-token --file`.
   - It restarts `tsx-buttons` and `tsx-mqtt`.
   - It saves each file that it edits as `*.pre-provision`.
3. Wait for the checks. The script presses the Lights key and checks the `tsx_button` event, the MQTT entities and the kiosk page. It prints `FAIL` for each failed check.

The script logs in as `root` with the login that you set in `panel.conf` (`ROOT_PASSWORD_HASH` or `SSH_AUTHORIZED_KEY`, see [rootfs.md](rootfs.md) "Root login"). The panel has no default password. The script never puts a password on a command line, never prints it and never stores it.

| Option | Default | Meaning |
|---|---|---|
| `--panel <ip>` | `$PANEL_IP` | Address of the panel. Required. |
| `--ha-url <url>` | `$HA_URL` | Home Assistant URL, `http://` or `https://`. Required. |
| `--key <file>` | none | Private key for `root`. |
| `--password-file <file>` | `$PANEL_PASSWORD_FILE` | File with the root password. The script passes it to `sshpass -f`, so `sshpass` must be on the host. |
| `--broker <host>` | `$BROKER`, else none | MQTT broker host. |
| `--user <name>` | `tsw1060` | Home Assistant user of the panel. It must match `ha-provision.py --user`. |
| `--dashboard <path>` | `tsw-1060/home` | Dashboard path that `KIOSK_URL` opens. The default is the example dashboard. |
| `--check` | off | Print the preflight and stop. Nothing is written. |
| `--no-verify` | off | Skip the checks after the writes. |

With no `--key` and no `--password-file`, the script uses your ssh agent or the keys in `~/.ssh`. If none exists, it stops before it writes anything and lists the options.

To revoke access, delete the user of the panel in **Settings → People**. To rotate the tokens, run `ha-provision.py mint --rotate`, then run `panel-provision.sh` again.

### Build a dashboard for the panel

The project has an example "wall panel" dashboard: a sections view with three short tabs.

1. In Home Assistant, open **Settings → Dashboards → Add dashboard → From scratch** and open the raw YAML editor.
2. Paste the example, replace every example entity ID with your own, and save.
3. Set `KIOSK_URL` to the dashboard.

The panel draws every page with a 4-core Cortex-A9. The GPU patch (see [rootfs.md](rootfs.md)) moves only compositing to the GPU. JavaScript, layout and chart drawing stay on the CPU.

| Costly | Use instead |
|---|---|
| History or statistics graphs, mini-graph and apexchart cards | A tile card with the current value. View graphs on a phone or PC. |
| Camera cards (software video decode) | A snapshot on tap only, or omit. |
| Map cards | A person badge. |
| Animated backgrounds, weather animations, card-mod animations | Static colors. The kiosk asks every page for reduced motion. |
| One long scrolling view | Several short views (tabs) that fit the panel. |
| Masonry or deep nested stacks | A sections view with tile cards. |

Hide the sidebar and header: select "Always hide the sidebar" in the profile of the panel user, or use the community **kiosk-mode** plugin. Use a dedicated non-admin user, so that an accidental tap cannot reach the Home Assistant settings. The front keys can navigate between dashboard views (see [rootfs.md](rootfs.md)).

### Set the voice satellite

1. Run `tsx-config set VOICE on` and, to choose the wake word, `tsx-config set WAKE_WORD <name>` (for example `okay_nabu`). Run `tsx-config apply`.
2. In Home Assistant, create an **Assist pipeline** under **Settings → Voice assistants**. It needs a speech-to-text engine (a local add-on such as Whisper or Speech-to-Phrase, or a cloud service) and a text-to-speech engine (Piper works out of the box).
3. Select that pipeline for the satellite.

See "Voice satellite" for the entities and modes.

### Add a custom wake word

1. Get a wake word model for microWakeWord or openWakeWord. A model is a `.json` file and a `.tflite` file with the same name.
2. Copy the two files to the panel:

   ```sh
   scp hey_computer.json hey_computer.tflite root@<panel-ip>:/data/wakewords/
   ```

3. Wait about 10 seconds. Home Assistant connects to the panel again and shows the new wake word in the wake word select.

The [wake words page of tsx-linux-common](https://github.com/tsx-mainline/tsx-linux-common/blob/main/docs/wake-words.md) tells where to get or train a model. It also describes the `.json` fields, the checks, the removal of a model and the troubleshooting.

### Turn on the Bluetooth proxy

1. Run `tsx-config set BT_PROXY on`.
2. For active connections, run `tsx-config set BT_ACTIVE on`.
3. Run `tsx-config apply`. It starts the `tsx-bt` service and restarts the ESPHome server (`tsx-esphome` or the voice satellite).
4. In Home Assistant, open **Settings → Devices & services → Bluetooth**. The panel shows as a scanner. With `BT_ACTIVE=on` it shows as connectable, with its free connection slots. You configure nothing in Home Assistant.

### Turn on encryption of the API

1. Run `tsx-config set HA_API_KEY "$(head -c 32 /dev/urandom | base64)"`.
2. Run `tsx-config apply`. It restarts `tsx-esphome` and `tsx-voice`.
3. Read the key with `tsx-config get HA_API_KEY` and paste it into Home Assistant when it asks.

The installer offers to generate a key (default yes), keeps the existing key on a reinstall and prints a generated key once at the end. If Home Assistant already has the device without a key, it starts a re-authentication for that entry. The entry shows as needing attention under **Settings → Devices & services**. Enter the key there. You do not delete or add anything again.

### Play music (Music Assistant)

The panel is a Sendspin network-audio receiver. Music Assistant finds it over mDNS as a media player. Configure nothing in Home Assistant. Music Assistant and its mDNS discovery must be on the same network. The Sendspin client applies the volume that you set in Music Assistant or with a `media_player` volume call, whatever the ALSA volume of the panel is.

### Trigger an automation from a front key

The button daemon fires a plain Home Assistant event, with no MQTT or entity setup. It needs the token file `/etc/tsx/ha-token`. Without it, the daemon skips every Home Assistant action. The event carries the panel name, the button name, the press type (`short` or `long`) and the raw key code. The event type is configurable.

The five keys of the xx60 are `power`, `home`, `lights`, `up` and `down`, from top to bottom. A press fires this event and does nothing else: the keys have no local action. A press on a blank screen only wakes the screen. Home Assistant sets the key LEDs and their screen-off level. [rootfs.md](rootfs.md) "Front keys, key LEDs and the LED bar" tells how to bind an action to a key.

```yaml
trigger:
  - platform: event
    event_type: tsx_button
    event_data: {button: example_key, press: long}
```

## Reference

### Entities

The ESPHome device has these entities. The exact entity IDs depend on your Home Assistant and the panel name (`<panel>` below).

| Entity | Type | What it does |
|---|---|---|
| LED bar | RGB light, effects | Sets the color of the LED bar. See "LED bar light". Only where `tsx-ledbar` is installed. |
| Key LEDs | Brightness light | Sets the level of the key LEDs while the screen is awake. Off makes the keys dark at once, also while the screen is blank. Both hold until `tsx-keypad led auto` ([rootfs.md](rootfs.md) "Key LED levels"). The light shows the awake level. Only where the keys have LEDs. |
| Key LEDs screen-off level | Number, 0 to 255 | The level of the key LEDs while the screen is blank. `0` makes the keys dark. Stored in `panel.conf` (`KEY_LED_BLANK`), so it survives a reboot or reinstall. `tsx-buttons` applies it at once. Only where the keys have LEDs. |
| Screen | Switch | On = awake. Off blanks the screen. |
| Backlight | Number | Sets a fixed level in the brightness steps of the panel. It wins over the ambient light sensor until the next day/night change or until *Auto brightness* turns on. The slider on the panel turns it back into an offset ([rootfs.md](rootfs.md) "Quick settings"). |
| Blank timeout | Number (box), 0 to 86400 | Seconds without input before the screen goes dark. `0` = never. Stored in `panel.conf` (`BLANK_TIMEOUT`), so it survives a reboot or reinstall. `tsx-idled` applies it at once. |
| Orientation | Select: `landscape`, `portrait`, `landscape-flipped`, `portrait-flipped` | Sets how the panel hangs ([rootfs.md](rootfs.md) "Orientation"). Stored in `panel.conf` (`ORIENTATION`). The kiosk turns at once. The boot splash turns from the next boot. |
| Kiosk URL | Text | Sets the dashboard URL. Also updates `panel.conf` (`KIOSK_URL`), so it survives a reboot or reinstall. |
| Reload page | Button | Reloads the dashboard. |
| Reboot | Button | Reboots the panel. |
| Volume | Number, 0 to 100 % | Sets the volume. Only with the TSW1060 sound card. |
| Each front key | Event (`press`, `long`) | Fires on a key press. The entity also lists `double`, which the panel never sends. Only with front keys. |
| CPU temperature | Sensor | The CPU temperature. |
| Uptime | Sensor | The time since boot. |
| IP address | Sensor | The IP address of the panel. |
| Touched recently | Binary sensor (motion) | On while the last real input (touch, front key or power key) is less than 30 s old. `tsx-idled` writes the time of the last input to `/run/tsx/last-input`, at most once a second. |
| Auto brightness | Switch | Writes `AUTO_BRIGHTNESS` in `panel.conf` (`tsx-als auto on\|off`). Only with the ambient light sensor. |
| Illuminance | Sensor | The lux after `ALS_SCALE` (`panel.conf` only, see [rootfs.md](rootfs.md) "Ambient light sensor"). Only with the ambient light sensor. |
| eMMC life used A, eMMC life used B | Sensors (%), diagnostic | The upper bound of the eMMC wear band, read every hour. Unknown if the eMMC does not report it. |
| eMMC end of life | Sensor (text), diagnostic | `normal`, `warning` or `urgent`. |
| Verbose boot | Switch | On shows kernel and boot text on the LCD instead of the splash, from the next boot. Stored in `panel.conf` (`BOOT_VERBOSE`). |
| Update | Update entity | Status and Install action of `tsx-autoupdate` (see "Update entity"). |
| Voice entities | See "Voice satellite" | On the same device. A panel with a microphone shows the voice selects and an idle assist satellite also with voice off. |
| Camera, Take snapshot, Last snapshot | Camera, button, timestamp sensor | The panel camera. All three with `CAMERA=snapshot`, only Camera with `CAMERA=live`, none with `off` (the default). The plugin `esphome.d/camera.py` adds them. See "Camera". |

A Bluetooth proxy is not an entity. With `BT_PROXY=on` the device is also a Bluetooth scanner for Home Assistant (see "Bluetooth proxy").

Typical entity IDs. The panel name replaces `<panel>`.

- `assist_satellite.<panel>_assist_satellite`
- `media_player.<panel>_<voice_satellite_name>` (TTS and announcements)
- `media_player.<panel>_<sendspin_name>` (music)
- `select.<panel>_wake_word`
- `light.<panel>_led_bar`, `light.<panel>_key_leds`
- `switch.<panel>_screen`
- `number.<panel>_backlight`, `number.<panel>_blank_timeout`, `number.<panel>_key_leds_screen_off_level`
- `binary_sensor.<panel>_touched_recently`
- `event.<panel>_key_<name>` (one for each front key, for example `event.<panel>_key_power`)
- `sensor.<panel>_emmc_life_used_a`, `sensor.<panel>_emmc_life_used_b`, `sensor.<panel>_emmc_end_of_life`
- `update.<panel>_update`
- `camera.<panel>_camera`, `button.<panel>_take_snapshot`, `sensor.<panel>_last_snapshot`

**eMMC health.** `tsx-emmc-state` copies `life_time` and `pre_eol_info` of the eMMC into `/run/tsx/emmc.state`. It runs at boot (from the `tsx-config` service, before `tsx-mqtt` and `tsx-esphome`) and every hour (`/etc/periodic/hourly`). The file has the lines `life_a`, `life_b` and `eol`, as hex codes. If the eMMC standard version is below 5.0, the file does not exist and the entities do not appear. The same holds if the eMMC reports `0x00` in every field (as on the TSS-10).

**Device name.** Both servers use the same ESPHome name and friendly name (`ha/voice/shim/tsx_panel/naming.py` in tsx-linux-common):

- The ESPHome name is `PANEL_NAME` in lowercase, with every character other than `[a-z0-9-]` changed to `-` (`TSS-10-ABCDEF` becomes `tss-10-abcdef`). Without `PANEL_NAME` it is `tsx-<mac>`.
- The friendly name is `PANEL_NAME` as you typed it. Otherwise it is `NAME` in `/etc/tsx/esphome.conf` or `voice.conf`, and the default is the hostname.

The plugin `tsx_lva` replaces the `lva-<mac>` name of linux-voice-assistant. A change of `VOICE` therefore does not rename the device. The project (`tsx-mainline.tsx-esphome`), the manufacturer, the model and the versions are also the same in both modes, so the device page does not change. Home Assistant keys the entry by MAC address. Entity unique IDs come from the MAC and the ID of each entity, so a change of the device name keeps the entity IDs. The title of the entry can keep the previous name. Rename it by hand if you want.

**Which process serves the device.** It depends on `VOICE`:

| `VOICE` | Process | Behavior |
|---|---|---|
| `on` | `tsx-voice` (`linux-voice-assistant`) | One process serves the voice entities and the panel entities. The plugin `ha/voice/shim/tsx_lva` appends the panel entities to `ServerState.entities` at connection time. Home Assistant sees one device. |
| `off` | `tsx-esphome` (`ha/voice/shim/tsx_panel/esphome_server.py`) | A standalone server on the same port. |

Exactly one of the two runs. `tsx-audio enable voice` stops `tsx-esphome` and starts `tsx-voice`. `tsx-audio disable voice` does the reverse. `tsx-config apply` calls both for `VOICE`. `tsx-esphome` does not start at boot while `tsx-voice` is in the default runlevel. `tsx-voice` stops `tsx-esphome` when it starts. If `tsx-voice` cannot start (no microphone or no wake word library), `tsx-esphome` serves the entities.

A panel with a microphone announces the voice feature of the satellite in both modes (`voice_assistant_feature_flags` is `VOICE_ASSISTANT` with `VOICE=off`). Home Assistant makes the voice selects only when it sets up the config entry, and only if the device announces the voice feature at that time. With the same announcement in both modes, a change of `VOICE` needs no reload of the integration. See "Voice satellite".

Both share one backend (`ha/voice/shim/tsx_panel/`) and the same state files and tools (`/run/tsx/*.state`, `tsx-ledbar`, `tsx-keypad`, `tsx-blank`, `tsx-als`, `amixer`). `tsx-mqtt` is a POSIX shell script, because it also runs in the Alpine build and rescue environment.

**Privileged helper.** Blank and wake the screen, the backlight override, `tsx-ledbar`, `tsx-keypad`, `tsx-config apply` and reboot need root. The Home Assistant layer does none of these itself. `tsx-panelctl` is the one interface to the hardware for `tsx-esphome`, `tsx-mqtt` and the voice satellite (see [rootfs.md](rootfs.md) "Profiles" and "The seam: tsx-panelctl"). The voice satellite runs as the `kiosk` user (groups `kiosk` and `audio`), not as root. The plugin, `tsx-esphome` and `tsx-mqtt` write one whitelisted command to the FIFO `/run/tsx/panelctl` (root and group `kiosk`, mode 660). The root service `tsx-panelctl` runs it. The volume comes from `tsx-panelctl get volume` and the LED bar check from `tsx-panelctl has ledbar`. The checks of the bar firmware (`has ledbar-fx`, `has ledbar-leds`) read `/run/tsx/ledbar.fw`. The root service `tsx-ledbar` writes this file, because only root can ask the bar for `CAPS`. The whitelist is in `ha/voice/shim/tsx_panel/backend.py` and `usr/local/sbin/tsx-panelctl`.

### LED bar light

The LED bar light is an RGB light. Each effect takes its color from the light.

| Effect | Needs | What it does |
|---|---|---|
| `None` | none | Shows the light color. |
| `Pulse` | none | A software breathing effect. |
| `Breathe`, `Blink`, `Rainbow` | Bar firmware TSX-LEDBAR | Run on the bar ([LED bar](https://github.com/tsx-mainline/tsx-linux-common/blob/main/docs/ledbar.md) "Effects"). |
| `Chase` | TSX-LEDBAR 0.1.3 or later (`tsx-panelctl has ledbar-leds`) | A dot of the light color (with its brightness) runs down both sides. One run takes 1.5 s. |
| `Fill` | TSX-LEDBAR 0.1.3 or later | A level bar from the bottom up in the light color at full level. The brightness of the light sets the height (0 to 100 %). |
| `Spectrum` | TSX-LEDBAR 0.1.3 or later | The hue circle on the bar at the brightness of the light. One cycle takes 10 s. The light keeps its color. |

The bar also has a split effect (one color on each side). A light has one color, so split is an action only (`ledbar_split`). The MQTT light has no effects.

### LED bar actions

With TSX-LEDBAR 0.1.3 or later, the device lists five user-defined actions (ESPHome "actions"). Home Assistant registers each one as `esphome.<name>_<action>` when the device connects. `<name>` is the ESPHome name of the device with `_` in place of `-`. A device `my-panel` gives `esphome.my_panel_ledbar_set_led`. The actions need no option of the ESPHome integration. The option "Allow the device to perform Home Assistant actions" is for the other direction and can stay off. With stock firmware or TSX-LEDBAR 0.1.2 (no 16 LEDs), the device lists no actions. MQTT has no LED bar actions.

Levels are whole numbers from 0 to 100 for each color, not the 0 to 255 of a light. LEDs are numbered top to bottom as `R1` to `R8` (right side) and `L1` to `L8` (left side), or by index `0` to `15`.

| Action | Fields | Result |
|---|---|---|
| `ledbar_set_led` | `led` (text), `red`, `green`, `blue` | Sets LEDs of the pattern. `led` is `R1` to `R8`, `L1` to `L8`, an index `0` to `15`, a range (`R1-R4`, `8-11`), `R`, `L` or `ALL`. |
| `ledbar_set_side` | `side` (`R`, `L`, `right` or `left`), `red`, `green`, `blue` | Sets one side of the pattern. |
| `ledbar_fill` | `percent`, `red`, `green`, `blue` | The fill effect with this color and height. |
| `ledbar_split` | `right_red`, `right_green`, `right_blue`, `left_red`, `left_green`, `left_blue` | The split effect: one color on the right side, one on the left. |
| `ledbar_clear` | none | Drops the pattern. The bar shows the light color again. |

Examples:

`ledbar_set_led`: the first four right LEDs blue.

```yaml
action: esphome.my_panel_ledbar_set_led
data:
  led: R1-R4
  red: 0
  green: 0
  blue: 60
```

`ledbar_set_side`: the left side red.

```yaml
action: esphome.my_panel_ledbar_set_side
data:
  side: left
  red: 100
  green: 0
  blue: 0
```

`ledbar_fill`: a half-full green bar.

```yaml
action: esphome.my_panel_ledbar_fill
data:
  percent: 50
  red: 0
  green: 100
  blue: 0
```

`ledbar_split`: red on the right side, blue on the left side.

```yaml
action: esphome.my_panel_ledbar_split
data:
  right_red: 100
  right_green: 0
  right_blue: 0
  left_red: 0
  left_green: 0
  left_blue: 100
```

`ledbar_clear`: drop the pattern.

```yaml
action: esphome.my_panel_ledbar_clear
```

Rules:

- The first `ledbar_set_led` or `ledbar_set_side` copies the light color into all 16 LEDs, then changes the LEDs that you give.
- A LED action ends the running effect. An effect on top of the pattern keeps the pattern. Effect `None` goes back to the pattern.
- A change of the light color ends the pattern and the effect.
- The panel brings back the pattern and effect after a restart of the bar.
- The light does not show the pattern. It keeps the light color.
- The device answers each call with a status. A bad field (for example `led: R9` or a level of 101) fails the action in Home Assistant with a message. The bar does not change.

### Voice satellite

The voice satellite uses the ESPHome native API. Discovery creates these entities:

- `assist_satellite` for the panel.
- A media player for TTS replies and announcements. It is separate from the Sendspin media player.
- A wake word **select** that sets which installed wake word phrase the satellite hears. It lists the built-in wake words and the custom models in `/data/wakewords` (see "Add a custom wake word").
- Sensitivity (mic sensitivity), mute and "thinking sound" controls.

With `VOICE=off`, a panel with a microphone shows only part of these entities in Home Assistant:

- `assist_satellite`. It stays idle and does not start a pipeline.
- The Assistant, Assistant 2 and Finished speaking detection selects.
- The wake word selects. They are unavailable, because the panel sends no wake word list.

The media player and the sensitivity, mute and "thinking sound" controls exist only with `VOICE=on`. With `VOICE=on` the satellite sends the wake word list when Home Assistant connects, and the wake word selects show it. With `VOICE=off`, the panel does not offer the features announcement, start conversation and timers.

Wake-word detection runs on the panel (see [rootfs.md](rootfs.md)). Two modes exist:

| Mode | Behavior |
|---|---|
| Push-to-talk | A front-key action starts listening. No always-on wake-word inference runs. This is the lightest mode on this CPU. |
| Local wake word | The panel listens for the selected wake word with an on-device model. At idle it uses more CPU than push-to-talk. |

Set the mode with `WAKE=ptt` or `WAKE=local` in `/etc/tsx/voice.conf`. The shipped value is `local`. Then run `rc-service tsx-voice restart`.

A panel without a microphone (U-Boot `government=1`, for example the TSW-760-NC, see [hardware.md](hardware.md) "Panel variants") has no voice satellite. `tsx-voice` does not start there, also with `VOICE=on`, and `tsx-esphome` serves the panel entities. The entities `assist_satellite`, the Assistant and Finished speaking detection selects, its media player, the wake word select and the sensitivity, mute and "thinking sound" controls do not exist. All other entities keep their names.

### Bluetooth proxy

The panel can act as a Bluetooth proxy like an ESPHome device with `bluetooth_proxy`. It has two levels:

| Level | Settings | Behavior |
|---|---|---|
| Passive | `BT_PROXY=on` | The panel listens for BLE advertisements (thermometers, plant sensors, beacons) and passes them to Home Assistant over the ESPHome device. It sends nothing over the air. This is `bluetooth_proxy: active: false`. |
| Active | `BT_PROXY=on` and `BT_ACTIVE=on` | Home Assistant can also connect to BLE devices through the panel, read and write GATT characteristics and get notifications. This is `bluetooth_proxy: active: true`. |

Settings:

| Key | Values | Default |
|---|---|---|
| `BT_PROXY` | `on`, `off`, empty | Empty = the default of the panel type. On the xx60 it is `off`. A board file can set another default with `TSX_BT_PROXY_DEFAULT`. |
| `BT_ACTIVE` | `on`, `off` | `off` |
| `BT_MAC` | A Bluetooth address | Empty = the eth0 MAC. Cannot apply on a board with no chip file. |

Feature flags that the device announces:

| Setting | Flags | Meaning |
|---|---|---|
| `BT_PROXY=on` | 97 | Passive scan, raw advertisements, scanner state and mode. |
| `BT_PROXY=on`, `BT_ACTIVE=on` | 119 | Also active connections, remote caching, cache clearing. |

**Parts.**

- `tsx-bt` (OpenRC service, root) brings the controller up and runs `tsx-btscan` (`/usr/local/lib/tsx/btscan.py` and `btgatt.py`) under `supervise-daemon`. `supervise-daemon` restarts `tsx-btscan` after 2 s if it stops. The chip-dependent steps are in one chip file.
- `tsx-btscan` opens a raw HCI socket on `hci0` and runs an LE scan (100 ms window every 100 ms, no duplicate filter). It scans only while a client is connected. It passes each advertising report to the ESPHome server over `/run/tsx/bt-adv.sock`. It also holds the BLE links of the active proxy and runs GATT over them. The ESPHome server reaches that part over `/run/tsx/bt-gatt.sock`. Both sockets have mode 660 and group `kiosk`.
- The ESPHome server (`ha/voice/shim/tsx_panel/bluetooth.py`, in both front ends) announces `bluetooth_proxy_feature_flags` and `bluetooth_mac_address`. It sends reports in `BluetoothLERawAdvertisementsResponse` messages (at most 16 advertisements, at most every 100 ms). At most 512 advertisements wait to go out. If the ESPHome event loop is slow, the oldest ones drop. One flush sends at most 8 messages.

The scanner uses a raw HCI socket and not BlueZ. It needs only the Python standard library, with no `bluetoothd` and no D-Bus. `hciconfig` and `btmgmt` can see the controller. The scanner runs as root, because the voice satellite (user `kiosk`) cannot open an HCI socket.

**Scanner state and mode.** The flag `STATE_AND_MODE` (64) lets Home Assistant read the scanner state and ask for a scan mode.

- Home Assistant sends `BluetoothScannerSetModeRequest`. `tsx-btscan` scans actively only if a subscribed connection asks for it and `BT_ACTIVE=on`. With `BT_ACTIVE=off` the scan stays passive and nothing goes over the air. The answer shows `mode` passive and `configured_mode` as asked.
- The panel sends `BluetoothScannerStateResponse` after each subscription, each mode request and each scanner change. The state is `running` while the scan runs or pauses for a connect. It is `failed` if the controller refuses the scan commands.
- Between the ESPHome server and `tsx-btscan`, the mode is a two-byte message (`m`, 0 or 1) on `bt-adv.sock`. The state is a three-byte message (`S`, state, mode) from `tsx-btscan`. The format is in the header of `btscan.py`.

**Start rules.** `tsx-bt up` follows these rules:

1. If `hw.conf` says `BT=no` (the TSW-760-NC), it records `state=absent` and stops. It never touches the chip.
2. If the kernel has no Bluetooth, it records `state=absent` and stops. The ESPHome servers then do not announce the proxy.
3. It finds the Bluetooth address and runs `chip_up` of the chip file. A board whose kernel driver registers `hciN` without help sets `TSX_BT_CHIP=none`.
4. It waits for `hciN` for at most 20 s (`TSX_BT_WAIT`). A late kernel driver gets `HCIDEVUP` (`btscan.py --up`).

The chip file is `/usr/local/lib/tsx/bt-chip-csr8811.sh`. The xx60 board file names it in `TSX_BT_CHIP`. It holds the rfkill pulse, the PSR upload (with `csr_psload.py`) and `hciattach`. On a panel with `BT=no` it gives the `REASON` text of `hw.conf` as the reason. A board with another chip sets `TSX_BT_CHIP` to its own file with the functions `chip_up` and `chip_down`. `tsx-bt` itself has no chip steps.

The address source on the xx60 is `BT_MAC`, else the eth0 MAC. If neither exists, or the board has no chip file, the controller keeps its own address. `tsx-btscan` reads it with Read BD_ADDR and writes it to `/run/tsx/bt.mac`, where the ESPHome servers read it. If `bt.mac` exists already, `tsx-btscan` only logs a warning when the controller reports another address.

**Active connections.** The links use the ATT socket of the kernel (L2CAP, fixed channel 4). The kernel makes the LE connection. `tsx-btscan` is the GATT client: MTU exchange, service discovery, read, write, write without response, notifications and indications. This needs no `bluetoothd` and no D-Bus. One link comes up in these steps:

1. Home Assistant sends a connect request. `tsx-btscan` takes a slot and reports the new slot count.
2. `tsx-btscan` stops the passive scan and connects. The kernel scans for that one device and connects when it sees it.
3. `tsx-btscan` agrees on the ATT MTU (up to 517 bytes), reports "connected" and starts the passive scan again.
4. Home Assistant reads the services (or uses its cache), reads, writes and subscribes. Home Assistant writes the CCCD of a notification itself.
5. A disconnect request, a drop by the device or a closed Home Assistant connection takes the link down. `tsx-btscan` reports the HCI reason and frees the slot.

Limits:

- 3 links at a time (`BluetoothConnectionsFreeResponse` reports `limit` 3). The controller limit is not known (see [hardware.md](hardware.md)). A connect that the controller refuses fails with an error and frees the slot. A fourth connect gets error 0x80 (no resources) at once.
- `BluetoothSetConnectionParamsRequest` gets a negative answer (error 0x85). The kernel keeps the connection parameters.
- One connect at a time. A second connect waits.
- A connect fails after 20 s if the device does not answer. Home Assistant gives up after 30 s.
- While a link comes up, the kernel scans only for that device and other advertisements stop. A device in range takes less than a second. A device out of range takes the full 20 s.
- No pairing and no encryption. A device that needs a bond does not work through the panel.
- A peer that reads the remote features as peripheral (for example a Linux PC with a Bluetooth 5 controller) can drop about half of the links while they come up. Home Assistant tries again (see [hardware.md](hardware.md)).
- An NC panel (U-Boot `government=1`, for example the TSW-760-NC) has no Bluetooth module. The proxy stays off, also with `BT_PROXY=on` ([hardware.md](hardware.md) "Panel variants").
- The panel keeps no GATT cache. Home Assistant keeps it (remote caching).
- A process that can open `/run/tsx/bt-gatt.sock` (root and group `kiosk`, the users that run the ESPHome server) can connect to BLE devices. With `BT_ACTIVE=off`, `tsx-btscan` refuses every connect, also one that comes directly over the socket.

**Check on the panel.**

1. Run `tsx-bt status`. It shows `state=up`, the Bluetooth address and the `hciconfig` output.
2. Read `/var/log/tsx-bt.log`. It has the bring-up steps, "passive scan on", a line when a link comes up ("connected") and when it goes down ("disconnected", with the reason). Every 10 minutes it counts reports and links.
3. In Home Assistant, open **Settings → Devices & services → Bluetooth** and look for the panel as a scanner.

A failed bring-up never stops the boot. The device info still announces the proxy, but no advertisements arrive and no link comes up. `tsx-bt status` and the log show the reason. On a panel without a Bluetooth module (`government=1`), `tsx-bt status` says `state=absent` and the device info announces no proxy.

### Camera

The camera works on the TSW-1060 and the TSS-10. The TSW-760 has the same camera. It is not tested on hardware. The NC models have no camera. `CAMERA` in `panel.conf` sets the mode: `off` (the default), `snapshot` or `live`. Only the panel sets the mode, with `tsx-config` or the setup page. Home Assistant cannot turn the camera on.

[camera.md](camera.md) describes the modes, the entities, privacy, the limits and troubleshooting. [hardware.md](hardware.md) "Camera" describes the sensor and the capture device.

### Security

The ESPHome native API exposes a Reboot button and the kiosk URL, next to the voice satellite entities. Two settings in `panel.conf` protect them. One module enforces both for both front ends (`ha/voice/shim/tsx_panel/security.py`, patched into the shared `APIServer` base class).

| Key | Values | Default | Meaning |
|---|---|---|---|
| `HA_API_KEY` | 32 random bytes, base64 | empty (plaintext API) | The ESPHome "noise" encryption (`Noise_NNpsk0_25519_ChaChaPoly_SHA256`, the same as `api: encryption: key:` on an ESPHome device). Code in `tsx_panel/noise.py`, on py3-cryptography. |
| `HA_ALLOW_FROM` | Comma list of IPv4 or IPv6 addresses or CIDRs (`tsx-config` validates it) | empty (allow any) | The panel closes the connection of any other peer at once. With a key it is defense in depth. Without a key it is the only protection. Use the LAN address of Home Assistant, not the host of the dashboard URL if a reverse proxy is in front. |

With a key, the panel refuses a client that has no key or a wrong key with the standard ESPHome answers. Home Assistant shows "requires encryption" or "invalid encryption key", and nothing hangs. mDNS advertises `api_encryption`, so the discovery flow asks for the key first. The key is in `/run/tsx/esphome.key` (mode 640, group `kiosk`), because the voice satellite runs as `kiosk` and cannot read `panel.conf`. If that file exists but is not usable, both servers refuse to start. They do not fall back to plaintext. With an empty key the plaintext API works with no setup. `tsx-config show` and `apply` warn while both settings are empty. Use a key.

The `kiosk` user runs Chromium without a sandbox on this hardware. The `kiosk` group can write the FIFO of `tsx-panelctl`. The service treats every line as hostile:

- `read` splits the line into a fixed number of fields and does not split caller input again. `set -f` disables pathname expansion.
- It matches each command against the exact form that `tsx_panel/backend.py` sends, with a fixed argument count.
- It range-checks numbers (LED values 0 to 100, key LED level 1 to 255, key LED screen-off level 0 to 255, volume 0 to 100).
- It compares enum arguments with `=` and never passes them on as a CLI option.
- A `config-url` value must start with `http://` or `https://`.

It logs anything else (control characters stripped, text truncated) and drops it. `tests/test-panelctl.sh` of tsx-linux-common tests these checks with a glob, a leading-dash "option", wrong argument counts, an out-of-range number and an overlong numeric string.

### MQTT

MQTT is the fallback transport (`HA_TRANSPORT=mqtt` or `both`). `HA_TRANSPORT=both` runs both transports that you configured. It needs an MQTT broker, the MQTT integration of Home Assistant with discovery on, and the broker in `panel.conf`. The `tsx-mqtt` bridge then publishes entities that Home Assistant discovers.

| Key | Default | Meaning |
|---|---|---|
| `HA_TRANSPORT` | `esphome` | `esphome`, `mqtt` or `both`. |
| `MQTT_HOST` | empty | Broker address. Empty keeps the bridge off. It exits quietly and publishes nothing. |
| `MQTT_PORT` | `1883` | Broker port. |
| `MQTT_USER`, `MQTT_PASSWORD` | empty | Broker credentials. |

MQTT entities:

| Entity | Type | What it does |
|---|---|---|
| LED bar | RGB light | Sets the bar color. No effects. Only where `tsx-ledbar` is installed. |
| Key LEDs | Brightness light | Shows the level while the screen is awake. Only where the keys have LEDs. The MQTT device has no screen-off level number. |
| Screen | Switch | On = awake. |
| Backlight | Number | Brightness step range of the panel. |
| Blank timeout | Number (box) | Seconds, `0` = never (`tsx-config set BLANK_TIMEOUT` + `apply`, as on the ESPHome device). |
| Touched recently | Binary sensor (motion) | Last input less than 30 s ago. |
| Each front key | Event and device triggers | The event entity has the types short, long and hold. The device triggers are short press and long press. |
| Illuminance | Sensor | The lux. Only with the ambient light sensor. |
| Auto brightness | Switch | As on the ESPHome device. Only with the ambient light sensor. |
| Volume | Number, 0 to 100 % | The ALSA "Master" volume. Only with the sound card. |
| eMMC life used A and B, eMMC end of life | Diagnostic sensors | As on the ESPHome device. Only with `/run/tsx/emmc.state`. |
| Update | Update entity | Status of `tsx-autoupdate`. |

The bridge uses a last-will-and-testament availability topic. It publishes its discovery payloads again whenever the MQTT integration of Home Assistant restarts.

### Update entity

`tsx-autoupdate` (see [rootfs.md](rootfs.md) "Updates") publishes its status as a Home Assistant `update` entity on the ESPHome device and on the MQTT bridge. Both read `$TSX_RUN_DIR/update-ha-state.json` (`UpdateEntity` in `ha/voice/shim/tsx_panel/entities.py`), so they agree. The entity shows:

- the installed and the latest version
- a release summary with the pending package list and these notes:
  - "reboot pending" shows if a kernel, musl, openrc, busybox or tsx-* package upgrade waits for the night window.
  - "Chromium held since ..." shows while a newer, unsigned Chromium build is on hold.
- whether an install is in progress

It appears under **Settings → Devices & services → Updates** and on an Update card:

```yaml
type: update-entity
entity: update.example_panel_update
```

**Install** (on the card, or `payload_install` over MQTT) runs `tsx-autoupdate now` at once, not in the night window. It uses the `update-install` command of `tsx-panelctl`, which runs `tsx-autoupdate now` in the background. The window and the idle checks still apply to the reboot. An update that needs a reboot reports "reboot pending" until the panel is in the window and idle.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Home Assistant shows "requires encryption" or "invalid encryption key" | `HA_API_KEY` is set on the panel and the client has no key or a wrong key. | Enter the key from `tsx-config get HA_API_KEY`. |
| A device that Home Assistant already has shows as needing attention after you set a key | Home Assistant needs the key (re-authentication). | Enter the key on the entry. |
| The panel does not show up as a discovered device | mDNS multicast does not reach Home Assistant, for example across a VLAN. | Add the ESPHome integration by host and port 6053. |
| `tsx-esphome` and `tsx-voice` do not start | `/run/tsx/esphome.key` exists but is not usable. The servers never fall back to plaintext. | Set a valid `HA_API_KEY` (base64 of 32 bytes) and run `tsx-config apply`. |
| The kiosk URL entity and Reload page do nothing | `KIOSK_DEVTOOLS` is off. They need it on (the default). The panel logs the failure and does not stop. | Set `KIOSK_DEVTOOLS=1` in `/etc/kiosk.conf`. |
| The login form shows and you cannot type a password | No keyboard. | Seed a token with `kiosk-set-token <token>`. |
| A trusted-network login fails behind a proxy | Home Assistant sees the proxy address. | Point `KIOSK_URL` at a direct LAN address, or use a token. |
| The wake word select is unavailable, and the media player and the sensitivity, mute and "thinking sound" controls are missing | `VOICE=off`, the wake word library `libtensorflowlite_c.so` is missing (package `tensorflow-lite-c`), or the satellite did not start. | Run `tsx-config set VOICE on` and `tsx-config apply`. Then run `tsx-voice status` and read `/var/log/tsx-voice.log`. |
| No voice entities | No microphone (NC panel, `government=1`). | Voice is not available on an NC panel. |
| The Assistant and wake word selects stay unavailable after `VOICE=on` | Home Assistant set up the config entry while the panel announced no voice feature. | Reload the ESPHome config entry once. Later changes of `VOICE` need no reload. |
| A custom wake word is not in the wake word select | The model failed a check, or the panel plays a reply, a timer alarm or media. | Read the line with "skipped" in `/var/log/tsx-voice.log`. See the wake words page of tsx-linux-common. |
| Voice gives no spoken reply | Home Assistant has no Assist pipeline with STT and TTS. | Create the pipeline and select it for the satellite. |
| No LED bar actions in Home Assistant | The bar has stock firmware or TSX-LEDBAR 0.1.2 (no 16 LEDs). | Use TSX-LEDBAR 0.1.3 or later. |
| No zone effects and no LED bar actions with `VOICE=on`, but they show with `VOICE=off` | `/run/tsx/ledbar.fw` is missing: an older `tsx-ledbar` service writes no such file. The voice satellite runs as `kiosk` and cannot ask the bar for `CAPS`. | Update the board package. Then run `rc-service tsx-ledbar restart` and `rc-service tsx-voice restart`. |
| A LED bar action fails with a message | A field is bad (for example `led: R9` or a level of 101). | Use the field ranges in "LED bar actions". |
| The panel is not a Bluetooth scanner | `BT_PROXY` is off, the panel has no Bluetooth module (`government=1`), or the bring-up failed. | Run `tsx-bt status` and read `/var/log/tsx-bt.log`. |
| A BLE connect fails | A fourth link, a device out of range (20 s), a device that needs a bond, or `BT_ACTIVE=off`. | See the limits in "Bluetooth proxy". |
| eMMC wear entities are missing | The eMMC standard version is below 5.0, or the eMMC reports `0x00`. | None. The panel cannot read the wear. |
| Graphs or camera cards make the dashboard slow | The CPU draws every page. | See "Build a dashboard for the panel". |
