# Recovery

This page describes the mainline rescue system and the full factory restore back to stock Android. Use it when a panel does not reach the kiosk, when an install stops, or when you want stock Android back and have no backup of the unit.

For how U-Boot chooses what to boot, and why the golden slot is dangerous by default, see [boot.md](boot.md). For the normal install path, see [install.md](install.md).

## Tasks

### Reach the rescue system

The rescue image sits in the golden slot (`p1:boot.img`). U-Boot boots it on its own when `boot_retry` reaches 10. To boot it on purpose from a running mainline system:

1. Copy the golden image over the boot slot: `cp /media/bootfat/boot.img /media/bootfat/tsxboot.img`.
2. Run `reboot`.

The rescue brings up DHCP on eth0 and starts dropbear. The screen shows the IP address and the login. For the login rules, see "Rescue login".

### Leave the rescue system after a repair

1. Run `tsx-rescue status` to see the counters and the layout state.
2. Complete the repair.
3. Run `tsx-rescue done && reboot -f`.

`tsx-rescue done` makes one verified env write. It resets `boot_retry` and `golden_boot_retry` and keeps `DataRecoveryDone=1`. The next boot goes to the kiosk.

### Repair from inside the rescue

- Run `e2fsck` on the root file system.
- Reinstall the root file system from a host, or from a USB stick with a `GO` marker. This runs the stage-2 installer of the first install (see [install.md](install.md)).

### Recover from an interrupted install

The rescue-first installer (`installer/steps/tsx-rescue-arm.sh`, default `--guard once`) arms one rescue boot with `tsx_once=1`. U-Boot clears `tsx_once` before it loads the rescue (see [boot.md](boot.md) "The `tsx_once` state machine"). If the install stops, the panel needs one power cycle and nothing else.

1. If the rescue boots but the install does not finish (no network, the host driver stopped, the panel lost power), power-cycle the panel. You can also run `reboot -f` in a root shell on the rescue.
2. Wait for the boot. Stock Android starts. The eMMC `boot` and root regions are unchanged, and you need no `tsxboot.off`.
3. To retry, run `installer/steps/tsx-rescue-arm.sh install` from a stock Android root shell. It arms `tsx_once=1` again and resets `boot_retry` to 0. `p1:boot.img` and `p1:tsxboot.img` already hold the rescue image, so only the env write and the reboot repeat.

If the panel never reaches the rescue, the arm did not land the hook. This cannot happen with `--guard once`. It can happen with `--guard fallback`. Arm again.

`DataRecoveryDone=1` (set by the arm step) is a second defense. If `boot_retry` reaches the golden threshold by other causes, the golden boot cannot reformat the storage.

### Recover from a boot image that does not boot

`tsx-update-boot` rolls back a failed write by itself. An image that writes correctly but does not boot reaches no kiosk. `boot_retry` counts every retry, and the panel lands in this rescue or on stock Android on its own. Then write a good image from the rescue with `tsx-update-boot` (see [boot.md](boot.md)).

### Reach the rescue with no network (USB recovery)

Use this path when a unit does not boot far enough for SSH or UART. USB recovery must be enabled on the panel (`tsx-install-mainline` does this). You need a USB stick and a host that has the rescue image.

1. On the host, build the stick: `installer/payload/mkpayload --recovery --out DIR --rescue-tsw1060 IMG`. The stick holds `jabil.txt` and the rescue image or images.
2. Copy the files to the root of a FAT-formatted USB stick.
3. Plug the stick into the USB-A socket of the panel.
4. Power-cycle the panel. The stock `jabil_factory` hook of U-Boot boots the rescue from the stick.
5. Wait a few boots until the DHCP and dropbear banner shows on the screen.

If USB recovery is not enabled and you have a root shell, run `installer/emmc/tsx-usb-recovery enable` first.

### Restore stock Android without a backup

Use this path when no backup of the unit exists. You need the firmware package (`.puf`) for the product line. The restore writes every partition that the Crestron updater touches. It also writes recovery, cache and data. It keeps the identity of the panel (MAC, serial or tsid, product name) from the live environment.

**Warning:** The restore erases the mainline install and the data of the panel. Do not power off during the restore.

Before you start:

- The host needs `sshpass`, `python3`, `curl`, `unzip` and e2fsprogs (`mke2fs`, `e2fsck`, `debugfs`). On Debian, e2fsprogs is in `/sbin`, so add that to `PATH`.
- The panel must reach the host. The rescue downloads the restore bundle from an HTTP server on the host (port 8081 by default).
- If the unit already has a Crestron account, set `TSX_ADMIN_PW` (the console and web-UI admin password, user `TSX_ADMIN_USER`, default `admin`). Step 7 of the driver needs it to verify the console.

Steps:

1. Make sure the panel is in the rescue (see "Reach the rescue system").
2. Fetch the firmware package if it is not present: `rootfs/vendor-fetch.sh`. It downloads the `.puf` from the public Crestron firmware server to `rootfs/vendor-cache/tsw-xx60_3.002.1061.001.puf`. The repository never holds the `.puf`.
3. Run the driver:

   ```sh
   installer/tsx-restore-factory PANEL_IP [--puf FILE] [--env FILE] [--uart auto|yes|no]
                                 [--sshshell FILE | --stock-sshshell]
   ```
4. Watch the progress. The rescue screen shows the step, a progress bar and "DO NOT power off the system."
5. Wait for the final boot of stock Android. A factory-fresh unit has no Crestron account, so nothing can check this boot over SSH. Use the UART or watch the screen.

The driver checks the tools before it touches the panel. It checks the package against a pinned sha256 for the firmware release. A different `--puf` is accepted with a warning. The root-over-SSH patch needs the pristine package.

#### What the driver does

1. Reads the live environment from the SD card at 1 MiB and checks its CRC.
2. Builds a bundle with `installer/factory/mkbundle.sh`. The identity fields (MAC or `ethaddr`, tsid, product name) come from the live env. The other parts are:
   - **recovery**, **misc**, **data** and the alignment gaps: zeroed.
   - **cache**: an empty ext4 file system with the on-disk parameters of the factory image. The result is byte-reproducible.
   - **logo**: compared, and written only for the length of the reference logo image.
   - **boot** and **system**: from the firmware package.
3. Writes the eMMC regions in this order: misc, recovery, cache, logo (verify only), data, system, boot. It skips a region that already matches the target hash and reads every region back after the write. **boot0, boot1, the bootloader and the reserved area are read only, for identity verification. The restore never writes them.**
4. Restores the SD card: the Crestron MBR, the golden FAT `boot.img`, the factory `p2` system image and the factory `p5` to `p8` file systems. It writes the env without the mainline hook: the stock `switch_bootmode`, `boot_retry=0`, `golden_boot_retry=0` and `DataRecoveryDone=0`. It also disables USB recovery.

#### Root over SSH

By default, the restored `system.img` is the image of the `.puf` with one change. In `/system/bin/sshShell.sh`, the line `/system/bin/telnetSSHProxy SSH $1` in the interactive branch becomes `if [ "$command" == "rootsh" ]; then /system/bin/bash -l; else /system/bin/telnetSSHProxy SSH $1; fi`. After a Crestron account exists, `ssh -tt admin@PANEL rootsh` (`installer/steps/rootsh`) gives a root shell with no UART. A plain `ssh admin@PANEL` still gives the Crestron console.

`mkbundle.sh` makes the change with an awk recipe and keeps the mode, owner and SELinux label of the file. It verifies that the diff against the stock file is exactly that line. It refuses a firmware whose `sshShell.sh` lacks the line (an unknown release or a modified image). In that case, use one of these:

- The pristine `.puf`.
- `--sshshell FILE`: your own `sshShell.sh`, used as it is.
- `--stock-sshshell`: `system.img` is byte-identical to the `.puf`. Root over SSH then needs the UART.

## Reference

### What the rescue system is

The rescue image has the same kernel, DTB and initramfs as the kiosk image. A flag sends `/init` to a small standalone system and `/init` does not run `switch_root`. The rescue never formats, never installs on its own, and resets no counter. A kiosk that keeps failing cycles between the rescue and stock Android on the eMMC. It never reaches a destructive image.

The initramfs also starts the same rescue when the root is missing or broken, when `/etc/tsx/force-rescue` exists, or when `tsx.rescue` is on the kernel command line.

### Rescue login

`/usr/sbin/tsx-rescue-login` decides who can log in. `rcS` runs it before it starts dropbear.

1. It mounts `LABEL=tsxdata` read only and reads `/tsx/panel.conf`. `ROOT_PASSWORD_HASH` is the root password and `SSH_AUTHORIZED_KEY` is the root key (see [rootfs.md](rootfs.md) "Root login"). With a key and no hash, the password stays locked and only the key works. The screen says `the root password or SSH key of this panel`.
2. If `/data` is not readable, or `panel.conf` has neither value, the script makes a random one-time password for this boot. The screen shows it on the `login` line. It goes nowhere else: not to the network, the kernel log, the serial console or a file on disk. It lives in `/run` (RAM, mode 600) until the panel restarts. Dropbear accepts only this password.
3. If the script cannot make a password, the screen says `NONE`. Nobody can log in over the network. Use the keyboard shell on the panel.

The installer scripts use your SSH key or the password in `TSX_RESCUE_PW`. Without `TSX_RESCUE_PW`, they use `TSX_MAINLINE_PW`. `tsx-install-mainline` asks for the one-time password on a terminal when it starts from stock Android. `tsx-restore-factory` takes `--rescue-pw`.

For test builds only, `TSX_DEV_RESCUE_HASH` (a sha512-crypt hash, passed to `rootfs/build-rootfs.sh initramfs` and `installer/initramfs/build-initramfs.sh`) puts a fixed password into the rescue image. The screen then says `the password of this test build`. The optional file `rootfs/authorized_keys` adds a developer key to the same image. Public images have neither.

### The rescue screen

`/usr/sbin/tsx-rescue-status` draws the screen on the LCD (`/dev/tty0`) and mirrors one line to `/dev/kmsg` (and so to `ttyAML0`). The script ships in the base initramfs (`rootfs/initramfs/overlay`), and inittab starts it on tty1. `installer/rescue-v2/mkrescue-v2.sh` stamps the rescue image with its version line. The base initramfs also ships `tsx-rescue`, `tsx-boot-ok` and `/etc/tsx/uboot-env.conf`, so `tsx-rescue status` and `tsx-rescue done` work in every rescue.

The rescue moves the kernel console away from the LCD with busybox `setlogcons 12`. Kernel lines stay on the serial console and in `dmesg` and never print over the frame.

| Item | Content |
|---|---|
| Banner | The ASCII Tux next to "TSX - LINUX" (figlet `smslant`, 63 columns) and the word "rescue". The console font is Terminus bold (16x32 on 1280x800, 12x24 on 1024x600), loaded by `tsx-confont` (see [boot.md](boot.md) "Boot splash") |
| Model | `product_name` from the U-Boot env without its firmware and tsid suffix, the stock firmware version and the unit id |
| Versions | The version line of the rescue and `uname -r` |
| Network | The IP address, its source (DHCP or static `tsx.ip=`), the eth0 MAC and its source (U-Boot env or random), the `ssh root@<ip>` command and the login line. Until `rcS` sets the MAC, the line says "starting" and shows the MAC from the U-Boot env |
| Operation (only while an install or restore runs) | Its name, the current step, a progress bar and "DO NOT power off the system." A failed operation stays as "FAILED: ..." |
| Footer | "Press Enter for a rescue shell" |

The operation block reads these files:

| File | Content |
|---|---|
| `/run/tsx-install-state` | The current step. `installer/steps/tsx-rescue-install` and the factory restore tools write it |
| `/run/tsx-progress` | The `pr_dd` progress file: a 40-cell bar with MiB and percent. The screen ignores it when it is older than 2 minutes |
| `/run/tsx-op` | `PID NAME` of the tool. If the pid is gone, the screen says "stopped" |
| `/run/rescue-reason` | Why the rescue started. The screen does not show it. The shell prints it at login, and `tsx-rescue status` shows it over ssh |

The screen gives no power-cycle advice, because the effect depends on the U-Boot environment (see "Recover from an interrupted install").

**Rescue shell on the panel.** Plug a USB keyboard into the USB-A socket and press Enter on tty1 for a root shell on the LCD. `exit` returns to the screen. The local console has no password, and the serial console (`ttyAML0`) also gives a root shell with no password. ssh uses the rules of "Rescue login". The screen does not echo typed text. The shell also opens while an operation runs. Its first lines warn you not to power off or reboot.

**LCD console.** The rescue shares kernel and DTB with the kiosk image. `CONFIG_FRAMEBUFFER_CONSOLE=y`, `CONFIG_DRM_MESON=y` and the DRM fbdev emulation give an `fbcon` console. Normal boots keep fbcon off the LCD with `fbcon=map:1`, so the initramfs binds it before it enters the rescue (`tsx-splash console` in `rescue()`). `/dev/console` is the serial port and `/dev/tty0` is the LCD. If the LCD console fails, `tsx-rescue-status` still writes its status to `/dev/kmsg`.

### Rescue network and MAC

The rescue sets the MAC of `eth0` from `ethaddr` of the U-Boot env before DHCP. It first waits until the storage device that holds the env is available. The logic is in the base `rcS` (`rootfs/initramfs/overlay/etc/init.d/rcS`), so every rescue path uses it. `installer/rescue/mkrescue.sh` checks that the base boot image has this logic in `rcS`. The DHCP client-id (option 61) follows from the MAC, because busybox `udhcpc` derives it from the interface.

The kiosk side uses `select_eth0_mac()` in `/etc/init.d/tsx-setup` (`base/etc/init.d/tsx-setup` in tsx-linux-common). A valid env `ethaddr` always wins. When `/etc/tsx/eth0.mac` holds a different MAC, the function writes the env MAC to the file. When the env has no valid `ethaddr`, the function uses the MAC in the file. When the file has no valid MAC either, the function makes a random locally administered MAC and saves it in the file.

To check a live unit, run `cat /run/tsx-eth0-mac-src` in the rescue. It prints `uboot`, or `random` when the env has no `ethaddr`. The kernel log has `tsx-rescue: eth0 MAC ... (from U-Boot env)`.

`tsx-restore-factory` finds the panel by scanning the local subnet for a host whose MAC matches the env `ethaddr`. It assumes no fixed IP.

### USB recovery tool

`installer/emmc/tsx-usb-recovery enable|disable|status` edits the env variable `switch_bootmode` on the card at 1 MiB. The edit switches VBUS on before the `usb start 0` of U-Boot. Without it, U-Boot never sees a USB stick on this hardware (see [boot.md](boot.md) "U-Boot USB needs VBUS held before enumeration").

| Command | Effect |
|---|---|
| `enable` | Adds the VBUS prefix. `tsx-install-mainline` enables it on every panel that it converts. It costs about 0.5 s on each boot |
| `disable` | Removes the prefix. `tsx-restore-factory` disables it. The factory env write also resets `switch_bootmode` to the stock value |
| `status` | Prints `enabled`, `disabled` or `foreign`. `foreign` means `switch_bootmode` does not start with `usb start 0;`, and the tool does not touch it |

The script runs unchanged from the Android root shell, the rescue or the kiosk. It does not depend on `tsx-lib.sh`. It makes at most one env write and verifies it by readback with the same CRC discipline as `tsx-boot-ok`.

### Factory restore tools

| Script | Runs on | Does |
|---|---|---|
| `installer/factory/mkbundle.sh` | Host | Builds a restore bundle from a `.puf` package (and optionally a backup of the unit) |
| `installer/factory/tsx-emmc-restore` | Panel, in the rescue | Writes the eMMC regions from the bundle by raw offset. It needs no partition table |
| `installer/factory/tsx-factory-restore` | Panel, in the rescue | Writes the SD card back to the Crestron factory layout |
| `installer/tsx-restore-factory` | Host | Drives the whole restore |

Driver options:

| Option | Meaning |
|---|---|
| `PANEL_IP` | Required |
| `--puf FILE` | Firmware package. Default: the package from `rootfs/vendor-fetch.sh` |
| `--env FILE` | A saved 64 KiB U-Boot env of this unit. It replaces the env that the driver reads from the card. The file must hold the unit's `ethaddr` |
| `--uart auto\|yes\|no` | Same as in the install driver (see [install.md](install.md)). `auto` uses the serial console only if it seems active. `no` runs everything over the network. `yes` forces the serial console. The rescue is reachable over the network, so the UART is optional |
| `--sshshell FILE`, `--stock-sshshell` | See "Root over SSH" |
| `--rescue-pw` | Rescue password (see "Rescue login") |

### Never write U-Boot

The restore reads boot0, boot1, the bootloader and the reserved area for verification and never writes them. See [boot.md](boot.md) "Never write U-Boot".

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `tsx-emmc-restore check` refuses everything | The `boot0` hash does not match the bundle, or the bundle is for another firmware version | Run `mkbundle.sh` again for the live env of this unit. Do not force past a `boot0` mismatch. The check proves that U-Boot is untouched |
| A region write succeeds but a later check shows stale data, or an install skips a format, or the boot goes to the rescue | A leftover file system superblock sits in a region that the tool does not clear (see "Stale file system labels") | Zero the superblock area of the region before the restore, or extend the bundle to cover it |
| Stock Android resets a few minutes after the restore | The Crestron recovery path ran once on a fresh empty card partition | Let it finish and reboot once. The stability wait of the driver expects this |
| `restore` stops: `sshShell.sh` line not found | Unknown firmware release or a modified image | Use the pristine `.puf`, `--sshshell FILE` or `--stock-sshshell` |

#### Stale file system labels

A file system superblock that stays in a region makes a later mount use the label and UUID that it holds. Two cases:

- A leftover `tsxdata` superblock at the start of a card data partition makes the auto-install step skip the format, because the label and a clean `e2fsck -fn` look correct. The result is a corrupt, half-migrated `/data`.
- A leftover `tsxroot-emmc` superblock in an eMMC alignment gap beats the installed root in the root selection of the initramfs (see [boot.md](boot.md) "Root selection"). The boot goes to the rescue.

A tool that reuses a region must not accept an existing label or UUID as proof of correct content. It compares an identifier that it wrote itself (a UUID for the current layout generation), or it wipes the superblock area first.

#### The `ash` `dd` stdin trap

Panel scripts run under busybox `ash`. `ash` gives a background job `/dev/null` as stdin. `bash` gives it the stdin of its parent. A background `dd` that must read from a pipe therefore reads nothing under `ash`, and no copy and no progress happens.

The progress helper `pr_dd` (used by `tsx-emmc-restore` and `tsx-factory-restore`) runs `dd` in the background and prints MiB, percent and ETA. It redirects the real input to a separate file descriptor (`7`) before it starts the job. A panel script that starts a background job that reads a pipe must do the same. Test such a script under `busybox sh`, because `bash` does not show the problem.
