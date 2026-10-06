#!/bin/sh
# Runs INSIDE an armv7 alpine:3.24 container (run.sh). It builds the guest
# initramfs for the voice satellite test: Alpine base, ALSA, the "voice"
# packages of rootfs/packages.txt, the board audio files of rootfs/overlay, the
# voice files of tsx-linux-common (the checkout that TSX_COMMON names, default
# the folder tsx-linux-common next to this repository, which run.sh mounts),
# tsx-peak, and linux-voice-assistant. The script installs
# linux-voice-assistant through the SAME install-lva.sh as the tsx-ha package.
# It also adds test samples and /init.
#   mkinitramfs.sh OUT.cpio.gz
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOTFS=$(cd "$HERE/../../../rootfs" && pwd)
COMMON=${TSX_COMMON:-$ROOTFS/../../tsx-linux-common}
[ -r "$COMMON/ha/voice/install-lva.sh" ] || { echo "no tsx-linux-common checkout at $COMMON (set TSX_COMMON)"; exit 1; }
TESTS=$(cd "$HERE/../.." && pwd)
OUT=$1
R=/build/guest; rm -rf $R; mkdir -p $R/etc/apk
apk add -q --no-cache build-base cpio >/dev/null
cp /etc/apk/repositories $R/etc/apk/
# the voice block of packages.txt (from "# voice" to the next comment)
VOICE=$(awk '/^# voice/{v=1; next} v && /^#/ && seen{exit} v && /^#/{next} v && /^[a-z0-9]/{print; seen=1}' $ROOTFS/packages.txt | tr '\n' ' ')
echo "voice packages from packages.txt: $VOICE"
[ -n "$VOICE" ] || { echo "no voice packages found"; exit 1; }
apk add -q --root $R --initdb --no-cache --keys-dir /etc/apk/keys \
	--repositories-file $R/etc/apk/repositories \
	alpine-baselayout busybox musl-utils alsa-lib alsa-utils util-linux-misc tcpdump procps-ng $VOICE
O=$ROOTFS/overlay
install -D -m 644 $O/etc/asound.conf $R/etc/asound.conf
install -D -m 644 $O/etc/tsx/audio.conf $R/etc/tsx/audio.conf
install -D -m 644 $COMMON/ha/etc/tsx/voice.conf $R/etc/tsx/voice.conf
install -D -m 755 $COMMON/ha/etc/init.d/tsx-voice $R/etc/init.d/tsx-voice
install -D -m 755 $O/usr/local/bin/tsx-audio $R/usr/local/bin/tsx-audio
for f in tsx-voice tsx-voice-hook tsx-voice-run; do install -D -m 755 $COMMON/ha/usr/local/bin/$f $R/usr/local/bin/$f; done
gcc -O2 -Wall -Wextra -s -o $R/usr/local/bin/tsx-peak $ROOTFS/src/tsx-peak.c -lm
LVA_CACHE=/build/lva sh $COMMON/ha/voice/install-lva.sh $R
mkdir -p $R/test && cp $HERE/guest-tests.sh $HERE/fake_ha.py $R/test/
for w in okay_nabu hey_jarvis alexa; do mkdir -p $R/test/$w; cp $TESTS/cache/pmw-git/tests/$w/[123].wav $R/test/$w/; done
cat > $R/init <<'I'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm; mount -t devpts devpts /dev/pts; mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs tmpfs /run; mount -t tmpfs tmpfs /tmp
ip link set lo up; hostname tsx-test
echo "=== guest up: $(uname -r), $(nproc) cpus, $(awk '/MemTotal/{print $2}' /proc/meminfo) kB ==="
sh /test/guest-tests.sh
echo "=== guest tests exit $? ==="
sync; poweroff -f
I
chmod 755 $R/init
du -sh $R $R/opt/lva $R/usr/lib 2>/dev/null
(cd $R && find . | cpio -o -H newc 2>/dev/null | gzip -1) > "$OUT"
ls -l "$OUT"
