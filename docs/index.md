# tsx-xx60-linux

This repo holds mainline Linux for the Crestron TSW-760, TSW-1060 and TSS-10 panels (Amlogic Meson8m2). It has the installer, the kernel, the root file system and the rescue system. The panel boots from the eMMC and shows a Home Assistant dashboard.

## Pages

Do a job:

- [Install and reinstall](install.md): install, reinstall and update a panel, the installer options and the payload.
- [Home Assistant integration](ha.md): add the panel to Home Assistant and use its entities, LED bar actions, voice and Bluetooth proxy.

Look up a part. Read Recovery when an install fails or when you want stock Android back:

- [Hardware](hardware.md): the board, SoC, display, touch screen, LED bar and audio parts.
- [Boot](boot.md): U-Boot, the boot image and the root selection.
- [Kernel](kernel.md): the kernel flavors, the patches and the build.
- [Rootfs](rootfs.md): the root file system, the profiles, the panel configuration and the panel services.
- [Recovery](recovery.md): the rescue system, the repair steps and the factory restore to stock Android.
