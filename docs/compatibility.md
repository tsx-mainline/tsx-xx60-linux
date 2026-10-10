# Compatibility

This page lists each hardware variant of the xx60 panels and its support status. Update this page when a variant gets a test on hardware or when the code for a variant changes.

## Status values

| Status | Meaning |
|---|---|
| Tested | The system runs on this variant on hardware. |
| Expected | No code for this variant is necessary. It has the same board or the same driver as a tested variant. Nobody has run the system on it. |
| Implemented | The code for this variant exists. Nobody has run it on hardware. |
| Gap | The hardware differs from a tested variant, and the code does not handle the difference. The system can boot, but some parts can be wrong. |
| Not supported | The system cannot run on this variant. |

## Models

U-Boot selects the board from the `aml_dt` env value that the factory sets. The `government` flag marks the NC models ([hardware.md](hardware.md) "Panel variants").

| Model | Size | `aml_dt` | `government` | Status | Notes |
|---|---|---|---|---|---|
| TSW-1060, TSS-10 | 10" | `yushan_one_10inch` | 0 | Tested | The TSW and TSS models have the same hardware. |
| TSW-1060-NC | 10" | `yushan_one_10inch` | 1 | Expected | The same board as the TSW-1060. The NC handling is tested on the TSW-760-NC. |
| TSW-760-NC | 7" | `yushan_one_7inch` | 1 | Tested | |
| TSW-760 | 7" | `yushan_one_7inch` | 0 | Expected | The same board as the TSW-760-NC, with a microphone, a camera and a Bluetooth module. These parts are tested on the TSW-1060. The camera is not tested on a 7-inch panel. |
| Earlier 10" board | 10" | `yushan_one_old10inch` | 0 or 1 | Gap | See "Earlier boards". |
| Earlier 7" board | 7" | `yushan_one_old7inch` | 0 or 1 | Gap | See "Earlier boards". |
| TSW-560 | 5" | `yushan_one_5inch`, `yushan_one_old5inch` | 0 or 1 | Not supported | A 540x960 MIPI-DSI display. Mainline has no DSI host driver for the Meson8m2. |

## Touch glass

Each panel size has touch glass from one of two vendors. The LCD is the same. The vendor kernel uses one touch driver for both glasses, with a firmware file for each vendor.

| Glass | Status | Notes |
|---|---|---|
| EDT | Tested | FocalTech chip ID 0x65. The `edt-ft5x06` driver. |
| Truly | Expected | The same touch driver in the vendor kernel. Nobody has checked the chip ID with `edt-ft5x06` or the touch key zones. |

The backlight limits are different for the two glasses. The system limit `BACKLIGHT_MAX=23` is at or below the vendor limit for both glasses on the current boards.

| Board | Vendor limit, Truly glass (max / min) | Vendor limit, EDT glass (max / min) |
|---|---|---|
| `yushan_one_10inch` | 23 / 1 | 24 / 2 |
| `yushan_one_7inch` | 29 / 2 | 25 / 1 |
| `yushan_one_old10inch` | 22 / 5 | none |
| `yushan_one_old7inch` | 24 / 8 | none |

## Earlier boards

The stock boot image holds a device tree for an earlier board of each size (`yushan_one_old10inch`, `yushan_one_old7inch`). The tsx boot image gives these boards the device tree of the current board of the same size ([boot.md](boot.md)). The earlier boards differ from the current boards as follows:

| Part | Current board | Earlier board | Effect on the system |
|---|---|---|---|
| Camera | Fitted | No camera node | `tsx-hw` reads only the `government` flag. It reports `CAMERA=yes`, and the camera entity does not work. |
| Backlight limit, 10" | 23 / 1 | 22 / 5 | `BACKLIGHT_MAX=23` is one step above the vendor maximum. `BACKLIGHT_MIN=1` is below the vendor minimum. |
| Backlight limit, 7" | 29 / 2 (Truly), 25 / 1 (EDT) | 24 / 8 | `BACKLIGHT_MIN=1` is below the vendor minimum. |
| Key LED PWM | 366 Hz | 300 kHz | The device tree sets 366 Hz on all boards. |
| LVDS pixel clock, 10" | 68.136 MHz, vertical total 835 | 66.1 MHz, vertical total 810 | The device tree sets the current timing on all 10-inch boards. |
| SD and eMMC clock limit | 40 MHz | 50 MHz | None. The current limit is lower. |
