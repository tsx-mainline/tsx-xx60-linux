#!/bin/sh
# Extract the vendor climax_hostsx (NXP TFA host tool, Android 4.4 bionic) and the
# libraries it needs from the unit A backup (read-only), into vendor-bin/ (this directory).
# Proprietary Crestron/NXP binaries: keep local, do not publish.
set -e
P=$(cd "$(dirname "$0")/.." && pwd)
IMG=$P/../../captures/tsw-1060/backup/tsw1060-mmcblk0.img
T=${TMPDIR:-/tmp}/tsx-p16-sys.$$
mkdir -p "$T" "$P/vendor-bin/system/bin" "$P/vendor-bin/system/lib"
# p2 = /system (ext4), start sector 206849, 1638400 sectors
dd if="$IMG" of="$T/p2.img" bs=512 skip=206849 count=1638400 status=none
for f in bin/climax_hostsx bin/linker; do debugfs -R "dump /$f $P/vendor-bin/system/$f" "$T/p2.img" 2>/dev/null; done
for l in libc libcutils libm libstdc++ libutils liblog libbacktrace libstlport libgccdemangle libunwind libunwind-ptrace libnetd_client libjbl_acoustic; do
  debugfs -R "dump /lib/$l.so $P/vendor-bin/system/lib/$l.so" "$T/p2.img" 2>/dev/null
done
chmod +x "$P/vendor-bin/system/bin/"*
rm -rf "$T"
sha256sum "$P/vendor-bin/system/bin/climax_hostsx" "$P/vendor-bin/system/lib/libjbl_acoustic.so"
