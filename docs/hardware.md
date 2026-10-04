# Hardware

This page lists the hardware of the Crestron TSW-760, TSW-1060 and TSS-10 touch panels and the support status of each part. The board codename is `yushan_one`. Jabil makes the panels.

## Summary

| Part | Device | Support |
|---|---|---|
| SoC | Amlogic Meson8m2, quad Cortex-A9 | Works. The CPU runs at most at 1608 MHz |
| GPU | Mali-450 | Works (Lima) |
| Memory | 2 GB DDR3L | Works |
| Storage | 4 GB Hynix eMMC, removable SD-class card | Works |
| Display | LVDS panel, 7" or 10" | Works |
| Backlight | MP3309C on i2c-2 | Works |
| Touch | FocalTech FT5x06 on i2c-2 | Works |
| Front keys | 5 touch zones, 5 key LEDs | Works |
| Audio | ZL38051 voice processor, 2 x TFA9890 amplifiers, 2 microphones | Works |
| Ambient light sensor | MAX44009 on i2c-1 | Works |
| Ethernet | SMSC LAN8710 RMII PHY | Works |
| Bluetooth | CSR8811 on UART A | Works. A userspace tool loads the chip (see "Bluetooth (CSR8811)") |
| USB LED bar | USB accessory with an STM32 controller | Works |
| Camera | OV5640 on MIPI CSI-2 | Works on the TSW-1060 and TSS-10. Up to 1920x1080 at 30 fps and 2592x1944 at 15 fps. Not tested on the TSW-760 (see "Camera") |
| 5" TSW-560 variant | MIPI-DSI panel | Not supported. The LVDS pipeline does not apply to it |

The NC models (for example the TSW-760-NC-B-S) are fully supported. They have no microphone, no camera and no Bluetooth module. See "Panel variants".

## SoC and CPU

| Item | Value |
|---|---|
| SoC | Amlogic Meson8m2. CPU id 0x1d in the `Serial` line of `/proc/cpuinfo` |
| CPU | Quad Cortex-A9 |
| GPU | Mali-450 (Lima in mainline) |
| Compatibles | `amlogic,meson8m2-*` for the SoC, the VPU and the clock controller |
| PMIC | Ricoh RN5T618 at i2c-0 address 0x32 |
| VCCK (CPU core supply) | PMIC DCDC1. 825 to 1150 mV, ramp 250 uV/us. All four CPUs use it as `cpu-supply` |
| VDDEE/VDDAO | PMIC DCDC2, 1.15 V. The DTS makes it read-only |
| DDR3L supply | PMIC DCDC3, 1350 mV. The DTS makes it read-only |

U-Boot sets VCCK to 1100 mV at 1200 MHz. Read the DCDC1 voltage register with `i2cget -f 0 0x32 0x36`. The value 0x28 is 1100 mV and 0x2a is 1125 mV.

### CPU frequency and thermal limits

- The CPU runs at most at 1608 MHz. `scaling_available_frequencies` ends at 1608000.
- 1800 MHz at 1125 mV is not stable under bursty load. The board DTS does not enable `opp-1800000000`, and userspace cannot enable boost. 1992 MHz at 1150 mV is also not stable. The OPP is disabled.
- The global `cpufreq/boost` file exists, but no policy supports boost. A write fails with `EINVAL`. On the 7.2 kernel the value that you read back can flip after a failed write. `policy0/boost` and `cpuinfo_max_freq` stay the same. A reboot resets the file.
- The vendor kernel table `sys_pll_settings` has rows named "1800" and "1992". These rows program 1656 and 1704 MHz.
- The OD field of `sys_pll` (`HHI_SYS_PLL_CNTL` bits 17:16) divides by 1, 2 or 4. OD = 3 is not /8.
- At every OPP from 96 to 1608 MHz, the measured CPU frequency is the frequency that cpufreq reports. `rootfs/tests/cpufreq/vf-check.sh` measures it.

| Thermal trip | Vendor table (`yushan_one_10inch.dtd`) | Mainline |
|---|---|---|
| 70 C | Limit to 1608 MHz | Board DTS: passive trip, cooling state 1 at most (1416 MHz) |
| 80 C | Limit to 1200 MHz | `meson8.dtsi`: passive trip, no cooling limit |
| 90 C | Limit to 800 MHz | `meson8.dtsi`: hot trip |
| 110 C | | `meson8.dtsi`: critical trip |

Mainline uses the `step_wise` governor with 250 ms passive polling. Four busy cores run at 1416 MHz and stay near 75 to 77 C. Without the 70 C trip, four busy cores gain about 3 % throughput and run 6 to 7 C hotter. A kiosk load stays below 70 C and runs at 1608 MHz.

## Memory and storage

The panel has two independent storage devices. The Android names do not show which is which.

| Device | Linux name | Controller | Content as shipped |
|---|---|---|---|
| Hynix eMMC (H4G2a, 4 GB) | `mmcblk1` | SDHC port C, BOOT pins, 8-bit, 47.2 MHz | U-Boot (boot0, boot1 and the bootloader area). The Amlogic region layout `bootloader`, `reserved`, `cache`, `logo`, `recovery`, `misc`, `boot`, `system`+`data` (8 regions, see [boot.md](boot.md)). The stock `bootcmd` reads the Android `boot` region (kernel and DTB) |
| Removable SD-class card (Phison MP995) | `mmcblk0` | SDIO port B, CARD pins, card-detect active high | The Crestron MBR layout in the next table |

Stock card layout:

| Partition | Size | Content |
|---|---|---|
| p1 | 40 MB, FAT | Golden `boot.img` |
| p2 | 800 MB, ext4 | Android `/system` |
| p3 | 1 MB | U-Boot environment at byte offset 0x100000 (64 KiB used) |
| p5 | 1.5 GB | `sdcard` |
| p6 | 500 MB | `/data` |
| p7 | 100 MB | Cache |
| p8 | 300 MB | Logs |

U-Boot keeps its environment on the card (`mmcblk0` offset 0x100000), not on the eMMC. U-Boot logs "Saving Environment to eMMC..." and then "sd card save env ok". `saveenv` does not write the eMMC.

RAM is 2 GB on the TSW-760 and the TSW-1060 (`MemTotal` 2041668 kB).

Mainline uses the eMMC. A mainline install changes the layout:

| Layout | Boot | Root | Card |
|---|---|---|---|
| Transitional (card) | Golden slot and U-Boot hook | `p2` of the card | `p5` to `p8` merge into `p4` (`tsxdata`, `/data`) |
| Final (eMMC) | eMMC `boot` region (`mmcblk1p7`, from `blkdevparts=`) | eMMC `system`+`data` region (`mmcblk1p8`, ext4, `LABEL=tsxroot-emmc`) | `p1` (rescue image and U-Boot environment) and `p4` (`tsxdata`) |

In the final layout, everything that changes at run time lives on `p4` of the card: logs, the Chromium profile, and the audio and voice state. The layout bind-mounts it into the eMMC root. The conversion writes the eMMC boot and root regions once. See [boot.md](boot.md) for the golden slot, the U-Boot hook and "Root selection". See [install.md](install.md) for the partition tables of both layouts.

## Buses and addresses

| Bus | Address | Device | Use |
|---|---|---|---|
| i2c-0 | 0x32 | RN5T618 | PMIC |
| i2c-1 | 0x45 | ZL38051 | Voice processor |
| i2c-1 | 0x34 | TFA9890 | Left amplifier |
| i2c-1 | 0x36 | TFA9890 | Right amplifier |
| i2c-1 | 0x4a | MAX44009 | Ambient light sensor, interrupt GPIOX_7 (hwirq 119) |
| i2c-2 | 0x38 | FocalTech FT5x06 | Touch, IRQ GPIOX_21 (`gpio_intc` hwirq 133, falling edge), reset GPIODV_0 (active low) |
| i2c-2 | 0x17 | MP3309C | Backlight, enable GPIODV_28 |
| I2C_D | 0x3c | OV5640 | Camera sensor. The I2C_D controller uses interrupt SPI 39. |
| UART_AO | | `ttyAML0` | Console, 115200n8 |
| UART A | | `ttyAML1` | CSR8811 Bluetooth |
| usb0 | | DWC2 host port | External USB-A socket, VBUS GPIOX_18 |

## GPIOs

| GPIO | Function | Level |
|---|---|---|
| GPIODV_22 | LCD regulator enable | Active low |
| GPIODV_23 | LCD supply | Active low |
| GPIODV_8 | LCD panel enable | Active high |
| GPIODV_28 | MP3309C backlight enable | High = on |
| GPIODV_29 | PWM_C, keypad LED brightness (about 366 Hz) | PWM |
| GPIODV_0 | Touch reset | Active low |
| GPIOX_21 | Touch interrupt | Falling edge |
| GPIOX_11, 19, 10, 17, 16 | Key LED enable, keys 1 to 5 from top to bottom | Active low |
| GPIOX_7 | Ambient light sensor interrupt | |
| GPIOX_18 | USB-A VBUS | |
| GPIOY_8 | Bluetooth reset and power (`rfkill-gpio`, node `bt-dev`) | Active high holds the chip in reset |
| GPIOAO_8 to 11 | I2S MCLK, BCLK, LRCLK and data out | |
| GPIOY_5 | I2S data in | |
| `GPIO_BSD_EN` | Speaker enable. See "Audio" | |

## Display: LVDS panel

The interface is LVDS, single link, 8-bit, VESA/JEIDA packing (`repack=1`). The 7-inch panel (TSW-760) and the 10-inch panel (TSW-1060 and TSS-10) both use it. The vendor DTS names the pinctrl groups "ttl", but the interface is LVDS.

LVDS uses dedicated pins, not a CBUS pinmux group. The PHY is the shared DIF/CSI PHY. The driver programs it through `HHI_DIF_CSI_PHY_CNTL1..3` in the register window of the clock controller. A DRM encoder needs a syscon regmap to HHI for this.

### Panel timings

| | TSW-760 (7") | TSW-1060 / TSS-10 (10") |
|---|---|---|
| Active | 1024 x 600 | 1280 x 800 |
| Total | 1344 x 635 | 1360 x 835 |
| Pixel clock | 51.2064 MHz | 68.136 MHz |
| Hsync width / back porch | 1 / 160 | 20 / 30 |
| Vsync width / back porch | 5 / 6 | 2 / 4 |

Mainline runs the 7" panel at 60 Hz from a 51.205916 MHz pixel clock. The vendor uses 51.205 MHz.

### VID2 PLL and the LVDS clock chain

The pixel clock comes from a fractional PLL (`HHI_VID2_PLL_CNTL`, CBUS 0x10e0). The clock tree is:

```
xtal -> vid2_pll_dco -> vid2_pll (OD /1 /2 /4)
        -> viid_pll_pre_div / viid_pll_post_div -> viid_pll mux
        -> vid2_pll_final_div ("XD")
        -> vclk2_in_sel -> vclk2_en -> vclk2_div1
        -> cts_encl_sel -> cts_encl (ENCL pixel clock)
```

Register values for the 10" panel:

| Register | Value | Meaning |
|---|---|---|
| `HHI_VID2_PLL_CNTL` (0x10e0) | `0xc1000427` | M=39, N=1, OD sel=2 |
| `HHI_VID2_PLL_CNTL2` (0x10e1) | `0x0439abef` | FRAC=0xbef |
| `HHI_VID2_PLL_CNTL3` (0x10e2) | `0xca49b823` | |
| `HHI_VID2_PLL_CNTL4` (0x10e3) | `0xd4000d67` | Spread spectrum off |
| `HHI_VID2_PLL_CNTL5` (0x10e4) | `0x01700101` | Output mux = VID2 path |
| `HHI_VIID_CLK_DIV` (0x104a) | `0x00018100` | |
| `HHI_VIID_CLK_CNTL` (0x104b) | `0x000c0001` | |
| `HHI_VIID_DIVIDER_CNTL` (0x104c) | `0x0001e903` | |

For the 10" panel, FRAC 0xbef gives M = 39 + 3055/4096 = 39.746 and a DCO of 24 MHz x 39.746 = 1907.800782 MHz. OD /2 gives a 476.950196 MHz LVDS bit clock. A /7 divider gives a 68.135743 MHz pixel clock.

For the 7" panel, the DCO is 1433.777 MHz (level 1) and the bit clock is 358.444 MHz. FRAC is 0xbda. The vendor uses 0xbd8 because it truncates the pixel clock to whole kHz. This is a -9.5 ppm difference.

Clock rules for the LVDS encoder:

- `clk_set_rate(cts_encl, ...)` is not enough. The divider search of the common clock framework can meet the ENCL rate with the wrong topology (for example a pre-divide by 5 instead of 1). The pixel clock is then right, but the 7x bit clock for the LVDS PHY is wrong.
- The encoder sets exclusive rates on `vid2_pll`, `viid_pll_pre_div`, `viid_pll_post_div` and `vid2_pll_final_div` in this order. It then fixes the parents and enables `cts_encl`. See [kernel.md](kernel.md).
- U-Boot leaves the pixel clock at about 103 MHz after its LCD init (`set_hpll_clk_out()` writes `HHI_VID2_PLL_CNTL2` = `0x0430a800`). This gives about 91 Hz refresh. The encoder always reprograms the whole chain and does not use the state that the bootloader leaves.
- `HHI_GCLK_OTHER` bit 23 (vendor name `VCLK2_ENCL`) is a peripheral clock gate. The clock driver models it as `CLKID_VCLK2_ENCL`, and the LVDS encoder enables it with `cts_encl`. With the bit clear, the ENCL runs and the measured clock is correct, but the VPU raises no vsync interrupt. Every DRM commit then times out (`flip_done timed out`) and the boot stalls for about one minute.

### Panel power sequencing

Both panel sizes use three GPIOs, chained with delays:

| Step | GPIO | Action | Delay before next step |
|---|---|---|---|
| 1 | GPIODV_22 | Low (regulator enable, active low) | 10 ms |
| 2 | GPIODV_23 | Low (active low) | 170 ms total from step 1 |
| 3 | GPIODV_8 | Low, then high (active high) | 20 ms |

Power-off is the reverse, with gaps of 20, 120 and 10 ms. The DTS uses three chained `regulator-fixed` nodes. These nodes cannot describe the exact power-off gaps, because `panel-lvds` has no delay properties for each panel. The names of the supply rails behind GPIODV_22 and GPIODV_23 are not known.

### Backlight

| Item | Value |
|---|---|
| Driver | MP3309C, I2C |
| Address | i2c-2, 0x17 |
| Enable | GPIODV_28 |
| Mode and OVP | SYNC mode, 35.5 V OVP (the mainline default matches the vendor value) |
| Brightness limit | Step 23 of 31. Userspace must keep this limit, because the vendor tuning assumes it |

PWM_C (GPIODV_29, 366 Hz) drives the keypad LEDs, not the LCD backlight. There is no `pwm-backlight` node.

Brightness 0 does not switch the chip off. The driver writes 0 to the dimming bits D4..D0 of register 0x00 and keeps the EN bit set. The enable GPIO stays high. The LED current is zero. At brightness 0, register 0x00 reads 0x80 and register 0x01 reads 0x28. At level 3, register 0x00 reads 0xe0.

With the backlight dark, the LCD still shows the last frame, and the frame is visible in room light. To blank the screen, stop the scanout and remove the panel power. `tsx-idled` does this through the compositor (sway `output * power off`). The CRTC then goes inactive, and `panel-lvds` turns the panel regulators off (GPIODV_8 low, GPIODV_22 and GPIODV_23 high). The panel enable path calls `backlight_enable()`, so the backlight stays dark until `tsx-idled` writes a level. The power-on sequence of the panel (about 225 ms) is most of the wake time. See [rootfs.md](rootfs.md#screen-blanking).

## Touch, front keys and key LEDs

The touch controller is a FocalTech FT5x06 family part (chip ID 0x65, an EDT glass). It is at i2c-2 address 0x38 and uses the mainline driver `edt-ft5x06`. The IRQ is on `gpio_intc` hwirq 133 (GPIOX_21), falling edge. The reset line is GPIODV_0, active low.

### Front keys

The panel has five capacitive keys printed on the glass. They are in a column to the right of the LCD. They are not separate switches, GPIOs or an ADC/I2C keypad. The sensing area of the touch controller extends past the visible LCD. Five rectangles outside the LCD area are the keys.

Mainline uses the generic `touch-overlay` helper (`drivers/input/touch-overlay.c`) in `edt-ft5x06`:

- A `touch-overlay` DT child node on the touchscreen defines a `segment-screen` (the display area) and five `segment-keyN` rectangles.
- A contact in a key rectangle is a key event. A contact on the screen segment is a normal touch. The driver drops any other contact.
- A swipe that starts on the screen and ends over a key stays a touch.
- The keys send `KEY_F13` to `KEY_F17`, not the vendor codes `KEY_BACK`, `KEY_HOME`, `KEY_MUTE`, `KEY_VOLUMEUP` and `KEY_VOLUMEDOWN`. A browser and a compositor give the vendor codes real meanings, which the kiosk must not trigger. A userspace daemon maps F13 to F17 to actions (see [rootfs.md](rootfs.md)).

| Key | Position from top | Function printed on glass | Key code | Key LED enable GPIO |
|---|---|---|---|---|
| 1 | Top | Power | `KEY_F13` | GPIOX_11 |
| 2 | | Home | `KEY_F14` | GPIOX_19 |
| 3 | | Lights | `KEY_F15` | GPIOX_10 |
| 4 | | Up | `KEY_F16` | GPIOX_17 |
| 5 | Bottom | Down | `KEY_F17` | GPIOX_16 |

### Key LEDs

- Each key has one enable GPIO, active low (table above). The DT declares them as `gpio-leds` (`tsx:key1` to `tsx:key5`).
- All five keys share one brightness PWM: PWM_C on GPIODV_29, about 366 Hz. The DT declares it as `pwm-leds` on `pwm_cd` (`tsx:keypad`). On this panel PWM_C serves only the keypad LEDs.
- At PWM duty 0, the Meson8 PWM block still emits a very short pulse. For a dark key at level 0, software must also drop the enable GPIO of each key.
- U-Boot turns the key LEDs on (level 128) before Linux starts.

## USB LED bar

The LED bar is an external USB-A accessory. It plugs into the same USB-A socket that a rescue stick uses.

| Item | Value |
|---|---|
| Controller | Crestron STM32, USB `14be:001b` ("IO Processor") |
| Alternate IDs | `0009` and `001a` (bootloader and alternate) |
| Speed and endpoints | Full speed, two bulk endpoints (out 0x02, in 0x82) |
| Port | usb0 (first DWC2 host port, VBUS on GPIOX_18). Android numbers it "bus 2" |
| Kernel driver | `leds-crestron-stm32`. One multicolor LED class device `tsx:rgb:bar` (`max_brightness` 100, `red green blue`) |
| LEDs | 16 RGB LEDs, 8 on each side |

Protocol: each write is one bulk OUT transfer with no header. The payload is the Cresnet frame (`dest len payload...`, `byte[1] == len-2`). The device echoes each frame on the bulk IN endpoint with `byte[0] = 0x02`.

| Join | Frame |
|---|---|
| Analog (RGB channel 0 to 100) | `00 05 14 <join_hi> <join_lo> <val_hi> <val_lo>`. Joins 3, 4 and 5 are R, G and B |
| Digital (on/off) | `00 03 00 <join_lo> <join_hi>\|0x80*off` |

The stock firmware shows one color on all 16 LEDs. The optional firmware `tsx-ledbar-fw` adds per-LED control and effects. The LEDs have these names and indexes:

| Index | Name | Index | Name |
|---|---|---|---|
| 0 to 7 | `R1` to `R8` (right side, top to bottom) | 8 to 15 | `L1` to `L8` (left side, top to bottom) |

Each LED has its own red, green and blue output on three TLC59116 drivers. The table below is the LED map of the optional firmware tsx-ledbar-fw (`led_out` in `fw/src/leds.c`). The stock firmware has no per-LED control. The map gives the driver output for each LED index. The red, green and blue drivers use the same output number.

| Index | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Output | 15 | 6 | 0 | 1 | 2 | 3 | 4 | 5 | 14 | 13 | 12 | 11 | 10 | 9 | 8 | 7 |

See [ha.md](ha.md) for the LED bar controls in Home Assistant.

## Ambient light sensor

| Item | Value |
|---|---|
| Sensor | MAX44009 |
| Address | i2c-1, 0x4a |
| Interrupt | GPIOX_7 (hwirq 119) |
| Driver | Mainline IIO driver `max44009` |

A userspace daemon sets the backlight level from the lux value with a step curve (see [rootfs.md](rootfs.md) "Ambient light sensor"). The front window passes only part of the light. `ALS_SCALE` in `panel.conf` corrects this. The default is 1.0.

## Audio

The audio path is: SoC I2S <-> Microsemi ZL38051 voice processor (AEC and noise reduction, i2c-1 0x45) <-> two TFA9890 class-D amplifiers (i2c-1, 0x34 left and 0x36 right) <-> two speakers. Two digital microphones also feed the ZL. The ZL is the I2S clock slave to the SoC and the clock master to the amplifiers. The ZL boots the vendor configuration from its own flash. In this configuration, the ZL passes playback straight through and returns one echo-cancelled mono microphone stream to the SoC.

| Part | Support |
|---|---|
| I2S playback | Works. The kernel clears the JTAG override on the I2S pins (see below) |
| Capture | Works. The AUDIN driver provides it |
| ZL38051 | Works. `zl38060.c` has I2C access and the `mscc,flash-boot` mode |
| TFA9890 | Works. The kernel driver runs the amplifiers with the DSP bypassed. A userspace loader enables the DSP |

### I2S pins and JTAG

The I2S output pins of the SoC are GPIOAO_8 to 11 (MCLK, BCLK, LRCLK and data). U-Boot leaves `AO_SECURE_REG1` at 0x102. This register is in the `secbus2` block, not in the normal pinmux. Bits 1 and 8 route the JTAG debug port onto GPIOAO_8 to 11. This overrides the pinmux and the GPIO output registers. With the bits set, every I2S pad reads a constant level, and playback and capture fail without an error.

A `set_mux_hook` in the Meson8 pinmux driver clears both bits through the `secbus2` syscon whenever a function is muxed onto GPIOAO_8 to 11.

### Speaker enable

- The speaker-enable line (`GPIO_BSD_EN`, the vendor name) is not a plain GPIO bit on Meson8m2.
- The output value bit is `PAD_PULL_UP_REG2` bit 0. It is not `GPIO0_O` bit 31. M8M2 is not `IS_MESON_M8_CPU`, so `GPIO0_O` bit 31 is the BOOT_0 pull-direction bit in the pinctrl bank model.
- The output enable is `GPIO0_O` bit 30 plus `AO_SECURE_REG0` bit 0.
- A `simple-audio-amplifier` node gates the line. The line is high only while audio plays (plus 5 s).

### Other audio facts

- On Meson8, the AIU I2S FIFO interrupt fires once for each buffer, not once for each period. A platform flag makes the driver report periods from an hrtimer (see [kernel.md](kernel.md)).
- Capture uses the AUDIN driver (no mainline Meson8 capture path exists). It uses a private ring buffer. A 4 ms timer converts it to ALSA periods. The samples are 24-bit, packed 8-left and 8-right for each 64-byte FIFO block.
- The flash configuration of the ZL sets -12 dB on the amplifier feed. The TFA9890 runs with its internal DSP bypassed (digital unity gain, no limiter). The only protection is a software volume cap. The cap is 0 dB (`max_dB` of the "Master" volume in `/etc/asound.conf`). With the -12 dB of the ZL, a full-scale sample reaches the amplifiers at -12 dBFS at most. This is 12 dB below the maximum level of stock Android, which runs the DSP.
- The sound card has the name `TSW-1060` on all models. Userspace uses this name.

### TFA9890 CoolFlux DSP

In stock Android, a userspace library loads the DSP over the I2C bus of the codec driver (`libjbl_acoustic.so`, linked with the NXP "nxpTfaHost" library). No kernel driver loads it. The DSP firmware, the speaker model and the volume-step tables come from a tuning variant that the factory selects. One byte in the SPI NOR flash (offset 0x1f000+3) holds the choice: 0x00/0xFF, 0x01 and 0x02 select three `.cnt` container files, one for each of three speaker suppliers. The choice does not depend on the panel size.

TFA9890 registers (16-bit, big-endian, addresses 0x34 and 0x36):

| Reg | Name | Notes |
|---|---|---|
| 0x00 | status | Bit 11 = ACS (DSP configured), bit 10 SPKS, bit 5 OCDS |
| 0x06 | audio | VOL[15:8] in 0.5 dB steps, bit 5 CFSM (soft mute) |
| 0x09 | SYS_CTRL | PWDN/I2CR/CFE/AMPE/DCA/SBSL/AMPC |
| 0x70-0x73 | CoolFlux RPC | Message-based load of patch, config, speaker model and EQ. Acknowledge through 0x73 |

Mainline ships a userspace loader (`tfa_dsp.py`), not a kernel firmware loader. The load is about 320 opaque vendor I2C transactions. The module parameter `snd_soc_tfa989x.dsp=1` (off by default) does these things:

- It turns off the register cache of the codec driver, which would otherwise fight the loader.
- It adds a "DSP" input source and a "DSP Playback Volume" control.
- If the DSP is not configured (`ACS=1`), the driver falls back to the bypass path for each channel. A failed or skipped load never leaves one amplifier protected and the other not.

The DSP configuration survives amplifier power-down (`SBSL`, `CFE` and `AMPC` persist). The `.cnt` tuning files are Crestron and NXP proprietary data and are not in the repository. The build or the install gets them from the firmware image of the user and checks their checksums (see [rootfs.md](rootfs.md)).

## Bluetooth (CSR8811)

| Item | Value |
|---|---|
| Chip | CSR8811A08, Bluetooth 4.0 |
| Port | UART A (`/dev/ttyAML1`). UART_AO (`ttyAML0`) stays the console |
| Reset and power | `rfkill-gpio` node `bt-dev` on GPIOY_8. Active high holds the chip in reset |
| Protocol | BCSP, 115200 baud, 8 data bits, even parity, one stop bit, no flow control |
| Crystal | 26 MHz |

These are the BCSP defaults of the chip. The vendor PSR file leaves `PSKEY_UART_CONFIG_BCSP` (`&01bf`) commented out, so the default `0x0806` (parity on, even, no RTS/CTS) applies. `hciattach ... bcsp` sets this line. `btattach -P bcsp` sets no parity and does not work with this chip.

The kernel has the BCSP protocol of `hci_uart` (`CONFIG_BT_HCIUART_BCSP`). It has no driver that loads the PSR and no serdev driver for a BCSP chip. The bring-up is a userspace sequence. `tsx-bt up` runs it (`rootfs/overlay/usr/local/sbin/tsx-bt`):

1. It blocks and unblocks the `bt-dev` rfkill. This pulses the reset line.
2. It uploads the PSR over BCSP with `csr_psload.py` (`/usr/local/lib/tsx/`). The script establishes the BCSP link, sends one BCCMD SETREQ for each PS key into PSRAM (store `0x0008`) in file order, and then does a warm reset. It does the job of `bccmd psload`. BlueZ 5.66 and later do not have `bccmd psload`, and Alpine does not ship it.
3. It runs `hciattach -s 115200 /dev/ttyAML1 bcsp 115200` (Alpine package `bluez-deprecated`). `hciattach` establishes the BCSP link again and hands the line to the kernel.
4. It runs `hciconfig hci0 up` and checks that the BD address is the one that it loaded.

`tsx-bt up` takes about 4.5 s. After it, `hci0` is UP RUNNING. The chip reports "CSR - bc7" and HCI version 4.0. During link establishment the chip does not answer a SYNC with a SYNC-RESP. It sends its own SYNC and sends CONF after the SYNC-RESP of the host. `csr_psload.py` handles this.

No `bluetoothd` runs. The passive scanner of the Bluetooth proxy uses a raw HCI socket. The links of the active proxy use the ATT socket of the kernel (see [ha.md](ha.md) "Bluetooth proxy").

### PSR file

The vendor file is `/system/bin/PSR-CSR8811.psr` of stock Android (7814 bytes, sha256 `96709f6c...76676aa8be`). It holds the ROM patches of the CSR8811A08, the UART setup (BCSP, 115200), the 26 MHz crystal and its trim. It is Crestron data and is never in this repository or in an image.

- The installer reads it from the panel (read-only) before it overwrites the eMMC root region (`installer/lib/tsx-psr.sh`, [install.md](install.md) "Bluetooth PSR file").
- If the panel has no file, the installer takes it from the public firmware package of Crestron (`rootfs/vendor-fetch.sh --psr`, the `system.img` of the `.puf`).
- The panel keeps it in `/usr/local/share/tsx/csr8811/`, with a `SOURCE` record.
- Without the file, `tsx-bt` loads only the Bluetooth address, and the chip runs on its ROM defaults.

### Bluetooth address

The base PSR has no address. A `PSKEY_BDADDR` line adds it: `&0001 = 00m4 m5m6 00m3 m1m2` for the address `m1:m2:m3:m4:m5:m6` (four 16-bit words: LAP high, LAP low, UAP, NAP). `tsx-bt` uses `BT_MAC` of `panel.conf` if it is set. Otherwise it uses the eth0 MAC. Stock Android uses the same address: the property `ro.boot.mac_bt`, which equals the U-Boot `ethaddr`. The address is unique for each panel and stays the same over a reinstall. A passive scan never sends it over the air.

### LE links (active proxy)

| Item | Value |
|---|---|
| LE Read Supported States | `0x1f3fffff` |
| Scan while central link is held | Yes (bit 24) |
| Second link while one is held | Yes (bit 28) |
| Scan while initiating a link | No (bits 22 and 23). The kernel stops every scan before LE Create Connection |
| LE Read Buffer Size | 0. LE links share the 10 ACL buffers of 310 bytes |
| Links offered by the proxy | 3. The maximum that the chip supports is not known |
| ATT MTU | 517 |

- After `hciattach`, LE Host Supported is off, and the kernel refuses LE links (`HCI_LE_ENABLED` is not set, because no `bluetoothd` runs). `tsx-btscan` sends Write LE Host Supported once before its first link.
- For a link, the kernel programs its own scan: a 60 ms window every 60 ms, with only the one device in the accept list. The kernel stops this scan when the link is up or has failed. `tsx-btscan` pauses its scan before the connect and sends its scan commands again 0.5 s after each link event. During a connect, the advertisement rate falls to about 0.2 per second.
- An active scan on the raw socket puts the kernel in the discovery state "finding". While the state is "finding", the kernel does not start the scan for a pending link, and each connect fails after 20 s (Linux 6.18). `tsx-btscan` sends Inquiry Cancel with the scan off after an active scan, and once after it opens the HCI socket. The kernel then sets the state to "stopped". The CSR8811 answers "Command Disallowed", and the kernel logs "Ignoring error of Inquiry Cancel command". This is expected.
- A connect to an address that no device uses fails after 20.2 s.
- A connect takes 1.8 to 2.6 s for a peer that advertises every 1.28 s.
- A peer that reads the remote features as peripheral can drop the link while it comes up. The CSR8811 is a Bluetooth 4.0 central and does not know that procedure. Some controllers answer "Unsupported Remote Feature" and the peer drops the link (HCI reason 0x3E or 0x13). The proxy reports the failure, and Home Assistant tries again. BLE sensors do not read the remote features.

## Camera

The TSW-1060 and the TSS-10 have an OmniVision OV5640 camera sensor (5 MP, chip ID 0x5640). The vendor board files name an OV5645, but the fitted sensor is an OV5640. The sensor sends YUV 4:2:2 frames over 2 MIPI CSI-2 data lanes. The camera has no privacy shutter.

The TSW-760 has a camera with the same connections. The vendor device trees of the 7-inch and the 10-inch panel have the same camera node. The TSW-760 DTB and the TSW-1060 DTB have the same camera nodes. The camera of the TSW-760 is not tested on hardware.

Two kernel modules drive the camera: `ov5640` for the sensor and `meson8-csi2` for the receiver and the capture device. The NC models have no camera. The camera is off by default in Home Assistant (see [ha.md](ha.md) "Camera").

### Capture a frame

1. Install `v4l-utils` with `apk add v4l-utils`.
2. Run `media-ctl -p` and find the device node of the entity `meson8-csi2-capture`. The steps below use `/dev/media0` and `/dev/video0`.
3. Set the sensor and the receiver to the same format:

   ```sh
   media-ctl -d /dev/media0 -V '"ov5640 3-003c":0 [fmt:UYVY8_1X16/1280x720]'
   media-ctl -d /dev/media0 -V '"meson8-csi2":0 [fmt:UYVY8_1X16/1280x720]'
   ```

4. Set the capture format and write 30 frames to a file:

   ```sh
   v4l2-ctl -d /dev/video0 --set-fmt-video=width=1280,height=720,pixelformat=UYVY
   v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=30 --stream-to=frames.uyvy
   ```

### Connections

| Signal | Connection |
|---|---|
| I2C | I2C_D (GPIOH_7, GPIOH_8), address 0x3c. The sensor has no interrupt line. The I2C_D controller uses SPI 39. |
| Power-down | GPIOH_6, active high |
| Reset | GPIOH_4, active low |
| Clock | 24 MHz from GEN_CLK on GPIOH_9 |
| Supplies | DOVDD 1.8 V, AVDD 2.8 V, DVDD 1.5 V. The supplies are always on. The device tree describes them as fixed regulators |
| Data | 2 data lanes on clock channel A of the D-PHY |

### Receiver

The receive path is the D-PHY, a DesignWare CSI-2 host (version 1.02) and the CSI-2 adapter. The adapter runs in memory mode: it writes each frame into a DMA buffer and raises an interrupt at the end of the frame. The capture path does not use VDIN.

| Block | Address or register | Notes |
|---|---|---|
| CSI-2 host | 0xd0140000 | |
| D-PHY | 0xd0142000 | |
| CSI-2 adapter | 0xd010a800 | On the VPU bus, inside the VPU range of `drm/meson`. The driver maps it without a region request. Frame interrupt SPI 95, rising edge |
| Analog front end | `HHI_CSI_PHY_CNTL0`, `HHI_CSI_PHY_CNTL1` | Lane power and analog setup |
| PHY clock | `HHI_MIPI_PHY_CLK_CNTL` | Source 1 (fclk_div3, 850 MHz) divided by 4 gives 212.5 MHz. The host and the D-PHY registers need this clock. Without it, a register access aborts. Only sources 1 and 5 give a clock |
| CSI clock gate | `HHI_GCLK_MPEG1` bit 18 (`CSI_DIG_CLKIN`) | |
| Byte order | `CSI2_GEN_CTRL1` | Maps the bytes of each 32-bit word. The reset value 0xe4 stores each word in reversed byte order. The driver sets 0x1b, so memory holds the bytes in bus order |

The driver sets two D-PHY timings from the link frequency:

- HS settle: the minimum of the D-PHY window, 85 ns + 6 UI. The middle of the window gives bad frames at a 248 MHz link. `THS_SETTLE` reads back 0, but the written value has an effect.
- Clock lane check: the largest divider that keeps the divided HS clock at 40 MHz or more. A slower check clock makes the clock lane leave HS mode.

### Media graph and formats

| Entity | Node | Role |
|---|---|---|
| `ov5640 3-003c` | V4L2 subdevice | Sensor |
| `meson8-csi2` | V4L2 subdevice | CSI-2 receiver |
| `meson8-csi2-capture` | Video device, `V4L2_CAP_IO_MC` | Capture to memory |

| Item | Value |
|---|---|
| Pixel formats | UYVY, VYUY, YUYV, YVYU. Each format matches the bus code of the same name |
| Frame sizes | 32x16 to 2592x1944 |
| I/O | MMAP, DMABUF and `read()` (videobuf2 dma-contig) |

### Modes

| Size | Link frequency | Frame rate | Bytes per frame (UYVY) |
|---|---|---|---|
| 640x480 | 192 MHz | 30 fps | 614400 |
| 1280x720 | 248 MHz | 30 fps | 1843200 |
| 1920x1080 | 296 MHz | 30 fps | 4147200 |
| 2592x1944 | 336 MHz | 15 fps | 10077696 |

Both kernel flavors give the same frame rates.

### Power

The sensor is in power-down with its clock off while no program uses the camera. Runtime PM powers it down 1 s after the last user closes it: GPIOH_6 goes high and GEN_CLK stops. The receiver clocks run only while a stream runs.

### Image tuning

The `ov5640` driver in this kernel writes a tuning table for the TSW-1060 camera module at each power-on, after its init table. The table holds 104 registers from the vendor kernel: the auto white balance block, the color matrix and the lens correction. The driver selects it by the machine compatible `crestron,tsw1060` or `crestron,tsw760`, so the TSS-10 and the TSW-760 use it too. The vendor kernel writes the same table on both panel sizes. The kernel log shows `ISP tuning for crestron,tsw1060` (`crestron,tsw760` on a TSW-760). Without the table, the image has a magenta cast.

### Limits

- At 2592x1944, the first 10 to 12 frames after a stream start have an error bit and no data. The driver drops them. The first good frame can take up to 3.5 s.
- The driver drops the first frame interrupt after each start, because it reports 0 bytes. The sequence number counts every frame interrupt, so the sequence can have gaps.
- `v4l2-compliance` passes all tests on the media device, the video device and the receiver subdevice. The `ov5640` subdevice fails the frame interval tests.
- A USB UVC camera also works in the external USB-A socket. The LED bar accessory uses the same socket.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `media-ctl -p` shows no `ov5640 3-003c` entity, and no subdevice nodes exist | The `ov5640` module did not load, or the sensor did not answer on I2C_D. An NC model has no sensor. The receiver waits for the sensor | Run `dmesg \| grep ov5640` and `lsmod`. Load the module with `modprobe ov5640` |
| `VIDIOC_REQBUFS` or `VIDIOC_STREAMON` fails with `EBUSY` | Another program uses the camera, for example the Home Assistant camera | Stop the other program. For the Home Assistant camera, set `CAMERA=off` ([ha.md](ha.md) "Camera") |
| A stream at 2592x1944 gives no frame | A rare start failure at the largest size | Stop the stream and start it again |
| The image has a magenta cast | The `ov5640` driver has no tuning table for this camera module | Use the `tsx-xx60` kernel. Its `ov5640` driver logs `ISP tuning for crestron,tsw1060` (or `crestron,tsw760`) at probe |

## Ethernet

| Item | Value |
|---|---|
| PHY | SMSC LAN8710, RMII |
| Drivers | Mainline `dwmac` and the PHY driver |
| Addressing | DHCP by default |
| MAC address | The U-Boot `ethaddr` environment variable. The factory or the provisioning sets it once for each panel. It does not come from a SoC efuse |

U-Boot passes the MAC to the kernel through the device tree or the bootargs.

## Panel variants

The U-Boot variable `government` marks a panel variant. U-Boot puts it on the kernel command line as `androidboot.government=N`. Linux cannot change it. A write of `government=0` with `fw_setenv` does not last. U-Boot sets the value again at the next boot from another source, probably the factory key storage. The project never writes U-Boot.

| Flag | Models | Microphone | Camera | Bluetooth module |
|---|---|---|---|---|
| `government=0` | TSW-760, TSW-1060, TSS-10 | Yes | Yes | Yes (CSR8811) |
| `government=1` | NC models, for example TSW-760-NC-B-S | No | No | No |

The speaker works on both variants. On an NC panel, nothing answers on UART A: the UART receives no byte, and the CTS input stays high.

At boot, the `tsx-config` service runs `tsx-hw detect` before `tsx-config apply`. `tsx-hw` is the only program that reads the flag. It writes `/run/tsx/hw.conf` (mode 644, so the `kiosk` and `tsx-setup` users can read it):

| Key | Values | Meaning |
|---|---|---|
| `GOVERNMENT` | `0`, `1`, `unknown` | The flag from the command line |
| `MIC` | `yes`, `no` | A microphone is fitted |
| `BT` | `yes`, `no` | A Bluetooth module is fitted |
| `CAMERA` | `yes`, `no` | A camera is fitted |
| `REASON` | text | Why a part is missing (empty if none is) |

With `government=1`, `MIC`, `BT` and `CAMERA` are `no`. Any other value, no flag, or no `hw.conf` means a panel with all parts. `tsx-hw get KEY` and `tsx-hw show` print the file. If the command line has no flag, the rescue reads the U-Boot environment. `tsx-hw` has no fallback to the environment, because `fw_printenv` needs the env disk and can hang ([boot.md](boot.md) "Troubleshooting").

These programs read `hw.conf`, not the command line:

| Program | Behavior without a part |
|---|---|
| `tsx-config` | Accepts `VOICE=on`, `BT_PROXY=on`, `BT_ACTIVE=on` and each `CAMERA` mode, so that a `panel.conf` from another panel still loads. `set` and `show` print a warning. `apply` treats these keys as `off` ([rootfs.md](rootfs.md) "Panel configuration") |
| `tsx-bt` | Does not touch the chip (no rfkill pulse, no UART). `tsx-bt status` prints `state=absent` with the reason. `up` and `down` exit 0 |
| `tsx-voice` | Does not start. `tsx-esphome` serves the panel entities, also with `VOICE=on` |
| `tsx-esphome` | Announces no Bluetooth proxy flags and no voice features. It has no camera entities. The other entities are the same as on a panel with all parts ([ha.md](ha.md)) |
| Setup page | Shows the voice assistant, the Bluetooth proxy and the camera as not available |
| Installer | Looks for no Bluetooth PSR file and does not download the `.puf` for it ([install.md](install.md) "Bluetooth PSR file"). The speaker DSP files install as on other panels |

If the chip does not answer on a panel with `government=0`, the failure reason names the flag.

Host tests: `rootfs/tests/test-hw.sh`, and the government cases in `rootfs/tests/test-bt.sh`, `test-tsx-config-apply.sh`, `test-esphome.sh`, `test-setup.sh` and `installer/lib/tests/test-tsx-psr.sh`.

## Model differences

| | TSW-760 | TSW-1060 | TSS-10 |
|---|---|---|---|
| Panel | 7", 1024x600, 51.2064 MHz | 10", 1280x800, 68.136 MHz | 10", 1280x800, 68.136 MHz |
| SoC and board | Meson8m2, `yushan_one` | Meson8m2, `yushan_one` | Meson8m2, `yushan_one` |
| Boot image | Own DTB and `aml_dt` variant string | Own DTB and `aml_dt` variant | Same hardware as the TSW-1060. Only the `product_name` environment string and the hostname differ. Use the TSW-1060 DTB |
| U-Boot env | `lcdsize=7inch`, `aml_dt=yushan_one_7inch`, `display_width/height=1024/600` | `lcdsize=10inch`, `aml_dt=yushan_one_10inch` | As TSW-1060 |
| Touch keys (vendor `tpkey_1..5`) | x 1060..1130, y 5..90, 120..210, 250..340, 380..470, 510..600 | x 1310..1380, y 50..140 ... 650..740 | As TSW-1060 |
| Backlight dimming steps in the vendor kernel, max/min (EDT glass) | 29/2 (25/1) | 23/1 (24/2) | As TSW-1060 |
| VID2 PLL | DCO 1433.77 MHz ("level 1": CNTL3 0xca45b823, OD_FB 0) | DCO 1907.80 MHz ("level 2": CNTL3 0xca49b823, OD_FB 1) | As TSW-1060 |
| Board DTS | `meson8m2-crestron-tsw760.dts` | `meson8m2-crestron-tsw1060.dts` | `meson8m2-crestron-tsw1060.dts` |

The two panel sizes differ only in the rows above. The vendor `.dtd` files also name different touch firmware files. Both sizes have:

- the same SoC and 2 GB RAM
- the same 4 GB Hynix eMMC with the same region layout
- the same card layout and U-Boot environment location
- the same I2C devices at the same addresses (PMIC, ZL38051, TFA9890, MAX44009, MP3309C, FocalTech touch)
- the same GPIOs for panel power, keys, key LEDs and USB VBUS
- the same LAN8710 PHY
- the same camera connections (I2C_D at 0x3c, power-down GPIOH_6, reset GPIOH_4, clock GPIOH_9, 2 CSI-2 data lanes)

The NC variants (`government=1`) lack the microphone, the camera and the Bluetooth module. They use the same device trees as the full models.

One boot image holds the DTBs of both LVDS sizes in a multi-DTB container (the vendor `AML_` format). U-Boot picks the DTB by the `aml_dt` board string. See [boot.md](boot.md) and [kernel.md](kernel.md) for the DTBs and the config fragment.
