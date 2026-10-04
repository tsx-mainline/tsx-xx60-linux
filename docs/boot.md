# Boot

This page describes how the TSW-760, TSW-1060 and TSS-10 boot. It covers the vendor U-Boot (Amlogic Meson8m2, board `yushan_one`), the boot image, the U-Boot environment, the hook that starts mainline, the root selection and the boot splash. Read it when you build a boot image, change the U-Boot environment or debug a boot that does not reach the kiosk.

For the kernel side of the boot image, see [kernel.md](kernel.md). For the rootfs and the initramfs, see [rootfs.md](rootfs.md). For the install and recovery procedures, see [install.md](install.md) and [recovery.md](recovery.md).

## Tasks

### Reach the U-Boot prompt or do a TFTP boot

The hook runs before U-Boot reads the serial stop key. When the hook is live, the stop key cannot reach the prompt. Disable the hook first.

1. From a running Linux (kiosk or rescue), create the switch file: `mount /media/bootfat && touch /media/bootfat/tsxboot.off && umount /media/bootfat`.
2. Power-cycle the panel. U-Boot prints `tsx: mainline disabled`. It reaches the prompt or boots Android. The stop key works as normal.
3. At the prompt, run the TFTP boot: `dhcp; setenv serverip <host-ip>; tftpboot ${loadaddr} test.img; bootm`.
4. Remove `tsxboot.off` before you go back to normal operation. The hook stays disabled while the file exists.

The stop key is Enter, space or Ctrl-C (not `x`).

### Update the boot image of a panel that runs mainline

Do not use TFTP for a permanent update. This includes a switch between the `lts` and `stable` kernel flavors (see [kernel.md](kernel.md)). To switch the flavor of a panel that has both kernel packages, `tsx-kernel-flavor` is simpler (see [install.md](install.md) "Change the kernel flavor or the boot image").

1. Copy the boot image to the panel.
2. Run `tsx-update-boot IMG SHA256` (in `/usr/local/sbin`). On the eMMC layout, run `tsx-update-boot --emmc IMG SHA256`.
3. Reboot.

On the card layout, the tool writes only `p1:tsxboot.img` and does not touch the golden `p1:boot.img`. On the eMMC layout, it raw-writes the eMMC `boot` partition. It first saves the installed image to `/data/tsxboot-emmc.prev.img` and verifies the copy by readback. If the readback of the new image is bad, it restores the saved image. On success it prints the rollback command: `tsx-update-boot --emmc /data/tsxboot-emmc.prev.img <sha>`. The tool refuses an image that has no DTB for the board of the panel.

### Reset the boot counters by hand

At the U-Boot prompt, run `setenv boot_retry 0; setenv golden_boot_retry 0; saveenv`. In a running system, `tsx-rescue done` does the same with one verified write (see [recovery.md](recovery.md)).

### Test a new display DTB before you write it to the eMMC

**Warning:** U-Boot reads the display nodes of the eMMC `boot` partition (`p7`) on every power-on, before any prompt. A DTB there that crashes or hangs this code stops every boot. A power cycle does not help, and the serial stop key does not help. Recovery then needs Amlogic USB Burning Mode. The SD-card rescue, `tsx_once` and `tsxboot.off` all act later and cannot prevent this.

Test the exact DTB in RAM first. Nothing is written, and a power cycle undoes the test.

1. Put `test.dtb` on `p1` of the SD card.
2. At the U-Boot prompt, check the current DTB: `md.l 0x0f000000 4`. The first word is `edfe0dd0`.
3. Load the new DTB: `mmcinfo; fatload mmc 0 0x0f000000 test.dtb`.
4. Make the LCD driver read it again: `video dev disable; video dev enable`.
5. Check that the output has no `not find` line. A good DTB prints `load lcd model in dtb: LP097X02`, `lcd_clk=68.135MHz, frame_rate=60.0Hz` and `Init LCD mode: LP097X02, lvds(1) 8bit, 1280x800@60.0Hz`.
6. Redraw the logo with `run prepare`. Check for `bl_extern_power_on` and for no `not find /keypad_led` line.
7. Run `reset`. The panel boots with the unchanged `p7`.

### Enable boot from a USB stick

See "U-Boot USB needs VBUS held before enumeration" below and "USB recovery" in [recovery.md](recovery.md).

## Reference

### Boot chain

1. The vendor U-Boot (Amlogic 2011-derived, Crestron build 1.00.12) starts. Its console is UART_AO, 115200 8N1, 3.3 V.
2. Before the prompt, U-Boot reads the DTB from the eMMC `boot` partition and sets up the LCD, the backlight and the key LEDs (see "U-Boot display nodes").
3. `preboot` runs `switch_bootmode`. When the hook is installed, this runs `tsx_boot`, which boots `tsxboot.img` from the FAT partition `p1` of the SD card.
4. If the hook does not boot, the stock `bootcmd` boots the Android-format boot image in the eMMC `boot` partition. `checkBootRetry()` can send the boot to the golden image instead (see "`boot_retry`, the golden slot and why it is destructive").
5. The kernel starts and `/init` of the initramfs selects the root (see "Root selection").

### The boot image

U-Boot boots an **Android boot image (v0)** with `bootm`. The page size must be 2048, because `bootm` hard-codes `os_hdr + 0x800`.

| Part | Content |
|---|---|
| Kernel payload | A **uImage** (the U-Boot legacy image format) at offset `0x800`. `bootm` reads the type, compression, load address and entry address from its header. Stock uses an LZO-compressed uImage with load and entry `0x00208000`. The tsx boot images use an uncompressed uImage with the same addresses. `bootm` ignores the load address in the header of the boot image |
| `second` field | The DTB: a plain FDT (magic `d00dfeed`) or an Amlogic `AML_` multi-DTB container. `get_multi_dt_entry()` (`common/aml_dt.c`) selects the entry with the env variable `aml_dt`. If `second` is empty, `bootm` falls back to ATAGs |
| Ramdisk | The initramfs |

`bootm` relocates the FDT, writes the env `bootargs` into `/chosen/bootargs`, fixes up `/memory` from the detected DRAM size and adds `linux,initrd-start/end`. It jumps with `r0=0, r1=machid, r2=FDT`.

The stock `bootcmd` does not use `imgread dtb` for the kernel. Only the `second` field matters. U-Boot itself runs `imgread dtb boot` for its display setup (see "U-Boot display nodes").

#### The `AML_` multi-DTB container

One boot image holds the DTBs of several board variants. One image serves the TSW-760, the TSW-1060 and the TSS-10.

- The container starts with the magic `AML_`, a `u32 version` (2) and a `u32 count`. Then it has one 56-byte entry for each DTB.
- An entry holds `soc`, `platform` and `variant` as 16-byte space-padded strings with every 4-byte group byte-reversed, a `u32 offset` and a `u32 size`. U-Boot never reads the size field.
- The header is rounded up to 2048 bytes. The DTB blobs follow it.
- U-Boot matches the env value `aml_dt = soc_platform_variant` (`yushan_one_10inch` on the 10-inch models) against the entries in order.
- If no entry matches, `get_multi_dt_entry()` passes the container itself to the kernel as the FDT, and nothing boots. A plain FDT boots whatever `aml_dt` says.

The tsx boot images have four entries:

| `aml_dt` variant | DTB |
|---|---|
| `yushan_one_10inch`, `yushan_one_old10inch` | `meson8m2-crestron-tsw1060.dtb` |
| `yushan_one_7inch`, `yushan_one_old7inch` | `meson8m2-crestron-tsw760.dtb` |

The `yushan_one_old*` names are variant names from the vendor container. To add a board variant, add an entry to the container. U-Boot and the env need no change.

#### Build tools

| Tool | Use |
|---|---|
| `kernel/mkimage.sh` | Builds the Android boot image header, the uImage wrapper and optionally the `AML_` container. It does not need the 32-bit `mkbootimg` of the vendor |
| `kernel/mkimage.sh --board-dtbs DIR` | Packs the two board DTBs into the container. `kbuild.sh image` and `rootfs/mkbootimg.sh` use it, so the rescue image and the installed-system image use it too |
| `kernel/mkimage.sh --dtbs name=path,...` | Packs the DTBs that you name |
| `kernel/mkimage.sh --selftest` | Repacks the stock boot image from its own parts. The result must be byte-identical |
| `kernel/mkimage.sh --append-dtb` | Appends the DTB to the zImage and leaves `second` empty. This is a fallback. The packed images do not use it |
| `aml-dt.py list\|unpack\|pack` | Reads and writes the `AML_` container |

### Where the U-Boot environment lives

The live environment is on the SD card (`mmcblk0`) at raw offset `0x100000` (1 MiB). It is 64 KiB, a single copy, with a CRC32 header. `fw_env.config` on the Android side agrees: `/dev/block/mmcblk0 0x100000 0x10000`.

The output of `saveenv` is misleading:

```
Saving Environment to eMMC...
MMC BOOT,emmc_saveenv : saveenv 131 / sd card save env ok
```

The first line is wrong. The second line shows what happens: the write goes to the SD card. The eMMC has no copy of the variables.

There is no redundant copy. If the CRC is bad, or no card is present, U-Boot uses its built-in default environment. This environment boots the golden FAT image (see below).

### The env hook (`tsx_boot`)

The stock `preboot` runs `switch_bootmode`, which starts with `usb start 0`. The hook is two env variables. Install them with `fw_setenv` from Linux or at the U-Boot prompt:

```
tsx_boot = mmcinfo; if fatexist mmc 0 tsxboot.off; then echo tsx: mainline disabled;
           else if fatexist mmc 0 tsxboot.img; then echo tsx: booting tsxboot.img;
           fatload mmc 0 ${loadaddr} tsxboot.img; bootm; fi; fi

switch_bootmode = usb start 0; if fatexist usb 0 jabil.txt; then run jabil_factory; else fi;
                  if itest ${boot_retry} -lt 6; then run tsx_boot; fi
```

This is the persistent hook. The installer default is the one-shot variant (see "The `tsx_once` state machine").

| Element | Behavior |
|---|---|
| `mmcinfo` first | In `preboot`, U-Boot has not initialized the SD controller at this point. Without `mmcinfo`, `fatexist mmc 0 ...` fails with `** Unable to use mmc 0:1 for fatload **` and U-Boot falls through to Android |
| `tsxboot.off` on `p1` | Disables the hook and does not change the env. U-Boot prints `tsxboot.off is exist` and `tsx: mainline disabled`, and boots Android |
| `itest ${boot_retry} -lt 6` | The hook runs only for the first 5 boot attempts after a reset of the counter. A broken `tsxboot.img` cannot loop forever |
| `bootcmd` | Cannot hold the hook. On this U-Boot build, every boot resets `bootcmd` to a fixed golden string. `switch_bootmode` (through `preboot`) is the working hook point |

### `boot_retry`, the golden slot and why it is destructive

`checkBootRetry()` in U-Boot runs on every boot and increments `boot_retry`. Android resets it on its own. A good mainline boot must also reset it (the `tsx-boot-ok` service does this).

| `boot_retry` | Boots |
|---|---|
| 1 to 5 (with the hook) | `tsxboot.img` from `p1` (mainline) |
| 6 to 9 | Stock eMMC Android |
| 10 (`golden_boot_retry` 1 to 5) | Golden: `p1:boot.img` |
| `golden_boot_retry` 6 | One more Android attempt, then golden again |

**Warning:** The Crestron golden `boot.img` is destructive. Its ramdisk mounts `mmcblk0p2` as `/system`. Unless the env has `DataRecoveryDone=1`, `crestInit.sh` sets `reformatDataPartition=1` and reboots. The second golden boot then runs `cleanUpCache.sh FORMAT`. This runs `mke2fs` on `p5` and `p7` and `rm -rf /data/*`. A normal Android boot resets `DataRecoveryDone` to 0. The golden boot never resets `boot_retry`, so a panel that reaches golden stays there until an operator acts.

Two measures protect the panel:

- **`tsx-boot-ok`** is an OpenRC service. When the kiosk is confirmed up, it makes one `fw_setenv -s` write that sets `boot_retry=0`, `golden_boot_retry=0` and `DataRecoveryDone=1`. It skips the write if the env is already correct. It reads the env back to verify that only these variables changed. A routine reboot loop then never reaches golden. If a golden boot happens, `DataRecoveryDone=1` stops it from formatting anything.
- **A mainline rescue image in the golden slot** replaces the destructive recovery with a rescue system that you reach over the network. The rescue writes nothing on its own (see [recovery.md](recovery.md)).

### The `tsx_once` state machine

`installer/tsx-install-mainline` puts the panel into the mainline rescue system and runs the eMMC write from there. It uses a true one-shot, controlled by the env variable `tsx_once` and not by `boot_retry`.

The default guard of `installer/steps/tsx-rescue-arm.sh` (`--guard once`) installs this `switch_bootmode` (`TSX_SWITCH_ONCE` in `installer/android/tsx-lib.sh`, mirrored by `GUARDS['once']` in `installer/sdcard/tsx-env.py`):

```
usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;
if itest ${tsx_once} -eq 1; then setenv tsx_once 0; saveenv; run tsx_boot; fi
```

U-Boot clears `tsx_once` before it runs `tsx_boot`. The shot is spent when U-Boot reaches this line, whether `tsxboot.img` exists, whether `bootm` returns, and whether the rescue ever answers on the network. If `tsx_once` is unset or `0`, the hook does nothing and the stock `bootcmd` runs. Before an install, this boots stock Android. After the eMMC layout is in place, it boots mainline from the eMMC.

| Step | What runs | State after |
|---|---|---|
| 1. Arm (Android root shell, `tsx-rescue-arm.sh`) | Backs up the env and the disk head. Copies the rescue image to `p1:boot.img` (golden slot) and to `p1:tsxboot.img` (hook target) | `switch_bootmode` is the `once` hook, `tsx_boot` is installed, `boot_retry=0`, `golden_boot_retry=0`, `DataRecoveryDone=1`, `tsx_once=1`. The panel reboots |
| 2. Rescue boot | U-Boot sees `tsx_once=1`, clears it, and runs `tsx_boot`, which boots the rescue from `p1:tsxboot.img` | `tsx_once=0`. `checkBootRetry()` increments `boot_retry` once |
| 3. Install (`installer/steps/tsx-rescue-install`, run by the host over ssh) | Writes the eMMC boot (`p7`) and root (`p8`) images and verifies them by readback. Folds `p5` to `p8` of the card into `p4` (`tsxdata`). Deploys the TFA9890 files and optionally `KIOSK_URL` into the new root | No env change |
| 4. Finalize (one verified env write) | Runs `installer/emmc/tsx-usb-recovery enable`. Writes `p1:tsxboot.off` | `boot_retry=0`, `golden_boot_retry=0`, `DataRecoveryDone=1`, `tsx_once=0`. `switch_bootmode` has the USB-recovery VBUS prefix |
| 5. Done | The panel reboots. The stock `bootcmd` (`imgread kernel boot; bootm`) boots the eMMC boot image. Nothing reads the hook again | `tsx-boot-ok` keeps the counters healthy on every good kiosk boot |

`tsx_once` is the safety net. After step 1, the panel allows exactly one rescue boot. The install can stop before step 4, for example with no network, a stopped host driver or a power loss. After a power cycle, `tsx_once` is already `0`. The hook does nothing and **stock Android boots**. This needs no UART, no host driver and no operator action other than the power cycle.

`DataRecoveryDone=1` is a second defense. If `boot_retry` reaches the golden threshold by other causes, the golden boot cannot reformat the storage. For the operator procedure, see [recovery.md](recovery.md) "Recover from an interrupted install".

The fold of `p5` to `p8` into `p4` changes one MBR byte (`TSX_MBR_P4_TYPE_OFFSET` in `installer/android/tsx-lib.sh`, `0x05` to `0x83`). The installer makes it after it verifies the eMMC writes. If step 3 stops early, the Android partitions of the card stay untouched.

The golden slot holds the rescue image (`p1:boot.img`) from step 1 on, whatever the result of the install.

`tsx-env.py unhook` builds the stock env for a factory-restore bundle (see `installer/tsx-restore-factory`). It unsets `tsx_boot` and `tsx_once` and resets `boot_retry`, `golden_boot_retry` and `DataRecoveryDone`.

#### Persistent guards (`fallback` and `nogolden`)

`tsx-rescue-arm.sh --guard fallback|nogolden` installs a persistent hook (`TSX_SWITCH_FALLBACK`, `TSX_SWITCH_NOGOLDEN`). These guards do not use `tsx_once`. They run `tsx_boot` on every boot while `boot_retry<6`, so they are not a true one-shot. A rescue armed this way tries for up to 5 boots before stock Android boots. The tests and the card-stage install path use these guards.

With these guards, the arm step writes `boot_retry=3`. Do not use 4. The U-Boot pass at `boot_retry=4` is special: it prints `Checking reboot value 4 == 4`, saves the env without incrementing, and resets the SoC. The next pass reads 5, saves 6 and skips the hook, so stock Android boots and there is no rescue. With 3, the rescue boot lands on 4, and one more reboot goes 4, 5, reset, 6, stock Android. `--guard once` does not depend on this value.

#### Serial log of a good arm run

The serial log of an arm run shows these items in order:

1. The U-Boot banner.
2. The `saveenv` lines (see "Where the U-Boot environment lives").
3. `tsx: booting tsxboot.img`.
4. The banner of the rescue system.

A second power cycle with no install progress shows none of items 2 and 3. Stock Android boots straight through.

### Stock `bootcmd` and the eMMC layout

The stock, unmodified `bootcmd` does not depend on the hook:

```
mmcinfo; imgread kernel boot ${loadaddr}; bootm;
```

`imgread kernel boot` reads an Android boot image from the eMMC partition named `boot`. It uses the partition table of U-Boot and no file system. On this layout, `boot` is `mmcblk1p7` at raw offset `0x2fc00000`, 32 MiB at most. If you write a tsx boot image there, the stock environment boots mainline directly, with no FAT and no env logic. The mainline-on-eMMC layout uses this (see [install.md](install.md)). On this layout, the SD-card hook is only the way to reach the rescue system.

The eMMC region table, as U-Boot prints it (4 GB device):

```
bootloader   0     - 4M
reserved     36M   + 64M     (U-Boot's own partition table copy)
cache        108M  + 512M
logo         628M  + 48M
recovery     684M  + 32M
misc         716M  + 32M
boot         764M  + 32M     <- imgread kernel boot reads this
system/root  804M  + ~2.9G   (rest of the device)
```

Linux sees one bogus MBR-shaped partition on the eMMC, because sector 0 is the first sector of `u-boot.bin`. Linux gets the root and the other regions through `blkdevparts=mmcblk1:...` (`CONFIG_CMDLINE_PARTITION`). `mkimage.sh` puts this into the kernel command line at build time. It never writes sector 0 or the partition table of the eMMC.

### U-Boot display nodes (the boot logo)

The vendor U-Boot sets up the LCD before its autoboot prompt. It takes the panel configuration from the device tree in the Android boot image in the eMMC `boot` partition (`mmcblk1p7`). This applies to every boot, including a rescue boot from the SD card.

1. In `board_init_r()`, after U-Boot loads the env, it runs `preloaddtb` (`imgread dtb boot ${loadaddr}`). This reads the `second` payload of the boot image. For an `AML_` container, it picks the entry for `aml_dt` (set by `get_dt=checkhw` from the detected panel size). It copies the FDT to `0x0f000000`.
2. `vpu_probe()`, `lcd_probe()` and the key LED driver read that FDT by path: `/vpu` (`clk_level`), `/lcd`, the model node `/<lcd_model_name>` (`lcd_LP097X02`), `/backlight`, `/bl_extern_i2c_mp3309c`, `/lcd_extern_mipi_TFT540960`, `/keypad_led` and `/pinmux/keypad_led`. The PWM backlight methods use `/pinmux/lcd_backlight*`. GPIOs are strings (`"GPIODV_22"`), not phandles. The drivers do not read `pinctrl-*` or `compatible`.
3. Then `main_loop()` runs `preboot` (the logo: `run prepare`), the env hook and `abortboot`.

The kernel board files carry the vendor nodes. The nodes match the DTBs of stock firmware 3.002.1061 (`yushan_one_10inch` and `yushan_one_7inch`):

- `meson8m2-crestron-tsw-xx60.dtsi` has `/vpu`, `/lcd`, `/backlight`, `/bl_extern_i2c_lp8556`, `/lcd_extern_mipi_TFT540960`, `/keypad_led` and `/pinmux/{keypad_led,lcd_backlight,lcd_backlight_combo}`. They are the same on both panel sizes.
- Each board file has `/lcd_LP097X02` (panel timing) and `/bl_extern_i2c_mp3309c` (dimming limits).

The files do not carry the properties that only the vendor kernel reads (`pinctrl-*`, `lcd_model_config`) or the fixed phandle numbers. No compatible of these nodes matches a Linux driver, so Linux ignores them.

If the boot image in `p7` has no display nodes, the boot prints `vpu preset: not find /vpu node in dts`, `dts: not find /lcd node`, `backlight init: not find /backlight node` and `keypad_led init: not find /keypad_led node`. U-Boot falls back to a MIPI-DSI default (`Init LCD mode: <NULL>, mipi(0)`). The TSW-1060 still shows the logo. The TSW-760 stays black for about 10 s after power-on. Every boot image of a kernel package has the nodes.

Before you change these nodes, test the DTB in RAM (see "Test a new display DTB").

### Root selection

The kernel command line has no `root=`. The initramfs (`rootfs/initramfs/overlay/init`) finds the root. It waits up to 3 seconds for a labeled root file system and tries these labels in order:

1. `LABEL=tsxroot-emmc` (eMMC layout)
2. `LABEL=tsxroot` (SD-card root, `mmcblk0p2`)
3. If it finds neither, or a label has no working `/sbin/init`, it starts the **rescue**. The rescue starts the network and dropbear, writes nothing and never runs `switch_root`.

Each candidate must mount and must contain a working `/sbin/init`. A half-written or corrupt root counts as not found. On the eMMC layout, the `blkdevparts=mmcblk1:...` fragment names the `boot` and root regions. The SD card can keep a fallback root after you install the eMMC layout.

### Boot splash

From the kernel on, the LCD shows one picture until the dashboard paints: the TSX - LINUX word mark with Tux above it on black, a status line and a progress bar. The vendor U-Boot logo before the kernel belongs to U-Boot. The serial console keeps every line of kernel and OpenRC output.

| Stage | Screen | Source |
|---|---|---|
| Power-on | Dark | U-Boot |
| U-Boot | Vendor logo, keys lit | U-Boot (`logo=osd1,...`). The kernel keeps the panel powered and keeps the backlight and key LEDs as U-Boot set them until the meson DRM driver binds |
| DRM bind | Black for a fraction of a second | The DRM driver switches the U-Boot plane off. `/init` waits for its framebuffer, then sets the mode |
| Initramfs | Splash: "starting", "checking the root file system", "starting the system" | `tsx-splash show` and `status` |
| Rootfs | Splash: "starting services", then "starting the kiosk <address>" | `tsx-setup`, the `kiosk` service |
| Sway start | Black for less than 1 s | Sway takes the display |
| Page load | Splash with "loading <host>" | The sway background (`swaybg`). The browser window is transparent |
| Reveal | The Home Assistant page | `tsx-kiosk-reveal` makes the browser window opaque |

**Handoff from U-Boot.** U-Boot powers the panel, sets the backlight (MP3309C step 13 on EDT glass, vendor level 128), lights the front keys (key PWM 50 percent) and shows its logo. The board DTS keeps this state in the kernel:

- The three fixed regulators of the LVDS panel have `regulator-boot-on`.
- The key PWM has `default-state = "keep"` and `default-brightness = <13>`.
- `tsx-idled` holds the backlight level after boot until `tsx-als` has a real reading (15 s at most). `tsx-als` skips 0 lx readings before its first level (`ALS_START_WAIT`).

The meson DRM driver turns the U-Boot plane off when it probes. `/init` waits up to 2 s for fb0 to be the framebuffer of the DRM driver before it draws the splash or binds the text console. `tsx-splash status` redraws the whole splash if fb0 changed driver since `show`.

**Kernel command line.** `CONFIG_CMDLINE` (the `tsx-xx60.config` fragment, see [kernel.md](kernel.md)) ends in `console=tty0 console=ttyAML0,115200n8 loglevel=7 fbcon=map:1`. `fbcon=map:1` maps every virtual console to framebuffer 1, which never exists. The framebuffer console never takes over fb0, and no kernel text reaches the LCD. The kernel messages go to the buffer of tty0 and to the serial port. `console=ttyAML0` is last, so `/dev/console` is the serial port.

**Initramfs.** `tsx-splash show` draws the splash after the rescue checks. It forces a mode set on fb0 and writes the frame. The status line follows the root checks. `tsx-splash console` switches the screen back to text. It binds fbcon to fb0 with `FBIOPUT_CON2FBMAP`, and the buffer of tty0 shows at once. It runs in these cases:

- Every way into the rescue system (`rescue()` in `/init`: the rescue image, `tsx.rescue`, no usable root, `force-rescue`, a failed `tsx-autoinstall`).
- `tsx-autoinstall`, as soon as it prints anything.
- `tsx.verbose` on the command line (a one-off U-Boot boot with extra bootargs, no `saveenv`).
- `BOOT_VERBOSE=1` in `panel.conf`.

`tsx-splash show` and `status` do nothing while fbcon is bound.

**Console font.** `/init`, `tsx-autoinstall` and `tsx-rescue-status` run `/usr/sbin/tsx-confont` after they bind the text console. The built-in 8x16 kernel font is small, and the figlet banner of the rescue screen falls apart with it. `tsx-confont` reads the framebuffer size (`/sys/class/graphics/fb0/modes`) and loads the largest Terminus bold font that gives at least 80x25 cells, with busybox `setfont` on `/dev/tty0`:

| LCD | Font | Console |
|---|---|---|
| 1280x800 (TSW-1060, TSS-10) | `ter-132b`, 16x32 | 80x25 |
| 1024x600 (TSW-760) | `ter-124b`, 12x24 | 85x25 |
| 1280x800 turned a quarter (`ORIENTATION` portrait) | `ter-120b`, 10x20 | 80x64 |
| 1024x600 turned a quarter | The kernel 8x16 (no Terminus font gives 80 columns) | 75x64 |

For a turned console (fbcon `rotate` 1 or 3), `tsx-confont` swaps the width and height first. The PSF files (`ter-116b` to `ter-132b`, SIL OFL 1.1) come from `font-terminus` in Alpine at build time (`rootfs/initramfs/mkinitramfs-switchroot.sh`, into `/usr/share/tsx/consolefonts/`). The font is kernel state and stays after `switch_root`. If there is no framebuffer, no font that fits, or `setfont` fails, the default kernel font stays. `tools/console-preview.py` renders text with a PSF file as the console shows it. `rootfs/tests/test-confont.sh` checks the font choice.

**Kiosk handoff.** `tsx-setup` and the `kiosk` service update the status line. The sway kiosk session (the default, `KIOSK_OSK`) hands over without a white flash:

- `kiosk-session` renders the current splash frame to a PNG (`tsx-splash png`) and uses it as the sway background.
- A sway rule (`for_window [app_id="^chrome-"] opacity 0`) keeps the browser window transparent. Chromium renders normally.
- `tsx-kiosk-reveal` watches the page over DevTools. It makes the window opaque when all of these conditions are true:
  - The page is loaded.
  - The first contentful paint is done.
  - No Home Assistant loading screen shows.
  - The page painted no larger element for 700 ms.
- A browser error page (no network, or a TLS error from an unset clock) reloads every 5 s at most. After `KIOSK_REVEAL_TIMEOUT` (60 s), the reveal shows whatever is there.
- After the reveal, the sway background changes to a solid color: the page background color (read over DevTools) or black. The splash does not show where the window does not cover the output, for example after the on-screen keyboard hides.

`KIOSK_SPLASH=off` in `/etc/kiosk.conf` gives a black background and a window that is visible at once. The cage session (`KIOSK_OSK=off`) has no handoff.

**`BOOT_VERBOSE`.** The kernel command line is built into the image and is the same for every panel. `tsx-config apply` keeps `/etc/tsx/boot-verbose` on the root file system in step with `BOOT_VERBOSE=1` in `panel.conf`. From the next boot, `/init` binds the text console as soon as it mounts the root. The first 1.3 s or so (kernel start to root mount) show at once from the tty0 buffer, wrapped at 80 columns. For a live view from the first line, use the serial console or `tsx.verbose`.

**Orientation** (`ORIENTATION` in `panel.conf`, see [rootfs.md](rootfs.md)). The setting is in `/etc/tsx/orientation` on the root file system. Until `/init` mounts the root, the splash is landscape. After the mount, `/init` reads the file with `tsx-orientation` and passes the name to `tsx-splash -o`. `tsx-splash` records it in `/run/tsx-splash.fb`, and the next `status` redraws the whole frame turned. In the rootfs, `tsx-splash` reads `/etc/tsx/orientation` itself. It composes the frame upright (from portrait artwork for portrait) and writes it to the framebuffer turned by the quarter turns. `tsx-splash png` writes the upright frame, because sway turns its output.

When the text console is on screen, `/init` writes `/sys/class/graphics/fbcon/rotate_all` (3 for portrait, 1 for portrait-flipped, 2 for landscape-flipped) and runs `tsx-confont` again. The kernel has `CONFIG_FRAMEBUFFER_CONSOLE_ROTATION`. The rotation stays after `switch_root`. The rescue system always sets it to 0, so the rescue screen is landscape.

**Artwork** (`rootfs/splash/`):

| File | Content |
|---|---|
| `tsx-linux-mark.svg` | The word mark "TSX-LINUX" in JetBrains Mono Bold (SIL OFL 1.1), two tones |
| `tux-80.png` | The 80x80 boot logo of the kernel (`drivers/video/logo/logo_linux_clut224.ppm`). Larry Ewing drew Tux with The GIMP. GPL-2.0 like the kernel. See `rootfs/splash/ATTRIBUTION` |

`mksplash.sh` renders one full-screen frame for each panel size at build time, in the build container. The sizes are 1280x800 (TSW-1060, TSS-10), 1024x600 (TSW-760) and the same two upright for portrait (800x1280 and 600x1024). Tux is at 2x, nearest neighbor. The script needs `rsvg-convert`, Pillow and `font-jetbrains-mono`. It stops if fontconfig does not find the font. It also produces two Terminus console fonts for the status line. The repository holds no font and no generated file.

`tsx-splash` picks the frame for the framebuffer size at run time. For another size, it centers the closest smaller frame on black. `rootfs/tests/test-splash.sh` checks the frames on the host. The rescue screen and `/etc/motd` show the name as ASCII art next to an ASCII Tux (`figlet -f smslant "TSX - LINUX"`, 63 columns with Tux).

### U-Boot USB needs VBUS held before enumeration

U-Boot USB port A (the external USB-A socket) reports `No USB device found` on every unmodified boot. Nothing switches VBUS on early enough. If VBUS is already high, `usb start 0` finds the device at once. From cold, switch VBUS on and hold it first:

```
gset GPIOX_18 out high; msleep 500; usb start 0
```

A delay of 200 ms also works. The recipe adds 0.5 to 1.5 s to the boot time. Only the optional USB install and recovery path needs it. SD-card and eMMC boots do not.

`installer/emmc/tsx-usb-recovery enable` puts this line in front of the live `switch_bootmode` (it edits the env on the card at 1 MiB). `usb start 0` then finds a stick before the stock `jabil_factory` check. `tsx-install-mainline` and `tsx-install-usb` enable it. `tsx-restore-factory` disables it.

With the line in place, the `jabil.txt` mechanism of U-Boot (`common/cmd_usb.c "usb factory"`) works like this:

1. U-Boot reads `jabil.txt` (three lines, one image name for each panel size) from the stick root.
2. It loads the named image from the stick root with `fatload` (no subdirectory).
3. It runs `bootm` on the image.

The image is a stage-2 installer image for `tsx-install-usb`, or a rescue image for a recovery-only stick (`mkpayload --recovery`). The image that runs renames `jabil.txt` (`installer/initramfs/tsx-autoinstall` on the install path), so a stick that stays in does not boot again.

**Limit:** U-Boot reads `jabil.txt` into a 150-byte stack buffer and copies three `strtok` lines with `strcpy` into 50-byte name buffers. A file with fewer than three lines crashes U-Boot into a reset loop while the stick is in. A file with more than 149 bytes, or a name of 50 or more characters, overflows the stack. `mkpayload` writes exactly three short lines. Do not edit the file by hand.

### Never write U-Boot

No tool in this project writes U-Boot itself on either storage device. This covers boot0, boot1, the eMMC `bootloader` area and the first 1 MiB of the SD card (MBR, U-Boot binary and env). Every install and recovery procedure stays inside this boundary. The env at 1 MiB is the one exception, and only the tools named on this page write it.

The factory restore writes the eMMC beyond `boot` and the root. It reads boot0, boot1, bootloader and reserved for verification only (see [recovery.md](recovery.md)). If U-Boot itself is damaged, recovery needs Amlogic USB Burning Mode. This project does not implement it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `fw_printenv` or `fw_setenv` never returns and uses a full CPU core | The configured env is larger than the data there (a short file, a truncated image, or a device smaller than offset plus size). `flash_read_buf()` in `tools/env/fw_env.c` treats a `read()` of 0 as a partial read and loops. SIGTERM stops it | Limit every call with `timeout -s KILL` (`TSX_FWENV_TIMEOUT`, default 10 s). On the Android side, use `tsx_fw_bound` in `installer/android/tsx-lib.sh`. Boot-time callers (`tsx-hostname`, `tsx-boot-ok`) already log the failure and continue |
| The serial stop key does not reach the prompt | The hook runs before `abortboot` | Create `tsxboot.off` on `p1` (see "Reach the U-Boot prompt") |
| `** Unable to use mmc 0:1 for fatload **` and Android boots | The hook has no leading `mmcinfo` | Add `mmcinfo;` at the start of `tsx_boot` |
| Stock Android boots after an interrupted install | The one-shot `tsx_once` is spent. This is the designed fallback | Arm again (see [recovery.md](recovery.md)) |
| The panel boots the golden rescue and not the kiosk | `boot_retry` reached 10 | Fix the cause. Run `tsx-rescue done && reboot -f` |
| LCD black for 10 s, then the kernel splash (TSW-760) | The boot image in `p7` has no display nodes | Write a boot image from a kernel package. These images have the display nodes |
| No U-Boot logo and no prompt on every boot | A DTB in `p7` crashes the display code | Amlogic USB Burning Mode. Test DTBs in RAM first |
| `No USB device found` | VBUS is low at enumeration | Run `tsx-usb-recovery enable` |
| Reset loop with a USB stick in | `jabil.txt` has fewer than three lines or is too long | Rebuild the stick with `mkpayload` |
