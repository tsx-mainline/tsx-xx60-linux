# tsx-xx60-linux

Mainline Linux and a Home Assistant kiosk for the Crestron TSW-760, TSW-1060 and TSS-10 touch panels. It replaces the vendor Android 5.1 firmware.

The panels are Amlogic Meson8m2 boards. The image has a mainline kernel, an Alpine Linux root file system, a Wayland kiosk (sway and Chromium) and a rescue system. The kiosk shows a Home Assistant dashboard full screen. The installer keeps a way back, so you can always restore stock Android.

## Supported models

| Model | Support |
|---|---|
| TSW-1060 (10 inch) and TSS-10 | Supported. TSS-10 is a variant of the same board. |
| TSW-760 (7 inch) | Supported. It is the same board with a 1024x600 display. |
| NC models, for example TSW-760-NC | Fully supported. They have no microphone, no camera and no working Bluetooth chip. |
| TSW-560 (5 inch) | Not supported. It has a MIPI-DSI display, not LVDS. |

## Status

| Feature | Status |
|---|---|
| Boot to the kiosk from the eMMC or from an SD card | Works |
| Touch screen and on-screen keyboard | Works |
| On-panel setup page | Works. See [rootfs.md](docs/rootfs.md) "Setup page". |
| Front keys and key LEDs | Works |
| Screen sleep and wake on touch | Works. The backlight and the display output turn off. |
| GPU-accelerated kiosk browser | Works. It needs a Chromium patch, see [rootfs.md](docs/rootfs.md). |
| Speakers, microphones and echo cancellation | Works |
| Speaker amplifier DSP (TFA9890) | Works with a userspace loader. The kernel driver runs the amplifiers with the DSP bypassed. The `tsx-tfa-dsp` service loads the DSP at each boot. If the load fails, the amplifiers stay in bypass. See [hardware.md](docs/hardware.md) "TFA9890 CoolFlux DSP". |
| CPU frequency | The maximum is 1608 MHz. 1800 MHz is not stable. |
| USB RGB LED bar | Works. The optional firmware tsx-ledbar-fw adds effects and control of each LED. |
| Voice assistant | Works on models with a microphone. It is a voice satellite with an on-panel wake word. The NC models have no microphone, so they have no voice assistant. See [ha.md](docs/ha.md). |
| Bluetooth (CSR8811) | Works as a Bluetooth proxy for Home Assistant, passive (`BT_PROXY`) or active (`BT_ACTIVE`). Both are off by default. The NC models have no working Bluetooth chip. |
| Ambient light sensor | Works. Automatic brightness follows the sensor. |
| Camera | Works on the TSW-1060 and TSS-10, up to 1920x1080 at 30 fps. The TSW-760 has the same camera. It is not tested on hardware. The camera is off by default. Home Assistant gets a camera entity in snapshot or live mode. See [camera.md](docs/camera.md) and [hardware.md](docs/hardware.md) "Camera". |
| Install from stock Android over the network | Works, with or without a UART. |
| Install from an SD card to the eMMC | Works. |
| Factory restore to stock Android | Works, with or without a UART and without a backup of the panel. |

## Start

1. Read [docs/index.md](docs/index.md) for the list of pages.
2. Follow [docs/install.md](docs/install.md) to install a panel.
3. Follow [docs/ha.md](docs/ha.md) to add the panel to Home Assistant.

Read [docs/recovery.md](docs/recovery.md) when an install fails or when you want stock Android back.

## Repository layout

| Directory | Contents |
|---|---|
| `docs/` | The documentation pages. |
| `kernel/` | The pinned kernel commit for each flavor (`KERNEL_REV.lts`, `KERNEL_REV.stable`) and the boot image tool. |
| `rootfs/` | The image build from packages, the profiles, the board files (`overlay/`) and the rescue initramfs. |
| `installer/` | The install and factory restore tools, the payload, the rescue system and their tests. |
| `provision/` | Home Assistant and panel provisioning scripts. |
| `tools/` | Bench, register, DSP, build and release tools. |
| `ci/` | Dockerfiles, `lint.sh` and the documentation link check. |

## License

This repository uses the GNU General Public License v2.0 or later (GPL-2.0-or-later). See [LICENSE](LICENSE). The kernel fork uses GPL-2.0, the same as its upstream.

## Trademark notice

Crestron and the names of Crestron products (including TSW-760, TSW-1060 and TSS-10) are trademarks of Crestron Electronics, Inc. This project is independent, community-made software. Crestron Electronics, Inc. does not support or endorse it, and is not affiliated with it.

## Warning

If you flash a panel with these tools, you replace its factory software. This voids any manufacturer warranty. An interrupted or incorrect flash can leave a panel unable to boot.

The installer and recovery scripts never write U-Boot or the first 1 MiB of either storage device. No software can recover that region. Use these tools at your own risk.
