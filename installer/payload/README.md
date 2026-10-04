# Install payload

The payload is a FAT32 USB stick, or a plain staging directory that a host serves over HTTP. It installs the mainline kiosk on a Crestron TSW-1060 or TSW-760. The boot image has the DTBs of both models. Build the payload on the host with `installer/payload/mkpayload`.

In this file, "stick" means the physical USB medium. The same payload directory also works over HTTP with no stick. This is the network install method, `tsx-install-mainline` (see [docs/install.md](../../docs/install.md)).

## Tasks

### Prepare the stick

1. Format the stick as FAT32 (MBR, one partition). Android mounts only vfat sticks.
2. Mount the stick.
3. Run `mkpayload --out DIR ...` with the options in "mkpayload modes".
4. Take the LED bar out of the external USB-A socket while the stick is in.

Android mounts the stick at `/mnt/media_rw/udisk0` (FUSE view `/storage/udisk0`). The match comes from `fstab.amlogic`: `voldmanaged=udisk0:auto`, type vfat.

### Flow 1 (default): convert from the Android root shell, over the network

Build the payload:

```
mkpayload --out DIR --rootfs-p2 out/rootfs-p2.ext4 --rescue-tsw1060 out/tsx-rescue-tsw1060.img \
  --bootimg-tsw1060 out/tsxboot-audio-autoinstall.img
```

Then run `preflight` and `install` on the panel.

One run writes these items, in this order:

1. p2 (kiosk rootfs).
2. p1 (kiosk image, the rescue system in the golden slot, and the Crestron golden `boot.img`, which it saves to the stick).
3. The env hook.
4. MBR byte 498 (p5 to p8 become one p4).

Then the panel reboots. The kiosk boots from p2. The initramfs formats p4 as `tsxdata` one time. This removes the Android on the card. `factory/puf-tool.sh` and `tsx-factory-restore` restore it.

`installer/steps/legacy/tsx-android-to-card` runs this flow from start to end over HTTP. It needs no stick and no UART once root over the Crestron sshd works (see "Automated load"). `installer/tsx-install-mainline` does not use this script. It installs through the rescue system (see [docs/install.md](../../docs/install.md)).

### Flow 2: stock Android unit, root shell, by hand

1. Plug the stick into the USB-A socket of the panel. Android must run.
2. Run `ssh -tt $TSX_ADMIN_USER@<panel-ip>`. Root bash needs the tty. The default user is `admin`.
3. Run `bash /mnt/media_rw/udisk0/tsx-install/android/tsx-android-install.sh preflight`. This step only reads. Every line must say `ok`.
4. Run `bash /mnt/media_rw/udisk0/tsx-install/android/tsx-android-install.sh install`.
5. Type `INSTALL`. The script backs up to the stick and to `/data/local/tsx-backup`. It writes `p2` (kiosk rootfs), `p1:boot.img` (the rescue system), `p1:tsxboot.img` and the U-Boot hook (with the `fw_setenv` of Android). It writes the MBR byte last. Then it reboots.
6. Wait. U-Boot boots `p1:tsxboot.img`. The kiosk starts from `p2`. The initramfs formats `p4` as `tsxdata` one time. The panel screen shows the progress. The run takes about 2 to 5 minutes.
7. Remove the stick and put the LED bar back.

This is the only supported card-stage path.

### Flow 3 (USB install method): stock unit, no network

This flow needs only a root shell and no usable network. First enable `tsx-usb-recovery` on the panel. `tsx-install-mainline` enables it for good. You can also enable it by hand over the UART (see [docs/recovery.md](../../docs/recovery.md) "USB recovery"). Then the stock `switch_bootmode` and `jabil_factory` hook of U-Boot sees the stick, because `tsx-usb-recovery` switches VBUS on before U-Boot looks for USB devices (see [docs/boot.md](../../docs/boot.md) "U-Boot USB needs VBUS held before enumeration").

1. Build the payload: `mkpayload --usb --out DIR --rootfs-p2 ... --rescue-tsw1060 ... --bootimg-tsw1060 ...`.
2. Plug the stick into the panel.
3. Open a root shell on the panel (Crestron sshd `rootsh`, or the UART console).
4. Run `sh tsx-install-usb`. It verifies the stick and enables `tsx-usb-recovery` (it does nothing if this is already on). It keeps `DataRecoveryDone=1` and reboots.
5. Wait. U-Boot runs `jabil_factory` and loads the stage-2 image from the stick. `tsx-autoinstall` installs everything and shows the progress on the panel screen. It renames `/jabil.txt`, so a stick that stays in does not boot again. Then it reboots into the kiosk.
6. When the panel is reachable, run `steps/legacy/tsx-card-to-emmc <panel-ip>` and `steps/tsx-deploy-tfa.sh <panel-ip>` over the network. They finish the eMMC migration.

This flow ends on the card stage, the same as Flow 1 and Flow 2 (see [docs/install.md](../../docs/install.md) "USB install method").

### USB recovery stick (no root shell)

1. Enable `tsx-usb-recovery` on the panel.
2. Run `mkpayload --recovery --out DIR --rescue-tsw1060 IMG`.
3. Plug in the stick and power-cycle the panel.

The panel boots straight into the mainline rescue system. See [docs/recovery.md](../../docs/recovery.md) "USB recovery".

### Flow 4: reinstall a unit that boots mainline, hands off

1. Build the stick with `--go`.
2. Plug the stick in and power-cycle the panel.

`tsx-autoinstall` sees a USB mass-storage device and `tsx-install/GO`. It reinstalls p5 and p1 and renames `GO` to `GO.done-<unit>-<time>`. A reinstall formats p5. If the stick has no `token.txt`, the Chromium profile (the HA login) is lost.

## Undo

- Quick: from the kiosk, run `mount /media/bootfat && touch /media/bootfat/tsxboot.off` (Android boots). From Android, run `tsx-android-uninstall.sh --disable`.
- Full, from stock Android: run `tsx-android-uninstall.sh`. It restores the stock `switch_bootmode`, deletes `tsx_boot` and removes the p1 files. If the Android sdcard must be empty, first run `rootfs/uninstall.sh --p5-mkfs` in the mainline rescue system.
- Env: run `tsx-android-uninstall.sh --restore-env <backup>/env-0x100000.bin`.
- USB recovery: run `installer/emmc/tsx-usb-recovery disable`. `tsx-restore-factory` does this automatically.

## Reference

### Payload layout

| Path | What |
|---|---|
| `/jabil.txt` | 3 lines (5inch, 7inch, 10inch image names) for the stock U-Boot `jabil_factory` hook. Enable `tsx-usb-recovery` on the panel first (`installer/emmc/tsx-usb-recovery`) |
| `/tsxboot-tsw1060.img` | Mainline boot image (initramfs with `tsx-autoinstall`) |
| `/tsxboot-tsw760.img` | Present when you pass `--bootimg-tsw760`. Without it the installers refuse 7-inch units |
| `/tsx-install-usb` | `--usb` only: the single panel-side command (flow 3) |
| `/tsx-usb-recovery` | `--usb` only: a copy of `installer/emmc/tsx-usb-recovery`. `tsx-install-usb` runs it |
| `/tsx-install/tsx-install.conf` | key=value: `VERSION`, `ROOTFS`, `ROOTFS_SHA256`, `BOOTIMG_<model>`, optional `RESCUE_<model>`, `KIOSK_URL`, `TOKEN_FILE`, `GUARD`, `DEFUSE_GOLDEN` |
| `/tsx-install/SHA256SUMS` | Every payload file, with paths relative to the stick root |
| `/tsx-install/rootfs.tar.gz` | The mainline rootfs. It must contain `ENV_VERIFIED=yes` |
| `/tsx-install/rescue-tsw1060.img` | Optional: the mainline rescue for the golden slot |
| `/tsx-install/rootfs.info` | What `mkpayload` found in the tarball |
| `/tsx-install/token.txt` | Optional HA long-lived token. Keep the stick private |
| `/tsx-install/GO` | Optional: arms the hands-off reinstall (flow 4) |
| `/tsx-install/android/` | `tsx-android-install.sh`, `tsx-android-uninstall.sh`, `tsx-lib.sh` |
| `/tsx-install/linux/` | `install.sh`, `uninstall.sh`, `tsx-disk.sh` (for manual rescue) |
| `/tsx-install/backup/<unit>-<time>[-mainline]/` | Written by the installers: the env block, the first 2 MiB of the disk, the first MiB of p5, `fw_printenv`, the Android sdcard archive |
| `/tsx-install/log/` | Installer logs |

A recovery-only stick (`mkpayload --recovery`) is much smaller. It holds only `jabil.txt` and the rescue image or images. It has no `tsx-install/` tree (see [docs/recovery.md](../../docs/recovery.md) "USB recovery").

### mkpayload modes

| Mode | Command |
|---|---|
| Android flow (default) | `mkpayload --out DIR --rootfs-p2 FILE --rescue-tsw1060 IMG --bootimg-tsw1060 IMG` |
| USB install | The same inputs, plus `--usb` |
| Two-stage payload and GO reinstall | `mkpayload --out DIR --rootfs rootfs.tar.gz --bootimg-tsw1060 IMG` (stage 2 installs the tarball on p5) |
| Recovery stick | `mkpayload --recovery --out DIR --rescue-tsw1060 IMG [--bootimg-tsw760 IMG]` |

### mkpayload options

| Option | What |
|---|---|
| `--bootimg-tsw760 IMG` | TSW-760 boot image. The boot image has the DTBs of both models, so you can pass the same file |
| `--rescue-tsw1060 IMG` | Golden-slot rescue image (`rescue/mkrescue.sh`) |
| `--url URL` | Kiosk URL (`KIOSK_URL`) |
| `--token-file F` | HA long-lived token, seeded at the first kiosk start |
| `--config FILE` | `panel.conf` (`installer/panel.conf.example`), copied onto the stick for the record. Build `--rootfs-p2` with the same file through `steps/mkp2rootfs.sh --config-file`. p2 has no `/data` yet, so the stick cannot write into it (`docs/rootfs.md` "Panel configuration") |
| `--go` | Create `tsx-install/GO`. Units that already boot mainline reinstall from this stick at the next power cycle |
| `--usb` | Also copy `tsx-install-usb` and `tsx-usb-recovery` onto the stick root. It needs `--rootfs-p2`, `--rescue-tsw1060` and `--bootimg-tsw1060`, with `tsx-autoinstall` in the boot image |
| `--guard fallback\|nogolden` | Hook variant that stage 2 installs (default `fallback`) |
| `--no-defuse-golden` | Stage 2 does not set `DataRecoveryDone=1` (default: it does) |
| `--allow-stale` | Accept a rootfs without `ENV_VERIFIED=yes` |
| `--allow-no-autoinstall` | Accept a boot image whose initramfs has no `tsx-autoinstall`. Then only the `--source net` flow works |

### jabil.txt limits

The limits come from `common/cmd_usb.c "usb factory"`. U-Boot reads the file into a 150-byte stack buffer. It uses `strcpy` to copy three `strtok` lines into 50-byte names.

| Condition | Result |
|---|---|
| The file has fewer than 3 lines | `strcpy(NULL)` crashes U-Boot. The panel reboots in a loop while the stick is in |
| The file has more than 149 bytes, or a name has 50 or more characters | The stack overflows |

`mkpayload` writes 3 short lines (about 50 bytes). Do not edit the file by hand.

## Automated load: steps/legacy/tsx-android-to-card

This script is an expert and debug tool (see [steps/legacy/README.md](../steps/legacy/README.md)).

`steps/legacy/tsx-android-to-card --payload DIR --rootfs FILE [--uart auto|yes|no] <panel-ip>` runs the whole no-adb conversion from start to end. It does these steps:

1. It forces stock Android if the panel is on mainline.
2. It repairs p5 if p5 is not stock.
3. It waits for stock Android to settle. It always does this, not only after a p5 reformat. A stock unit can run the one-time Crestron golden re-install on its first boot and reboot itself. The wait ends when `fwUpgrade=0`, the upgrade image directory is gone, `getprop sys.boot_completed` is 1 and p5 is mounted. The script accepts that one self-reboot.
4. It gets root over the Crestron sshd (`steps/rootsh`). It installs the patched `sshShell.sh` if that file is not there yet.
5. It splits the payload, serves it over HTTP and runs `steps/mkpanelfetch.sh` on the panel.
6. It runs `preflight`. Then it runs `install --p2-written`, after you type `INSTALL` or when you pass `--yes`.
7. It waits for the kiosk to boot.

| Option | What |
|---|---|
| `--results FILE` | Log file. The script logs every step with a timestamp. Default `results/tsx-android-to-card-<date>.txt` |
| `--from-step N` | Resume a run at step N |
| `--dry-run` | Print the step list for either control channel. It does not touch the panel, the UART or the network, except for a local `ip route get` |
| `--uart auto\|yes\|no` | Control channel for step 3, step 4 and step 7. Default `auto` |
| `--yes` | Do not ask before the install |

`out/sshShell.sh` must be next to the rootfs image. `DIR` must be a subdirectory of that same `out/`, so that the HTTP server can reach it.

With `--uart auto`, the script uses the serial console only if `serlog.py` seems to run (`pgrep`) and `../../tools/bench/uc.sh` exists. If not, these steps run over the network only. `--uart no` always selects the network. `--uart yes` forces the serial console and stops with an error if `uc.sh` is missing.

### Network-only mode (no UART)

Make sure of these conditions before you use this mode:

- Root over ssh works through the Crestron sshd (`steps/rootsh`). The patched `/system/bin/sshShell.sh` (`out/sshShell.sh`, see [docs/install.md](../../docs/install.md) "Prerequisites") is already on the panel.
- A Crestron admin account exists. Set `$TSX_ADMIN_USER` (default `admin`) and `$TSX_ADMIN_PW` (required).

A factory-fresh unit can have no account but already have the `sshShell.sh` patch. Run `steps/crestron-admin <panel-ip>` first. It creates the account through the first-run call of the web UI. The driver then reaches root without the UART. If the `sshShell.sh` patch is missing, network-only mode cannot install it. The install needs a root shell, from the UART or from an earlier root session. The driver then stops with an error that says so.

The network-only mode differs from the UART mode in these steps:

| Step | Network-only behavior |
|---|---|
| 3 | Runs the same checks through `rootsh` instead of the UART root prompt. The checks are `fw_printenv fwUpgrade`, the upgrade image directory, `getprop sys.boot_completed` and the p5 mount. The step accepts the one self-reboot of the golden re-install and retries until the timeout. If p5 is not mounted at all, the step stops at once. The `mke2fs` repair works only over the UART, so run the script again with `--uart yes` |
| 4 | Checks `rootsh_ok` first. If that check fails, the step uses `crestron-admin`. It does not install `sshShell.sh` over the UART |
| 7 | Polls `ssh root@<panel-ip> uname -r` for up to about 400 s instead of watching the serial log. It accepts the install reboot. Then it logs `/proc/cmdline` and `findmnt -no SOURCE /` (expect `/dev/mmcblk0p2`). It also logs whether `chromium` (the kiosk) runs |
