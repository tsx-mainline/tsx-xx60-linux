# Install and reinstall

This page shows how to install mainline Linux on a TSW-760, TSW-1060 or TSS-10 and how to reinstall or update a panel that runs it. The installer writes the kiosk to the eMMC. For the boot flow see [boot.md](boot.md). For the way back to stock see [recovery.md](recovery.md). For Home Assistant see [ha.md](ha.md).

Two install methods exist:

- **Network** (default): one host command. It needs no USB stick.
- **USB**: use it only when the panel has a root shell but no usable network (UART only).

## Tasks

### Install from stock Android (network)

Before you start, make sure these items are ready:

- The panel runs stock Android and the host can reach it over the network.
- The host has `sshpass`, `ssh`, `python3`, `curl`, `sha256sum` and `ip`. The `.puf` download also needs `unzip`, and the PSR download also needs `debugfs` (e2fsprogs).
- The panel can connect back to the host on TCP ports 8079 and 8081.
- A root shell over the Crestron sshd works (see "Root over the Crestron sshd").
- You have a payload (see "Get the payload").

Steps:

1. Set the Crestron admin password in the environment: `export TSX_ADMIN_PW=<password>`. `TSX_ADMIN_USER` defaults to `admin`.
2. Run the installer:

   ```sh
   installer/tsx-install-mainline <panel-ip> \
     --payload installer/out/payload --kernel lts
   ```

3. Answer the panel configuration prompts (see "Panel configuration"). Give a root password or an SSH public key.
4. Type `INSTALL` at each confirmation. The installer asks before it arms the rescue boot (this reboots the panel) and before it writes the eMMC.
5. Wait for the summary. The installer prints progress for each step. The panel reboots into the mainline kiosk.
6. If the panel screen shows a one-time rescue password, set `TSX_RESCUE_PW` to it and run the same command again. The installer asks for it on a terminal.

The install runs these stages:

| Stage | Script | What it does |
|---|---|---|
| 1 | `installer/steps/tsx-ensure-root` | Makes sure the panel is stock Android and settled. Makes sure root over the Crestron sshd works (`installer/steps/rootsh`). |
| 2 | `installer/steps/tsx-rescue-arm.sh` | Backs up the env and the first 2 MiB of the disk. Writes the rescue image to `p1:boot.img` (golden slot, after it backs up the Crestron golden image) and to `p1:tsxboot.img` (one-shot hook target). Installs the U-Boot env hook with `tsx_once=1`. Reboots the panel. |
| 3 | `installer/lib/tsx-rescue.sh` | Finds the rescue on the network by the MAC of the panel, which the installer records before the reboot. Pushes the install bundle: the boot image of the chosen flavor and `--kiosk-url`. Serves the root image over HTTP. |
| 4 | `installer/steps/tsx-rescue-install` | Runs inside the rescue. Writes eMMC `boot` (`p7`) and root (`p8`) with live progress. Verifies each image by readback. Runs `resize2fs` so the root fills `p8`. Folds card partitions `p5` to `p8` into `p4` (`tsxdata`). Deploys the TFA9890, PSR and `KIOSK_URL` files into the new root. Writes the final env (`tsx-usb-recovery enable`, `p1:tsxboot.off`). Reboots. |
| 5 | host driver | Waits for the SSH of the kiosk. With your key (or `TSX_MAINLINE_PW`) it checks that root is `/dev/mmcblk1p8` and prints a summary. Without login it waits for the OpenSSH banner on port 22 and prints which root login case applies. |

Stage 2 never writes `p2` or the MBR of the card. The rescue does that after it verifies the eMMC writes. `tsx_once` is a true one-shot. U-Boot clears it before it loads `tsxboot.img`. One power cycle with no install progress therefore returns the panel to stock Android. See [boot.md](boot.md) "The `tsx_once` state machine".

The installer serves every file over HTTP: the rescue image, the eMMC boot and root images and, only if the panel has none, the DSP files. The panel needs no USB stick.

### Reinstall or update a panel that runs mainline

Use this task to install a payload on a panel that runs mainline, or to start from a clean root. You need no Crestron account, no `TSX_ADMIN_PW` and no `rootsh`.

1. Make sure your SSH key is in the root login of the panel. If the panel has a root password, set `TSX_MAINLINE_PW`.
2. Run the installer:

   ```sh
   installer/tsx-install-mainline <panel-ip> --payload DIR --kernel lts|stable \
     [--config FILE] [--wipe-data] [--yes] [--dry-run]
   ```

3. Wait for the summary.

The installer finds that the panel answers as the mainline kiosk (root on eMMC `p8`). It then does these steps:

1. It copies `rescue.img` to `/tmp` on the kiosk and checks its sha256.
2. It runs [`installer/lib/tsx-arm-from-mainline.sh`](../installer/lib/tsx-arm-from-mainline.sh) on the kiosk. `tsx-restore-factory` uses the same script. The script checks that the U-Boot hook is installed (if not, it writes nothing). It copies the rescue to `p1:tsxboot.img` (verified), removes `p1:tsxboot.off`, sets `tsx_once=1` and reboots.
3. The installer finds the rescue and copies it into the golden slot (`p1:boot.img`, verified). It then continues as in a first install: it writes and verifies the eMMC boot and root, writes the final env and reboots.

If the run stops after the rescue is up, run the same command again. It resumes in the rescue. If the rescue never answers, one more power cycle boots the installed kiosk. `tsx_once` is spent and the eMMC is unchanged. The stock boot command boots eMMC `p7`.

`--dry-run` shows the path the installer takes. It probes the panel read-only.

### Keep or wipe data

The eMMC boot and root are always replaced. The `/data` partition (`tsxdata`, card `p4`) is **kept** by default. These items survive: the Chromium profile and Home Assistant login, the logs, `panel.conf`, the voice and Sendspin state, `/root` and `/home`. The kiosk comes back on its dashboard without input.

The rescue keeps `p4` only if both conditions are true:

- `p4` is an ext4 file system with the label `tsxdata`.
- A read-only check (`e2fsck -fn`) is clean. If it finds problems, the rescue runs one `e2fsck -fp` repair and checks again.

If the rescue cannot keep `p4`, it formats `p4` and prints `WARNING: ... cannot be kept`.

To start from a clean state, or if the kept `/data` causes problems:

1. Add `--wipe-data` to the command.
2. After the install, if `panel.conf` has no token, log in to Home Assistant on the panel.

`--wipe-data` formats `tsxdata` as a first install does. Only `panel.conf` carries over (from `--config`, from the prompts, or with `--yes` from the current file of the panel). If `panel.conf` has a login token, the kiosk is back on its dashboard without input.

A first install from Android always folds the card and formats `tsxdata`, because the panel has no `tsxdata` partition.

What happens to `panel.conf` on a kept `tsxdata`:

| Option | Result |
|---|---|
| `--config FILE` or the prompts | The file that you give replaces `/data/tsx/panel.conf`. The prompts offer the current values as defaults. |
| `--yes` with no `--config` | The panel keeps its own file. Only `KERNEL_FLAVOR` changes to the `--kernel` that you installed. |

The kept `/data` is bind-mounted over `/var/lib/kiosk`, `/var/log`, `/var/lib/tsx`, `/var/lib/sendspin`, `/root` and `/home` (`tsx-data`, see [rootfs.md](rootfs.md)). The bind mounts hide the files that the root image has in those directories. The root image has no file there that the panel needs.

### Install over USB

Use this method when the panel has a root shell but no usable network.

1. Build the payload on the host:

   ```sh
   installer/payload/mkpayload --usb --out DIR \
     --rootfs-p2 installer/out/rootfs-p2.ext4 \
     --rescue-tsw1060 installer/rescue/out/tsx-rescue-tsw1060.img \
     --bootimg-tsw1060 installer/out/tsxboot-audio-autoinstall.img \
     [--config FILE]
   ```

2. If you need a panel configuration, put it into `rootfs-p2.ext4` first: `installer/steps/mkp2rootfs.sh --config-file FILE`. The card stage has no `/data` at build time. The script stores the file as `/etc/tsx/panel.conf.seed`. `tsx-config apply` installs it as `/data/tsx/panel.conf` at the first boot that mounts `/data`. `mkpayload --config FILE` also copies the file onto the stick for the record.
3. Copy `DIR` onto a FAT32 USB stick. Plug it into the USB-A socket of the panel.
4. In a root shell on the panel, run `sh tsx-install-usb`. It verifies `SHA256SUMS`, arms USB recovery (`tsx-usb-recovery enable`), sets `DataRecoveryDone=1` and reboots. It installs nothing itself.
5. Leave the stick in. The panel reboots. The install starts at the next power cycle. The stock `jabil_factory` hook of U-Boot sees the stick ([boot.md](boot.md) "U-Boot USB needs VBUS held before enumeration") and boots the stage-2 image. Then `tsx-autoinstall` does the install. The panel screen shows progress.
6. When the panel is reachable over the network, move the root to the eMMC:

   ```sh
   installer/steps/legacy/tsx-card-to-emmc <panel-ip>
   installer/steps/tsx-deploy-tfa.sh <panel-ip>
   ```

The USB boot does not install straight to the eMMC. The result of step 5 is the card-stage layout (see "Layouts"). `tsx-autoinstall` also has an Android-CLI path (`tsx-android-install.sh`). Use `tsx-install-usb` for the USB install.

### Change the kernel flavor or the boot image

For the two flavors see [kernel.md](kernel.md).

If the panel has the kernel packages `tsx-xx60-kernel-lts` and `tsx-xx60-kernel-stable` (see [rootfs.md](rootfs.md) "The project apk repository"), both boot images are on the panel (`/boot/tsxboot-emmc-lts.img`, `/boot/tsxboot-emmc-stable.img`). Switch without a network:

1. Run `tsx-kernel-flavor` to show the selected flavor, the running kernel and the installed images.
2. Run `tsx-kernel-flavor stable` (or `lts`). It writes the image with a backup and a readback check, and sets `KERNEL_FLAVOR`.
3. Run `reboot`.

`apk upgrade` and `tsx-autoupdate` write the boot image of a kernel package only for the selected flavor.

If the panel does not have the packages, or uses the card layout, use `tsx-update-boot`. It is in `/usr/local/sbin`. The package `tsx-xx60-boot-tools` installs it in `/usr/sbin`. The source is [`rootfs/overlay/usr/local/sbin/tsx-update-boot`](../rootfs/overlay/usr/local/sbin/tsx-update-boot). On a root image that lacks it, copy the file to `/data` and run it with `sh`.

```sh
tsx-update-boot IMG SHA256          # card layout: p1:tsxboot.img only
tsx-update-boot --emmc IMG SHA256   # eMMC layout: raw write to the eMMC boot partition
```

Example for an eMMC panel (the root image has the modules of both flavors):

```sh
scp DIR/stable/boot.img root@<panel-ip>:/data/boot-stable.img
ssh root@<panel-ip> tsx-update-boot --emmc /data/boot-stable.img \
  "$(awk '$2=="boot.img"{print $1}' DIR/stable/SHA256SUMS)"
ssh root@<panel-ip> reboot
```

On the eMMC layout the command saves the previous image (`/data/tsxboot-emmc.prev.img` and its sha256) and verifies the write by readback. If the readback is bad, it restores the saved image. If the readback is good, it prints the rollback command. For an image that does not boot, see [boot.md](boot.md) "`boot_retry`, the golden slot and why it is destructive". This command does not change the golden and rescue fallback.

### Configure the panel after install

If you skipped the configuration prompts, the panel has no `KIOSK_URL`. The kiosk then shows a **setup page** on the touchscreen with the on-screen keyboard. The page has these settings: Home Assistant URL, login method, panel name, time zone, screen orientation, voice and MQTT, and the root password and SSH key (blank when the panel has none).

To use the page from a laptop or phone, open `http://<panel-ip>:8080/setup` and enter the six-digit pairing code from the panel screen. After you configure the panel, the page is not reachable from the network. See [rootfs.md](rootfs.md) "Setup page".

To open the page again, run `tsx-config setup` over SSH, or press **Setup** in the quick-settings overlay. The page is available (locally and from the LAN, with a fresh pairing code) for about 15 minutes. The current configuration stays.

With `HA_LOGIN_METHOD=token` and a token, the kiosk logs in at first boot. With `trusted`, Home Assistant needs a trusted-network auth provider. To seed or replace a token by hand, run `kiosk-set-token`. [ha.md](ha.md) covers the rest.

## Reference

### Installer options

```sh
installer/tsx-install-mainline <panel-ip> --payload DIR --kernel lts|stable [options]
```

| Option | Default | Meaning |
|---|---|---|
| `<panel-ip>` | none | Required. The panel to install. |
| `--payload DIR` | `installer/out/payload` | The payload directory. |
| `--kernel lts\|stable` | none | Required. The kernel flavor to install. |
| `--uart auto\|yes\|no` | `auto` | The control channel of stage 1. `auto` uses the serial console only if a serial logger seems to run. `yes` forces it. `no` uses the network only. Stages 2 to 5 always use the network. |
| `--kiosk-url URL` | none | The dashboard URL. |
| `--config FILE` | none | Use `FILE` as `panel.conf`, with no prompts. `tsx-config` validates it, so a mistyped key or bad value is rejected before the panel changes. |
| `--yes` | off | Skip the prompts and the `INSTALL` confirmations. With no `--config`, write no `panel.conf` and apply only `--kiosk-url`. |
| `--wipe-data` | off | Format `tsxdata` on a reinstall. |
| `--dry-run` | off | Print the step list and the path. Never prompts. Changes nothing except a local route lookup. |
| `--sshshell FILE` | none | Your own `sshShell.sh` for the root shell over SSH. |
| `--results FILE` | none | Write a timestamped log of every step. |
| `--tfa-source auto\|panel\|puf\|none` | `auto` | Where to get the speaker DSP files. |
| `--psr-source auto\|panel\|puf\|none` | `auto` | Where to get the Bluetooth PSR file. |

Environment variables:

| Variable | Meaning |
|---|---|
| `TSX_ADMIN_PW` | Crestron console and web UI admin password. Required for a first install. |
| `TSX_ADMIN_USER` | Admin user. Default `admin`. |
| `TSX_MAINLINE_PW` | Root password of a running mainline panel, when you log in with a password and not a key. If set, the installer skips the check for a root password or key. |
| `TSX_RESCUE_PW` | The one-time password that the rescue shows on the panel screen. |
| `TSX_PANEL_KIND` | `android`, `mainline`, `rescue` or `unreachable`. The value skips the network probe of the installer. Without it, the installer finds the kind from the ssh banner. If no ssh answers, it assumes stock Android. |

### Panel configuration

The installer builds `/data/tsx/panel.conf` after it arms the rescue and before it looks for the rescue. The file holds the panel name, the Home Assistant URL and login, the time zone, voice, MQTT, a root password hash and an SSH key. See [rootfs.md](rootfs.md) "Panel configuration" and `installer/panel.conf.example`. The installer builds and checks the file with the `tsx-config` script of tsx-linux-common. Set `TSX_COMMON` to the top of a checkout of that repository. The default is the folder `tsx-linux-common` next to this repository. You can answer in three ways:

| Mode | Behavior |
|---|---|
| Prompts (default) | Each prompt has a default. Enter keeps it. On a reinstall, the installer first reads the existing `/data/tsx/panel.conf` and offers its values. |
| `--config FILE` | The installer uses `FILE` with no prompts. Use it for scripted and multi-panel installs. |
| `--yes`, no `--config` | No prompts and no `panel.conf`. A reinstall keeps the file of the panel. |

### Root password and SSH key

A public image has no fixed root password. The install stops unless it gets a root password or an SSH public key. This holds for the prompts, for `--config` and for `--yes`. With `--yes` and no `--config`, only a reinstall can pass, and the panel's own `panel.conf` must have a hash or a key.

The last two prompts are:

1. `Root password, 8 characters or more`. Type it twice. An empty answer means key only.
2. `SSH public key for root's authorized_keys`. Give a key if you gave no password. The installer asks again if you gave neither.

The installer hashes the password on the host (sha512-crypt, with `openssl`, `mkpasswd` or the `crypt` module of `python3`). It sends the password to the hash tool on standard input. It never prints, logs or stores the password. `panel.conf` holds only `ROOT_PASSWORD_HASH` and `SSH_AUTHORIZED_KEY`. The panel applies them at the first boot. On a reinstall, an empty answer keeps the saved hash and key.

| Case | Result |
|---|---|
| Password | The login on the panel screen and over SSH takes it. SSH also takes a key if you gave one. |
| Key only | The root password is locked (`*` in `/etc/shadow`). SSH takes the key. The screen and serial console logins stay off until you run `passwd` over SSH. |

A test image built with `TSX_DEV_ROOT_HASH` has a fixed password (see [rootfs.md](rootfs.md) "Root login"). Give it in `TSX_MAINLINE_PW`, for example `TSX_MAINLINE_PW=tsx` when the hash is the hash of `tsx`.

The rescue has no fixed password. It uses the panel login from `/data`, so your key (or `TSX_MAINLINE_PW`) works on a reinstall. When the rescue cannot read `/data`, it shows a one-time password on the panel screen. See [recovery.md](recovery.md) "Rescue login".

### Root over the Crestron sshd

A first install needs a Crestron admin account and a root shell on the panel over the Crestron SSH daemon.

1. A Crestron admin account must exist. A factory-fresh panel has none. `installer/steps/crestron-admin <panel-ip>` (with `TSX_ADMIN_PW` set) creates it with the call that the first-run form makes. Some panels redirect every web UI page to that form. Others serve the web UI with authentication off. The script handles both. `installer/steps/crestron-admin --status <panel-ip>` shows whether an account exists. The installer runs the script for you.
2. The admin account must get a root shell over SSH. The installer gets it with `installer/steps/rootsh`.

**Lockout.** The Crestron sshd blocks an IP address for 24 hours after 3 failed logins (console commands `SETLOGINATTEMPTS` and `SETLOCKOUTTIME`). The block also stops `installer/steps/rootsh` from that host ("Your IP address is blocked"). The installer reads the SSH identification line first and never tries a login on a host that answers as `CrestronSSH`. To clear a block, log in to the Crestron console from another machine and run `REMBLOCKEDIP <blocked-ip>`. `LISTBLOCKEDIP` shows the list.

### The payload

The `--payload` directory has this layout:

| File | Content |
|---|---|
| `rescue.img` (and `.sha256`) | The rescue image. It is the golden slot and the one-shot target. |
| `<flavor>/root.img` | The compact root image, built to the content size plus a margin (typically under 1 GiB). `resize2fs` grows it to fill `p8`. |
| `<flavor>/boot.img` | The eMMC boot image (kernel, DTB, initramfs). |
| `<flavor>/manifest` | The manifest. |
| `<flavor>/SHA256SUMS` | The checksums. |

`<flavor>` is `lts` or `stable`.

#### Get the payload

Every tagged release publishes `tsx-xx60-lts-payload.tar.zst`, `tsx-xx60-stable-payload.tar.zst` and a `SHA256SUMS` file for both. They are on <https://github.com/tsx-mainline/tsx-xx60-linux/releases>. `.github/workflows/release.yml` builds them.

1. Download the archive for your flavor and `SHA256SUMS` into the top directory of the repository.
2. Verify and unpack it:

   ```sh
   sha256sum -c --ignore-missing SHA256SUMS
   mkdir -p installer/out/payload
   tar --zstd -xf tsx-xx60-lts-payload.tar.zst -C installer/out/payload
   ```

The result is `installer/out/payload/{rescue.img, lts/{root.img,boot.img,manifest,SHA256SUMS}}`.

To build the payload yourself, run these scripts. The build needs only the sources of this repo and the Alpine and kernel.org downloads. No proprietary input is needed.

- [`installer/emmc/mk-tsxroot-emmc.sh`](../installer/emmc/mk-tsxroot-emmc.sh)
- [`installer/emmc/mk-v2-bundle.sh`](../installer/emmc/mk-v2-bundle.sh)
- [`installer/rescue-v2/mkrescue-v2.sh`](../installer/rescue-v2/mkrescue-v2.sh)

`ci/build-rescue.sh` chains them for the rescue image.

Each release also has `tsx-xx60-kernel-<flavor>-bundle.tar.zst`. The install does not use it. The CI of [tsx-aports](https://github.com/tsx-mainline/tsx-aports) uses it to build the package `xx60/tsx-xx60-kernel-<flavor>` (zImage, DTB, boot image and modules). That package pins the release tag and the sha512sum of the asset in its `APKBUILD`. See [`tools/build/README.md`](../tools/build/README.md#ci-release-asset-for-tsx-aports-tsx-xx60-kernel-flavor-bundletarzst).

### Layouts

End state (eMMC):

| Region | Content |
|---|---|
| eMMC `boot` (32 MiB) | Mainline boot image (kernel, DTB, initramfs). |
| eMMC `system`+`data` (about 2.9 GiB) | Mainline root (ext4, `LABEL=tsxroot-emmc`). |
| SD card `p1` | Rescue image only (golden slot) and env. |
| SD card `p4` | `tsxdata` (`/data`), all runtime state. |

The `system`+`data` size is the size of the partition, not of the root image. `resize2fs` grows the root to fill it.

All runtime state lives on `p4`: logs, the Chromium profile, the audio state and the voice state. The data-binding service of the rootfs bind-mounts `p4` into the eMMC root. The install writes the eMMC boot and root once. Normal operation does not write them.

Card stage (USB method only, a transitional layout):

| Partition | Content |
|---|---|
| `p1` (FAT) | Mainline boot image and the Crestron golden `boot.img`, moved to the rescue slot. |
| `p2` | Mainline root (ext4). |
| `p4` | `tsxdata` (`/data`), formatted at first boot. |
| env (1 MiB offset) | Hook installed, `DataRecoveryDone=1`. |

This layout uses the Android partitions `p5` to `p8` of the card. Android does not boot from the card after that. The way back is a full factory restore ([recovery.md](recovery.md)). `installer/steps/legacy/tsx-android-to-card` also creates this layout.

### Scripts and libraries

| Script | Runs on | Role |
|---|---|---|
| `installer/steps/tsx-rescue-arm.sh` | Android root shell | Backs up the env, writes the rescue to `p1`, installs the env hook with `tsx_once=1`, reboots. Never writes `p2` or the MBR. |
| `installer/steps/tsx-rescue-install` | Rescue | Writes and verifies eMMC `boot` and root, folds the card into `p4`, deploys the DSP, PSR and `KIOSK_URL` files, arms USB recovery, writes `p1:tsxboot.off` so the stock `bootcmd` takes over (`imgread kernel boot` from the eMMC), reboots. |
| `installer/lib/tsx-rescue.sh` | Host and panel | `pr_dd` (live MiB, percent and rate for a background `dd`), the verified single-write env helper, the MBR fold and the MAC-based rescue discovery that `tsx-restore-factory` also uses. |

### Speaker DSP files (TFA9890)

The TFA9890 tuning files (`.cnt` containers) are Crestron and NXP data. They are never in the rootfs image or in this repository (see [rootfs.md](rootfs.md) "Proprietary blobs: `vendor-fetch.sh`"). Every panel has them in its own firmware. The rescue takes them from the panel, read-only, before it writes anything (`installer/steps/tsx-rescue-install tfa`, `installer/lib/tsx-tfa.sh`). It tries these sources in order. The first source that has all three variants wins:

1. The installed mainline root: `/usr/local/share/tsx/tfa9890/<variant>/stereo.cnt` on eMMC `p8`. This also works with `--wipe-data`.
2. The stock Android boot image in eMMC `p7`. Its ramdisk has the files in `jabil/tfa9890/`. The rescue reads it before it writes the mainline boot image.
3. The `.puf` download (fallback). The host runs `rootfs/vendor-fetch.sh`, which downloads the public Crestron firmware package (357 MB, cached) and extracts the files. The host pushes them to the rescue. This needs `unzip` on the host.

With sources 1 and 2 the files never leave the panel. The installer prints `TFA9890 source used: ...`. The panel keeps a record in `/usr/local/share/tsx/tfa9890/SOURCE` with the source, the firmware and the sha256 of each file.

The installer checks each `stereo.cnt`:

- If the sha256 equals the pinned value (the list in `rootfs/vendor-fetch.sh`), it uses the file.
- If the sha256 differs but the file is a sound NXP container (`PM` header, size field equal to the file size, correct CRC32), it uses the file. It prints a warning with the hash and firmware. Report such a hash.
- Otherwise it rejects the file and tries the next source.

| `--tfa-source` | Behavior |
|---|---|
| `auto` | The order above. |
| `panel` | Never download. |
| `puf` | Skip the panel. Always download. |
| `none` | Install no DSP files. |

A missing DSP set never stops the install. Without it the speakers work, but without the vendor EQ and the volume-step presets. To add the files after the install, run `installer/steps/tsx-deploy-tfa.sh <panel-ip>` (the `.puf` download).

### Bluetooth PSR file (CSR8811)

The CSR8811 chip needs the file `PSR-CSR8811.psr` (ROM patches and radio setup) from the Crestron firmware. It is never in this repository or in an image. The rescue looks for it on the panel, read-only, before it writes anything (`installer/steps/tsx-rescue-install psr`, `installer/lib/tsx-psr.sh`):

1. The installed mainline root: `/usr/local/share/tsx/csr8811/PSR-CSR8811.psr` on eMMC `p8`.
2. The system partition of stock Android: `bin/PSR-CSR8811.psr` in the same eMMC region.
3. The `.puf` download (fallback). The host runs `rootfs/vendor-fetch.sh --psr`. It uses the same download and cache as the DSP files, extracts `/bin/PSR-CSR8811.psr` from `system.img` with `debugfs` (no mount, no root) and checks the pinned sha256. The host pushes the file to the rescue. This needs `unzip` and `debugfs` on the host and about 1.1 GB of free temporary space for a short time.

With sources 1 and 2 the file never leaves the panel. The installer accepts the pinned sha256, or another sha256 with a warning if the file is sane PSR text. It prints `Bluetooth PSR source used: ...` and writes the file and a `SOURCE` record to `/usr/local/share/tsx/csr8811/` on the new root.

`--psr-source auto|panel|puf|none` works like `--tfa-source`. A missing PSR file never stops the install. Without it, the Bluetooth proxy loads only its address (see [hardware.md](hardware.md) "Bluetooth (CSR8811)"). A reinstall gets the file from the download if the root has none.

A panel with U-Boot `government=1` (the TSW-760-NC) has no Bluetooth module ([hardware.md](hardware.md) "Panel variants"). In modes `auto` and `panel`, the rescue reads the flag first (kernel command line, else U-Boot env). With `government=1` it looks for no file, the host does not download the `.puf`, and the installer prints `Bluetooth PSR source used: not needed: government=1, ...`. The `SOURCE` record then has `source=not-needed`. `--psr-source puf` still downloads the file. The speaker DSP files are not affected.

### Stock LED bar firmware image

The USB LED bar has its own firmware. The stock image (`statussign_*.upg`, for example `statussign_1.3443.00018.upg`) is a Crestron file and is never in this repository, a package or an image. The installer keeps a copy on the panel so that you can load the stock bar firmware back.

The rescue looks for the file in the stock Android system partition, read-only (`installer/steps/tsx-rescue-install ledstock`, `installer/lib/tsx-ledstock.sh`), at `vendor/firmware/` or `system/vendor/firmware/`. It accepts a file made of S-records with the application tag record first. The install copies it to `/data/tsx/vendor/` on tsxdata and checks the copy. A `.source` file next to it records the Android build and the sha256.

- A reinstall that keeps `/data` keeps the copy.
- `--wipe-data` and any other format of `tsxdata` remove the copy. Install from Android again to get it back.
- If the rescue finds no file, the installer prints one line and continues. A panel with no LED bar is not affected.

To load the stock firmware into the bar, see [rootfs.md](rootfs.md) "LED bar".

### Progress output

Every driver script prints progress and does not run silently:

- During large writes it prints per-region lines and a tick with MiB written, percent and ETA about every 15 s.
- It streams the output of remote commands live.
- It prints heartbeat lines in every wait loop (Android settle, kiosk start, reboot).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Your IP address is blocked` from `rootsh` | The Crestron sshd blocked the host after 3 failed logins. | Run `REMBLOCKEDIP <blocked-ip>` on the Crestron console from another machine. |
| The installer cannot get a root shell on stock Android | The admin account gets no root shell over SSH. | Set up the root shell (see "Root over the Crestron sshd"). Then run the installer again. |
| The install stops before it writes anything and asks for a root password or key | `panel.conf` has no `ROOT_PASSWORD_HASH` and no `SSH_AUTHORIZED_KEY`. | Give a password or a key in the prompts or in `--config FILE`. |
| The rescue asks for a password | The rescue cannot read `/data` (first install). | Read the one-time password on the panel screen. Set `TSX_RESCUE_PW` and run the same command again. |
| The run stops after the rescue is up | A network or host interruption. | Run the same command again. It resumes in the rescue. |
| The rescue never answers | The rescue did not boot or is not on the network. | Power cycle once. The panel boots the installed kiosk or stock Android. Run the command again. |
| `WARNING: ... cannot be kept` | `p4` is not a clean `tsxdata` ext4 file system. | None needed. The rescue formatted `p4`. Restore `panel.conf` with `--config FILE` if needed. |
| The panel boots to the setup page | No `KIOSK_URL` in `panel.conf`. | Configure the panel (see "Configure the panel after install"). |
| A boot image does not boot | The image is bad. | See [boot.md](boot.md) "`boot_retry`, the golden slot and why it is destructive" and [recovery.md](recovery.md). |
| Speakers have no EQ or volume presets | The DSP files are missing. | Run `installer/steps/tsx-deploy-tfa.sh <panel-ip>`. |
| The Bluetooth proxy loads only its address | The PSR file is missing. | Reinstall with `--psr-source puf`, or see [hardware.md](hardware.md) "Bluetooth (CSR8811)". |
