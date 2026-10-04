# Card-stage steps

`tsx-android-to-card` and `tsx-card-to-emmc` are expert and debug tools. To install a panel, use `installer/tsx-install-mainline` (see [docs/install.md](../../../docs/install.md)).

## What the scripts do

| Script | What |
|---|---|
| `tsx-android-to-card` | Writes the kiosk rootfs to `p2` of the SD card. This is a full second root, not only a rescue system. The panel boots it. Options and steps: [installer/payload/README.md](../../payload/README.md) "Automated load" |
| `tsx-card-to-emmc` | Moves boot and root from the card to the eMMC |

`installer/tsx-install-mainline` does not use these scripts. A small rescue system writes the eMMC directly, so the card never holds a second full root.

## Where the card-stage image is used

The **USB install method** uses the same card-stage rootfs image. The image is `rootfs-p2.ext4` from `installer/steps/mkp2rootfs.sh`. It goes through `installer/android/tsx-android-install.sh` and `tsx-autoinstall`. Panels with no usable network need this method (see [docs/install.md](../../../docs/install.md) "USB install method"). No other installer script calls the two scripts here.

`installer/steps/tsx-ensure-root` is a copy of steps 2 to 4 of `tsx-android-to-card`. These steps configure the network and the UART to get a root shell on stock Android. `tsx-install-mainline` uses the copy. `tsx-android-to-card` keeps its own inline version, so that it works alone.
