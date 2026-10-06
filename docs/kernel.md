# Kernel

This page is the developer reference for the panel kernel: the two flavors, the branches and pins, the build, the boot image, the kernel packages and the config and DTS notes.

## Fork and branches

The parent of the fork is `torvalds/linux`. The fork is `github.com/tsx-mainline/linux`. The integration tree of Martin Blumenstingl (`xdarklight/linux`, branch `meson-mx-integration-*`) is a second, read-only remote (`xdarklight`). It has much of the Meson8 and Meson8b VPU, clock and pinctrl groundwork that this port builds on.

| Item | Value |
|---|---|
| Base branch pulled in | `xdarklight/meson-mx-integration-6.20-20251223`. This branch moves. Check the `xdarklight` remote for a newer `meson-mx-integration-*` branch before you rebase |
| Working branches | One for each flavor. Each is a linear history on a `torvalds/linux` tag plus the pulled-in `meson-mx-integration-*` commits plus the commits that this port adds |
| Board DTS | `arch/arm/boot/dts/amlogic/meson8m2-crestron-tsw1060.dts` (TSW-1060 and TSS-10) and `meson8m2-crestron-tsw760.dts` (TSW-760). Both include `meson8m2-crestron-tsw-xx60.dtsi`, which holds everything that does not depend on the panel size. The files are the same on both flavor branches, and both flavors build the same DTBs |
| Config fragment | `arch/arm/configs/tsx-xx60.config`. `merge_config.sh` merges it onto `multi_v7_defconfig`. It is not a standalone defconfig. It lists only what this board adds or changes. It has the same name on both flavor branches |

## Two kernel flavors

| | `lts` (default) | `stable` |
|---|---|---|
| Branch | `tsx-xx60-lts` | `tsx-xx60-stable` |
| Upstream track | `v6.18.y` | `v7.2.y` |
| Pin file | `kernel/KERNEL_REV.lts` | `kernel/KERNEL_REV.stable` |
| Pinned commit | `58619999fb5f` | `eddf71e798ef` |
| Base | `v6.18.54` plus 56 `xdarklight` commits plus the commits that this port adds | `v7.2.8` plus 54 `xdarklight` commits plus the commits that this port adds (`git describe`: `v7.2.8-119-geddf71e798ef`) |
| `kernelrelease` | `6.18.54-00121-g58619999fb5f` | `7.2.8-00119-geddf71e798ef` |
| Use | The long-term support kernel. `tsx-install-mainline` installs it by default | The newest stable kernel, on a newer upstream base |
| Package | `tsx-xx60-kernel-lts` | `tsx-xx60-kernel-stable` |

Both branches carry the same board-support commits (DTS, config fragment, drivers) on top of their own base.

- **Watchdog.** The hardware watchdog is the PMIC watchdog (`rn5t618-wdt`). The kernel command line sets `rn5t618_wdt.early=1`. The driver then starts the watchdog at probe, about 1.7 s into the boot, and keeps it on through a restart. A freeze after that point resets the panel within 32 s. A halt or a power-off turns the watchdog off.

- **Pins.** Each pin file is a text file with one commit hash. CI and local builds check out the fork at that commit for the flavor that they build. The pins do not follow the latest commit. To move a flavor to a later kernel commit, change its pin.
- **Change order.** A change goes to `stable` first. Then a cherry-pick or a rebase takes it to `lts`. The `lts` kernel moves only when its pin changes.
- **Build tools.** `tools/build/kbuild.sh`, `tools/build/remote-build.sh` and `./build.sh` take `-f` or `--flavor lts|stable` (or `$FLAVOR`). The default is `lts`. See [../tools/build/README.md](../tools/build/README.md).
- **CI.** `.github/workflows/kernel.yml` and `release.yml` build a matrix over `[lts, stable]`. The artifact names have the flavor and the `kernelrelease`. A tagged release attaches the files of both flavors.
- **Installer.** `installer/tsx-install-mainline PANEL_IP --kernel lts|stable` selects the flavor. The option is required. `tsx-update-boot` (on the panel, `/usr/local/sbin`) switches an installed panel between the flavors (see [install.md](install.md) "Change the kernel flavor or the boot image").

### Kernel packages

`tsx-xx60-kernel-lts` and `tsx-xx60-kernel-stable` (the project apk repository, tsx-aports) install side by side.

- Each package owns its `/lib/modules/<release>/` and ships `/boot/tsxboot-emmc-<flavor>.img`.
- On an upgrade, only the selected flavor (`KERNEL_FLAVOR`) writes the eMMC boot partition.
- `tsx-kernel-flavor lts|stable` switches the flavor.

See [rootfs.md](rootfs.md) "The project apk repository".

### Package guard

The rootfs build checks the kernel packages when it installs from a local apk tree (`TSX_APK_LOCAL`). `rootfs/check-boot-images.py` reads `/boot/tsxboot-emmc-<flavor>.img` of each flavor and checks two things:

- The kernel release in the image ends with the first 12 digits of the pin.
- The initramfs in the image has the file `usr/share/tsx/initramfs.stamp` with the stamp of this checkout. `rootfs/initramfs-stamp.sh` hashes the sources of the initramfs.

A stale package stops the build. To fix it, rebuild the `tsx-xx60-kernel-<flavor>` package with the current initramfs.

### Carried commits per flavor

`xdarklight/meson-mx-integration-6.20-20251223` has 98 commits on top of `v6.19-rc2`. Each flavor carries the commits that this board needs, minus the commits that its base has.

| `xdarklight` commits | `lts` (`v6.18.54`) | `stable` (`v7.2.8`) | Reason |
|---|---|---|---|
| 54 Meson8/8m2 commits (Ethernet RMII clock and `dwmac-meson`, CVBS DAC PHY, USB2 PHY ID and connector, TrustZone firmware, VPU/HDMI for Meson8, `rtc_32k`, `mpll` `sdm_en`, IP101A/G PHY clocks, and others) | Carried | Carried | Used by this board |
| `drm/meson: venc: add support for HDMI DMT modes up to 3840x2160` | Carried | In the base | In upstream `v7.0` |
| `ARM: dts: meson: drop iio-hwmon in favour of generic-adc-thermal` | Carried | In the base | In upstream `v7.0` |
| `arm64: dts: amlogic: move CPU OPP table ...` | Not carried | In the base | arm64 only |
| Meson NAND: 3 `mtd: rawnand: meson` commits and 3 DTS commits | Not carried | Not carried | The panel has eMMC and no raw NAND. The DTB has no NAND node |
| `regulator: pwm-regulator` (2) | Not carried | Not carried | VCCK is DCDC1 of the RN5T618 PMIC. The board has no PWM regulator |
| 33 others: other boards (WeTek Core, MXIII, M8S, S82, Odroid-C1, EC100, MXQ), arm64 and other-SoC drivers, Etron xHCI, CS4334, rtw88, PHYs that this board does not have, the global-timer WiP and its revert | Not carried | Not carried | Not used by this board |

This port adds the same 63 commits, in the same order, to both branches. Where the two bases have a different API, the branch that needs it has an adapted version of the commit.

- `stable` uses `drm_atomic_commit` and the bridge-owned connector attach (LVDS encoder, TranSwitch HDMI), `pcm_new` (AUDIN) and `snd_soc_component_to_dapm()` (TFA9890). It adds `CONFIG_EXPERT=y` to the fragment, because the `v7.2` `multi_v7_defconfig` does not set it and `GPIO_SYSFS` needs it.
- `lts` programs the RMII mode in `init()` of `dwmac-meson`, because `v6.18` has no `set_phy_intf_sel()` hook.

The other `.config` differences between the flavors come from `multi_v7_defconfig` (drivers for other SoCs). Two more options differ. On `stable`, `GPIO_CDEV_V1` and `SND_SUPPORT_OLD_API` are off, which is the `v7.2` default. On `lts`, they are on. Nothing in the rootfs uses the v1 GPIO character device ABI or the ALSA PCM API that `SND_SUPPORT_OLD_API` enables.

## Config fragment: notable choices

| Option | Reason |
|---|---|
| `# CONFIG_ARCH_AXXIA is not set` | `multi_v7_defconfig` enables AXXIA, which moves `TEXT_OFFSET` to `0x308000`. With AXXIA off, the kernel loads at `0x00208000`. This matches the stock Android kernel and stays above the 2 MiB `hwrom` no-map reservation |
| `CONFIG_CMDLINE` with `CMDLINE_EXTEND` | The stock Android bootargs have no `console=`. The built-in line sets `console=tty0 console=ttyAML0,115200n8` (the serial port is last, so it is `/dev/console`), `loglevel=7`, `fbcon=map:1` (no kernel text on the LCD, see "Boot splash" in [boot.md](boot.md)) and the `blkdevparts=` clause |
| `# CONFIG_PSTORE_RAM is not set` | The stock bootargs pass `ramoops.mem_address=0x04e00000`. The mainline device tree does not reserve this region. With `PSTORE_RAM=y` (the `multi_v7` default), ramoops would write into live RAM |
| `CONFIG_PARTITION_ADVANCED=y`, `CONFIG_CMDLINE_PARTITION=y` | Needed only by the eMMC-root boot layout. See below |
| `CONFIG_INPUT_UINPUT=m` | `/dev/uinput` for input-injection tests (key handling in `tsx-buttons`, the quick-settings overlay). Nothing in the rootfs loads it. `multi_v7_defconfig` does not enable it |
| `CONFIG_VIDEO_OV5640=m`, `CONFIG_VIDEO_MESON8_CSI2=m` | The camera: the OV5640 sensor driver and the Meson8 MIPI CSI-2 receiver and capture driver, as modules. `multi_v7_defconfig` already enables the media core (`MEDIA_SUPPORT=m`, `VIDEO_DEV=m`). `VIDEO_MESON8_CSI2` selects `MEDIA_CONTROLLER`, `VIDEO_V4L2_SUBDEV_API`, `V4L2_FWNODE` and `VIDEOBUF2_DMA_CONTIG` |
| `CONFIG_IP_MULTICAST=y` and related options | mDNS discovery on the panel network interface. Sendspin and the mDNS or avahi discovery of the voice satellite need it ([ha.md](ha.md)) |
| DRM, GPU, LED and PWM options | Listed explicitly for documentation, also where `multi_v7_defconfig` already sets them |

Do not put `clk_ignore_unused` or `pd_ignore_unused` on the command line. They hide clock-ownership bugs, and the LVDS encoder holds its own clocks.

### `blkdevparts=` for an eMMC root

On the eMMC, Linux sees one bogus MBR-shaped partition (byte 0 is the first sector of `u-boot.bin` in the bootloader area). It cannot address the boot, cache, recovery and root regions. `CONFIG_CMDLINE_PARTITION` and a `blkdevparts=mmcblk1:...` clause on the command line define the regions. Nothing writes a partition table to the disk. The clause lives in the boot image, not in the board DTS. See [boot.md](boot.md) for the full string and the layout.

## Kernel changes by topic

### LVDS encoder (drm/meson)

`drivers/gpu/drm/meson/meson_encoder_lvds.c` is a `drm_bridge` and a `drm_encoder` for Meson8m2 only. Its structure is like the G12A MIPI-DSI encoder. The probe finds VPU port 3 and wraps the panel as a bridge (`devm_drm_of_get_bridge` and `DRM_BRIDGE_ATTACH_NO_CONNECTOR`). It builds the connector with `drm_bridge_connector_init`. The bridge order matches the vendor: panel `prepare` (power), encoder `enable` (clocks and signal), panel `enable` (backlight). Disable is the reverse.

The driver computes every register write from the DRM mode and the bus format of the panel (vesa-24, jeida-24 or vesa-18). It uses the vendor formulas (`set_venc_lcd`, `lcd_tcon_config`, `set_tcon_lcd`, `set_control_lvds`, `set_pll_lcd`, `init_phy_lvds`) in the vendor order. A host test can check the register code against a captured golden state without hardware.

The encoder runs this clock sequence on every `enable` (see [hardware.md](hardware.md) for the register values):

1. `clk_set_rate_exclusive(vid2_pll, 7 * pixel_clock)`
2. `clk_set_rate_exclusive(viid_pll_pre_div, 7 * pixel_clock)`
3. `clk_set_parent(viid_pll, viid_pll_post_div)`
4. `clk_set_rate_exclusive(viid_pll_post_div, pixel_clock)`
5. `clk_set_rate_exclusive(vid2_pll_final_div, pixel_clock)`
6. `clk_set_parent(vclk2_in_sel, vid2_pll_final_div)` and `clk_set_parent(cts_encl_sel, vclk2_div1)`
7. `clk_prepare_enable(cts_encl)` plus the optional `vclk2_encl` gate

The sequence has no direct `clk_set_rate(cts_encl, ...)`. `cts_encl_sel` can reparent to another divider at the same numeric rate, and the topology matters (see [hardware.md](hardware.md)).

The driver uses `panel-lvds` (generic, timings from the DT) and not `panel-simple` (a fixed table keyed by part number). The panel has no confirmed part number. The vendor gives the 7" and the 10" panel the same wrong LG part name. `panel-lvds` has no power-delay properties for each panel, so the delays are in the regulator nodes of the DT.

### VID2 PLL clock driver

`drivers/clk/meson/meson8b.c` has the Meson8m2 VID2 PLL and the VIID divider as CCF clocks (`vid2_pll_dco`, `vid2_pll`, `viid_pll_*`, `vid2_pll_final_div`). It also has these changes:

- `vclk2_en` and `vclk2_div1..12` use `HHI_VIID_CLK_CNTL`.
- The mux table of `cts_encl_sel` has VCLK2 as a parent. The vendor kernel and the U-Boot clock state need this parent.
- `determine_rate` and `set_rate` of the PLL round the requested rate up, because the FRAC calculation truncates. For the 10" panel, this gives FRAC 0xbef.
- `HHI_GCLK_OTHER` bit 23 (vendor name `VCLK2_ENCL`) is the gate clock `CLKID_VCLK2_ENCL`. The LVDS encoder enables it with `cts_encl`. See [hardware.md](hardware.md) "VID2 PLL and the LVDS clock chain" for the symptom without it.

### pinctrl-meson8

- GPIODV bank: the register indices are 6/7/8 (`PREG_PAD_GPIO2` EN_N/O/I = CBUS 0x2012 to 0x2014).
- I2S pinmux groups: the I2S functions use the real group names, with no `_pins` suffix. GPIOY_5 (I2S data in) can be muxed.
- AO pinmux `set_mux_hook`: clears bits 1 and 8 of `AO_SECURE_REG1` (the JTAG override on GPIOAO_8 to 11) when a function is muxed onto those pins.
- `GPIO_BSD_EN` (speaker enable): a per-SoC hook in the pinctrl core and Meson8m2 match data handle the `AO_SECURE_REG0` write and the BOOT_0 pull-direction protection (see [hardware.md](hardware.md) "Audio").

### Buttons and touch overlay

The five capacitive keys on the front panel are zones of the touch controller (see [hardware.md](hardware.md)).

- `edt-ft5x06` has the `touch-overlay` support that `st1232` has. The probe reads the `segment-*` rectangles of a `touch-overlay` child node. For each IRQ, the driver classifies the contacts against them and reports a key event or a normal MT touch. Without a `touch-overlay` node, the driver reports every contact as a normal MT touch.
- The board DTS declares `segment-screen` and five `segment-key1..5` rectangles (`linux,code = KEY_F13..KEY_F17`). It also declares the `keypad-leds` node (`gpio-leds`, all active low, LED class devices `tsx:key1` to `tsx:key5`) and the `keypad-backlight` node (`pwm-leds` on `pwm_cd`, LED class device `tsx:keypad`).

### LED bar driver

`drivers/leds/rgb/leds-crestron-stm32.c` matches USB `14be:001b` (and the bootloader and alternate IDs `0009` and `001a`). It registers one `led_classdev_multicolor` device (`tsx:rgb:bar`). It keeps a bulk IN URB queued for the echo and status frames of the device. It exposes the sysfs attributes `raw`, `rx_last` and `firmware` for diagnostics.

`led_classdev_multicolor_register_ext()` overwrites `led_cdev.groups`. The driver adds its own sysfs attribute group again after the registration and removes it before the unregistration.

### Audio

[hardware.md](hardware.md) has the register detail.

- **AIU FIFO period timer.** On Meson8, the I2S FIFO interrupt fires once for each buffer, not once for each period. Other Meson SoCs fire once for each period, and the ALSA drivers above the FIFO level assume this. The platform flag `i2s_fifo_irq_per_buffer` (meson8 and meson8b) makes the driver report periods from an hrtimer at half the period time. The real FIFO IRQ stays for other bookkeeping.
- **AUDIN capture driver.** It is the capture front-end of Meson8. It uses a private 64 KiB ring buffer. The samples are 24-bit, packed 8-left and 8-right for each 64-byte FIFO block. A 4 ms timer produces the ALSA periods (mmap and shared capture both work). `gx-card` accepts AUDIN as a capture front-end.
- **ZL38051 in `zl38060.c`.** The driver has I2C register access (the SPI command-byte protocol, with repeated-start for reads). It has the `mscc,flash-boot` mode. This mode skips the firmware and version checks and the routing changes, because the chip boots a flash configuration that does the routing. It exposes the controls `ZL Mic Capture Switch/Volume` and `ZL AEC Switch`.
- **TFA9890 DSP (`tfa989x.c`).** The module parameter `snd_soc_tfa989x.dsp` (off by default) disables the register cache and adds a DSP input source and a volume control. The default behavior is the bypass path. Userspace loads the DSP firmware (see [hardware.md](hardware.md) and [rootfs.md](rootfs.md)).

### CPU frequency

| Change | Detail |
|---|---|
| `sys_pll_params_table` in `meson8b.c` | Has M values for 1800 and 1992 MHz. The upstream table has entries up to 1632 MHz and one at 84 MHz |
| `sys_pll` OD divider | `HHI_SYS_PLL_CNTL` bits 17:16 are a table of /1, /2 and /4, not a 2-bit power-of-two divider. OD = 3 is not /8 |
| VCCK regulator | DCDC1 has the range 825 to 1150 mV. All four CPUs have `cpu-supply` |
| OPPs | `opp-1800000000` and `opp-1992000000` stay disabled as in `meson8.dtsi`. 1608 MHz is the top OPP |
| Thermal | `meson8.dtsi` has an 80 C passive trip, a 90 C hot trip and a 110 C critical trip (`step_wise`, 250 ms passive polling). The board DTS adds a 70 C passive trip. `step_wise` takes it to cooling state 1 at most, which is 1416 MHz |

`scaling_available_frequencies` ends at 1608000. See [hardware.md](hardware.md) "SoC and CPU" for the limits and the thermal numbers.

The global `cpufreq/boost` file exists, because cpufreq-dt always registers `set_boost`. Every write to it fails with `EINVAL`. On the 7.2 kernel, each failed write flips the value that you read back. No policy supports boost, so `cpufreq_boost_trigger_state()` returns `-EOPNOTSUPP`, and its error path stores `!state`. After `echo 0 > boost`, the file reads 1. `policy0/boost` stays 0, and `cpuinfo_max_freq` and `scaling_max_freq` stay 1608000. A reboot resets the file.

For a DT that enables a boost OPP, note this behavior of the 7.2 kernel. `cpufreq_frequency_table_cpuinfo()` only raises `cpuinfo.max_freq`. After `boost` goes 1 to 0, `cpuinfo_max_freq` stays at the boost value, and so does the boost QoS request that `policy_set_boost()` sets from it. Only a `scaling_max_freq` at the normal top frequency caps the CPU. `rootfs/tests/cpufreq/` writes this value before it turns boost off. If you write `cpuinfo_max_freq` into `scaling_max_freq`, the CPU runs at the boost frequency with boost reading 0.

### Camera

The camera path is an OV5640 sensor on I2C_D and the MIPI CSI-2 receiver in the SoC. [hardware.md](hardware.md) "Camera" has the registers, the modes and the limits.

| Change | Detail |
|---|---|
| GEN_CLK clock (`meson8b.c`) | `gen_clk_sel` (mux, XTAL only, `HHI_GEN_CLK_CNTL` bits 15:12), `gen_clk_div` (bits 6:0) and `gen_clk` (gate, bit 11). IDs 233 to 235. The sensor master clock, 24 MHz |
| MIPI PHY clock and CSI gate (`meson8b.c`) | `mipi_phy_sel` (fclk_div3 at source 1), `mipi_phy_div` and `mipi_phy` (gate, bit 8) on `HHI_MIPI_PHY_CLK_CNTL`, and the gate `meson8_csi_dig_clkin` (`HHI_GCLK_MPEG1` bit 18). IDs 236 to 239. The device tree sets the PHY clock to 212.5 MHz |
| GEN_CLK pin (`pinctrl-meson8.c`) | Group `gen_clk_h`: the GEN_CLK output on GPIOH_9 |
| I2C master D (`meson8.dtsi`) | Node `i2c_D` (`amlogic,meson6-i2c`, SPI 39), disabled, and the pin group `i2c-d1` |
| CSI-2 receiver (`meson8.dtsi`) | Node `mipi_csi2` (`amlogic,meson8-mipi-csi2`), disabled. `reg` has the host, the D-PHY and the adapter. Interrupt SPI 95. Clocks `csi` and `phy`. `amlogic,hhi-sysctrl` points to the HHI system controller |
| Binding | `Documentation/devicetree/bindings/media/amlogic,meson8-mipi-csi2.yaml`. One input `port` with 1 to 4 data lanes |
| Driver | `drivers/media/platform/amlogic/meson8-csi2/meson8-csi2.c`, module `meson8-csi2`. A receiver subdevice and a capture video device (vb2 dma-contig). The adapter writes each frame to memory. No VDIN |
| Sensor tuning (`ov5640.c`) | A tuning table for the TSW-1060 camera module (auto white balance, color matrix, lens correction), selected by the machine compatible `crestron,tsw1060` or `crestron,tsw760`. Other machines get no table |
| Board DTS | `meson8m2-crestron-tsw-xx60.dtsi`, so the TSW-760 and the TSW-1060 DTBs have the same camera nodes: three fixed supplies, the `gen-clk-h` pins, `i2c_D` with `camera@3c` (`ovti,ov5640`), and the endpoints of the sensor and the receiver on data lanes 1 and 2 |

Stream start: the driver turns on the clocks and puts the adapter in memory mode with the first buffer. Then it starts the analog front end, the D-PHY, the CSI-2 host and the sensor. Stream stop runs in the reverse order. The clocks are on only while a stream runs.

At each frame interrupt, the driver reads the byte counter, the line counter and the error status of the adapter. A frame with the right size and no error completes the buffer. Otherwise the buffer stays for the next frame. With no free buffer, the driver stops the memory writes until a buffer comes back.

### Bluetooth UART

The board DTS enables `&uart_A` with the `a1` pin group and `uart-has-rtscts`. The chip runs BCSP with even parity and no flow control, so userspace does not turn RTS/CTS on. A `rfkill-gpio` node controls the reset and power line. The kernel has the BCSP protocol of `hci_uart` (`CONFIG_BT_HCIUART_BCSP`) and no driver that loads the PSR of the chip. The bring-up is in userspace (see [hardware.md](hardware.md) "Bluetooth (CSR8811)").

## Board DTS notes

- The board DTS disables `&cvbs_dac`. The VPU node of `meson8.dtsi` has `phys = <&cvbs_dac>`, and `CONFIG_PHY_MESON_CVBS_DAC` is not built, because the board has no CVBS output. With the DAC enabled, `fw_devlink` holds the VPU probe for the full 10 s deferred-probe timeout.
- `assigned-clock-parents` on the VPU node: the defaults of `meson8.dtsi` force `VCLK2_IN_SEL` onto `VID_PLL_FINAL_DIV`. With these defaults, the `drm/meson` probe takes VCLK2 off the VID2 PLL path and blanks the bootloader picture. The board DTS sets `VCLK2_IN_SEL` to `VID2_PLL_FINAL_DIV`, `VIID_PLL` to the post-divider and `CTS_ENCL_SEL` to VCLK2 div1.
- Ethernet pin group: the generic `eth_pins` group of mainline claims GPIOZ_0..3. On this board these pins are I2C_A and I2C_B. With that group, the I2C probe fails with "pin already requested". The board DTS uses an RMII-only pin group that matches the vendor pinmux.
- PMIC: the DTS has no `regulators` node with `regulator-always-on`, because it would switch on rails that the bootloader left off. Without any constraints, late cleanup can switch off rails that nothing has claimed yet. All eleven PMIC rails stay visible and not forced.

## Development checks

- **Host tests.** Each subsystem has a `hosttest/` harness. It extracts the register-computation functions of the driver and runs them against a fake regmap. It compares the result with a golden register state captured from a panel. It covers the VID2 PLL clock math, the LVDS encoder register set (cold and warm start), the CPU frequency table and the TFA9890 DSP loader.
- **Static checks.** Run `checkpatch --strict`, `dt_binding_check` and `dtbs_check` on every binding and DTS that you change. The known noise is the SoC-level schema gaps (`hhi-sysctrl` children, `reg` of `clkc` and `pwrc`, and missing schemas for `meson8-hdmi-tx` and `meson8-nfc`). Use `W=1` builds for the driver directories that you change.
- **Register tools.** `regdump`, `regsnap` and `regdiff` in `tools/regs/` read registers on a panel. `regdump` is a static ARMv7 `/dev/mem` reader, `regsnap` takes a snapshot, and `regdiff` classifies the differences from a golden vendor capture.

## How to build

The build is local by default. It needs no build host and no environment variable:

```sh
./build.sh kernel                       # lts kernel (default): zImage + dtbs + boot image
./build.sh kernel --flavor stable       # same, stable flavor
CCACHE=1 tools/build/kbuild.sh           # same, with a persistent ccache (~/.cache/tsx-ccache)
```

`kbuild.sh` builds in docker on the machine where you run it (`ci/Dockerfile.mainline`, built automatically if it is missing). It reads the kernel source from `LINUX_DIR` (default `../linux-<flavor>`, for example `../linux-lts`, a sibling checkout of this repo). If the directory does not exist, the script clones `github.com/tsx-mainline/linux` and checks out `kernel/KERNEL_REV.<flavor>`.

You can run the build on another machine with `tools/build/remote-build.sh`. Two variables with no default drive it. If you set neither, it runs the same local build:

```sh
BUILD_HOST=<ssh host> BUILD_DIR=<path on that host> \
  tools/build/remote-build.sh --flavor lts|stable kernel   # zImage, board DTB, ccache'd
BUILD_HOST=<ssh host> BUILD_DIR=<path on that host> \
  tools/build/remote-build.sh --flavor lts|stable image    # + kernel/mkimage.sh -> tsxboot.img
```

See `tools/build/README.md` for the option list, for what the script sends to `BUILD_HOST`, and for the rules about concurrent builds.

- The config recipe is always the same: `multi_v7_defconfig`, then `merge_config.sh` with `arch/arm/configs/tsx-xx60.config`, then `olddefconfig` (it warns about any fragment option that did not survive).
- A cold build without ccache takes about 7 minutes on a 20-core machine. The full `multi_v7` module set takes about 40 minutes on a modest workstation. An incremental build with a warm ccache takes a few seconds.

## Boot image

`kernel/mkimage.sh` builds the Android-format boot image that mainline boots from. It has these parts:

| Part | Content |
|---|---|
| Kernel | A uImage (the U-Boot legacy image format) that wraps the zImage (uncompressed, load and entry `0x00208000`, as in stock) |
| `second` slot | A plain FDT or an Amlogic `AML_` multi-DTB container |
| Ramdisk | The initramfs |

- The script can repack the stock `boot.img` byte-identically as a self-test.
- It can build one boot image with both the 7" and 10" board DTBs in one multi-DTB container. One image then serves both panel sizes, with no change to U-Boot or its environment. U-Boot picks the DTB by matching its `aml_dt` environment string against the board-string entries of the container.

See [boot.md](boot.md) for the U-Boot side of the format and [install.md](install.md) for how the image reaches the panel.
