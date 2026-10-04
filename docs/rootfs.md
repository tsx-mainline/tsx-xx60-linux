# Rootfs

The panel runs a minimal Alpine Linux root filesystem. This page covers how the build makes the
rootfs, what runs on the panel, and the kiosk browser stack. For the kernel and the board, see
[kernel.md](kernel.md) and [hardware.md](hardware.md). For the install, see
[install.md](install.md). For the Home Assistant side, see [ha.md](ha.md).

## Tasks

### Build a rootfs

1. Build with the wrapper. It runs `rootfs/mkrootfs.sh` in an armv7 Alpine container under
   `qemu-user`. The result is native armv7 code.

   ```sh
   PROFILE=console ./build-rootfs.sh rootfs
   PROFILE=console BUILD_HOST=... BUILD_DIR=... tools/build/remote-build.sh rootfs
   ```

2. Find the outputs: a tarball, an ext4 image, a package manifest (`rootfs.manifest`, the exact
   installed versions), a size report and checksums.

Set `PROFILE` to `console`, `kiosk` or `ha` (default `ha`). See "Profiles".

### Build from packages

1. Set `TSX_FROM_PACKAGES=1` and give `TSX_APK_LOCAL`, a local copy of the published apk tree:

   ```sh
   TSX_FROM_PACKAGES=1 TSX_APK_LOCAL=<published tree> PROFILE=console ./build-rootfs.sh all
   ```

2. To compare with the default build (`TSX_FROM_PACKAGES=0`, which compiles the tools and copies
   the whole overlay), build the same profile both ways and run:

   ```sh
   rootfs/tests/compare-rootfs.py old/rootfs.tar.gz new/rootfs.tar.gz --expect rootfs/tests/compare-rootfs.expect
   ```

   The script compares the type, mode, owner and content hash of each path. It also reads the
   initramfs (`.cpio.gz`). It prints each difference that no rule in `compare-rootfs.expect`
   explains and exits with status 1 if there is one.

### Change the orientation

Run `tsx-config set ORIENTATION portrait` and `tsx-config apply`. You can also use the setup page
or the *Orientation* select of the Home Assistant device. See "Orientation".

### Open the setup page again

Run `tsx-config setup` over ssh, or press *Setup* in the quick-settings overlay. The page opens on
the panel screen and at `http://<panel-ip>:8080/setup` for 15 minutes. See "Setup page".

### Set the root login

1. Give the installer a root password or an SSH public key. It stops without one.
2. To change the password later, run `passwd` on the panel. The change stays across reboots and
   reinstalls that keep `/data`.

See "Root login".

### Update the panel

The panel updates itself (`tsx-autoupdate`). To install at once, run `tsx-autoupdate now`. To read
the state, run `tsx-autoupdate status`. See "Updates".

## Build reference

### Base and packages

| Item | Value |
|---|---|
| Base | Alpine v3.24 (`ALPINE` variable), musl libc, OpenRC, eudev, busybox |
| Packages | `rootfs/packages.txt`. `rootfs/profiles/*.list` say which profile installs which package |
| Project packages | `rootfs/packages-tsx.txt`, from `TSX_APK_LOCAL` |
| Installed size | about 750 MiB with the voice stack. See [install.md](install.md) for the partition sizes |
| Root image | `mke2fs -d` writes the ext4 image straight from the directory tree. The build needs no loop mount and no privileged container |
| Kernel modules | none by default. The kernel has the display, panel, touch, GPU and backlight drivers built in |
| `TSX_SKIP_BOOT_CHECK=1` | skips the check of the kernel packages in `mkrootfs.sh`. Use it for a comparison build only |
| `TSX_DEV_ROOT_HASH` | test builds only. A sha512-crypt hash for root. See "Root login" |

Package groups:

| Group | Packages |
|---|---|
| Kiosk | `chromium`, `sway`, `squeekboard`, `wvkbd-mobintl`, `dbus`, `libinput`, `mesa-dri-gallium`, `mesa-egl`, `mesa-gles`, `mesa-gbm`, `font-dejavu` |
| Network, time, access | `ifupdown-ng`, `chrony`, `openssh-server` |
| Audio | `alsa-lib`, `alsa-utils`, `avahi`, `avahi-compat-libdns_sd` |
| Voice | `python3`, `py3-zeroconf`, `py3-numpy`, `py3-protobuf`, `py3-cryptography`, `py3-tzlocal`, `py3-aiohappyeyeballs`, `py3-mpv`, `mpv-libs` |
| Tools | `curl` (HA REST calls from the button daemon), `libusb` (LED bar), `mosquitto-clients` (MQTT bridge), `i2c-tools`, `htop` |

`chromium` needs `icu-data-full` (about 31 MiB). You cannot replace it with `icu-data-en`.

Without a local apk tree, the build compiles `cage` 0.3.1 from source (see "cage"), builds
`sendspin-cli` and TFLite locally, and patches the Alpine Chromium in place (see "GPU path").
With the tree, these come from the project packages `tsx-xx60-chromium`, both kernel packages,
`sendspin-cli`, `tensorflow-lite-c` and `tsx-keys`.

The build downloads only official Alpine packages and a few pinned, checksummed source tarballs
(cage, the Sendspin build dependencies, the TFLite C library). It fetches nothing from an unpinned
URL.

### Kernel modules

`build-rootfs.sh modules` copies `*.ko` files read-only from a kernel build directory. Use it for
drivers that are modules (USB, sound). It refuses a module whose vermagic does not match the
target kernel release.

### Proprietary blobs: `vendor-fetch.sh`

The TFA9890 speaker DSP tuning files (`.cnt` containers) and the Bluetooth PSR file are Crestron
and NXP blobs. They are never in the repository, in CI output or in a release.

| Command or variable | Effect |
|---|---|
| `rootfs/vendor-fetch.sh` | Downloads the public Crestron firmware package, extracts the ramdisk of the Android boot image, finds the three tuning-variant files and checks each against a pinned sha256. A mismatch stops the build. |
| `vendor-fetch.sh --check` | Checks an already fetched cache without the network. |
| `vendor-fetch.sh --psr` | Takes `PSR-CSR8811.psr` from `system.img` of the same package, checks its sha256 and writes it to `vendor-local/csr8811/`. Only the installer reads that directory. |
| `TFA_VENDOR_FETCH=no` | Stops `mkrootfs.sh` from fetching. CI sets it. |
| `TFA_VENDOR_SRC` | Points the script at your own Crestron firmware package. The sha256 pin still applies. |
| `installer/steps/tsx-deploy-tfa.sh PANEL_IP` | Copies the verified `.cnt` files over ssh onto an installed panel. A missing file is a warning. The panel runs without DSP tuning until the files are there. |
| `ci/check-no-proprietary.sh` | Fails the build (exit 1) if a `.cnt` or `.psr` file is in the output. `remote-build.sh` runs it after a `rootfs` build. |

A local build fetches the files by default into a git-ignored cache. The installer
(`tsx-install-mainline`) first takes the files from the panel (its mainline root or the stock
Android boot image). It runs `vendor-fetch.sh` on the installer machine only if the panel has no
valid set. See [install.md](install.md) "Speaker DSP files (TFA9890)" and "Bluetooth PSR file".

## Profiles

Home Assistant is an optional layer. A profile is a set of files, packages, services and users.
Each profile includes the profile above it in the table. The serial console has a getty in all
three.

| Profile | What it adds | The screen |
|---|---|---|
| `console` | SSH, `tsx-config`, the rescue tools, `tsx-autoupdate`, audio, the front keys, the light sensor, the Bluetooth tools | A text login. A USB keyboard works. |
| `kiosk` | The Chromium kiosk on any URL (`KIOSK_URL`), screen blanking, the on-screen keyboard, the setup page | The browser. No getty on tty1. |
| `ha` (default) | The Home Assistant layer (`tsx-ha`): the ESPHome device, the MQTT bridge, the voice satellite, the Bluetooth proxy, Sendspin, `kiosk-set-token`, the Home Assistant fields of the setup page | The browser |

`rootfs/profiles/console.list`, `kiosk.list` and `ha.list` name what each profile adds.
`rootfs/profile.sh` reads them. One line names one thing:

| Word | Meaning |
|---|---|
| `overlay` | a file of `rootfs/overlay` |
| `built`, `tree` | a file or directory that `mkrootfs.sh` installs |
| `step` | a build step |
| `pkg` | a package of `packages.txt` or `packages-tsx.txt` |
| `svc` | an OpenRC service and its runlevel |
| `user` | a system user |

A profile can have its own files in `rootfs/profiles/NAME/overlay`. The build copies them last.
The console profile has the tty1 login and the banner there. The kiosk profile has
`/etc/tsx/profile`. A missing `/etc/tsx/profile` means `ha`.
`rootfs/tests/test-profiles.sh` checks that each overlay file and package is in exactly one list.

### Package-built images

With `TSX_FROM_PACKAGES=1`, `mkrootfs.sh` does these steps:

1. It installs the meta package of the profile (`tsx-xx60-console`, `tsx-xx60-kiosk` or
   `tsx-xx60-ha`) from `TSX_APK_LOCAL`, with the Alpine packages of `packages.txt`.
2. It compiles nothing. The packages hold the compiled tools (`tsx-idled`, `tsx-buttons`,
   `tsx-splash`, `tsx-overlay`, `tsx-ledbar`, `tsx-peak`, `cage`).
3. It copies only the files of `profiles/image.list` from the overlay: `fstab`, `inittab` and the
   profile marker.
4. It runs `install-lva.sh` from `tsx-ha` (`/usr/share/tsx/install-lva.sh`). The script downloads
   pinned Python wheels, so it stays a build step.
5. It does these steps itself: the TFA9890 containers, the root password, users that need
   no package, and the image trim.

| Package | Files |
|---|---|
| `tsx-base`, `tsx-setup`, `tsx-autoupdate`, `tsx-buttons`, `tsx-ha`, `tsx-rescue-ui`, `tsx-splash` | the common software (tsx-linux-common) |
| `tsx-idled` | `tsx-idled`, its init script, `tsx-blank`, `tsx-display-power`. Every profile runs them. |
| `tsx-kiosk` | the kiosk session, `tsx-overlay`, the blank cursor theme `/usr/share/tsx/cursors` |
| `tsx-xx60-board` | `board.sh`, `panel-board.conf`, `motd.board`, `tsx-hw`, `tsx-als`, `tsx-cpufreqd`, `tsx-audio`, `tsx-ledbar`, `tsx-ledbard`, `tsx-tfa-dsp`, `tsx-peak`, `tsx-boot-ok`, `tsx-emmc-state`, `tsx-update-boot`, `uboot-env.conf`, `asound.conf` |
| `tsx-xx60-board-kiosk` | the patched `cage`, `tsx-chromium-es2` and its patch tool |

`tsx-splash` is at `/usr/local/bin/tsx-splash` in the image and in the initramfs.

The initramfs uses the same packages. `mkinitramfs-switchroot.sh` fetches the versions that
`initramfs/packages.pin` names. It takes `tsx-rescue-ui` and `tsx-splash` whole, `board.sh`,
`tsx-boot-ok` and `uboot-env.conf` from `tsx-xx60-board`, and `tsx-orientation` from `tsx-kiosk`.
The initramfs stamp (`initramfs-stamp.sh`) covers `packages.pin` in this mode. A boot image of one
mode does not match the stamp of the other mode. Build the kernel packages again in the mode that
the image uses.

### The console profile

The panel boots to a text login on the screen.

- `/etc/inittab` has `getty` on tty1 and on the serial port.
- `/etc/tsx/boot-verbose` is in the image. The initramfs gives the screen to the text console and
  loads the Terminus console font that fits the screen (`tsx-confont`, see [boot.md](boot.md)
  "Boot splash"). `tsx-config apply` keeps the flag file.
- `tsx-banner` writes `/etc/issue` (above the login prompt) and `/etc/motd` (after the login).
  Both show the Tux and `TSX - LINUX` art, the model, the IP address, `SSH is on` and the root
  password case. `/etc/local.d/tsx-banner.start` writes them at boot. The hook
  `/etc/udhcpc/post-bound/tsx-banner` writes them again at each DHCP lease.
- There is no `/etc/kiosk.conf`. `tsx-idled` and `tsx-buttons` use built-in defaults: blank after
  300 s, brightness 17 by day and 8 by night, night from 22 to 7. `tsx-idled` logs
  `no /etc/kiosk.conf, using defaults` at start. This is normal. To change the blank time, run
  `tsx-config set BLANK_TIMEOUT`. To change another value, create `/etc/kiosk.conf` with only that
  key.
- The first host name is `tsx-console`. `tsx-hostname` then uses `PANEL_NAME`, the U-Boot env, or
  the model and the MAC.

A console image ignores `KIOSK_URL`, `HA_*`, `MQTT_*` and `VOICE`. `tsx-autoupdate` does not look
for a kiosk service. `tsx-audio enable voice` says that the service is not in the image.

### Calls between the layers

The base system does not need the layers above it. A call to a missing part does nothing.

| From | To | Without the target |
|---|---|---|
| `tsx-config` (base) | `tsx-audio enable voice`, `rc-service tsx-esphome`, `tsx-mqtt`, `tsx-bt`, `kiosk` | Runs only when `rc-service` knows the service |
| `tsx-config apply` | `/var/lib/kiosk/pending-token`, `tsx-orientation` | Writes the token file and calls the tool only when they exist |
| `tsx-audio` | `tsx-sendspin`, `tsx-voice` | `disable` does nothing. `enable` says the service is not in this profile. |
| `tsx-autoupdate` | the `kiosk` service, the `KIOSK_URL` page | The health check looks at them only when `/etc/init.d/kiosk` exists |
| `tsx-buttons` | `curl` to Home Assistant, kiosk DevTools (`navigate`) | The action fails and logs a line |
| `tsx-als`, `tsx-autoupdate`, `tsx-emmc-state` | state files that `tsx-mqtt` and `tsx_panel` read | Nobody reads them |
| `tsx-bt` | `btscan.py`, `btgatt.py` | Both are in the base. The `tsx-bt` service is in `ha`. |
| `tsx-esphome`, `tsx-voice`, `tsx-mqtt` (ha) | the hardware | They call `tsx-panelctl` only |
| `tsx-setupd` (kiosk) | the Home Assistant fields | They come from a plugin of `tsx-ha` |
| `init.d/kiosk` | `kiosk-set-token` | Runs only when `/var/lib/kiosk/pending-token` exists. A missing tool gives a warning. |

### The seam: tsx-panelctl

The Home Assistant layer reaches the buttons, the light sensor, the LED bar, the volume and the
display power only through `tsx-panelctl` (`rootfs/overlay/usr/local/sbin/tsx-panelctl`). The
base system owns it. `tsx_panel` and `tsx-mqtt` never call `tsx-ledbar`, `tsx-keypad`, `tsx-blank`,
`tsx-als`, `amixer` or the backlight device.

| Form | Effect |
|---|---|
| `tsx-panelctl` | The daemon. It reads one whitelisted command per line from the FIFO `/run/tsx/panelctl` (owner root, group `kiosk`) and runs the tool as root. It treats every line as hostile input. |
| `tsx-panelctl send CMD ARG...` | Writes one command to the FIFO. It stops after 3 s when no daemon reads the FIFO. |
| `tsx-panelctl get NAME` | Prints one value: `volume` (percent), `lux`, `als-auto`, `screen`, `ledbar`, `ledbar-fx`, `keypad-led`, `last-key`. |
| `tsx-panelctl has NAME` | Tells whether the panel has the hardware: `ledbar`, `ledbar-fx` (firmware TSX-LEDBAR), `ledbar-leds` (TSX-LEDBAR 0.1.3 or later, 16 LEDs), `keypad`, `als`, `sound`. It needs no root. `ledbar-fx` and `ledbar-leds` read `/run/tsx/ledbar.fw` ("The 16 LEDs"). |
| `tsx-panelctl events` | Prints a line when a value changes: `button NAME short\|long\|hold`, `lux N`, `als-auto on\|off`, `screen ...`, `ledbar R G B`, `keypad-led N`. |

The whitelisted commands are:

| Command | Command |
|---|---|
| `ledbar off\|on\|set R G B` | `ledbar fx NAME N...` |
| `ledbar led LEDS R G B` | `ledbar side R\|L R G B` |
| `ledbar clear` | `keypad led off\|auto\|N` |
| `blank on\|off` | `als auto on\|off` |
| `brightness N` | `backlight N` |
| `brightness-offset N` | `brightness-learn-reset` |
| `blank-timeout S` | `orientation NAME` |
| `volume N` | `config-url URL` |
| `verbose-boot on\|off` | `reload-page` |
| `setup` | `reboot` |
| `update-install` | `keypad led-blank N` |

The state files `/run/tsx/buttons.state`, `als.state`, `ledbar.state` and `/run/tsx-idled.state`
are the event interface. The base daemons write them. `tsx-mqtt` and `tsx_panel` read them.
`rootfs/tests/test-panelctl.sh` checks the whitelisted commands and the rejection of bad lines.

### Setup page fields

`tsx-setupd` is part of the kiosk profile. The base page has:

- the page URL (`KIOSK_URL`)
- Network: the panel name and the time zone
- Display: the screen orientation, the blank timeout and the light sensor settings
- Access: the root password and an SSH public key
- Updates: the kernel flavor

A package adds fields with a plugin file in `/usr/local/share/tsx/setup.d` (`TSX_SETUP_PLUGIN_DIR`
in tests). The plugin `setup.d/ha.py` of `tsx-ha` adds the Home Assistant URL with the discovery
and check buttons, the login method and token, the voice assistant and wake word, and MQTT. It also
reports the settings that a panel cannot use (no microphone, no Bluetooth module). `tsx-setupd`
loads the plugins once at start and skips a plugin that fails to load. A submit ignores the keys of
a missing plugin. A plugin sets each of its fields at load time, also to empty or unchecked. The
page sends a plugin field only when the user changed it (see "Save").

### Root login

A public image has no fixed root password. The root field of `/etc/shadow` is locked (`*`). A test
build can set one:

```sh
TSX_DEV_ROOT_HASH=$(openssl passwd -6 mypassword) ./build-rootfs.sh rootfs
```

`remote-build.sh` passes the variable on. The build log and `rootfs.sizes` say `root password:
none` or `root password: TSX_DEV_ROOT_HASH (test build)`.

The installer stops unless it gets a root password or an SSH public key (prompts, `--config FILE`
and `--yes`). See [install.md](install.md) "Panel configuration". It stores only the hash
(`ROOT_PASSWORD_HASH`) and the key (`SSH_AUTHORIZED_KEY`) in `panel.conf` on `/data`. The first
boot applies them with `tsx-config apply`.

| Case | Console login | SSH |
|---|---|---|
| Password set | The password | The password, or a key if the install gave one |
| Key only | Off (the field is locked) | The key. Log in and run `passwd` to enable the console login. |
| Password and key | The password | The password or the key |

- `tsx-config apply` writes the hash only when `panel.conf` has a new hash, or when root has no
  usable password. A password that you set later with `passwd` stays.
- A reinstall that keeps `/data` keeps the root password. `tsx-config sync-root` copies the
  `/etc/shadow` hash into `ROOT_PASSWORD_HASH` when root has a usable password that `panel.conf`
  lacks. It runs at each `apply`, when the tsx-config service stops, and at the start of an
  installer reinstall over ssh. The first `apply` after the reinstall applies the hash again.
- An installer `--config` file with no password takes the hash from the panel.
- A locked root (key only) never overwrites a saved hash. A new hash in a config file or in the
  prompts replaces it.
- Nothing prints or logs the hash. `panel.conf` has mode 600. `/root/.ssh` is on `/data`.
- The banner (`tsx-rootpw note`) shows the case. In the console profile, `tsx-banner watch` checks
  `/etc/shadow` and `authorized_keys` every 3 s and rewrites the banner after a change.
- If `tsx-rootpw note` finds a locked field and no key, it says that nobody can log in. Install
  again.

The rescue image has no fixed password. It uses the same two values from `/data`, or a one-time
password that only the panel screen shows. See [recovery.md](recovery.md) "Rescue login".

## Boot flow on the panel

The kernel boots an initramfs. Its `/init` does these steps:

1. It mounts `proc`, `sys` and `dev`.
2. It finds the root filesystem by label (see [install.md](install.md)). It waits a few seconds
   for the block device.
3. It runs `e2fsck -p` on the root. A repair triggers a reboot. A failed repair drops to the rescue
   system.
4. It mounts the root read-write and runs `switch_root` to `/sbin/init` (OpenRC).

From step 1, `/init` shows the boot splash (`tsx-splash`). The kernel keeps its text off the
screen. `/init` gives the screen back to the text console for the rescue system, a running install
and `BOOT_VERBOSE`. See "Boot splash" in [boot.md](boot.md).

`/init` drops into the rescue system (DHCP, SSH, basic disk tools) when:

- the rootfs is missing or broken
- `tsx.rescue` is on the kernel command line
- a flag file exists on the rootfs (it drops in once, to force a reinstall or uninstall)

See [recovery.md](recovery.md).

### OpenRC services (default runlevel)

| Service | Role |
|---|---|
| `tsx-data` | Moves persistent state onto the data partition on first boot, then bind-mounts it at every boot. Runs before most services. |
| `tsx-config` | Runs `tsx-hw detect` and `tsx-config apply`. It runs after `tsx-data` and before `tsx-setup`, `tsx-hostname`, `networking`, the kiosk, `tsx-sendspin`, `tsx-mqtt`, `tsx-panelctl`, `tsx-esphome` and `tsx-voice`. |
| `kiosk` | Runs the compositor and browser session (`kiosk-session`) under `supervise-daemon`. It respawns without limit. |
| `tsx-idled` | Screen blanking, wake-on-touch, backlight schedule, multi-finger gestures. |
| `tsx-buttons` | Front capacitive key daemon and key LEDs. |
| `tsx-ledbar`, `tsx-mqtt` | USB RGB LED bar control and the Home Assistant MQTT discovery bridge. |
| `tsx-als` | Ambient light auto-brightness. |
| `tsx-cpufreq` | CPU governor follower (see "Other kiosk defaults"). |
| `tsx-audio` | ALSA volume and mute state, amplifier input routing. |
| `tsx-tfa-dsp` | One-shot service. Loads the amplifier DSP firmware at boot. |
| `tsx-sendspin` | Sendspin network-audio player. Off by default. |
| `tsx-voice` | Voice assistant satellite. Off by default. It does not start on a panel without a microphone ([hardware.md](hardware.md) "Panel variants"). |
| `tsx-bt` | Bluetooth controller bring-up and `tsx-btscan` (BLE scanner and BLE links of the Bluetooth proxy), under `supervise-daemon` with a 2 s restart. It does nothing while `BT_PROXY` is off. On a panel without a Bluetooth module it records `state=absent`. Chip steps: `/usr/local/lib/tsx/bt-chip-csr8811.sh`. See [ha.md](ha.md) "Bluetooth proxy". |
| `tsx-boot-ok` | Resets the U-Boot boot-retry counter after a good boot ([boot.md](boot.md)). |
| `tsx-setup` | Time zone, swap, stable MAC address, other one-time setup. |
| `tsx-setupd` | The setup page server (see "Setup page"). |
| `sshd`, `chronyd`, `crond`, `seatd`, `watchdog` | Standard services. |

`tsx-update-boot` (`/usr/local/sbin`) replaces the boot image of an installed panel for a kernel
update or a flavor switch. See [install.md](install.md) "Change the kernel flavor or the boot image".

### Clock (network time)

The panel has no RTC.

- At boot, OpenRC `swclock` sets the clock from the mtime of `/var/lib/misc/openrc-shutdowntime`.
  The image ships that file with its build time. `/etc/periodic/15min/tsx-savetime` touches it while
  NTP has the time. The boot clock is the last known time and never earlier than the image.
- chrony (`/etc/chrony/chrony.conf`) steps the clock at any offset (`makestep 1 -1`) as soon as it
  has a server. The NTP servers of the DHCP lease come first. `udhcpc` asks for option 42 and the
  hook `tsx-dhcp-ntp` writes them to `/run/chrony-dhcp/eth0.sources` as preferred sources. Then
  chrony uses `pool.ntp.org`.
- The panel does not use `initstepslew`. It gives up after about 10 s when the link and DNS are not
  up at boot.
- Nothing in the boot waits for the clock. The browser starts at once. After chrony syncs, the kiosk
  reloads a page that failed on the clock (TLS). See `KIOSK_TIME_WAIT`.
- `tsx-config show` prints "NTP synced (server)" or "NOT synced yet" on stderr. `chronyc tracking`
  has the details.

### Periodic jobs

`crond` runs the default Alpine root crontab. It calls `run-parts` on the folders of
`/etc/periodic`. `run-parts` skips a file that is not executable.

| Folder | Job | Effect |
|---|---|---|
| `15min` | `tsx-savetime` | Touches the clock file while NTP has the time. |
| `hourly` | `tsx-emmc-state` | Writes the eMMC wear values to `/run/tsx/emmc.state` ([ha.md](ha.md) "Entities"). |
| `weekly` | `tsx-fstrim` | Runs `fstrim -v` on `/` and `/data` on Saturday at 03:00. It skips a file system that is not mounted, logs each result and never fails. |

`tsx-emmc-state` reads `life_time` and `pre_eol_info` of the eMMC (`mmcblk1`) and writes the lines
`life_a`, `life_b` and `eol`. The `tsx-config` service also runs it at boot. A chip that reports
`0x00` in every field gives no file and no entity. `tsx-mqtt` and the ESPHome device read the file.

| Field | Values |
|---|---|
| `life_a`, `life_b` | `0x01` = 0 to 10 percent of the life used, up to `0x0a` = 90 to 100 percent. `0x0b` = the estimate is exceeded. |
| `eol` (`pre_eol_info`) | `0x01` normal, `0x02` warning (80 percent of the spare blocks used), `0x03` urgent |

The script logs a value other than normal.

`rootfs/tests/test-initscripts.sh` sources the init scripts under `busybox sh` with stand-ins for
the OpenRC functions. It checks that a script starts and fails nothing on a panel that lacks its
part. It also checks `tsx-emmc-state` (fake sysfs, `TSX_EMMC_DIR`) and `tsx-fstrim`.

## The kiosk

`/usr/local/bin/kiosk-session` picks the compositor, the GPU path and the browser flags.
`/etc/kiosk.conf` controls it.

### Kiosk keys (`/etc/kiosk.conf`)

| Key | Default | Meaning |
|---|---|---|
| `KIOSK_URL` | empty | The page. Empty shows the setup page. |
| `KIOSK_OSK` | `squeekboard` | On-screen keyboard and compositor. See below. |
| `KIOSK_OSK_HEIGHT` | 300 | Keyboard height for `wvkbd` |
| `OSK_GESTURE` | `threefinger` | The gesture that toggles the keyboard |
| `KIOSK_OVERLAY` | `on` | The quick-settings overlay |
| `KIOSK_GPU` | `browser` | GPU path. See "GPU path". |
| `KIOSK_REDUCED_MOTION` | 1 | Tells pages `prefers-reduced-motion` |
| `KIOSK_DEVTOOLS` | 1 | Chromium DevTools on the loopback of the panel |
| `KIOSK_PROFILE` | `/var/lib/kiosk/chromium` | The persistent browser profile |
| `KIOSK_CACHE_DIR` | `/var/cache/kiosk` | HTTP and script cache, on the root filesystem |
| `KIOSK_TIME_WAIT` | empty | Wait for NTP before the browser starts. See below. |
| `KIOSK_SPLASH` | `on` | Boot splash hand-off |
| `KIOSK_REVEAL_TIMEOUT` | 60 | Seconds before the transparent browser window shows |
| `KIOSK_RESTART_AT` | `04:00` | Nightly kiosk restart |
| `BLANK_TIMEOUT` | 300 | Seconds without input before the screen blanks |
| `DISPLAY_POWER_CMD` | `/usr/local/bin/tsx-display-power` | Display on and off command |
| `CPUFREQ_AWAKE`, `CPUFREQ_BLANK` | `performance`, `schedutil` | CPU governors |
| `BACKLIGHT_MAX` | 23 | Highest backlight step |
| `RAMP_SLIDER_MS`, `RAMP_AUTO_MS` | 400, 1000 | Backlight ramp times |

### Compositor and on-screen keyboard

| `KIOSK_OSK` | Compositor | Behavior |
|---|---|---|
| `squeekboard` (default) | sway | The keyboard shows when a text field gets focus and hides when it loses focus. The page shrinks above the keyboard (1280x534 of 1280x800 on the 10-inch panel). |
| `wvkbd` | sway | No automatic show or hide. Only the gesture or a command toggles it. |
| `off` | cage | No on-screen keyboard. See "cage". |

A quick three-finger tap anywhere on the screen toggles the keyboard (`OSK_GESTURE=threefinger`).
`tsx-idled` detects it. It ignores the gesture and the wake-up touch while the screen is blank.

### cage

With `KIOSK_OSK=off`, the kiosk runs on cage, a single-window Wayland compositor. The build compiles
cage 0.3.1 from source with one patch. It does not use the Alpine package (0.3.0).

- cage 0.3.0 ignores a fullscreen request that comes before the window is mapped. The `--kiosk`
  flag of Chromium makes this request. cage 0.3.1 honors it.
- wlroots renders `XRGB8888` by default. The OSD plane of the panel has only `ARGB8888`. The patch
  `rootfs/src/cage-0.3.1-argb8888-fallback.patch` makes cage pick `ARGB8888` when the primary plane
  has no `XRGB8888`. Without the patch, cage fails with "Failed to pick primary buffer format" and
  shows a black screen.

Limits of the cage session: no overlay, no orientation (it stays landscape), and screen blanking
uses the backlight only.

### Quick settings and the front-key strip

These controls work on the panel. They need no Home Assistant.

| Action | Effect |
|---|---|
| Slide a finger along the five front keys | Up (or right on a portrait panel) makes the screen brighter. Each key changes the backlight by `SLIDE_STEP` (2) steps. A brightness bar shows at the screen edge and goes away 1.5 s after the last step. |
| Hold the top key (0.7 s) | Opens the overlay: a brightness slider and the buttons *Auto brightness*, *Screen off*, *Reload page*, *Setup* and *Close*. It closes 8 s after the last touch. |

The overlay has no orientation button.

The ambient light sensor stays in charge. The manual setting is an offset on top of the sensor
level (or on top of the day and night schedule when auto brightness is off). The offset lasts until
you turn *Auto brightness* on (overlay button, Home Assistant or `tsx-als auto on`), until
`brightness auto` runs (a key action), or until a reboot. When you turn auto brightness off, the
current level stays as a fixed level. A fixed level that you set with the Home Assistant
*Backlight* number wins until the next day and night change. Touching the local slider turns it
back into an offset.

| Item | Detail |
|---|---|
| Keys | The five keys are touch zones outside the LCD (board DT `touch-overlay`). The kernel reports `KEY_F13` to `KEY_F17` press and release events, not coordinates. A slide releases one key and presses the next within `SLIDE_GAP_MS` (250 ms). A short press of a strip key fires `SLIDE_GAP_MS` after its release. A slide runs no action and sends no Home Assistant event. `SLIDE_STEP=0` turns the slide off. |
| Level | `tsx-idled` computes `base` (the `tsx-als` level, else the schedule) plus `/run/tsx/brightness-offset`, limited to 1..`BACKLIGHT_MAX`. `/run/tsx/brightness` (absolute level) wins. It watches `/run/tsx` with inotify. `/run/tsx/brightness.state` has `level`, `base`, `offset`, `override`, `max`, `blank_timeout`, `min`. |
| Floor | `BACKLIGHT_MIN` is 1. Blanking still sets the backlight to 0. The slider has 24 linear steps. |
| Ramp | `RAMP_SLIDER_MS` for the slider, `RAMP_AUTO_MS` for light, schedule and reload. 0 is a jump. |
| Learning | `tsx-als` runs `tsx_brightness.py als-daemon`. An offset that stays the same for 8 s becomes a point of the curve. The curve goes to `/run/tsx/als-curve` and replaces `ALS_CURVE`. The offset returns to 0. Up to 12 points stay in `/data/tsx/brightness-learn.json`. Remove them with `tsx-panelctl send brightness-learn-reset` or the setup page button. `BRIGHTNESS_LEARN=off` turns learning off. |
| Overlay | `tsx-overlay` (`rootfs/src/tsx-overlay.c`) is a `wlr-layer-shell` client that sway starts with the kiosk. It draws with cairo, stays resident (a few MB) and has no wakeups while hidden. It takes no keyboard focus, so the on-screen keyboard keeps working. Touches outside it reach the page. `tsx-buttons` shows it through the FIFO `/run/tsx/overlay.ctl` (group `kiosk`). From a shell: `tsx-keypad overlay full\|slider\|hide\|toggle`. It runs as `kiosk` and acts only through `tsx-panelctl`. |
| cage | The slide sets the brightness. A long press of the top key runs `OVERLAY_FALLBACK` from `buttons.conf` (`blank toggle`). |

### Screen blanking

`tsx-idled` blanks the screen after `BLANK_TIMEOUT` seconds without input, on the power key and on
`tsx-blank on` (overlay *Screen off*, front keys, Home Assistant). A dark backlight is not enough,
because the LCD keeps the last frame (see [hardware.md](hardware.md#backlight)). The daemon also
turns the display output off.

1. Blank: it grabs the input devices, sets the backlight to 0 and runs `DISPLAY_POWER_CMD off`.
2. Wake: it runs `DISPLAY_POWER_CMD on`, waits for it, then sets the backlight level. The touch
   that wakes the screen does not reach the page.

- `tsx-display-power` sends `output * power off|on` to every sway of the kiosk user. Without sway,
  it writes `/sys/class/graphics/fb*/blank`. The kernel ignores that write while cage owns the
  display. An empty `DISPLAY_POWER_CMD` gives backlight-only blanking.
- The Alpine wlroots 0.20 fails the first `power on` after a `power off` on the Meson display
  ("Backend commit failed" in the kiosk log), because the Meson CRTC has no gamma LUT. The rootfs
  installs `tsx-xx60-wlroots0.20` from the project apk repository. This package replaces
  `wlroots0.20`. Its patch makes the first `power on` after a `power off` work. `tsx-display-power` also reads the power state back and
  repeats the request at most 3 times, so a panel with the Alpine package also wakes. The README of
  tsx-aports describes how to go back to the Alpine package.
- A wake takes 280 to 400 ms from the signal to the lit picture. The panel power-on sequence is
  about 225 ms of it.
- While the screen is blank, `tsx-idled` runs `off` again every 30 s. A kiosk that starts during
  the blank (the nightly restart) turns its output on, and the next `off` turns it off again.
- A blank does not change the orientation, the overlay or the on-screen keyboard.

### GPU path

The Mali-450 GPU supports only OpenGL ES 2.0. The Alpine Chromium package asks for an ES 3.0
context in its GPU process and, on Linux, cannot fall back to ES 2.0. An unpatched Chromium
crash-loops its GPU process and composites in software. No command-line flag changes this.

The ES2 patch (`rootfs/src/chromium-es2/`) is a 2-byte binary patch. It replaces one conditional
branch (`beq`) with two NOP bytes, so the fallback from ES 3.0 to ES 2.0 always runs.

- The patch tool (`patch-chromium.py` and `sigs.json`) patches only a binary whose whole-file
  sha256 is a pinned value. It re-checks the bytes around the site before it writes and the sha256
  of the patched file after. It leaves an unknown Chromium build untouched and says so in the build
  log.
- With the project apk repository, the rootfs installs `tsx-xx60-chromium`, which is patched when
  the package is built. The panel needs no pin and no in-place patch.
- Without the repository, `rootfs/packages.txt` pins the exact Alpine build (`chromium=<ver>`) in
  `/etc/apk/world`. `apk upgrade chromium` on the panel then refuses to replace the patched binary.
  To move to a newer Chromium, derive a new `sigs.json` entry, change the pin and rebuild (see
  `rootfs/src/chromium-es2/README.md`).
- `tsx-chromium-es2` on the panel checks, applies or reverts the patch without Python.

With `KIOSK_GPU=browser`, the session adds `--disable-features=AllowANGLEPassthroughShaders`
automatically. Without it the screen is black except for the scrollbar. The Mali-450 reports zero
vertex texture image units, and the ANGLE shader-link check counts the fragment texture samplers
against the vertex stage.

| `KIOSK_GPU` | Compositor | Browser |
|---|---|---|
| `auto` | GLES (Lima) if available, else pixman | Software (stock Chromium needs ES 3.0) |
| `on` | GLES | Tries the GPU, falls back |
| `compositor` | GLES | Software |
| `browser` (default) | GLES | GPU compositing through ANGLE ES2. Needs the patched Chromium. |
| `off` | pixman | Software |

If the picture is black or garbled, set `KIOSK_GPU=auto` in
`/etc/kiosk.conf` and restart the `kiosk` service.

### Other kiosk defaults

- **CPU governor.** `tsx-cpufreq` follows the state file of `tsx-idled`. It uses
  `CPUFREQ_AWAKE=performance` while the screen is awake and `CPUFREQ_BLANK=schedutil` while it is
  blank. The CPU runs at most at 1608 MHz. 1800 MHz is not stable (see "SoC and CPU" in
  [hardware.md](hardware.md)).
- **Reduced motion.** `KIOSK_REDUCED_MOTION=1` cuts the CPU use of an animated Home Assistant login
  page from about 47% to about 3% of all cores under software rendering.
- **Boot splash hand-off** (sway session). The compositor background is the boot splash, and the
  browser window stays transparent until the page has painted (`tsx-kiosk-reveal`, at most
  `KIOSK_REVEAL_TIMEOUT` s). `KIOSK_SPLASH=off` turns it off. See [boot.md](boot.md).
- **`KIOSK_TIME_WAIT`.** Empty: the browser starts without a wait for NTP, and a page that failed
  on the clock loads again after chrony syncs. A number sets a fixed wait in seconds. When nothing
  watches the page (cage, `KIOSK_DEVTOOLS=0` or `KIOSK_SPLASH=off`), the default is 20.
- **Policy.** A managed Chromium policy disables the password manager, translate, sign-in, sync,
  autofill, notifications, downloads and the "unsupported flag" bar. Extra flags
  (`KIOSK_EXTRA_FLAGS`, `KIOSK_DISABLE_FEATURES`) cut memory and CPU use.
- **Profile.** The browser profile is persistent, so a login survives reboots. The cache is on the
  root filesystem.

### Slow Home Assistant pages

The page runs on one Cortex-A9 core. The main thread of the Home Assistant frontend is the limit.

| Cause | Fix |
|---|---|
| Entity update rate. The frontend receives every state change of every entity. About 28 changes per second from 190 sensors keeps the page busy about a third of the time. | Throttle fast sensors at the source. For ESPHome, use `throttle_average` or `delta` filters or a longer `update_interval`. |
| Dashboard resources. Every Lovelace resource (custom cards, card-mod, browser_mod) loads and parses at every page load. 8 to 10 MB of JavaScript is common. | Remove the resources that you do not use. |

To measure, run `ssh -L 9222:127.0.0.1:9222 root@<panel-ip>` and open `chrome://inspect` in a
desktop Chrome (`KIOSK_DEVTOOLS=1`). Do not use the Performance and Profiler recorders. A V8 CPU
profile crashes the page renderer on armv7. The Network tab and `performance.getEntries()` are
safe.

## Orientation

`ORIENTATION` in `panel.conf` says how the panel hangs. The names describe the panel as you see it
from the front.

| `ORIENTATION` | The panel | Front keys | Picture on the LCD | sway `transform` | fbcon `rotate` |
|---|---|---|---|---|---|
| `landscape` (default) | as mounted by Crestron | right of the screen | as it is | `normal` | 0 |
| `portrait` | turned 90° clockwise | below the screen | turned 90° counter-clockwise | `270` | 3 |
| `landscape-flipped` | turned 180° | left of the screen | turned 180° | `180` | 2 |
| `portrait-flipped` | turned 90° counter-clockwise | above the screen | turned 90° clockwise | `90` | 1 |

Set it with `tsx-config set ORIENTATION NAME` and `tsx-config apply`, with the setup page, or with
the Home Assistant *Orientation* select. `tsx-config apply` keeps `/etc/tsx/orientation`
(world-readable, absent for `landscape`) and turns the running kiosk when the value changes.

`tsx-orientation` (`rootfs/overlay/usr/local/bin/tsx-orientation`) holds the table. All numbers
come from one value per name: the quarter turns clockwise at which the picture is drawn on the
native landscape LCD. `tsx-orientation info NAME` prints them. `tsx-splash` has the same table in
C.

| Part | Behavior |
|---|---|
| Kiosk (sway) | `kiosk-session` writes `output * transform N` and `input type:touch calibration_matrix ...` into the sway config. On a change, `tsx-orientation apply` sends both commands over the sway IPC socket. There is no restart and no page reload. The touch matrix is the identity in every orientation, because sway maps the touchscreen to the output and wlroots turns the touches. Chromium, the keyboard and the overlay get the new output size. squeekboard picks its portrait layout. wvkbd keeps `KIOSK_OSK_HEIGHT`. |
| cage (`KIOSK_OSK=off`) | Stays landscape. `kiosk-session` logs this. |
| Overlay | Stays at the right edge, centered, no higher than on the 10-inch landscape panel (720 px full, 600 px slider). Layout: `rootfs/src/tsx-overlay-layout.h`. |
| Front keys | They are keys, not coordinates, so they work in every orientation. The names and actions in `buttons.conf` belong to the physical key. Only the slide changes. `tsx-buttons` reads `/etc/tsx/orientation` at each slide step and turns the direction, so a slide up (landscape) or to the right (portrait) always makes the screen brighter. |
| Boot splash, text console | They turn from the root mount on (about 1 s after the splash first shows). See [boot.md](boot.md). |
| Always landscape | The vendor U-Boot logo, the first second of the splash, the cage session and the rescue system (it never depends on the setting). |

In `portrait`, the top of the picture is at the left edge of the native LCD.

## Front keys, key LEDs and the LED bar

`tsx-buttons` is a small C daemon for the five capacitive front keys and their LEDs. A press can
run a local action, call a Home Assistant service, navigate the kiosk, or only fire an HA event.
`tsx-keypad` controls the keys and LEDs from a shell. `tsx-ledbar` and `tsx-ledbard` control the
optional USB RGB LED bar. `tsx-mqtt` bridges it to MQTT ([ha.md](ha.md)). For the config syntax and
the action list, read `/etc/tsx/buttons.conf` and `tsx-keypad --help` on the panel.

| Item | Detail |
|---|---|
| Start check | At power-up the STM32 of the bar can fail to start its three LED driver chips, and no color lights. When the bar appears, `tsx-ledbard` asks the STM32 console (USB interface 0) for the state of each chip (`tsx-ledbar console 'tlcoutmode red 0'`). If a chip failed, it restarts the STM32 (`tsx-ledbar console reboot`) and checks again, at most 3 times. Then it sets the color. Log: `/var/log/tsx-ledbar.log`. For a manual check, stop the service and run `tsx-ledbard check`. |
| Screen state | A blank or wake of the screen never changes the bar. |
| LED map | With TSX-LEDBAR 0.1.5 or later, `tsx-ledbard` sends the LED map to the bar after each plug-in and each start of the bar, before the first color. See [LED map](#led-map). |
| Stock firmware | The installer from Android copies the stock image (`statussign_*.upg`, a Crestron file) to `/data/tsx/vendor/` ([install.md](install.md) "Stock LED bar firmware image"). It is never in a package or image. To load it back: `tsx-ledbar-flash flash /data/tsx/vendor/statussign_*.upg`. The tool comes with the package `tsx-ledbar-fw`. It checks the image, stops and starts the `tsx-ledbar` service and confirms the firmware name. |

### Key LED levels

The key LEDs share one level from 0 to 255. `tsx-buttons` sets it from the screen state and the time of day. `/etc/tsx/buttons.conf` holds the levels.

| Setting | When | Default |
|---|---|---|
| `LED_DAY` | The screen is awake, by day. | 128 |
| `LED_NIGHT` | The screen is awake, at night (`LED_NIGHT_START` to `LED_NIGHT_END`, else `NIGHT_START` to `NIGHT_END` of `kiosk.conf`). | 24 |
| `LED_BLANK` | The screen is blank (the screen-off level). `0` makes the keys dark. `KEY_LED_BLANK` in `panel.conf` replaces it. | 24 |

An override replaces the day and night levels. The `led` action of a key, `tsx-keypad led` and the Home Assistant *Key LEDs* light set it. It applies at once, also while the screen is blank. It holds across blank, wake and the day and night change. `tsx-keypad led auto` removes it.

| Override | Screen awake | Screen blank |
|---|---|---|
| None (`led auto`) | `LED_DAY` or `LED_NIGHT` | `LED_BLANK` |
| `led off` | Dark | Dark |
| `led N` (1 to 255) | `N` | `LED_BLANK` |

`KEY_LED_BLANK` in `panel.conf` sets the screen-off level. The Home Assistant number *Key LEDs screen-off level* writes it. `tsx-config apply` writes it as `LED_BLANK` to `/run/tsx/buttons.conf` and reloads `tsx-buttons`. `tsx-buttons` reads that file after `/etc/tsx/buttons.conf`. The file can change settings, but it cannot add keys or actions.

`/run/tsx/buttons.state` shows the levels:

| Line | Meaning |
|---|---|
| `led N SOURCE` | The present level of the LEDs. `SOURCE` is `day`, `night`, `blank` or `override`. |
| `led_awake N SOURCE` | The level while the screen is awake. `SOURCE` is `day`, `night` or `override`. The Home Assistant light shows this level. |
| `led_blank N` | The screen-off level. |

### LED bar in bootloader mode

The bar controller can stop in its stock bootloader (USB `14be:001a`). It then runs no application, and the LEDs stay dark. An interrupted load can cause this. The start guard of TSX-LEDBAR can also cause it: after three failed starts in a row, the guard hands the bar to the bootloader.

`tsx-ledbard` looks for this state when the service starts and when the bar appears later. It loads an image with `tsx-ledbar-fw-install --recover`. The tool comes with the package `tsx-ledbar-fw`, together with the TSX-LEDBAR image and the flasher.

| Case | What the daemon does |
|---|---|
| The package is installed and `/data/tsx/ledbar-fw.installed` exists | Loads the TSX-LEDBAR image |
| The package is installed, the file does not exist, and `/data/tsx/vendor/` has a stock image | Loads the newest stock image (`statussign_*.upg`) |
| The package is installed, the file does not exist, and there is no stock image | Loads the TSX-LEDBAR image |
| The package is not installed | Logs one line. It tells you to run `apk add tsx-ledbar-fw` and to restart the service |
| The package is installed, but its `tsx-ledbar-fw-install` has no `--recover-image` | Logs one line. It tells you to run `apk upgrade tsx-ledbar-fw` and to restart the service |

- The marker file `/data/tsx/ledbar-fw.installed` shows that the panel is set up for TSX-LEDBAR. `tsx-ledbar-fw-install` writes it and `tsx-ledbar-fw-uninstall` removes it. A recovery does not change it.
- If no image exists (the packaged image is missing and there is no stock image), the daemon logs one line and does nothing else.
- The daemon tries once for each start of the service. It does not try again after a failed load. It also does not try again when the bar returns to the bootloader later. To try again, run `rc-service tsx-ledbar restart`. You can also load an image by hand with `tsx-ledbar-fw-install` or `tsx-ledbar-fw-uninstall`.
- The load does not stop the `tsx-ledbar` service. It restarts `tsx-esphome` and `tsx-voice` when they run, because these services read the firmware name of the bar only at start.
- The daemon never sends `TLCRESET` and never cuts the power of the bar.
- `/var/log/tsx-ledbar.log` shows a start line, the progress lines of the flasher and a result line.
- `tsx-ledbard check` does not load an image. It reports the bootloader mode and exits with 1.

### LED bar effects

The open bar firmware TSX-LEDBAR (repository `tsx-ledbar-fw`) runs effects on the bar.
`tsx-ledbar fw` prints the firmware name and `effects yes` or `effects no`. With the stock firmware
`tsx-ledbar fx` refuses, and everything else works.

| Command | Effect |
|---|---|
| `tsx-ledbar fx fade R G B MS` | Fade to the color in MS ms (0 to 600000) |
| `tsx-ledbar fx blink R G B ON OFF` | Blink: ON ms on, OFF ms off |
| `tsx-ledbar fx breathe R G B MS` | Breathe, one breath in MS ms (100 to 600000) |
| `tsx-ledbar fx rainbow MS [LEVEL]` | Cycle the hue in MS ms at LEVEL (0 to 100, default 100) |
| `tsx-ledbar fx smooth MS` | Ramp each new color over MS ms (0 to 60000) |
| `tsx-ledbar fx cap PERCENT` | Power cap of the three colors (10 to 150, default 110) |
| `tsx-ledbar fx off` | End the effect and show the wanted color |
| `tsx-ledbar fx` | Print the running effect |

- The tool sends effects as lines on the bar console (USB interface 0). The kernel driver keeps
  interface 1.
- An effect does not change the wanted color. `fx off` shows the wanted color again, also after
  `fade`. For a smooth change that stays, run `tsx-ledbar fx smooth MS` once and then
  `tsx-ledbar set R G B`.
- `tsx-ledbar get` shows the wanted color, the running effect and the LED pattern.
  `/run/tsx/ledbar.state` records the effect (`fx ...`).
- A new color (`set`, `on`, `off`, `boot`, a front key, Home Assistant) ends the effect.
- `tsx-ledbar apply` sends the recorded color, pattern and effect again, so they come back after a
  restart of the bar.
- `FX_SMOOTH` and `FX_CAP` in `ledbar.conf` set the ramp and the cap. `tsx-ledbard` sends them each
  time the bar appears.
- Home Assistant shows `Breathe`, `Blink` and `Rainbow` as light effects ([ha.md](ha.md)).

### The 16 LEDs

TSX-LEDBAR 0.1.3 or later sets each of the 16 LEDs and has zone effects. `tsx-ledbar fw` prints
`leds yes` when the answer to `CAPS` has the word `leds16`. Without `leds yes` (for example with the
stock firmware), these commands refuse and change nothing.

The `CAPS` query needs root, because only root can open the USB device of the bar. So `tsx-ledbard`
writes the answer to `/run/tsx/ledbar.fw` (mode 644) after each plug-in and each start of the bar.
The file has the lines of `tsx-ledbar fw` and the line `caps` with the words of the answer to `CAPS`
(`caps none` when the bar has no `CAPS`). `tsx-panelctl has ledbar-fx` and `has ledbar-leds` read
this file. So the voice satellite (user `kiosk`) gets the same answer as root. The daemon removes
the file when the bar goes away, when the bar is in bootloader mode and when the service stops.
Then `tsx-panelctl` runs `tsx-ledbar fw`, which gives the full answer only to root.

A LED is `R1` to `R8` (right side) or `L1` to `L8` (left side), from top to bottom. The index `0`
to `15` is `R1` to `R8`, then `L1` to `L8`. `LEDS` is one LED, a range (`R1-R4`, `8-11`), a side
(`R` or `L`) or `ALL`.

| Command | Effect |
|---|---|
| `tsx-ledbar led LEDS R G B` | Set LEDs of the pattern (levels 0 to 100) |
| `tsx-ledbar side R\|L R G B` | Set one side of the pattern |
| `tsx-ledbar clear` | Drop the pattern and show the wanted color |
| `tsx-ledbar fx chase R G B MS` | A dot runs down both sides, one run in MS ms (100 to 600000) |
| `tsx-ledbar fx fill R G B PERCENT` | A level bar from the bottom up, PERCENT of the height |
| `tsx-ledbar fx spectrum MS [LEVEL] [ring\|rows]` | The hue circle, one cycle in MS ms. `ring` (firmware default) runs around the bar, `rows` along each side. |
| `tsx-ledbar fx split R G B R G B` | The first color on the right side, the second on the left |

- The first `led` or `side` copies the wanted color into all 16 LEDs, then changes the LEDs that
  you give. `/run/tsx/ledbar.state` records the pattern (`pattern` and 48 levels, or `pattern none`).
- A LED command ends the effect. An effect on top of the pattern keeps the pattern, and `fx off`
  goes back to it. A new color ends both.
- Home Assistant shows `Chase`, `Fill` and `Spectrum`, and has actions for the LEDs, sides, fill and
  split ([ha.md](ha.md) "LED bar actions").

### LED map

A LED map gives the position of each LED on the bar. The bar cannot tell its model, so the panel
tells the bar which map to use. The default map of TSX-LEDBAR 0.1.5 and later is the map of the
TSW-1060-LB. Only the TSW-1060-LB LED bar is tested on hardware. Another bar model can have a
different map.
After each plug-in and each start of the bar, `tsx-ledbard` sends the map of this panel, before the
first color. It sends it only when the answer to `CAPS` has the word `ledmap`.

| `LEDMAP` in `/etc/tsx/ledbar.conf` | Panel model | `tsx-ledbard` sends |
|---|---|---|
| Empty | TSW-1060 and its variants (for example TSW-1060-NC), TSS-10 | `LEDMAP TSW-1060-LB PANEL` |
| Empty | Other models | `LEDMAP DEFAULT`: the firmware default map (the TSW-1060-LB map) |
| A map name, for example `outputs` | Any | `LEDMAP NAME PANEL` |
| `default` | Any | `LEDMAP DEFAULT` |

- The panel model comes from `/run/tsx/model`. `tsx-hostname` writes it at boot from
  `product_name` in the U-Boot env. Without this file, the device tree gives the board:
  `crestron,tsw1060` counts as a TSW-1060.
- The map `outputs` lights LED n on output n. Use it to find the map of a bar model that has no map.
  The tsx-ledbar-fw docs give the steps.
- The firmware does not save the map. After `rc-service tsx-ledbar restart`, the daemon sends it
  again.
- `tsx-ledbar console LEDMAP` shows the map in use, for example `variant 1 map TSW-1060-LB panel`.
  The last word is the source: `default`, `panel` (from the daemon) or `console` (from a user). The
  variant value is for information only.
- `/var/log/tsx-ledbar.log` has one line for each map that the daemon sends, with the answer of the
  bar. A name that the bar does not have gives one log line, and the bar keeps its map.
- The daemon sends no `LEDMAP` to the stock firmware or to a TSX-LEDBAR version without `ledmap`. A
  `LEDMAP` key then gives one log line.

## Audio userland

| Part | Behavior |
|---|---|
| ALSA chain (`/etc/asound.conf`) | A `dmix` mixer feeds a software volume "Master", capped at 0 dB (it can attenuate, never amplify). A full-scale sample reaches the amplifiers at about -12 dBFS. The headroom is needed because the amplifier DSP is bypassed until the DSP loader runs. A second "Media" volume sits ahead of Master, so voice replies can duck music without changing the user volume. Capture uses a shared `dsnoop` device on one microphone channel. |
| Echo cancellation, noise reduction | Done in hardware by the ZL38051 processor before the SoC. Nothing in userspace does it. The processor gates capture to silence around its own resets and around playback, so a stop-word during a reply can be missed. In a quiet room the capture is digital silence or comfort noise near -78 dBFS, and the first 2 to 4 s of each stream are silence. |
| Microphone check | A plain `arecord` cannot show that the microphones work. Run `tsx-audio mic-check [SECONDS]`. It records the raw microphone (MIC3) on the right slot and the processed signal on the left slot, prints both levels and restores the routing. A working microphone in a quiet room gives a raw level of about -57 dBFS. The "mic" PCM and the voice satellite use only the left slot. |

`tsx-audio` (service and CLI) restores the saved volume and mute at boot and routes each amplifier
to its stereo channel.

| Command | Effect |
|---|---|
| `tsx-audio volume`, `mute` | Volume and mute |
| `tsx-audio speaker hold\|release` | Keeps the amplifier enable line up for a stream that needs it |
| `tsx-audio mic-check [SECONDS]` | See above |
| `tsx-audio enable\|disable sendspin\|voice` | Turns the service on or off (`sendspin` also starts `dbus` and `avahi-daemon`) |
| `tsx-audio card` | Prints the ALSA card name |

### TFA9890 DSP loader

The two speaker amplifiers (NXP TFA9890) have an internal DSP for excursion and thermal protection
and volume steps. The kernel has no loader for it, so `/usr/local/lib/tsx/tfa_dsp.py` (standard
library only) loads it from userspace. It loads the DSP firmware patch, mixer config, speaker model,
volume-step preset and EQ from the `.cnt` containers in `/usr/local/share/tsx/tfa9890/`. The
installer puts them there from the panel stock firmware or `vendor-fetch.sh`. The file `SOURCE` in
that directory says which.

`tsx-tfa-dsp` (OpenRC one-shot, config `/etc/tsx/tfa-dsp.conf`) does these steps at each boot:

1. It keeps the amplifier enable line up with a silent stream. The amplifiers need I2S clocks to
   talk over I2C.
2. It runs the loader.
3. It switches the amplifier inputs to the DSP.

A failure at any step leaves both amplifiers in plain bypass, their default state. A missing or bad
tuning file never leaves them unconfigured. The DSP configuration survives the amplifier low-power
states.

## Network audio and voice

| Part | Detail |
|---|---|
| Sendspin (`sendspin-cli`) | A network-audio receiver. It announces itself over mDNS and Music Assistant finds it as a media player. It applies the player software volume itself, so the volume slider works end to end. Alpine has no package, and the upstream armv7 binaries need glibc. `rootfs/src/sendspin/build.sh` builds it for musl armv7 (CI runs it before `mkrootfs.sh`). The project package `sendspin-cli` replaces the local build. Service `tsx-sendspin`, off by default. Turn it on with `tsx-audio enable sendspin` after the audio path works. |
| linux-voice-assistant | The Assist voice satellite. `rootfs/voice/install-lva.sh` installs it under `/opt/lva` (pinned, checksummed). It speaks the ESPHome native API on port 6053, so Home Assistant adds it through the ESPHome integration. |
| Wake word | Runs on the panel with TensorFlow Lite C, built from source for musl armv7 without NEON (`tensorflow-lite-c`). The default model is microWakeWord. openWakeWord is several times heavier on this CPU and not recommended next to the browser. Push-to-talk (a front-key action) skips wake-word inference. |
| Shim (`voice/shim/`) | Connects a local push-to-talk FIFO and the voice-state events to the satellite peripheral API, ducks the "Media" ALSA volume during a conversation, and drives the LED bar and key LEDs on wake. |
| `tsx-voice` | Service and CLI (`ptt`, `stop`, `mute`, `status`, ...). See [ha.md](ha.md) for the pairing and the wake word choice. |

## What lives on the data partition

Most of the rootfs is read-mostly. With a data partition, `tsx-data` moves these directories onto it
at the first boot. It copies with per-file sha256 verification and a crash-safe resume marker, and
it clears the original only after every file is confirmed. At every later boot it bind-mounts them
from the data partition.

| Directory | Content |
|---|---|
| `/var/lib/kiosk` | The browser profile (Home Assistant login, cookies) |
| `/var/log` | Logs |
| `/var/lib/tsx` | Runtime state, including `autoupdate` |
| `/var/lib/sendspin` | The player state (`ha` profile only) |
| `/root`, `/home` | Home directories |

Without a data partition, `tsx-data` does nothing and the state is lost at a reinstall. See
[install.md](install.md) for the partition layout and [recovery.md](recovery.md) for what a factory
restore does to it.

## Panel configuration

`/data/tsx/panel.conf` holds everything that makes one panel different: name, Home Assistant URL
and login, time zone, voice and MQTT settings, kernel flavor and root login. It is on the data
partition and survives a rootfs reinstall. It is a plain `KEY="value"` file with one setting per
line, `#` comments, mode 600. `installer/panel.conf.example` is a commented copy.

`tsx-config` (`rootfs/overlay/usr/local/sbin/tsx-config`, busybox ash) is the only program that
reads or writes the file.

| Command | Effect |
|---|---|
| `tsx-config get KEY` | Print the value |
| `tsx-config set KEY VALUE` | Validate the key (fixed whitelist) and the value (a format for each key), then rewrite the file atomically with mode 600 |
| `tsx-config unset KEY` | Remove the key |
| `tsx-config show` | Print every set key. Secrets show as `********`. |
| `tsx-config validate KEY VALUE` | Check a pair without root. It uses the same table as `set`, writes nothing and exits with 0 for a valid pair. |
| `tsx-config apply` | Run as root at boot, or by hand after a `set`. Turns `panel.conf` into the overrides that the services read. |
| `tsx-config sync-root` | Copy the root password hash into `panel.conf` (see "Root login") |
| `tsx-config setup` | Open the setup page for 15 minutes |

Nothing sources `panel.conf` as shell. The parser reads the literal text after the first `=` of a
line and removes a `"..."` or `'...'` wrapper. A value with `$(...)`, backticks or a stray quote is
only text. Shell scripts and Python tools can read and write the file safely.

### Keys

| Key | Default and meaning |
|---|---|
| `PANEL_NAME` | `<model>-<last 6 hex of the MAC>`, for example `TSS-10-ABCDEF`. Also the Sendspin player name, the voice satellite name and the sanitized `/etc/hostname`. |
| `KIOSK_URL` | The page the kiosk loads. Empty shows the setup page. |
| `HA_LOGIN_METHOD` | `token` or `trusted`. Unset shows the Home Assistant login form. |
| `HA_TOKEN` | A long-lived token, used with `HA_LOGIN_METHOD=token` |
| `TZ_NAME` | Time zone |
| `VOICE` | `on` or `off` |
| `WAKE_WORD` | Wake word name |
| `HA_TRANSPORT` | `esphome`, `mqtt` or `both`. Default `esphome` ([ha.md](ha.md) "Add the panel to Home Assistant"). |
| `HA_API_KEY` | ESPHome API encryption key: base64 of 32 random bytes. Empty means plaintext ([ha.md](ha.md) "Security"). |
| `HA_ALLOW_FROM` | Comma list of IPv4 or IPv6 addresses or CIDRs that may use the ESPHome API. Empty allows any. |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASSWORD` | The MQTT broker |
| `KERNEL_FLAVOR` | `lts` or `stable` ([kernel.md](kernel.md)) |
| `APK_URL` | Base URL of the project apk repository, or `off` (see "The project apk repository") |
| `BLANK_TIMEOUT` | Seconds without input before the screen goes dark. `0` is never. Maximum 86400. Overrides `kiosk.conf`. Also the Home Assistant *Blank timeout* number. |
| `KEY_LED_BLANK` | The level of the key LEDs while the screen is blank, 0 to 255. `0` makes the keys dark. Empty uses `LED_BLANK` of `/etc/tsx/buttons.conf`. Also the Home Assistant *Key LEDs screen-off level* number. See "Key LED levels". |
| `BOOT_VERBOSE` | `1` shows kernel and boot text on the LCD instead of the splash, from the next boot. `apply` keeps the flag file `/etc/tsx/boot-verbose`. |
| `ORIENTATION` | `landscape`, `portrait`, `landscape-flipped`, `portrait-flipped` |
| `BT_PROXY` | `on`, `off` or empty. Empty is the board default (`TSX_BT_PROXY_DEFAULT`), which is `off` on the xx60. |
| `BT_ACTIVE` | `on` or `off` (default `off`). With `BT_PROXY=on`, allows active connections, so Home Assistant can connect to BLE devices through the panel. |
| `BT_MAC` | The Bluetooth address. Empty means the eth0 MAC ([hardware.md](hardware.md) "Bluetooth (CSR8811)"). Without an eth0 MAC the controller keeps its own address and `tsx-btscan` writes it to `/run/tsx/bt.mac`. |
| `CAMERA` | `off` (default), `snapshot` or `live`. `on` is the same as `live`. The camera mode for Home Assistant ([ha.md](ha.md) "Camera"). |
| `AUTO_BRIGHTNESS` | `on` (default) or `off`. The backlight follows the light sensor. `tsx-als auto on\|off` and the Home Assistant *Auto brightness* switch write it. |
| `ALS_SCALE` | A factor from 0.01 to 1000 (default 1.0). Lux = sensor lux x `ALS_SCALE`. It corrects for the light that the front window blocks. |
| `ROOT_PASSWORD_HASH` | A crypt(3) hash, never a plaintext password |
| `SSH_AUTHORIZED_KEY` | An SSH public key |

On a panel without a microphone, Bluetooth module or camera (TSW-760-NC, U-Boot `government=1`,
see [hardware.md](hardware.md) "Panel variants"), `set` accepts `VOICE=on`, `BT_PROXY=on`,
`BT_ACTIVE=on` and each `CAMERA` mode and prints a warning. `apply` treats these keys as `off`.
`tsx-config` reads the panel parts from `/run/tsx/hw.conf` (`tsx-hw`). Without that file it acts as
on a full panel.

### What `apply` does

The `tsx-config` service runs `tsx-hw detect` (it writes `/run/tsx/hw.conf`) and then
`tsx-config apply`. `apply` never fails the boot. Each step logs and moves on.

| Output | Source | Notes |
|---|---|---|
| `/run/tsx/kiosk.conf` | `KIOSK_URL`, `TZ_NAME` | |
| `/run/tsx/sendspin.conf` | `SENDSPIN_NAME` | |
| `/run/tsx/voice.conf` | `NAME`, `WAKE_WORD` | |
| `/run/tsx/mqtt.conf` | `BROKER`, `PORT`, `USER`, `PASSWORD` | |
| `/run/tsx/esphome.key` | `HA_API_KEY` | mode 640, group `kiosk` |
| `/run/tsx/blank-timeout` | `BLANK_TIMEOUT` | mode 644. `tsx-idled` applies a change at once. |
| `/run/tsx/buttons.conf` | `LED_BLANK` (`KEY_LED_BLANK`) | mode 644. `apply` reloads `tsx-buttons` when the file changes. |
| `/run/tsx/als.panel` | `AUTO_BRIGHTNESS`, `ALS_SCALE` | |
| `/run/tsx/esphome.conf` | `TRANSPORT`, `ALLOW_FROM` | Always written, mode 644. The ESPHome plugin runs as `kiosk` and cannot read `panel.conf`. |
| `/run/tsx/bt.conf` | `PROXY`, `ACTIVE`, `MAC` | Always written, mode 644 |
| `/run/tsx/camera.conf` | `CAMERA` | Always written, mode 644. `off` on a panel without a camera. |
| `/run/tsx/panel-name` | `PANEL_NAME` | `tsx-hostname` reads it first |
| `/etc/tsx/orientation` | `ORIENTATION` | |
| `/etc/tsx/boot-verbose` | `BOOT_VERBOSE` | |

An override file that has nothing to say is removed, not written empty. `apply` never changes
`/etc/kiosk.conf` or the `/etc/tsx/*.conf` files. Each consumer reads its own `/etc` default first
and then `[ -r /run/tsx/X.conf ] && . /run/tsx/X.conf`, so `panel.conf` wins.

Other actions of `apply`:

- It restarts `tsx-esphome` when it runs and `esphome.conf`, the panel name or `VOICE` changed. A
  change such as `KIOSK_URL` leaves it running.
- It restarts `tsx-bt` (or stops it for `off`) when `BT_PROXY` or `BT_MAC` changed, before the
  ESPHome servers. A change of `BT_PROXY` or `BT_ACTIVE` restarts the ESPHome servers, because Home
  Assistant reads the Bluetooth feature flags only at connect.
- A change of `CAMERA` restarts the ESPHome server, so that Home Assistant reads the new entity
  list.
- `VOICE` runs `tsx-audio enable|disable voice`. Without a microphone it always disables voice.
  Without a Bluetooth module, `bt.conf` says `PROXY="off"` and `ACTIVE="off"`.
- A changed `ORIENTATION` turns the running kiosk (`tsx-orientation apply`).
- `HA_LOGIN_METHOD=token` with `HA_TOKEN` stages `/var/lib/kiosk/pending-token` when the token
  changed (a sha256 marker tracks it). The `start_pre` of the kiosk service seeds it into the
  browser profile at the next start.
- `ROOT_PASSWORD_HASH` replaces the root field of `/etc/shadow` only as "Root login" describes.
- `SSH_AUTHORIZED_KEY` is appended to `/root/.ssh/authorized_keys` if not there. `panel.conf` never
  removes a key.
- If `/etc/tsx/panel.conf.seed` exists and `/data/tsx/panel.conf` does not, `apply` moves the seed
  to `/data/tsx/panel.conf` once `/data` is mounted. This covers installers that ran before `/data`
  existed (the card-stage and USB flow). The network install ([install.md](install.md)) writes
  `panel.conf` straight to the `tsxdata` partition.

A panel with no `panel.conf` uses the `/etc` defaults.

### Ambient light sensor

`tsx-als` reads the MAX44009, multiplies the lux by `ALS_SCALE`, holds the value and maps it to a
backlight step with `ALS_CURVE` of `/etc/tsx/als.conf`. The Home Assistant *Illuminance* sensor
shows the scaled value. `raw` in `/run/tsx/als.state` is the sensor value. `tsx-als lux` prints one
scaled reading.

| Item | Detail |
|---|---|
| Settings source | `/etc/tsx/als.conf`, `/etc/kiosk.conf` and `/etc/tsx/panel-board.conf` (the last one wins). `tsx-als` rereads them and `/run/tsx/als.panel` every 5 readings and logs the values it uses. |
| `ALS_SCALE` | A value outside 0.01 to 1000 is logged and counts as 1.0. |
| `auto` | `tsx-als auto on\|off` rewrites the `auto` line of `als.state` at once (so `tsx-panelctl get als-auto` and the MQTT switch change at once). A backlight ramp ends when auto turns off. A change through `panel.conf` shows after at most 5 readings. |
| `ALS_PERIOD_S` | 0.8 s. It is never below `ALS_MIN_PERIOD_S` (0.8 s), the sensor update period. |
| Hold times | The light must stay brighter for `AUTO_BRIGHTEN_S` (1.5 s) or darker for `AUTO_DARKEN_S` (5 s). A flash or shadow shorter than that changes nothing. |
| Bands | The change must pass a band in log10(1 + lux): `AUTO_BRIGHTEN_BAND` (0.06) and `AUTO_DARKEN_BAND` (0.10). |
| Reversal | A one-step change against the last change needs a double band within `ALS_REVERSE_S` (30 s). |
| Ramp | One step every `ALS_RAMP_MS` (60 ms) |
| Model | `LightResponse` in `tsx_brightness.py` (`docs/adaptive-brightness.md` of tsx-linux-common) |
| Learning | Needs the light inside a narrow range during the hold, so a light change never makes or removes a point. |

The *Sensors* section of the setup page has `AUTO_BRIGHTNESS` and `ALS_SCALE`.

## Setup page

`/etc/kiosk.conf` ships with an empty `KIOSK_URL`. A panel with an empty URL shows the local setup
page. The same page opens at `http://<panel-ip>:8080/setup` from a laptop or phone. To open it on a
configured panel, run `tsx-config setup` (as root, over ssh) or press *Setup* in the overlay. The
page then opens for `TSX_SETUP_WINDOW` seconds without a change to `KIOSK_URL`. See
[install.md](install.md) "Configure the panel after install" for the end-user text.

### Settings (`/etc/tsx/setup.conf`)

| Key | Default | Meaning |
|---|---|---|
| `TSX_SETUP_PORT` | 8080 | The port |
| `TSX_SETUP_LAN` | `on` | Allow LAN access during the window or while unconfigured |
| `TSX_SETUP_WINDOW` | 900 | Seconds that a reopened page stays open |

### Parts

| Part | Role |
|---|---|
| `tsx-setupd` (`rootfs/overlay/usr/local/sbin/tsx-setupd`) | A Python HTTP server (standard library). It runs in the default runlevel of the `kiosk` and `ha` profiles, as the unprivileged user `tsx-setup`. |
| `tsx-setup-helper` (`.../sbin/tsx-setup-helper`) | A root daemon with its own FIFO (group `tsx-setup`) and a whitelisted line command set: `show`, `rev`, `set KEY VALUE`, `unset KEY`, `apply`, `setup`, `kiosk-restart`, `brightness-learn-reset`, `clear-setup-open` and `rootpw PASSWORD`. `rev` gives the revision of `panel.conf`: the sha256 of a salt and the file content. The salt is in `/run/tsx/setup-helper.salt` (mode 600). Each boot makes a new salt, and a restart of the helper keeps it. The helper never sends the salt. A request can start with a tag `#TAG`. The reply then starts with the same tag, and `tsx-setupd` reads only the reply with its own tag. |
| `tsx-kiosk-url` (`.../bin/tsx-kiosk-url`) | Called by `kiosk-session`. It returns the setup page URL when the configured URL is empty, or when `/run/tsx/setup-open` is younger than `TSX_SETUP_WINDOW`. Otherwise it returns the configured URL. Host test: `tests/test-setup.sh` in tsx-linux-common. |

- `tsx-setupd` never runs a shell built from form input. It checks each field with
  `tsx-config validate KEY VALUE` and sends a fixed line to the helper.
- The root password goes through `chpasswd` inside the helper, on stdin. The helper copies the
  resulting hash into `ROOT_PASSWORD_HASH`, so a factory reinstall applies it again.
- A key that is already set (`HA_TOKEN`, `MQTT_PASSWORD`, `SSH_AUTHORIZED_KEY`, the root password)
  shows as *set*, never as its value. Nothing of a request body goes to a log.
- `kiosk-session` waits up to about 10 s (with a heartbeat log line) for the setup port before it
  gives the URL to the browser.
- The window age uses monotonic time (`/proc/uptime`), not the wall clock, because the panel has no
  RTC and NTP steps the clock by months. A reboot closes the window.

### Access control

| Rule | Detail |
|---|---|
| Who can reach it | The LAN can reach the page only while the panel is unconfigured, or during the reopened window. |
| Pairing code | A LAN client must type a six-digit code that shows on the panel screen. The panel sends it nowhere else. A correct code pairs the browser with a session cookie, valid for the same window. The page rate-limits wrong codes from one address. |
| Localhost | The kiosk browser never needs a code. |
| Listening socket | Outside the window, the server listens on `127.0.0.1` only. In the window or while unconfigured, it listens on `0.0.0.0`. The handler also refuses non-loopback requests when the LAN is not allowed. |
| Rebind gap | A request in the short gap of a rebind (also from the kiosk) sees a connection reset. The client must retry. The same happens before `tsx-setupd` has bound its port. |

### Fields

The fields mirror the `panel.conf` keys. Groups: Network, Display, Access, Updates.

| Field | Notes |
|---|---|
| Page URL (`KIOSK_URL`) | With the `tsx-ha` plugin it is the Home Assistant URL. The page checks it live (it fetches `<url>/manifest.json` from the panel, refuses redirects to anything but http or https, and limits redirects and bytes). It pre-fills the URL from `_home-assistant._tcp` mDNS discovery (`py3-zeroconf`). Neither is required to save. |
| Login method | Plugin of `tsx-ha`: the Home Assistant login form, a long-lived token, or trusted network |
| Panel name | |
| Time zone | A select built from `/usr/share/zoneinfo` |
| Screen orientation | The kiosk turns when you save |
| Blank timeout | Under Display |
| Light sensor | `AUTO_BRIGHTNESS` and `ALS_SCALE`, under Sensors |
| Root password, SSH public key | |
| Kernel flavor | Under Updates |
| Voice on or off, wake word, Bluetooth proxy, MQTT | Plugin of `tsx-ha`. On a panel without a microphone and Bluetooth module the page shows them as not available. The voice switch is off and locked, and a save keeps `VOICE` and `WAKE_WORD`. |

### Save

A save writes only the fields that the user changed. A field that the user did not change keeps
the value of `panel.conf`, also a value that changed after the page loaded.

| Step | What happens |
|---|---|
| Load | The page gets the values and the revision of `panel.conf` (`/setup/api/state`). It fills each field once. A checkbox shows the stored state, checked or not checked. |
| Refresh | Every 20 s the page reads `/setup/api/status`: the pairing code and the revision. The refresh never changes a field. A new revision shows a notice with a *Reload the page* button. |
| Save | The page sends the revision of the load and the fields whose value differs from the value at load time. |
| Check | If `panel.conf` changed after the load (`tsx-config`, Home Assistant, another browser), the server refuses the save with HTTP 409. It changes nothing. The page tells the user to reload it. |
| Write | The server sets or removes only the keys that the page sent. It does not write a value that `panel.conf` already has. |
| Apply | `tsx-config apply` runs only when a key or the root password changed. |
| Close | The helper runs `clear-setup-open` and `kiosk-restart`, also after a save with no change. The kiosk loads the configured page at once. |

The revision covers the whole file, also the secrets that the page never shows. No writer of
`panel.conf` takes a lock. So the server does not see a change in the few milliseconds between the
check and the writes.

## Board file

The shared panel software reads the board file `/usr/local/lib/tsx/board.sh` and does not name the
board family. It holds plain variables and small functions and prints nothing when sourced. A value
in the environment wins (host tests use this).

| Name | xx60 value | Use |
|---|---|---|
| `TSX_FAMILY` | `xx60` | Package names (`tsx-xx60-chromium`) and the `panel.conf` header |
| `TSX_APK_CATEGORY` | `xx60` | The second apk repository (`<APK_URL>/<branch>/xx60`) |
| `TSX_HA_MODEL` | `xx60` | The model in Home Assistant (`xx60 (mainline Linux)` over MQTT, `xx60 panel` over ESPHome) |
| `TSX_SOUND_CARD` | `TSW1060` | The ALSA card name. `tsx-audio card` prints it. |
| `TSX_DISPLAY_DRM`, `TSX_RENDER_DRM`, `TSX_RENDER_ES2_DRM` | `meson*`, `lima panfrost`, `lima` | DRM drivers that `kiosk-session` picks |
| `TSX_DISPLAY_ENV` | the cage variables | Variables that `kiosk-session` exports |
| `TSX_BT_CHIP`, `TSX_BT_PROXY_DEFAULT`, `TSX_BT_MAC_SETTABLE` | the CSR8811 file, `off`, `yes` | Bluetooth (`tsx-bt`, `tsx-config`) |
| `TSX_MAC_SOURCE`, `TSX_MAC_DEV` | `uboot`, `/dev/mmcblk0` | The source of the eth0 MAC |

Functions: `tsx_board_model`, `tsx_board_stock_fw`, `tsx_board_unit_id`, `tsx_board_mac`,
`tsx_board_mac_early`, `tsx_board_mac_source`, `tsx_board_hostname_hint`, `tsx_board_rescue_extra`,
`tsx_board_ha_model`.
Python programs read a value with `tsx-board get NAME` and call a function with
`tsx-board call NAME`. For `tsx_board_model`, `tsx_board_stock_fw`, `tsx_board_unit_id`,
`tsx_board_mac` and `tsx_board_hostname_hint`, the call first reads the U-Boot env
(`tsx_board_load`).

The board file holds fixed facts. `tsx-hw` detects the parts that a panel can lack (microphone,
Bluetooth) at boot into `/run/tsx/hw.conf`.

## Updates

Packages come from Alpine (`rootfs/packages.txt`) and, with a local apk tree, from the project
repository (`rootfs/packages-tsx.txt`). The build pins a package only where needed (the Alpine
chromium). Others float with the `ALPINE` branch (`v3.24`) at build time.

A running panel updates its packages with `apk upgrade`. The stable Alpine branch gets security
updates and fixes. `tsx-autoupdate` (`rootfs/overlay/usr/local/sbin/tsx-autoupdate`) runs the
upgrade through `crond` every 15 minutes.

### Autoupdate behavior (`/etc/tsx/autoupdate.conf`)

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | 1 | Turn autoupdate on or off |
| `WINDOW` | `03:00-05:00` | Local time window for installs and reboots |
| `REBOOT` | `auto` | `never` disables the reboot. The status then shows "reboot pending" until you reboot. |
| `HOLD_DAYS` | 7 | Days to hold an unknown Chromium build |

| Step | Behavior |
|---|---|
| Daily check | `apk update` and `apk upgrade --simulate` list the pending packages and whether any needs a reboot (a kernel, `musl`, `openrc`, `busybox` or init package). |
| Install | Only inside `WINDOW` and only while the screen is idle (it uses the `tsx-idled` state). A needed reboot also waits for the window. `tsx-autoupdate now` installs at once. The window and the idle state then gate only the reboot. The Home Assistant Install button runs this command. |
| Chromium | `tsx-xx60-chromium` is a normal package. A rootfs built without the project repository pins the Alpine build in `/etc/apk/world`. For a newer Alpine build, `tsx-autoupdate` checks the signature list that comes with `patch-chromium.py` (`/usr/local/share/tsx/chromium-es2/`). It upgrades and patches a known signature at once. It holds an unknown signature (status "held since ...") for `HOLD_DAYS`. Then it installs the build unpatched with software rendering and logs this. |
| Health check | After a reboot it checks the kiosk service and the reachability of `KIOSK_URL` and records the result. |
| Status | `tsx-autoupdate status`, or `/run/tsx/update.json`. A persistent copy is in `/var/lib/tsx/autoupdate`. |

The status has: the installed version (an `apk info -v` fingerprint, plus `/etc/tsx/build-id` if
present), the pending count and list, reboot pending, the Chromium hold state, and the time and
result of the last check and install. The ESPHome device and `tsx-mqtt` publish a Home Assistant
`update` entity from it ([ha.md](ha.md)).

### The project apk repository

The project publishes signed apk packages (repository `tsx-aports`: `common/` for hardware-neutral
packages, `xx60/` for this board). `apk upgrade` updates them with the Alpine packages.

| Package | Replaces in a rootfs without the repository |
|---|---|
| `tsx-xx60-chromium` (Alpine build with the ES2 patch, `provides=chromium`) | the `chromium=<ver>` pin and the in-place patch |
| `tsx-xx60-kernel-lts`, `tsx-xx60-kernel-stable` (both installed) | unowned `/lib/modules/<release>/` trees |
| `tsx-xx60-wlroots0.20` | Alpine `wlroots0.20` (see "Screen blanking") |
| `sendspin-cli` (`/usr/bin`) | `/usr/local/bin/sendspin-cli` |
| `tensorflow-lite-c` (`/usr/lib/libtensorflowlite_c.so`) | `voice/tflite/` |
| `tsx-keys` (the signing key) | `overlay/etc/apk/keys/` (shipped in both cases) |

- **Repositories.** Every rootfs trusts the project key. `/etc/apk/repositories` lists
  `<TSX_APK_URL>/<branch>/common` and `.../xx60` first, before Alpine `main` and `community`, so
  `tsx-xx60-chromium` wins over Alpine `chromium`. The default URL is
  `https://tsx-aports.unexceptional.net`. The `APK_URL` key points a panel at a mirror, a LAN copy or
  a local directory, or is `off` (`tsx-config apply` rewrites only the marked block). The build
  never fetches from that URL. It uses `TSX_APK_LOCAL`.
- **Kernel packages.** Both flavors are installed, so a switch writes only a boot image. Each package
  ships `/boot/tsxboot-emmc-<flavor>.img`. Its install script writes the eMMC boot partition (through
  `tsx-update-boot`, with backup and readback verify) only when its flavor is the selected one
  (`KERNEL_FLAVOR`) and the image differs from the partition. `tsx-kernel-flavor lts|stable` switches
  the flavor ([install.md](install.md) "Change the kernel flavor or the boot image"). A kernel
  update counts as "needs a reboot".
- **Unreachable repository.** `apk` refuses every upgrade while a listed repository is unavailable.
  If only the project repositories are unreachable, `tsx-autoupdate` records a warning (status
  "repositories:", `repo_warning` in `update.json`, the update entity summary) and installs the Alpine
  updates with `--force-missing-repositories`. An unreachable Alpine repository blocks the install. By
  hand, run `apk upgrade --force-missing-repositories`, or `tsx-config set APK_URL off && tsx-config
  apply`.
- **Move from Alpine chromium.** When a configured repository offers `tsx-xx60-chromium`, the next
  `tsx-autoupdate` install runs `apk add tsx-xx60-chromium` (this removes Alpine `chromium`) and
  `apk del chromium` (this drops the world pin). The package file `/etc/tsx/chromium-es2-patched`
  replaces the in-place patch record. You can run the same steps by hand with the kiosk stopped.

## Performance

The kiosk composites with the GPU. These values are typical for a TSW-1060 with a test dashboard
page. A real dashboard gives different values.

| Item | Typical value |
|---|---|
| Scroll rate | 57 fps with the ES2 patch and GPU compositing. 7 fps in software. |
| Idle CPU, dashboard with a live clock | 2.4% of all cores with the GPU patch. 8.7% in software. |
| Chromium low-end device mode | On when the panel has less than 1400 MB of RAM. A 2 GB panel does not use it. |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The picture is black or garbled | The GPU path fails | Set `KIOSK_GPU=auto` in `/etc/kiosk.conf` and restart the `kiosk` service |
| The kiosk shows the setup page | `KIOSK_URL` is empty, or the setup window is open | Set `KIOSK_URL` on the page or with `tsx-config set KIOSK_URL URL` and `tsx-config apply` |
| The screen stays black after a wake | The Alpine wlroots fails `power on` | Install `tsx-xx60-wlroots0.20` from the project repository |
| `apk upgrade chromium` refuses | The pin protects the patched binary | Use the project repository, or follow "GPU path" to move the pin |
| `apk upgrade` fails | A listed repository is unreachable | See "Unreachable repository" |
| Setup page gives a connection reset | The server is rebinding its socket | Retry |
| `arecord` records only silence | The echo canceller gates capture for 2 to 4 s | Use `tsx-audio mic-check` |
| A panel has no console login after install | Key-only install, root is locked | Log in over SSH and run `passwd` |
| `tsx-idled` logs `no /etc/kiosk.conf, using defaults` | The console profile has no `kiosk.conf` | None. This is normal. |
| Home Assistant is slow on the panel | Many entity updates or many dashboard resources | See "Slow Home Assistant pages" |
