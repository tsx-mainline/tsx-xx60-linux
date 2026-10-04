# SD card method (card in a PC)

This method writes the mainline install to the removable SD card of the panel. You take the card out, write it in a PC, and put it back. You need no UART and no root shell. The method never writes to the eMMC.

The card is a Phison MP995, 4 GB (7,774,208 sectors = 3,980,394,496 bytes), `mmcblk0` on SDIO port B. It holds the Crestron MBR, the golden `boot.img` on p1, the U-Boot env at 1 MiB, and the Android `/sdcard` on p5. U-Boot, the stock Android system and the keys are on the soldered Hynix eMMC (H4G2a, 7,634,944 sectors).

## Tasks

### Flash a card in update mode

Update mode needs a card with the Crestron layout and a valid env.

1. On the dev host, build the card image: `installer/sdcard/mkcard.sh --out /var/tmp/card`. The output is `card-tsw1060.img(.gz)` and a manifest.
2. Take the card out of the panel. Put it in a PC with a card reader. Unmount any auto-mount.
3. Run `sudo installer/sdcard/flash-card.sh --image card-tsw1060.img.gz --device /dev/sdX`.

The script writes three things:

- **p1:** the FAT of the card, plus `tsxboot.img` and `tsxenv.bak`. The golden `boot.img` and the Android files stay.
- **p5:** the rootfs.
- **env:** the env block of the card. Only `tsx_boot`, `switch_bootmode`, `boot_retry` and `golden_boot_retry` change. The MAC, the tsid, the product name and every other variable keep their exact bytes.

The script does not write the MBR, the U-Boot copy, p2, p6 (`/data`), p7 or p8. It writes the env last. It reads back everything it wrote and compares it.

### Flash a new, blank or foreign card

1. Run `flash-card.sh --mode full` with the image. This writes the whole image.
2. Give the env of this unit: the env of the card, `--unit-env <backup>`, or `--generic-env`. The generic env has no MAC.

You can also write the image to a blank card with `dd` or balenaEtcher. The generic image has no MAC, a neutral tsid and no product name. If an efuse MAC is burned, U-Boot uses it (`common/main.c`). If not, the network MAC is random. Use `flash-card.sh` when you can.

### Undo a flash

1. Run `sudo flash-card.sh --restore <backup>.img --device /dev/sdX`.

The script makes the backup automatically before every flash. It backs up the whole card and verifies the backup.

## Reference

### Files

| File | Where it runs | What |
|---|---|---|
| `mkcard.sh` | Dev host, no root | Builds a full card image from a donor card image, `tsxboot.img` and `rootfs.ext4`. It makes a raw sparse `.img`, an `.img.gz`, a `.manifest` (sha256 for each region) and an `.env` |
| `flash-card.sh` | Any Linux PC, root | Backs up the whole card and verifies the backup. It merges the hook into the env of the card itself and writes only what is needed. It then verifies the result. `--restore` undoes a flash |
| `tsx-env.py` | Both | Handles the U-Boot env block. Commands: `check`, `show`, `unit`, `merge`, `generic`, `write`, `diff` |

### Modes of flash-card.sh

| Mode | Use | Needs |
|---|---|---|
| `update` (default) | Card with the Crestron layout | A valid env on the card |
| `full` | New, blank or foreign card | The env of this unit (card env, `--unit-env`, or `--generic-env`) |

### Card size

The card must be at least the size of the original (7,774,208 sectors). The script accepts a larger card, keeps the Crestron layout and leaves the rest unused. It refuses a smaller card.
