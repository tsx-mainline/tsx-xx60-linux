# Install and reinstall

This page shows how to install mainline Linux on a TSW-760, TSW-1060 or TSS-10 and how to reinstall or update a panel that runs it. The installer writes the kiosk to the eMMC. For the boot flow see [boot.md](boot.md). For the way back to stock see [recovery.md](recovery.md). For Home Assistant see [ha.md](ha.md).

Two install methods exist:

- **Network** (default): one host command. It needs no USB stick.
- **USB**: use it only when the panel has a root shell but no usable network (UART only).

## Tasks

### Install from stock Android (network)

Before you start, make sure these items are ready:

- The panel runs stock Android and the host can reach it over the network.
- The host has the tools of "Host requirements".
- The host can open ssh connections to the panel (TCP port 22). The panel needs no connection to the host (see "Network requirements").
- A root shell over the Crestron sshd works (see "Root over the Crestron sshd").
- You have a payload (see "Get the payload").

Steps:

1. Choose the Crestron admin user and password. On a factory-fresh panel, the installer creates the account with them. Otherwise, use the login of the account that exists.
2. Write the password into a file that only you can read, for example `~/.tsx-admin-pw`.
3. Run the installer:

   ```sh
   installer/tsx-install-mainline <panel-ip> \
     --payload installer/out/payload --kernel lts \
     --admin-user <user> --admin-password-file ~/.tsx-admin-pw
   ```

   If you do not give `--admin-password-file`, the installer asks for the password on a terminal. The user and the password have no default (see "Options and environment variables").

4. Answer the panel configuration prompts (see "Panel configuration"). Give a root password or an SSH public key.
5. Type `INSTALL` at each confirmation. The installer asks before it arms the rescue boot (this reboots the panel). Without a stage, it also asks before it writes the eMMC. With a stage, the rescue writes the eMMC with no more questions (see "Stage on the panel first").
6. Wait for the summary. The installer prints progress for each step. The panel reboots into the mainline kiosk.
7. If the panel screen shows a one-time rescue password, type it when the installer asks. For a run with no terminal, write it into a file and run the same command again with `--rescue-password-file FILE`.

The install runs these stages:

| Stage | Script | What it does |
|---|---|---|
| 1 | `installer/steps/tsx-ensure-root` | Makes sure the panel is stock Android and settled. Makes sure root over the Crestron sshd works (`installer/steps/rootsh`). |
| 2 | `installer/steps/tsx-rescue-arm.sh` | Backs up the env and the first 2 MiB of the disk. Writes the rescue image to `p1:boot.img` (golden slot, after it backs up the Crestron golden image) and to `p1:tsxboot.img` (one-shot hook target). Installs the U-Boot env hook with `tsx_once=1`. Reboots the panel. |
| 3 | `installer/lib/tsx-rescue.sh` | Finds the rescue on the network by the MAC of the panel, which the installer records before the reboot. Pushes the install bundle over ssh: the boot image of the chosen flavor and `--kiosk-url`. |
| 4 | `installer/steps/tsx-rescue-install` | Runs inside the rescue. Writes eMMC `boot` (`p7`) and root (`p8`) with live progress. The host streams the root image over ssh into this step. Verifies each image by readback. Runs `resize2fs` so the root fills `p8`. Folds card partitions `p5` to `p8` into `p4` (`tsxdata`). Deploys the TFA9890, PSR and `KIOSK_URL` files into the new root. Writes the final env (`tsx-usb-recovery enable`, `p1:tsxboot.off`). Reboots. |
| 5 | host driver | Waits for the SSH of the kiosk. With your key (or `--mainline-password-file`) it checks that root is `/dev/mmcblk1p8` and prints a summary. Without login it waits for the OpenSSH banner on port 22 and prints which root login case applies. |

Stage 2 never writes `p2` or the MBR of the card. The rescue does that after it verifies the eMMC writes. `tsx_once` is a true one-shot. U-Boot clears it before it loads `tsxboot.img`. One power cycle with no install progress therefore returns the panel to stock Android. See [boot.md](boot.md) "The `tsx_once` state machine".

The installer sends every file over the ssh connections that it opens: the rescue image, the eMMC boot and root images and, only if the panel has none, the DSP and PSR files. The panel needs no USB stick and no connection to the host.

### Reinstall or update a panel that runs mainline

Use this task to install a payload on a panel that runs mainline, or to start from a clean root. You need no Crestron account, no `--admin-user` or `--admin-password-file`, and no `rootsh`.

1. Make sure your SSH key is in the root login of the panel. If you log in with the root password of the panel, give it with `--mainline-password-file FILE`.
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

### Install from a USB stick

Use this method for a panel with no network, or for many panels with one stick. The stick holds the rescue, the images and the panel configuration. The panel needs no host and no network.

Before you start, make sure these items are ready:

- USB recovery is on in the panel. Every panel that runs mainline has it after `tsx-install-mainline`. A stock Android panel needs it once: run `installer/android/tsx-install-usb` in a root shell, or the arm step of `tsx-install-mainline`.
- A FAT32 USB stick with about 450 MiB free.
- A payload (see "Get the payload") with a rescue image that has `tsx-rescue-staged`.

Steps:

1. Make the stick folder on the host:

   ```sh
   installer/tsx-make-stick --payload installer/out/payload --kernel lts \
     --out STICKDIR --config panel.conf
   ```

2. Copy everything in `STICKDIR` to the root of the stick.
3. Check the copy: `(cd /media/stick && sha256sum -c SHA256SUMS)`.
4. If the LED bar is in the USB-A socket of the panel, remove it.
5. Put the stick into the USB-A socket.
6. Power-cycle the panel.
7. Watch the rescue screen. It shows each step and a progress bar. Do not power off.
8. When the screen says "Remove the USB stick", remove it. The panel then restarts into the kiosk.

The stick boot: U-Boot finds `jabil.txt` on the stick and boots `tsx-rescue.img` from it (see [boot.md](boot.md) "U-Boot USB needs VBUS held before enumeration"). The rescue finds no stage on the card and finds `tsx-stage/` on the stick. It installs the stage as described in "Stage on the panel first", with these differences:

- The rescue mounts the stick read-only and never changes it. One stick installs many panels.
- The rescue writes the sha256 of the `STAGE` file to `p1:tsxstick.done`. A panel that boots from the same stick again does not install again.
- If the stick stays in through a reboot after its install, U-Boot boots the stick again. The rescue then sees `p1:tsxstick.done`, renames `jabil.txt` on the stick to `jabil.txt.done` and reboots into the kiosk. Before you use the stick for the next panel, rename `jabil.txt.done` back to `jabil.txt`.
- The rescue ignores a stick that has no `jabil.txt`, because U-Boot did not start the rescue from that stick. So a stick that stays in after its install does not stop a later factory restore or push install.
- The rescue of the stick goes to the golden slot (`p1:boot.img`) and to `p1:tsxboot.img`. The old `p1:boot.img`, for example the golden image of Crestron on a stock card, goes to `/data/tsx/backup/p1-boot-<sha256>.img`.
- A mainline panel keeps a clean `tsxdata` (`/data`). A stock card is always folded and formatted.

`panel.conf`: `--config FILE` puts one configuration on the stick for every panel. Leave `PANEL_NAME` empty, so each panel takes `<model>-<MAC>`. Without `--config`, the script asks the questions of the installer. The stick needs a root password hash or an SSH key. `--no-config` makes a stick without `panel.conf`: a panel that runs mainline keeps its own `panel.conf`, and a stock Android panel refuses the stick before it writes anything.

The DSP and PSR files come from the panel. With `--tfa-source puf` (or `--psr-source puf`), the stick carries the files of the `.puf` download.

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

To use the page from a laptop or phone, open `http://<panel-ip>:8080/setup` and enter the six-digit pairing code from the panel screen. After you configure the panel, an administrator of Home Assistant opens the page from the network at any time: click **Log in with Home Assistant** and log in at the Home Assistant of the panel. No pairing code is necessary. See [rootfs.md](rootfs.md) "Setup page".

To open the page again, run `tsx-config setup` over SSH, or press **Setup** in the quick-settings overlay. The page shows on the screen, and the pairing code works from the LAN, for about 15 minutes. The current configuration stays.

With `HA_LOGIN_METHOD=token` and a token, the kiosk logs in at first boot. With `trusted`, Home Assistant needs a trusted-network auth provider. To seed or replace a token by hand, run `kiosk-set-token`. [ha.md](ha.md) covers the rest.

## Reference

### Host requirements

The installer runs on any Linux machine with `bash` and these tools:

- `ssh`, `python3`, `curl`, `ip`, `tar`, `find`, `sha256sum`, `du`, `stat` and `gzip`. The busybox versions of `tar`, `find`, `sha256sum`, `du`, `stat` and `gzip` also work.
- `sshpass` for a password login: the Crestron account of stock Android, and a root or rescue password instead of an ssh key.
- `unzip` (or `busybox` with its `unzip` applet) for the `.puf` download, and `debugfs` (e2fsprogs) for the PSR file from it.
- A checkout of this repository and a checkout of tsx-linux-common (see "Panel configuration").

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
| `--fetch TAG` | none | A mainline panel downloads the release `TAG` itself (see "Download the release on the panel"). Needs no `--payload`. `TAG` can also be the full download URL of a release. |
| `--stage auto\|yes\|no` | `auto` | Copy the install onto the card of the panel before the rescue boot (see "Stage on the panel first"). `auto` stages when it can and pushes over ssh when it cannot. `yes` stops when it cannot stage. `no` always pushes over ssh. |
| `--release-url URL` | `https://github.com/tsx-mainline/tsx-xx60-linux/releases/download` | The URL of the releases for `--fetch TAG`. |
| `--stage-wait SECONDS` | `2400` | The time that the installer waits for a staged install to finish. |
| `--ssh-ciphers LIST` | `chacha20-poly1305@openssh.com` first | The ssh cipher list for the streams into the rescue (see "Network requirements"). |
| `--common DIR` | `tsx-linux-common` next to this repository | The tsx-linux-common checkout (see "Panel configuration"). |

### Options and environment variables

Each setting of the installer has a command line option. The environment variable of a setting is for automation. If you give both, the option wins.

The logins have no default value. If the installer needs a login and you gave none, it asks on a terminal. With no terminal, or with `--yes` or `--dry-run`, it stops with an error that names the option. It stops before it logs in to the panel.

A password on the command line shows in the process list and in the shell history. Use the `-file` form or the prompt. The file holds the password on its first line.

| Option | Variable | Meaning |
|---|---|---|
| `--admin-user USER` | `TSX_ADMIN_USER` | The Crestron admin user. Necessary for an install from stock Android. |
| `--admin-password-file FILE`, `--admin-password PW` | `TSX_ADMIN_PW` | The Crestron console and web UI password of that user. Necessary for an install from stock Android. On a factory-fresh panel, the installer creates the account with this user and password. The prompt asks for the password two times. |
| `--mainline-password-file FILE`, `--mainline-password PW` | `TSX_MAINLINE_PW` | The root password of a panel that runs mainline, when you log in with a password and not a key. If you give it, the installer skips the check for a root password or key in `panel.conf`. |
| `--rescue-password-file FILE`, `--rescue-password PW` | `TSX_RESCUE_PW` | The one-time password that the rescue shows on the panel screen. Without it, the rescue login uses your key or the mainline password. |
| `--release-url URL` | `TSX_RELEASE_URL` | See "Installer options". |
| `--stage-wait SECONDS` | `TSX_STAGE_WAIT_S` | See "Installer options". |
| `--ssh-ciphers LIST` | `TSX_SSH_CIPHERS` | See "Installer options". |
| `--common DIR` | `TSX_COMMON` | See "Installer options". |

The step scripts `installer/steps/crestron-admin`, `installer/steps/rootsh` and `installer/steps/tsx-ensure-root` take the same login options. `installer/tsx-restore-factory` takes the admin and rescue options. The installer gives the logins to its steps in the environment.

`TSX_PANEL_KIND` (`android`, `mainline`, `rescue` or `unreachable`) is a test hook with no option. It skips the network probe of the installer. Without it, the installer finds the kind from the ssh banner. If no ssh answers, it assumes stock Android.

### Panel configuration

The installer builds `/data/tsx/panel.conf` after it arms the rescue and before it looks for the rescue. The file holds the panel name, the Home Assistant URL and login, the time zone, voice, MQTT, a root password hash and an SSH key. See [rootfs.md](rootfs.md) "Panel configuration" and `installer/panel.conf.example`. The installer builds and checks the file with the `tsx-config` script of tsx-linux-common. Give the top of a checkout of that repository with `--common DIR` (or `TSX_COMMON`). The default is the folder `tsx-linux-common` next to this repository. You can answer in three ways:

| Mode | Behavior |
|---|---|
| Prompts (default) | Each prompt has a default. Enter keeps it. On a reinstall, the installer first reads the existing `/data/tsx/panel.conf` and offers its values. |
| `--config FILE` | The installer uses `FILE` with no prompts. Use it for scripted and multi-panel installs. |
| `--yes`, no `--config` | No prompts and no `panel.conf`. A reinstall keeps the file of the panel. |

The time zone prompt offers the zone of the panel file on a reinstall. Otherwise it offers the time zone of the PC (`/etc/timezone`, else the link `/etc/localtime`, else `timedatectl`, else UTC). A new panel without a `panel.conf` (`--yes`, no `--config`) keeps the zone of the image (`America/Denver`). Put `TZ_NAME` in the `--config` file to set another zone.

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

A test image built with `TSX_DEV_ROOT_HASH` has a fixed password (see [rootfs.md](rootfs.md) "Root login"). Give it with `--mainline-password-file FILE`, for example a file that holds `tsx` when the hash is the hash of `tsx`.

The rescue has no fixed password. It uses the panel login from `/data`, so your key (or the password of `--mainline-password-file`) works on a reinstall. When the rescue cannot read `/data`, it shows a one-time password on the panel screen. See [recovery.md](recovery.md) "Rescue login".

### Network requirements

The host opens every connection of the install. The panel never opens a connection to the host. The install works on a network that drops new connections from the panel, for example an IoT VLAN, if the host can reach port 22 of the panel.

| Stage | Connection | What goes over it |
|---|---|---|
| 1, 2 (stock Android) | ssh to the Crestron sshd (`installer/steps/rootsh`) | The commands, and one tar with the arm script and the rescue image (`rootsh --put`) |
| 2 (reinstall) | ssh to the kiosk (OpenSSH) | The commands and the rescue image |
| 3, 4 | ssh to the rescue (dropbear) | The install bundle as one tar stream, the root image as a stream into `tsx-rescue-install run --root-from -`, and the DSP and PSR files from a `.puf` download |

The checks:

- `rootsh --put` sets the tty of the root shell to raw mode with no echo. It sends the file only after the shell prints a ready marker. Then it compares the sha256 of the copy with the file.
- The rescue checks the bundle against `SHA256SUMS` before it replaces `/tmp/b`.
- The rescue reads the boot and root images back from the eMMC and prints a `WRITE-RESULT` line with the sha256. The host compares it with the manifest of the payload.

Speeds on a TSS-10 (100 Mbit/s Ethernet, routed path with a round trip of 1.9 ms):

| Measurement | MiB/s |
|---|---|
| eMMC write of random data through ext4, with `fsync`, no network | 3.3 |
| eMMC write of zeros to `p8`, with `fsync`, no network | 4.0 |
| ssh into the rescue, `chacha20-poly1305@openssh.com` | 4.5 |
| ssh into the rescue, `aes128-ctr` | 3.1 |
| ssh into the rescue, `aes256-ctr` | 3.0 |
| Root image during the install (ssh and eMMC together, 993 MiB in about 6 min) | 2.8 to 3.0 |

The eMMC sets the speed of the install. The first 200 MiB go faster (4.5 MiB/s), until the page cache is full.

The dropbear of the rescue has no GCM ciphers. So the installer puts `chacha20-poly1305@openssh.com` first. The receive window of dropbear (24 KiB) sets the ssh speed, not the CPU. On a path with a longer round trip, the ssh speed falls below the eMMC speed and the install takes longer. A test dropbear with a 2 MiB window (`-W`) gave 10 to 11 MiB/s on the same path.

`installer/tsx-restore-factory` uses the same method. The host pushes the factory bundle (about 700 MiB) to `/tmp/b` of the rescue as one tar stream over ssh. The rescue shows the MiB received about every 15 s and checks `SHA256SUMS` before the restore uses the files.

If a run stops while the rescue is up, run the same command again. The new run stops an earlier run that is still busy, for example a `dd` that flushes the eMMC after a lost connection. It keeps the DSP and PSR files that the earlier attempt found. After the root stream ends, a lost connection does not stop the rescue: the install goes on and reboots the panel.

### Stage on the panel first

Before the rescue boot, while stock Android or the kiosk still runs, the installer copies the install onto the card of the panel. The rescue then installs from that copy by itself. After the rescue boot the install needs no network. A lost link or a move of the panel to another network does not stop it.

| Panel | Where the stage goes | How it gets there |
|---|---|---|
| Stock Android | Card `p5` (the `sdcard` partition, ext2, about 1.4 GiB): `tsx-stage/` | `installer/steps/rootsh --put`, one file at a time, each sha256 checked |
| Mainline (a reinstall) | Card `p4` (`tsxdata`, `/data`): `/data/tsx-stage/` | One tar stream over ssh, `SHA256SUMS` checked on the panel |

The stage holds the install bundle (the boot image, the scripts of the rescue, `panel.conf` and the kiosk URL) and the root image as gzip (about 390 MiB for a 1 GiB root image). The installer makes `root.img.gz` next to `root.img` once and uses it again while the root image stays the same. The files arrive in `tsx-stage.new/` first. The installer renames the folder only after the last check, so the rescue never finds half a stage.

In the rescue, `installer/steps/tsx-rescue-staged` starts once at boot. It runs these steps:

1. It looks for `tsx-stage/STAGE` on card `p5` (stock layout) or `p4` (folded card). With no stage, it does nothing.
2. It checks that the RAM holds the stage plus 64 MiB. If not, it stops, and the installer pushes the images over ssh.
3. It marks the stage as taken, copies it to RAM, checks the sha256 of every file and removes the stage from the card.
4. On a reinstall, it copies the rescue to the golden slot (`p1:boot.img`).
5. It gets the DSP, PSR and LED bar files from the panel. The `.puf` files in the stage are the fallback (see below).
6. It runs `tsx-rescue-install check`, then `run` with the root image through `gunzip`. The readback checks the sha256 of boot and root.
7. It copies its log to `/data/tsx/install-staged.log` on the new `tsxdata` and reboots into the kiosk.

The installer follows the log of the rescue while it can reach the rescue, and it waits for the kiosk. After the boot it reads `/data/tsx/install-staged.log` and compares the sha256 values with the payload. If the staged run fails while the host reaches the rescue, the installer pushes the images over ssh instead.

The `.puf` files: the rescue looks on the panel first, as without a stage. The stage cannot download the `.puf` during the rescue. With `--tfa-source puf` or `--psr-source puf`, the installer downloads the files before the stage. With `auto`, the stage carries the files only if the host has them in its cache already (`rootfs/vendor-local/`). If the panel and the stage have no DSP files, install them later with `installer/steps/tsx-deploy-tfa.sh`.

`--stage auto` pushes over ssh in these cases:

- The rescue image of the payload has no `tsx-rescue-staged` (an older payload).
- The card has not enough room for the stage.
- The copy to the panel fails.

If the installer stops before it arms the rescue boot, it removes the stage again. To remove a stage by hand, delete `tsx-stage/` on card `p5` (stock Android) or `/data/tsx-stage` (mainline).

### Download the release on the panel

A panel that runs mainline can download a release from GitHub itself. The host then needs no payload and sends no images. Use it for a reinstall or an update when the panel has internet access:

```sh
installer/tsx-install-mainline <panel-ip> --fetch v0.4.0 --kernel lts
```

The host copies `installer/steps/tsx-netinstall`, `installer/lib/tsx-verify-sig.py` and the install bundle (the scripts and `panel.conf`, no images) to `/data/tsx-net` of the panel. The panel then runs these steps:

1. It downloads `SHA256SUMS` and `SHA256SUMS.sig` of the release with `curl`.
2. It checks the signature with the public key of the project in `/etc/apk/keys/tsx-mainline-*.rsa.pub`, the key of the package repository. With no good signature it stops before the large downloads.
3. It checks the free space of `/data`, then downloads `tsx-xx60-rescue.img` and `tsx-xx60-<flavor>-manifest`, `-boot.img` and `-root.img.gz`. Each file must have the sha256 of the signed list. A download that stops goes on from the partial file the next time.
4. It makes the stage in `/data/tsx-stage` (see "Stage on the panel first").

Then the host arms the rescue of the release, and the rescue installs the stage with no network. After the boot, the host compares the sha256 values of boot and root with the signed manifest.

The release workflow signs `SHA256SUMS` with the private key of the project (the secret `TSX_APORTS_PRIVKEY`, as PEM text or as the base64 of the PEM text, `tools/release/sign-sums.sh`). If the secret holds another key, the release workflow fails. A release without `SHA256SUMS.sig`, or a release from before the download mode, does not install this way. Stock Android has no HTTPS client, so a first install always uses a payload on the host.

### Root over the Crestron sshd

A first install needs a Crestron admin account and a root shell on the panel over the Crestron SSH daemon.

1. A Crestron admin account must exist. A factory-fresh panel has none. `installer/steps/crestron-admin --admin-user <user> --admin-password-file FILE <panel-ip>` creates it with the call that the first-run form makes. Some panels redirect every web UI page to that form. Others serve the web UI with authentication off. The script handles both. `installer/steps/crestron-admin --status <panel-ip>` shows whether an account exists. The installer runs the script for you.
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
| `installer/lib/tsx-rescue.sh` | Host and panel | `pr_dd` (live MiB, percent and rate for a background `dd`), the verified single-write env helper, the MBR fold, the finder of the old root file system (`tsx_ext4_open`) and the MAC-based rescue discovery that `tsx-restore-factory` also uses. |

### Speaker DSP files (TFA9890)

The TFA9890 tuning files (`.cnt` containers) are Crestron and NXP data. They are never in the rootfs image or in this repository (see [rootfs.md](rootfs.md) "Proprietary blobs: `vendor-fetch.sh`"). Every panel has them in its own firmware. The rescue takes them from the panel, read-only, before it writes anything (`installer/steps/tsx-rescue-install tfa`, `installer/lib/tsx-tfa.sh`). It tries these sources in order. The first source that has all three variants wins:

1. The installed mainline root: `/usr/local/share/tsx/tfa9890/<variant>/stereo.cnt` on eMMC `p8`. This also works with `--wipe-data`.
2. The stock Android boot image in eMMC `p7`. Its ramdisk has the files in `jabil/tfa9890/`. The rescue reads it before it writes the mainline boot image.
3. The `.puf` download (fallback). The host runs `rootfs/vendor-fetch.sh`, which downloads the public Crestron firmware package (357 MB, cached) and extracts the files. The host pushes them to the rescue. This needs `unzip` on the host, or a `busybox` with the `unzip` applet.

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
2. The system partition of stock Android: `bin/PSR-CSR8811.psr` in the same eMMC region (see "The old root file system" below).
3. The `.puf` download (fallback). The host runs `rootfs/vendor-fetch.sh --psr`. It uses the same download and cache as the DSP files, extracts `/bin/PSR-CSR8811.psr` from `system.img` with `debugfs` (no mount, no root) and checks the pinned sha256. The host pushes the file to the rescue. This needs `unzip` (or the `unzip` applet of `busybox`) and `debugfs` on the host and about 1.1 GB of free temporary space for a short time.

With sources 1 and 2 the file never leaves the panel. The installer accepts the pinned sha256, or another sha256 with a warning if the file is sane PSR text. It prints `Bluetooth PSR source used: ...` and writes the file and a `SOURCE` record to `/usr/local/share/tsx/csr8811/` on the new root.

`--psr-source auto|panel|puf|none` works like `--tfa-source`. A missing PSR file never stops the install. Without it, the Bluetooth proxy loads only its address (see [hardware.md](hardware.md) "Bluetooth (CSR8811)"). A reinstall gets the file from the download if the root has none.

A panel with U-Boot `government=1` (the TSW-760-NC) has no Bluetooth module ([hardware.md](hardware.md) "Panel variants"). In modes `auto` and `panel`, the rescue reads the flag first (kernel command line, else U-Boot env). With `government=1` it looks for no file, the host does not download the `.puf`, and the installer prints `Bluetooth PSR source used: not needed: government=1, ...`. The `SOURCE` record then has `source=not-needed`. `--psr-source puf` still downloads the file. The speaker DSP files are not affected.

### Stock LED bar firmware image

The USB LED bar has its own firmware. The stock image (`statussign_*.upg`, for example `statussign_1.3443.00018.upg`) is a Crestron file and is never in this repository, a package or an image. The installer keeps a copy on the panel so that you can load the stock bar firmware back.

The rescue looks for the file in the stock Android system partition, read-only (`installer/steps/tsx-rescue-install ledstock`, `installer/lib/tsx-ledstock.sh`), at `vendor/firmware/` or `system/vendor/firmware/`. It accepts a file made of S-records with the application tag record first. The install copies it to `/data/tsx/vendor/` on tsxdata and checks the copy. A `.source` file next to it records the Android build and the sha256.

- A reinstall that keeps `/data` keeps the copy.
- `--wipe-data` and any other format of `tsxdata` remove the copy. Install from Android again to get it back.
- If the rescue finds no file, the installer prints one line and continues. A panel with no LED bar is not affected.

### The old root file system

The mainline root region `p8` starts at 796 MiB of the eMMC (`blkdevparts=`). The stock Android system partition starts at 804 MiB (the partition table of U-Boot, see [boot.md](boot.md)). So on a panel with stock Android, `p8` starts with 8 MiB of zeros, and the Android file system starts 8 MiB into `p8`. A mainline root starts at the first byte of `p8`. The TSW-1060 and the TSW-760 have the same layout.

Before the `psr` and `ledstock` commands look for their files, the rescue finds the ext4 file system in `p8` (`tsx_ext4_open` in `installer/lib/tsx-rescue.sh`):

- It reads the superblock at 0, 1, 2 ... 32 MiB into `p8`. The first primary ext4 superblock (magic, block group 0, a file system that fits in `p8`) wins.
- At offset 0 it mounts `p8` itself. At another offset it attaches a read-only loop device at that offset and mounts the loop device read-only.
- After the look-up it detaches the loop device.

The installer prints a line such as `ext4: the file system of /dev/mmcblk1p8 starts at 8 MiB: read-only loop device /dev/loop0`. The DSP lookup does not need this: it reads the Android boot image in `p7`.

To load the stock firmware into the bar, see [rootfs.md](rootfs.md) "LED bar".

### Progress output

Every driver script prints progress and does not run silently:

- During large writes it prints per-region lines and a tick with MiB written, percent and ETA about every 15 s.
- It streams the output of remote commands live.
- It prints heartbeat lines in every wait loop (Android settle, kiosk start, reboot).
- While the host pushes files into the rescue, the rescue screen shows the state, for example "receiving the install files from the host: 120 of 642 MiB", and a progress bar. The rescue writes the progress to `/run/tsx-progress`, as for its own writes.
- A copy to a running kiosk (the stage) writes its progress to the system log of the kiosk (`logger -t tsx-install`), because the kiosk shows its dashboard and has no rescue screen.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Your IP address is blocked` from `rootsh` | The Crestron sshd blocked the host after 3 failed logins. | Run `REMBLOCKEDIP <blocked-ip>` on the Crestron console from another machine. |
| The installer cannot get a root shell on stock Android | The admin account gets no root shell over SSH. | Set up the root shell (see "Root over the Crestron sshd"). Then run the installer again. |
| The install stops before it writes anything and asks for a root password or key | `panel.conf` has no `ROOT_PASSWORD_HASH` and no `SSH_AUTHORIZED_KEY`. | Give a password or a key in the prompts or in `--config FILE`. |
| The rescue asks for a password | The rescue cannot read `/data` (first install). | Read the one-time password on the panel screen. Type it when the installer asks, or put it in a file and run the same command again with `--rescue-password-file FILE`. |
| The run stops after the rescue is up | A network or host interruption. | Run the same command again. It resumes in the rescue. |
| `eMMC root readback mismatch` | The root stream stopped early, for example after a lost connection. | Run the same command again. |
| `rootsh --put: the root shell ... did not get ready` | The root shell on stock Android cannot set its tty to raw mode. | Make sure that `busybox stty` works in the root shell. Nothing was written. |
| The root write is slower than 2.5 MiB/s | The round trip to the panel is long, and the 24 KiB ssh window of the rescue sets the speed. | None needed. Run the installer on a host closer to the panel to make it faster. |
| The rescue never answers | The rescue did not boot or is not on the network. | Power cycle once. The panel boots the installed kiosk or stock Android. Run the command again. |
| `WARNING: ... cannot be kept` | `p4` is not a clean `tsxdata` ext4 file system. | None needed. The rescue formatted `p4`. Restore `panel.conf` with `--config FILE` if needed. |
| The panel boots to the setup page | No `KIOSK_URL` in `panel.conf`. | Configure the panel (see "Configure the panel after install"). |
| A boot image does not boot | The image is bad. | See [boot.md](boot.md) "`boot_retry`, the golden slot and why it is destructive" and [recovery.md](recovery.md). |
| Speakers have no EQ or volume presets | The DSP files are missing. | Run `installer/steps/tsx-deploy-tfa.sh <panel-ip>`. |
| The Bluetooth proxy loads only its address | The PSR file is missing. | Reinstall with `--psr-source puf`, or see [hardware.md](hardware.md) "Bluetooth (CSR8811)". |
