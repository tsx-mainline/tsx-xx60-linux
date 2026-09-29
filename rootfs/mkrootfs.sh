#!/bin/sh
# Runs INSIDE an armv7 Alpine container (see ../build-rootfs.sh), as root.
# Env: ALPINE (branch, e.g. v3.24), KVER (module dir name(s) under
#      /modules/lib/modules, space-separated for more than one kernel, or
#      empty), OUT (output dir), UIDGID (owner for outputs), IMG_MB (ext4
#      size in MiB), TSX_APK_URL (base URL of this project's apk repository,
#      written into the panel's /etc/apk/repositories; never fetched here),
#      TSX_APK_LOCAL (optional: a local copy of that repository's published
#      tree, <ALPINE>/common + <ALPINE>/xx60; packages-tsx.txt is installed
#      from it)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
R=/build/rootfs; mkdir -p /build
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
log() { echo "== $*"; }

printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "$ALPINE" "$MIRROR" "$ALPINE" > /etc/apk/repositories
apk update -q

# This project's apk repository (tsx-aports). The panel lists it first in
# /etc/apk/repositories at TSX_APK_URL (panel.conf APK_URL overrides that on
# the panel, tsx-config apply). Its packages (packages-tsx.txt) go into the
# image only from a LOCAL copy of the published tree (TSX_APK_LOCAL): the
# build never depends on TSX_APK_URL being reachable. Without a local copy
# the image carries what those packages replace (see packages-tsx.txt).
TSX_APK_URL=${TSX_APK_URL:-https://tsx-aports.unexceptional.net}; TSX_APK_URL=${TSX_APK_URL%/}
TSX_APK_LOCAL=${TSX_APK_LOCAL:-}
TSXREPO=0
if [ -n "$TSX_APK_LOCAL" ]; then
	for c in common xx60; do
		[ -r "$TSX_APK_LOCAL/$ALPINE/$c/armv7/APKINDEX.tar.gz" ] || { echo "TSX_APK_LOCAL: no $ALPINE/$c/armv7/APKINDEX.tar.gz under $TSX_APK_LOCAL"; exit 1; }
	done
	TSXREPO=1
fi
apk add -q --no-cache build-base linux-headers e2fsprogs tar gzip mkpasswd >/dev/null

log "compile tsx-idled"
gcc -O2 -Wall -s -o /build/tsx-idled "$HERE/src/tsx-idled.c"
gcc -O2 -Wall -s -o /build/tsx-buttons "$HERE/src/tsx-buttons.c"   # front-panel
apk add -q --no-cache libusb-dev >/dev/null                           # LED bar
gcc -O2 -Wall -s -o /build/tsx-ledbar "$HERE/src/tsx-ledbar.c" -lusb-1.0
gcc -O2 -Wall -s -o /build/tsx-peak "$HERE/src/tsx-peak.c" -lm       # audio
# boot splash: the same tool + artwork as the initramfs (status updates from
# OpenRC, the compositor background; docs/boot.md "Boot splash")
gcc -O2 -Wall -s -o /build/tsx-splash "$HERE/src/tsx-splash.c"
sh "$HERE/splash/mksplash.sh" /build/splash-out >/dev/null

CAGE_VER=0.3.1
CAGE_SHA256=6dc1619665acd367e0174c93b234002549a66f55f1de9197d67f0305415babc8
log "build cage $CAGE_VER (patched)"
apk add -q --no-cache meson samurai pkgconf wlroots0.20-dev wayland-dev wayland-protocols \
	libxkbcommon-dev libdrm-dev curl patch >/dev/null
curl -fsSL -o /build/cage.tar.gz https://github.com/cage-kiosk/cage/archive/refs/tags/v$CAGE_VER.tar.gz
echo "$CAGE_SHA256  /build/cage.tar.gz" | sha256sum -c -
rm -rf /build/cage-$CAGE_VER /build/cage-build; tar -C /build -xzf /build/cage.tar.gz
(cd /build/cage-$CAGE_VER && patch -p1 < "$HERE/src/cage-$CAGE_VER-argb8888-fallback.patch")
meson setup /build/cage-build /build/cage-$CAGE_VER -Dman-pages=disabled --prefix=/usr --buildtype=release >/dev/null
ninja -C /build/cage-build >/dev/null
strip /build/cage-build/cage

# quick-settings overlay (sway layer-shell client, kiosk user): the layer-shell
# protocol comes from wlr-protocols; it references xdg_popup, so xdg-shell's
# glue is linked too
log "build tsx-overlay"
apk add -q --no-cache cairo-dev wlr-protocols >/dev/null
P=/build/tsx-overlay-proto; rm -rf $P; mkdir -p $P
LS=/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml
wayland-scanner client-header $LS $P/wlr-layer-shell-unstable-v1-client-protocol.h
wayland-scanner private-code $LS $P/wlr-layer-shell-unstable-v1-protocol.c
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $P/xdg-shell-protocol.c
gcc -O2 -Wall -s -I$P -o /build/tsx-overlay "$HERE/src/tsx-overlay.c" $P/*.c \
	$(pkg-config --cflags --libs cairo wayland-client) -lm

log "install packages ($ALPINE, armv7)"
rm -rf $R; mkdir -p $R/etc/apk/keys
# trust this project's signing key (the same .pub the tsx-keys package ships)
cp "$HERE"/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
cp -a /etc/apk/keys/. $R/etc/apk/keys/
PKGS=$(grep -v '^#' "$HERE/packages.txt" | tr '\n' ' ')
: > /build/repositories
if [ $TSXREPO = 1 ]; then
	TSXPKGS=$(grep -v '^#' "$HERE/packages-tsx.txt" | tr '\n' ' ')
	log "tsx-aports packages from $TSX_APK_LOCAL: $TSXPKGS"
	# tsx-xx60-chromium provides chromium: no Alpine chromium pin next to it
	PKGS="$(grep -v '^#' "$HERE/packages.txt" | grep -v '^chromium=' | tr '\n' ' ') $TSXPKGS"
	printf '%s/%s/common\n%s/%s/xx60\n' "$TSX_APK_LOCAL" "$ALPINE" "$TSX_APK_LOCAL" "$ALPINE" > /build/repositories
fi
cat /etc/apk/repositories >> /build/repositories
apk add --root $R --initdb --no-cache -q --keys-dir /etc/apk/keys \
	--repositories-file /build/repositories $PKGS
cp -a /etc/apk/keys $R/etc/apk/
# the panel's list: this project's two repositories FIRST (tsx-xx60-chromium
# must win the tie with Alpine's chromium; tsx-aports README "Which chromium
# wins"). The block, marker line included, is what tsx-config apply writes.
{
	echo "# tsx-aports (tsx-config apply; panel.conf APK_URL)"
	echo "$TSX_APK_URL/$ALPINE/common"
	echo "$TSX_APK_URL/$ALPINE/xx60"
	cat /etc/apk/repositories
} > $R/etc/apk/repositories

log "overlay"
cp -a "$HERE"/overlay/. $R/
# tsx-autoupdate re-applies the Chromium ES2 patch on the panel after an upgrade:
# ship the patch tool + signature list from their single source in src/.
install -D -m 644 "$HERE/src/chromium-es2/patch-chromium.py" $R/usr/local/share/tsx/chromium-es2/patch-chromium.py
install -D -m 644 "$HERE/src/chromium-es2/sigs.json" $R/usr/local/share/tsx/chromium-es2/sigs.json
# the build's repository URL: tsx-config apply falls back to it when
# panel.conf has no APK_URL
printf '%s\n' "$TSX_APK_URL" > $R/etc/tsx/apk-url.default
# build id for tsx-autoupdate / the HA update entity (installed_version)
printf '%s\n' "${TSX_BUILD_ID:-$(date -u +%Y%m%d%H%M)}" > $R/etc/tsx/build-id
# the boot clock's floor (no RTC): swclock sets the clock from this file's
# mtime, so a new image never boots earlier than its build time
# (/etc/periodic/15min/tsx-savetime keeps it current while NTP has the time)
mkdir -p $R/var/lib/misc && touch $R/var/lib/misc/openrc-shutdowntime
install -m 755 /build/tsx-idled $R/usr/local/sbin/tsx-idled
install -m 755 /build/tsx-buttons $R/usr/local/sbin/tsx-buttons
install -m 755 /build/tsx-ledbar $R/usr/local/bin/tsx-ledbar
install -m 755 /build/cage-build/cage $R/usr/bin/cage
install -m 755 /build/tsx-overlay $R/usr/local/bin/tsx-overlay
install -m 755 /build/tsx-splash $R/usr/local/bin/tsx-splash
mkdir -p $R/usr/share/tsx/splash
cp /build/splash-out/*.ppm /build/splash-out/*.psf $R/usr/share/tsx/splash/
# audio: level meter, Sendspin player. sendspin-cli is built from source by
# rootfs/src/sendspin/build.sh (CI runs it before this script; a local build
# runs it by hand first) and never committed -- read it from that build's
# output dir here.
# voice: the Assist voice satellite linux-voice-assistant (pinned; see
# voice/install-lva.sh below)
install -m 755 /build/tsx-peak $R/usr/local/bin/tsx-peak
if [ $TSXREPO = 1 ]; then
	# the sendspin-cli package: /usr/bin/sendspin-cli (tsx-sendspin prefers it)
	[ -x $R/usr/bin/sendspin-cli ] || { echo "sendspin-cli package did not install /usr/bin/sendspin-cli"; exit 1; }
	SENDSPIN_BIN=/usr/bin/sendspin-cli
else
	SENDSPIN_CLI=${SENDSPIN_CLI:-"$HERE/src/sendspin/out/sendspin-cli"}
	[ -x "$SENDSPIN_CLI" ] || { echo "no sendspin-cli at $SENDSPIN_CLI (run rootfs/src/sendspin/build.sh first)"; exit 1; }
	install -m 755 "$SENDSPIN_CLI" $R/usr/local/bin/sendspin-cli
	SENDSPIN_BIN=/usr/local/bin/sendspin-cli
fi
log "linux-voice-assistant"
# TensorFlow Lite C for the wakeword models: the tensorflow-lite-c package
# (tsx-aports), else built from source by rootfs/voice/build-tflite.sh (never
# committed) and read from voice/tflite/ here, the same as sendspin-cli above:
# a local build runs it by hand first.
if [ $TSXREPO = 1 ]; then
	TFLITE_SO=/usr/lib/libtensorflowlite_c.so sh "$HERE/voice/install-lva.sh" $R
else
	[ -s "$HERE/voice/tflite/libtensorflowlite_c.so" ] || echo "WARNING: no voice/tflite/libtensorflowlite_c.so (run rootfs/voice/build-tflite.sh first); install-lva.sh will fail its checksum check"
	sh "$HERE/voice/install-lva.sh" $R
fi
echo "cage $CAGE_VER + argb8888-fallback.patch (built from source, sha256 $CAGE_SHA256)" > $R/usr/share/tsx-cage.version
chown -R 0:0 $R/etc $R/usr/local

# DSP: TFA9890 CoolFlux DSP tuning containers (.cnt). These are Jabil/NXP
# proprietary binaries (speaker model, patch, presets) and must NOT be copied
# into the overlay or published anywhere; install them from the local
# Android vendor tree at build time only, straight into the rootfs image.
# Missing containers are a warning, not a build failure: tsx-tfa-dsp
# checks for the file at load time and does nothing if it is absent.
TFA_VENDOR_LOCAL=${TFA_VENDOR_LOCAL:-"$HERE/vendor-local/tfa9890"}
TFA_VENDOR_SRC=${TFA_VENDOR_SRC:-}   # required (no default): path to the vendor's device_amlogic_common/audio/tfa9890 tree
TFA_VENDOR_FETCH=${TFA_VENDOR_FETCH:-yes}
log "TFA9890 DSP containers: $TFA_VENDOR_LOCAL first, then $TFA_VENDOR_SRC (proprietary, not published)"
if [ "$TFA_VENDOR_FETCH" != no ]; then
	tfa_missing=0
	for name in settings_yushan settings_yushan_2nd settings_yushan_3rd; do
		[ -r "$TFA_VENDOR_LOCAL/$name/stereo.cnt" ] || tfa_missing=1
	done
	if [ "$tfa_missing" = 1 ]; then
		log "vendor-local/tfa9890 incomplete; fetching from Crestron's public firmware .puf (see ../vendor-fetch.sh)"
		sh "$HERE/vendor-fetch.sh" || echo "WARNING: vendor-fetch.sh failed (no network in the build container?); falling back to $TFA_VENDOR_SRC or leaving the variant absent (set TFA_VENDOR_FETCH=no to skip this step)"
	fi
fi
tfa_found=0
for name in settings_yushan settings_yushan_2nd settings_yushan_3rd; do
	cnt="$TFA_VENDOR_LOCAL/$name/stereo.cnt"
	[ -r "$cnt" ] || cnt="$TFA_VENDOR_SRC/$name/stereo.cnt"
	if [ -r "$cnt" ]; then
		mkdir -p "$R/usr/local/share/tsx/tfa9890/$name"
		install -m 644 "$cnt" "$R/usr/local/share/tsx/tfa9890/$name/stereo.cnt"
		tfa_found=$((tfa_found + 1))
	else
		echo "WARNING: missing $name/stereo.cnt in $TFA_VENDOR_LOCAL or $TFA_VENDOR_SRC (TFA9890 DSP variant $name will not be available on the panel)"
	fi
done
[ "$tfa_found" -gt 0 ] || echo "WARNING: no TFA9890 .cnt containers found in $TFA_VENDOR_LOCAL or $TFA_VENDOR_SRC (tsx-tfa-dsp will have nothing to load; set TFA_VENDOR_LOCAL/TFA_VENDOR_SRC to override)"

# browser: re-enable Chromium's ES 3.0 -> 2.0 context fallback (2-byte patch,
# src/chromium-es2/). Only a build listed in sigs.json with the exact
# instruction bytes is patched; anything else keeps the stock binary (warning,
# the build goes on). Record: /etc/tsx/chromium-es2-patched. The unpatched
# binary is not kept (192 MB); tsx-chromium-es2 revert or apk fix chromium.
CHROMIUM_ES2_PATCH=${CHROMIUM_ES2_PATCH:-1}
ES2_RESULT="not requested (CHROMIUM_ES2_PATCH=$CHROMIUM_ES2_PATCH)"
if [ $TSXREPO = 1 ]; then
	# tsx-xx60-chromium: patched when the package was built; only verify
	log "chromium: tsx-xx60-chromium (ES2 patch built into the package)"
	apk add -q --no-cache python3 >/dev/null || echo "WARNING: python3 for the patch tool not installed"
	if [ -r $R/etc/tsx/chromium-es2-patched ] && python3 "$HERE/src/chromium-es2/patch-chromium.py" --check $R/usr/lib/chromium/chromium >/dev/null; then
		. $R/etc/tsx/chromium-es2-patched
		ES2_RESULT="tsx-xx60-chromium: $BUILD, patched (verified), sha256 $SHA256_PATCHED"
	else
		ES2_RESULT="tsx-xx60-chromium: patch NOT verified (software rendering?)"
		echo "WARNING: $ES2_RESULT"
	fi
elif [ "$CHROMIUM_ES2_PATCH" = 1 ]; then
	log "chromium ES2 fallback patch"
	rm -f $R/etc/tsx/chromium-es2-patched
	apk add -q --no-cache python3 >/dev/null || echo "WARNING: python3 for the patch tool not installed"
	if python3 "$HERE/src/chromium-es2/patch-chromium.py" $R/usr/lib/chromium/chromium \
		--sidecar $R/etc/tsx/chromium-es2-patched --target-path /usr/lib/chromium/chromium; then
		. $R/etc/tsx/chromium-es2-patched
		ES2_RESULT="applied: $BUILD, $OFFSET $ORIG->$PATCHED, sha256 $SHA256_ORIG -> $SHA256_PATCHED"
	else
		rm -f $R/etc/tsx/chromium-es2-patched
		ES2_RESULT="NOT applied (unknown build or signature mismatch; stock binary, software rendering)"
		echo "WARNING: chromium ES2 patch NOT applied: $ES2_RESULT"
	fi
fi
echo "chromium-es2-patch: $ES2_RESULT"

# every binary built above must find its shared libraries in the image
# (a package missing from packages.txt, e.g. libusb for tsx-ledbar, only
# shows up on the panel otherwise: "Error loading shared library")
log "shared library check"
for bin in /usr/local/sbin/tsx-idled /usr/local/sbin/tsx-buttons /usr/local/bin/tsx-ledbar \
	/usr/local/bin/tsx-peak /usr/local/bin/tsx-overlay /usr/local/bin/tsx-splash /usr/bin/cage $SENDSPIN_BIN; do
	out=$(chroot $R /lib/ld-musl-armhf.so.1 --list "$bin" 2>&1) || true
	if printf '%s\n' "$out" | grep -qE 'Error (loading|relocating)|not found'; then
		printf '%s\n' "$out" | head -n 5
		echo "ERROR: $bin: missing shared libraries (add the package to packages.txt)"; exit 1
	fi
done

log "users, services"
chroot $R /bin/sh -e <<'CH'
addgroup -S seat 2>/dev/null || true
addgroup -S render 2>/dev/null || true
adduser -D -H -h /var/lib/kiosk -s /sbin/nologin -g "kiosk browser" kiosk
for g in video input seat render audio; do addgroup kiosk $g 2>/dev/null || true; done
mkdir -p /var/lib/kiosk && chown kiosk:kiosk /var/lib/kiosk
# on-panel setup page (docs/rootfs.md "Setup page"): deliberately its OWN
# unprivileged user, not "kiosk" -- it parses HTTP from the LAN before any
# pairing has happened, a smaller and different trust boundary than the
# always-unsandboxed browser, and it never needs kiosk's video/input/audio
# group access. No home directory; talks to root only through
# tsx-setup-helper's FIFOs (group tsx-setup, created by that service).
adduser -D -H -s /sbin/nologin -g "on-panel setup page" tsx-setup
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update add $s sysinit; done
for s in root localmount tsx-data tsx-config modules sysctl hostname bootmisc syslog swclock seedrng tsx-setup tsx-hostname udev-postmount machine-id; do
	[ -e /etc/init.d/$s ] && rc-update add $s boot || echo "no service $s"
done
for s in networking chronyd sshd seatd crond watchdog tsx-idled tsx-cpufreq tsx-buttons tsx-als tsx-ledbar tsx-audio tsx-tfa-dsp dbus avahi-daemon tsx-sendspin tsx-panelctl tsx-esphome tsx-mqtt tsx-autoupdate kiosk tsx-boot-ok local; do
	[ -e /etc/init.d/$s ] && rc-update add $s default || { echo "MISSING service $s"; exit 1; }
done
for s in mount-ro killprocs savecache; do rc-update add $s shutdown; done
echo tsx-kiosk > /etc/hostname
printf '127.0.0.1\tlocalhost tsx-kiosk\n::1\t\tlocalhost\n' > /etc/hosts
mkdir -p /etc/crontabs && touch /etc/crontabs/root
# ssh: root with password or key (same as the rescue image; change on deploy)
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# allow ssh -L (DevTools tunnel for the first HA login); Alpine ships "no"
sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding local/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
# U-Boot env tool: never use Android's /dev/mmcblk0 copy by accident
rm -f /etc/fw_env.config
CH
H=$(echo tsx | mkpasswd -m sha-512 -s); case "$H" in \$6\$*) ;; *) echo "password hash failed"; exit 1;; esac
sed -i "s|^root:[^:]*:|root:$H:|" $R/etc/shadow
if [ -s "$HERE/authorized_keys" ]; then
	mkdir -p $R/root/.ssh; cp "$HERE/authorized_keys" $R/root/.ssh/; chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi

log "blank cursor theme"
# one 1x1 fully transparent Xcursor image
C=$R/usr/share/tsx/cursors/blank/cursors; mkdir -p $C
printf 'Xcur\020\000\000\000\000\000\001\000\001\000\000\000' > $C/left_ptr
printf '\002\000\375\377\030\000\000\000\034\000\000\000' >> $C/left_ptr     # toc: type image, size 24, pos 28
printf '\044\000\000\000\002\000\375\377\030\000\000\000\001\000\000\000' >> $C/left_ptr  # chunk hdr 36, type, size 24, v1
printf '\001\000\000\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' >> $C/left_ptr # w h xhot yhot delay
printf '\000\000\000\000' >> $C/left_ptr                                     # ARGB pixel (transparent)
for n in default arrow top_left_arrow pointer hand hand1 hand2 text xterm ibeam crosshair \
	 wait watch progress grab grabbing move all-scroll not-allowed col-resize row-resize \
	 e-resize w-resize n-resize s-resize ns-resize ew-resize nesw-resize nwse-resize \
	 context-menu help cell copy alias no-drop vertical-text zoom-in zoom-out; do
	ln -sf left_ptr $C/$n
done
printf '[Icon Theme]\nName=blank\n' > $R/usr/share/tsx/cursors/blank/index.theme
ln -sfn blank $R/usr/share/tsx/cursors/default

log "trim"
# /etc/machine-id: the dbus apk package's own post-install trigger runs
# dbus-uuidgen (or equivalent) against THIS build container the moment
# `apk add` installs it, baking one fixed id into the image -- every panel
# flashed from the same rootfs.tar.gz would then share that identical id
# until the next rebuild. Ship it empty instead: /etc/init.d/machine-id
# (OpenRC's own script, part of the openrc package, now added to the boot
# runlevel above) only fills it in `if [ -s /etc/machine-id ]; then return
# 0; fi` -- i.e. exactly when empty/missing -- so each unit's first real
# boot generates its own, once, straight onto that unit's own root fs.
: > $R/etc/machine-id
# Chromium UI locales: keep en-US only
[ -d $R/usr/lib/chromium/locales ] && find $R/usr/lib/chromium/locales -name '*.pak' ! -name 'en-US.pak' -delete
# man pages / doc / info: never read on a headless kiosk
rm -rf $R/usr/share/man $R/usr/share/doc $R/usr/share/info
# apk's own index cache (APKINDEX*.tar.gz, ~3 MiB); apk info in the manifest
# step below re-populates this, so it is also cleared a second time just
# before the tarball is made
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar
# locale data (gettext .mo files): nothing in this package set currently
# ships /usr/share/locale, but keep only en/C defensively if that changes
[ -d $R/usr/share/locale ] && find $R/usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name C -exec rm -rf {} +
# py3-numpy-tests (~13 MiB): apk's install_if binds it to py3-numpy, so
# `apk del --root $R py3-numpy-tests` is refused ("not removed due to:
# py3-numpy-tests: py3-numpy") as long as py3-numpy stays installed
# (verified against this Alpine release); remove the test trees directly
find $R/usr/lib/python3*/site-packages/numpy -depth -type d -name tests -exec rm -rf {} +
# sway-wallpapers (~5 MiB, /usr/share/backgrounds/sway): same install_if
# binding to sway blocks `apk del`. Unused here: the kiosk's generated sway
# config uses the boot splash as the only background (usr/local/bin/kiosk-session),
# so no wallpaper path is ever read
rm -rf $R/usr/share/backgrounds/sway
# python .pyc bytecode caches (~25 MiB combined): apk's split -pyc
# subpackages (python3-pycache-pyc0, py3-numpy-pyc) are install_if-bound to
# python3/py3-numpy the same way py3-numpy-tests is above, so `apk del` is
# refused there too; the interpreter just recompiles bytecode on first
# import (a few ms, once, per file) so dropping the caches is safe
find $R/usr/lib/python3* -depth \( -type d -name '__pycache__' -o -type f -name '*.pyc' \) -exec rm -rf {} +

copied=0
for kv in ${KVER:-}; do
	if [ $TSXREPO = 1 ] && [ -d "$R/lib/modules/$kv" ]; then
		# installed (and owned) by tsx-xx60-kernel-<flavor>: keep the package's tree
		log "kernel modules $kv: from its tsx-xx60-kernel package"
		copied=$((copied + 1))
	elif [ -d "/modules/lib/modules/$kv" ]; then
		[ $TSXREPO = 1 ] && echo "WARNING: kernel modules $kv: no tsx-xx60-kernel package in $TSX_APK_LOCAL has them; copied as unowned files"
		log "kernel modules $kv"
		mkdir -p $R/lib/modules
		cp -a "/modules/lib/modules/$kv" $R/lib/modules/
		rm -f "$R/lib/modules/$kv/build" "$R/lib/modules/$kv/source"
		depmod -b $R "$kv" 2>/dev/null || true
		copied=$((copied + 1))
	else
		echo "WARNING: no modules for $kv at /modules/lib/modules/$kv"
	fi
done
if [ "$copied" -gt 0 ]; then
	chown -R 0:0 $R/lib/modules
else
	log "no kernel modules copied (KVER=${KVER:-unset})"
fi

log "manifest and sizes"
mkdir -p "$OUT"
apk info --root $R -v 2>/dev/null | sort > "$OUT/rootfs.manifest"
{
	echo "rootfs total: $(du -sm $R | cut -f1) MiB"
	echo "largest packages (installed size):"
	apk info --root $R -s $(apk info --root $R 2>/dev/null) 2>/dev/null | awk '
		/ installed size:$/ {p=$1; sub(/-[0-9].*$/, "", p); next}
		NF==2 && p != "" {v=$1; u=$2; if (u=="KiB") v/=1024; if (u=="GiB") v*=1024; if (u=="B") v/=1048576; printf "%8.1f MiB  %s\n", v, p; p=""}' | sort -rn | head -25
	echo "largest directories:"
	du -xm -d 3 $R/usr $R/lib 2>/dev/null | sort -rn | head -15 | sed "s|$R||"
	echo "chromium-es2-patch: $ES2_RESULT"
	if [ $TSXREPO = 1 ]; then echo "tsx-aports: installed from a local tree: $TSXPKGS"
	else echo "tsx-aports: no local tree (TSX_APK_LOCAL unset): local builds of sendspin-cli/TFLite, Alpine chromium + in-place patch, unowned module trees"; fi
	echo "tsx-aports: panel repository URL $TSX_APK_URL/$ALPINE/{common,xx60}"
	ls $R/lib/modules 2>/dev/null | sed 's/^/kernel modules: /'
} > "$OUT/rootfs.sizes"
cat "$OUT/rootfs.sizes"

# the apk info calls above re-populate $R/var/cache/apk with the index cache
# cleared earlier in "trim"; clear it again so it doesn't ship in the image
rm -rf $R/var/cache/apk/*

log "tarball"
tar -C $R --numeric-owner -cpf - . | gzip -6 > "$OUT/rootfs.tar.gz"
log "ext4 image (${IMG_MB} MiB, label tsxroot)"
rm -f "$OUT/rootfs.ext4"
# no metadata_csum_seed / orphan_file, which the vendor 3.10
# kernel (Android on the same p5) rejects
mke2fs -q -t ext4 -O ^metadata_csum_seed,^orphan_file -L tsxroot -m 1 -d $R "$OUT/rootfs.ext4" "${IMG_MB}M"
e2fsck -fn "$OUT/rootfs.ext4" >/dev/null && echo "e2fsck clean"
(cd "$OUT" && sha256sum rootfs.tar.gz rootfs.ext4 > rootfs.sha256)
chown "$UIDGID" "$OUT"/rootfs.*
ls -ls "$OUT"/rootfs.*
