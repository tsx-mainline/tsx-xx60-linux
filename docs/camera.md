# Camera

The panel camera can send images to Home Assistant. The camera is off by default. Only the panel sets the camera mode. Home Assistant cannot turn the camera on.

The panel has one ESPHome device in Home Assistant ([ha.md](ha.md)). The camera entities are on this device. The ESPHome service is `tsx-esphome`, or `tsx-voice` when `VOICE=on`. Both services show the same camera entities with the same keys.

## Parts

The camera is a set of three plugins of the shared software (tsx-linux-common). The plugins are in this repository, because the camera is a part of this board.

| File on the panel | Package | Part |
|---|---|---|
| `/usr/local/lib/tsx/config.d/camera.sh` | `tsx-xx60-board` | The key `CAMERA` of `tsx-config` |
| `/usr/local/share/tsx/esphome.d/camera.py` | `tsx-xx60-board-ha` | The camera entities and the image requests of Home Assistant |
| `/usr/local/share/tsx/setup.d/camera.py` | `tsx-xx60-board-ha` | The camera field of the setup page |

In the repository, these files are in `rootfs/overlay`. A panel without these files has no `CAMERA` key and no camera entity.

## Modes

| Mode | Entities in Home Assistant | When the camera opens |
|---|---|---|
| `off` (default) | None | Never |
| `snapshot` | Camera, Take snapshot, Last snapshot | At each press of Take snapshot, for one image |
| `live` | Camera | When Home Assistant asks for an image. It closes 10 seconds after the last request. |

`CAMERA=on` is the same as `CAMERA=live`.

## Tasks

### Set the camera mode

1. Log in to the panel as root.
2. Run `tsx-config set CAMERA snapshot`. Use `live` or `off` for the other modes.
3. Run `tsx-config apply`.

The ESPHome service restarts. Home Assistant then reads the new entity list. It adds or removes the camera entities.

You can also set the mode on the setup page. Open the "Camera" section and select a mode.

### Turn the camera off

1. Run `tsx-config set CAMERA off`.
2. Run `tsx-config apply`.

Home Assistant removes the camera entities. Nothing opens the camera.

### Take a snapshot

1. In Home Assistant, press the Take snapshot button of the panel device.
2. Wait until the Last snapshot sensor shows the new time.
3. Open the Camera entity. It shows the new snapshot.

An automation or a script can do the same steps. Use the `button.press` action on Take snapshot. Wait for a state change of Last snapshot. Then use the image of the Camera entity, for example with the `camera.snapshot` action.

### Check the camera on the panel

1. Log in to the panel as root.
2. Run `python3 /usr/local/share/tsx/esphome.d/camera.py snapshot /tmp/test.jpg`.
3. Copy `/tmp/test.jpg` to a computer and look at the image.
4. Delete `/tmp/test.jpg`.

This command opens the camera also when the mode is `off`. It prints the image size and the start time. The command finds the `tsx_panel` folder in `/opt/lva/shim`. If `tsx_panel` is in another folder, set `PYTHONPATH` to that folder.

Use `python3 /usr/local/share/tsx/esphome.d/camera.py bench` to measure the capture speed.

## What Home Assistant shows

| Entity | Type | Mode | Content |
|---|---|---|---|
| Camera | `camera` | `snapshot`, `live` | Snapshot mode: the last snapshot. Live mode: a new image for each request. The state is `idle`. |
| Take snapshot | `button` | `snapshot` | A press takes one snapshot. |
| Last snapshot | `sensor`, device class timestamp | `snapshot` | The time when the panel took the last snapshot. It is `unknown` before the first snapshot. |

Snapshot mode answers the image requests from memory. No request opens the camera.

- A still image request (a dashboard card) gets the last snapshot at once.
- A live view (the MJPEG stream in the camera dialog) gets the last snapshot at once. It gets the same image again every 5 seconds. When the panel takes a new snapshot, the live view gets it at once.
- Before the first snapshot, Home Assistant gets an empty image and shows no picture.

The camera entity has the same key in the snapshot and live modes. A change between these two modes keeps its entity ID.

## Privacy

- The camera is off by default. In the `off` mode the panel has no camera entities. No process opens the camera. The sensor stays in power-down with its clock off.
- Only the panel sets the mode, with `tsx-config` or the setup page. Home Assistant has no control for the mode.
- In the `snapshot` mode the camera opens only for a press of Take snapshot. It takes one image and closes. The sensor powers down 1 second later. A user or an automation in Home Assistant can press the button at any time.
- In the `live` mode the camera opens when Home Assistant asks for an image. It closes 10 seconds after the last request.
- The panel keeps only the last snapshot, in memory. It writes no image to a disk. When the ESPHome service or the panel restarts, the snapshot is gone.
- The images go to Home Assistant over the ESPHome API. Set `HA_API_KEY` to encrypt the connection. Set `HA_ALLOW_FROM` to limit the hosts that can connect.
- A panel without a camera, for example the TSW-760-NC, never shows camera entities. `tsx-config` accepts each mode on such a panel and prints a warning with the `REASON` text of `hw.conf`. `tsx-config apply` writes `off`. The setup page shows the camera as not available.

## Reference

### Settings

| Key | File | Values | Default |
|---|---|---|---|
| `CAMERA` | `panel.conf` | `off`, `snapshot`, `live` (`on` = `live`) | `off` |

`tsx-config apply` writes the mode to `/run/tsx/camera.conf`. The plugin `config.d/camera.sh` does this. Both ESPHome services read this file at start. A change of the mode restarts the ESPHome service.

### Defaults and limits

| Item | Value |
|---|---|
| Image size | 1280x720 |
| JPEG quality | 80 |
| Snapshot: time from the press to the image | About 1 second. The Last snapshot sensor changes up to 1 second later. |
| Snapshot: image request | About 0.02 seconds. The camera stays closed. |
| Snapshot: same image again on a live view | Every 5 seconds |
| Live: images per second | 2 at most |
| Live: first image from a closed camera | About 0.8 seconds |
| Live: next image while the camera is open | 0.1 to 0.15 seconds |
| Live: CPU load at 2 images per second | About 14 percent of one core |
| Live: camera close after the last request | 10 seconds |
| Sensor power-down after the camera closes | 1 second |
| JPEG size at 1280x720 | About 20 to 100 KiB. A bright scene with much detail gives a larger file. |

`/run/tsx/camera.conf` also accepts `SIZE` (640x480, 1024x768, 1280x720, 1920x1080 or 2592x1944), `QUALITY` (1 to 100) and `FPS` (0.2 to 10, live mode only). These keys are for tests. `tsx-config apply` writes only `CAMERA` and removes them.

### Requirements

- The kernel driver for the camera sensor and the CSI-2 receiver. The software finds the capture device by its name, `meson8-csi2-capture`.
- The Alpine packages `libturbojpeg` and `py3-numpy`. The panel encodes the JPEG images with them. The package `tsx-xx60-board-ha` depends on them.

## Troubleshooting

The ESPHome service writes one line at start that tells why the panel has no camera entity. The log is `/var/log/tsx-esphome.log` or `/var/log/tsx-voice.log`.

| Symptom | Cause | Fix |
|---|---|---|
| No camera entity. The log says `no camera entity: CAMERA is off in panel.conf`. | The mode is `off`. | Set the mode and run `tsx-config apply`. |
| No camera entity. The log says `this panel has no camera`. | `/run/tsx/hw.conf` has `CAMERA=no`. The log line also has the `REASON` text of `hw.conf`. | None. The panel has no camera. |
| No camera entity. The log says `no camera video device`. | The kernel camera driver is not loaded. | Run `ls /dev/video*`. Look for `ov5640` in the kernel log (`dmesg`). Install a kernel with the camera driver. |
| No camera entity. The log says `libturbojpeg is missing`. | The package is not installed. | Run `apk add libturbojpeg`. Then restart the ESPHome service. |
| No camera entity. The log says `libturbojpeg is too old`. | The installed library has no TurboJPEG 3 API. | Run `apk upgrade libturbojpeg`. Then restart the ESPHome service. |
| The Camera entity shows no picture in the snapshot mode. | The panel has no snapshot since the ESPHome service started. | Press Take snapshot. |
| Last snapshot does not change after a press. | The capture failed. The log says `camera: snapshot failed`. | Read the error in the log. Run the check in "Check the camera on the panel". |
| A press fails at once. The log says `camera: snapshot failed: [Errno 67] Link has been severed`. | The sensor driver did not bind. `media-ctl -p` shows no `ov5640` entity. | Run `dmesg \| grep ov5640`. |
| The live view shows 2 images per second. | The live mode sends 2 images per second at most. | None. This limit keeps the CPU load low. |
| `tsx-config set CAMERA live` says `unknown key: CAMERA`. | The panel has no file `/usr/local/lib/tsx/config.d/camera.sh`. | Install the package `tsx-xx60-board`. |
| The setup page has no camera field. | The panel has no file `/usr/local/share/tsx/setup.d/camera.py`. | Install the package `tsx-xx60-board-ha`. |
