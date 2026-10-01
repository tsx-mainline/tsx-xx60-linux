#!/bin/sh
# Runs inside an armv7 Alpine container (see ../build-rootfs.sh), as root.
# Env:
#   ALPINE         branch, for example v3.24
#   KVER           module dir name(s) under /modules/lib/modules, space-separated
#                  for more than one kernel, or empty
#   OUT            output dir
#   UIDGID         owner of the outputs
#   IMG_MB         ext4 size in MiB
#   TSX_APK_URL    base URL of the apk repository of this project. The script
#                  writes it into /etc/apk/repositories of the panel and never
#                  fetches it.
#   PROFILE        console, kiosk or ha (default ha). What the image holds:
#                  profiles/*.list, profile.sh and docs/rootfs.md "Profiles".
#   TSX_DEV_ROOT_HASH  optional. A crypt(3) hash that becomes the root password
#                  of the image. For our own test builds only. Without it, the
#                  image has no root password (docs/rootfs.md "Root login").
#   TSX_APK_LOCAL  optional. A local copy of the published tree of that
#                  repository, <ALPINE>/common and <ALPINE>/xx60. The script
#                  installs packages-tsx.txt from it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
R=/build/rootfs; mkdir -p /build
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
log() { echo "== $*"; }

# The profile of the image. has KIND NAME asks the lists in profiles/.
PROFILE=${PROFILE:-ha}
sh "$HERE/profile.sh" includes "$PROFILE" >/dev/null || exit 1
has() { sh "$HERE/profile.sh" has "$PROFILE" "$1" "$2"; }
log "profile $PROFILE"

printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "$ALPINE" "$MIRROR" "$ALPINE" > /etc/apk/repositories
apk update -q

# The apk repository of this project (tsx-aports). The panel lists it first in
# /etc/apk/repositories at TSX_APK_URL. On the panel, panel.conf APK_URL
# overrides that URL (tsx-config apply). The image gets the packages of the
# repository (packages-tsx.txt) only from a local copy of the published tree
# (TSX_APK_LOCAL). The build never depends on a reachable TSX_APK_URL.
# Without a local copy, the image carries what those packages replace (see
# packages-tsx.txt).
TSX_APK_URL=${TSX_APK_URL:-https://tsx-aports.unexceptional.net}; TSX_APK_URL=${TSX_APK_URL%/}
TSX_APK_LOCAL=${TSX_APK_LOCAL:-}
TSXREPO=0
if [ -n "$TSX_APK_LOCAL" ]; then
	for c in common xx60; do
		[ -r "$TSX_APK_LOCAL/$ALPINE/$c/armv7/APKINDEX.tar.gz" ] || { echo "TSX_APK_LOCAL: no $ALPINE/$c/armv7/APKINDEX.tar.gz under $TSX_APK_LOCAL"; exit 1; }
	done
	TSXREPO=1
fi
apk add -q --no-cache build-base linux-headers e2fsprogs tar gzip >/dev/null

log "compile tsx-idled"
gcc -O2 -Wall -s -o /build/tsx-idled "$HERE/src/tsx-idled.c"
gcc -O2 -Wall -s -o /build/tsx-buttons "$HERE/src/tsx-buttons.c"   # front-panel
apk add -q --no-cache libusb-dev >/dev/null                           # LED bar
gcc -O2 -Wall -s -o /build/tsx-ledbar "$HERE/src/tsx-ledbar.c" -lusb-1.0
gcc -O2 -Wall -s -o /build/tsx-peak "$HERE/src/tsx-peak.c" -lm       # audio
# Boot splash: the same tool and artwork as the initramfs. OpenRC sends status
# updates to it, and the compositor uses it as the background (docs/boot.md
# "Boot splash").
gcc -O2 -Wall -s -o /build/tsx-splash "$HERE/src/tsx-splash.c"
sh "$HERE/splash/mksplash.sh" /build/splash-out >/dev/null

if has step compile-kiosk; then
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

	# Quick-settings overlay (sway layer-shell client, kiosk user). The layer-shell
	# protocol comes from wlr-protocols. The overlay references xdg_popup, so the
	# build also links the xdg-shell glue.
	log "build tsx-overlay"
	apk add -q --no-cache cairo-dev wlr-protocols >/dev/null
	P=/build/tsx-overlay-proto; rm -rf $P; mkdir -p $P
	LS=/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml
	wayland-scanner client-header $LS $P/wlr-layer-shell-unstable-v1-client-protocol.h
	wayland-scanner private-code $LS $P/wlr-layer-shell-unstable-v1-protocol.c
	wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $P/xdg-shell-protocol.c
	gcc -O2 -Wall -s -I$P -o /build/tsx-overlay "$HERE/src/tsx-overlay.c" $P/*.c \
		$(pkg-config --cflags --libs cairo wayland-client) -lm
fi

log "install packages ($ALPINE, armv7)"
rm -rf $R; mkdir -p $R/etc/apk/keys
# Trust the signing key of this project (the same .pub that the tsx-keys package ships).
cp "$HERE"/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
cp -a /etc/apk/keys/. $R/etc/apk/keys/
# The profile picks the packages (profiles/*.list). The lines keep the order and
# the pins of packages.txt and packages-tsx.txt.
PKGS=$(sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages.txt" | tr '\n' ' ')
: > /build/repositories
if [ $TSXREPO = 1 ]; then
	TSXPKGS=$(sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages-tsx.txt" | tr '\n' ' ')
	log "tsx-aports packages from $TSX_APK_LOCAL: $TSXPKGS"
	# tsx-xx60-chromium provides chromium and tsx-xx60-wlroots0.20 provides
	# wlroots0.20, so the Alpine lines for these two are dropped.
	PKGS="$(sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages.txt" | grep -v -e '^chromium=' -e '^wlroots0.20$' | tr '\n' ' ') $TSXPKGS"
	printf '%s/%s/common\n%s/%s/xx60\n' "$TSX_APK_LOCAL" "$ALPINE" "$TSX_APK_LOCAL" "$ALPINE" > /build/repositories
fi
cat /etc/apk/repositories >> /build/repositories
apk add --root $R --initdb --no-cache -q --keys-dir /etc/apk/keys \
	--repositories-file /build/repositories $PKGS
cp -a /etc/apk/keys $R/etc/apk/
# The panel list has the two repositories of this project first. That way
# tsx-xx60-chromium wins the tie with the Alpine chromium (tsx-aports README
# "Which chromium wins"). tsx-config apply writes this block, marker line
# included.
{
	echo "# tsx-aports (tsx-config apply. panel.conf APK_URL)"
	echo "$TSX_APK_URL/$ALPINE/common"
	echo "$TSX_APK_URL/$ALPINE/xx60"
	cat /etc/apk/repositories
} > $R/etc/apk/repositories

log "overlay ($PROFILE)"
sh "$HERE/profile.sh" stage "$PROFILE" $R
if has step chromium-es2; then
	# tsx-autoupdate applies the Chromium ES2 patch again on the panel after an
	# upgrade. Ship the patch tool and the signature list from their single
	# source in src/.
	install -D -m 644 "$HERE/src/chromium-es2/patch-chromium.py" $R/usr/local/share/tsx/chromium-es2/patch-chromium.py
	install -D -m 644 "$HERE/src/chromium-es2/sigs.json" $R/usr/local/share/tsx/chromium-es2/sigs.json
fi
# The repository URL of the build. tsx-config apply uses it when panel.conf
# has no APK_URL.
printf '%s\n' "$TSX_APK_URL" > $R/etc/tsx/apk-url.default
# The build id for tsx-autoupdate and the HA update entity (installed_version).
printf '%s\n' "${TSX_BUILD_ID:-$(date -u +%Y%m%d%H%M)}" > $R/etc/tsx/build-id
# The floor of the boot clock (the panel has no RTC). swclock sets the clock
# from the mtime of this file, so a new image never boots earlier than its
# build time. /etc/periodic/15min/tsx-savetime keeps the mtime current while
# NTP has the time.
mkdir -p $R/var/lib/misc && touch $R/var/lib/misc/openrc-shutdowntime
install -m 755 /build/tsx-idled $R/usr/local/sbin/tsx-idled
install -m 755 /build/tsx-buttons $R/usr/local/sbin/tsx-buttons
install -m 755 /build/tsx-ledbar $R/usr/local/bin/tsx-ledbar
if has step compile-kiosk; then
	install -m 755 /build/cage-build/cage $R/usr/bin/cage
	install -m 755 /build/tsx-overlay $R/usr/local/bin/tsx-overlay
fi
install -m 755 /build/tsx-splash $R/usr/local/bin/tsx-splash
mkdir -p $R/usr/share/tsx/splash
cp /build/splash-out/*.ppm /build/splash-out/*.psf $R/usr/share/tsx/splash/
# audio: level meter, Sendspin player. rootfs/src/sendspin/build.sh builds
# sendspin-cli from source. CI runs it before this script. For a local build,
# run it by hand first. The build output is never committed, so this script
# reads it from the output dir of that build.
# voice: the Assist voice satellite linux-voice-assistant (pinned, see
# voice/install-lva.sh below)
install -m 755 /build/tsx-peak $R/usr/local/bin/tsx-peak
SENDSPIN_BIN=
if has step sendspin; then
	if [ $TSXREPO = 1 ]; then
		# The sendspin-cli package installs /usr/bin/sendspin-cli (tsx-sendspin prefers it).
		[ -x $R/usr/bin/sendspin-cli ] || { echo "sendspin-cli package did not install /usr/bin/sendspin-cli"; exit 1; }
		SENDSPIN_BIN=/usr/bin/sendspin-cli
	else
		SENDSPIN_CLI=${SENDSPIN_CLI:-"$HERE/src/sendspin/out/sendspin-cli"}
		[ -x "$SENDSPIN_CLI" ] || { echo "no sendspin-cli at $SENDSPIN_CLI (run rootfs/src/sendspin/build.sh first)"; exit 1; }
		install -m 755 "$SENDSPIN_CLI" $R/usr/local/bin/sendspin-cli
		SENDSPIN_BIN=/usr/local/bin/sendspin-cli
	fi
fi
if has step lva; then
	log "linux-voice-assistant"
	# TensorFlow Lite C for the wakeword models comes from the tensorflow-lite-c
	# package (tsx-aports). Without it, rootfs/voice/build-tflite.sh builds it from
	# source. The build output is never committed, and this script reads it from
	# voice/tflite/, as it does for sendspin-cli above. For a local build, run
	# build-tflite.sh by hand first.
	if [ $TSXREPO = 1 ]; then
		TFLITE_SO=/usr/lib/libtensorflowlite_c.so sh "$HERE/voice/install-lva.sh" $R
	else
		[ -s "$HERE/voice/tflite/libtensorflowlite_c.so" ] || echo "WARNING: no voice/tflite/libtensorflowlite_c.so (run rootfs/voice/build-tflite.sh first). install-lva.sh will fail its checksum check"
		sh "$HERE/voice/install-lva.sh" $R
	fi
fi
has step compile-kiosk && echo "cage $CAGE_VER + argb8888-fallback.patch (built from source, sha256 $CAGE_SHA256)" > $R/usr/share/tsx-cage.version
chown -R 0:0 $R/etc $R/usr/local

# DSP: TFA9890 CoolFlux DSP tuning containers (.cnt). These are proprietary
# Jabil/NXP binaries (speaker model, patch, presets). Do not copy them into
# the overlay or publish them anywhere. Install them only at build time, from
# the local Android vendor tree, straight into the rootfs image.
# A missing container gives a warning, not a build failure. tsx-tfa-dsp checks
# for the file at load time and does nothing if the file is absent.
TFA_VENDOR_LOCAL=${TFA_VENDOR_LOCAL:-"$HERE/vendor-local/tfa9890"}
TFA_VENDOR_SRC=${TFA_VENDOR_SRC:-}   # required, no default: path to the device_amlogic_common/audio/tfa9890 tree of the vendor
TFA_VENDOR_FETCH=${TFA_VENDOR_FETCH:-yes}
log "TFA9890 DSP containers: $TFA_VENDOR_LOCAL first, then $TFA_VENDOR_SRC (proprietary, not published)"
if [ "$TFA_VENDOR_FETCH" != no ]; then
	tfa_missing=0
	for name in settings_yushan settings_yushan_2nd settings_yushan_3rd; do
		[ -r "$TFA_VENDOR_LOCAL/$name/stereo.cnt" ] || tfa_missing=1
	done
	if [ "$tfa_missing" = 1 ]; then
		log "vendor-local/tfa9890 incomplete. Fetching from Crestron's public firmware .puf (see ../vendor-fetch.sh)"
		sh "$HERE/vendor-fetch.sh" || echo "WARNING: vendor-fetch.sh failed (no network in the build container?). Falling back to $TFA_VENDOR_SRC or leaving the variant absent (set TFA_VENDOR_FETCH=no to skip this step)"
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
[ "$tfa_found" -gt 0 ] || echo "WARNING: no TFA9890 .cnt containers found in $TFA_VENDOR_LOCAL or $TFA_VENDOR_SRC (tsx-tfa-dsp will have nothing to load. Set TFA_VENDOR_LOCAL/TFA_VENDOR_SRC to override)"

# browser: enable the Chromium ES 3.0 to 2.0 context fallback again (2-byte
# patch, src/chromium-es2/). The build patches only a build that sigs.json
# lists with the exact instruction bytes. Any other build keeps the stock
# binary. The script then warns and the build goes on. The record is
# /etc/tsx/chromium-es2-patched. The build does not keep the unpatched binary
# (192 MB). To undo the patch, run tsx-chromium-es2 revert or apk fix chromium.
CHROMIUM_ES2_PATCH=${CHROMIUM_ES2_PATCH:-1}
ES2_RESULT="not requested (CHROMIUM_ES2_PATCH=$CHROMIUM_ES2_PATCH)"
if ! has step chromium-es2; then
	ES2_RESULT="none (profile $PROFILE has no browser)"
elif [ $TSXREPO = 1 ]; then
	# The package build already patched tsx-xx60-chromium. Only verify the patch.
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

# Every binary built above must find its shared libraries in the image.
# Otherwise a package missing from packages.txt (for example libusb for
# tsx-ledbar) only shows up on the panel: "Error loading shared library".
log "shared library check"
BINS="/usr/local/sbin/tsx-idled /usr/local/sbin/tsx-buttons /usr/local/bin/tsx-ledbar /usr/local/bin/tsx-peak /usr/local/bin/tsx-splash"
has step compile-kiosk && BINS="$BINS /usr/local/bin/tsx-overlay /usr/bin/cage"
BINS="$BINS $SENDSPIN_BIN"
for bin in $BINS; do
	out=$(chroot $R /lib/ld-musl-armhf.so.1 --list "$bin" 2>&1) || true
	if printf '%s\n' "$out" | grep -qE 'Error (loading|relocating)|not found'; then
		printf '%s\n' "$out" | head -n 5
		echo "ERROR: $bin: missing shared libraries (add the package to packages.txt)"; exit 1
	fi
done

log "users, services"
# The profile decides which services start and which users exist. The lists
# are in profiles/*.list. The chroot shell reads them from its environment.
TSX_SVC_BOOT=$(sh "$HERE/profile.sh" entries "$PROFILE" svc | awk '$1 == "boot" { print $2 }' | tr '\n' ' ')
TSX_SVC_DEFAULT=$(sh "$HERE/profile.sh" entries "$PROFILE" svc | awk '$1 == "default" { print $2 }' | tr '\n' ' ')
TSX_USERS=$(sh "$HERE/profile.sh" entries "$PROFILE" user | tr '\n' ' ')
case "$PROFILE" in console) TSX_HOSTNAME=tsx-console;; *) TSX_HOSTNAME=tsx-kiosk;; esac
export TSX_SVC_BOOT TSX_SVC_DEFAULT TSX_USERS TSX_HOSTNAME
chroot $R /bin/sh -e <<'CH'
case " $TSX_USERS " in *" kiosk "*)
	addgroup -S seat 2>/dev/null || true
	addgroup -S render 2>/dev/null || true
	adduser -D -H -h /var/lib/kiosk -s /sbin/nologin -g "kiosk browser" kiosk
	for g in video input seat render audio; do addgroup kiosk $g 2>/dev/null || true; done
	mkdir -p /var/lib/kiosk && chown kiosk:kiosk /var/lib/kiosk;;
esac
# The on-panel setup page (docs/rootfs.md "Setup page") deliberately has its
# own unprivileged user, not "kiosk". The page parses HTTP from the LAN before
# any pairing has happened. That is a smaller and different trust boundary
# than the browser, which always runs unsandboxed. The page also does not need
# the video, input and audio groups of kiosk. It has no home directory. It
# talks to root only through the FIFOs of tsx-setup-helper (group tsx-setup,
# which that service creates).
case " $TSX_USERS " in *" tsx-setup "*)
	adduser -D -H -s /sbin/nologin -g "on-panel setup page" tsx-setup;;
esac
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update add $s sysinit; done
for s in root localmount modules sysctl hostname bootmisc syslog swclock seedrng udev-postmount machine-id $TSX_SVC_BOOT; do
	[ -e /etc/init.d/$s ] && rc-update add $s boot || echo "no service $s"
done
for s in $TSX_SVC_DEFAULT; do
	[ -e /etc/init.d/$s ] && rc-update add $s default || { echo "MISSING service $s"; exit 1; }
done
for s in mount-ro killprocs savecache; do rc-update add $s shutdown; done
echo "$TSX_HOSTNAME" > /etc/hostname
printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost\n' "$TSX_HOSTNAME" > /etc/hosts
mkdir -p /etc/crontabs && touch /etc/crontabs/root
# ssh: root logs in with a password or a key (the same as the rescue image).
# Change this on deploy.
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# Allow ssh -L (the DevTools tunnel for the first HA login). Alpine ships "no".
sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding local/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
# U-Boot env tool: never use the Android /dev/mmcblk0 copy by accident.
rm -f /etc/fw_env.config
CH
# Root password (docs/rootfs.md "Root login"). A public image has none: the
# field in /etc/shadow is locked ("*"), never empty. The installer stops unless
# it gets a root password or an SSH key. It puts the hash of the password and
# the key in panel.conf, and the first boot applies them (tsx-config apply).
# With a key only, the password stays locked until a person sets one over ssh.
# Only a test build sets a fixed password: TSX_DEV_ROOT_HASH, a crypt(3) hash.
if [ -n "${TSX_DEV_ROOT_HASH:-}" ]; then
	case "$TSX_DEV_ROOT_HASH" in \$6\$*) ;; *) echo "TSX_DEV_ROOT_HASH is not a sha-512 crypt hash (\$6\$...)"; exit 1;; esac
	sed -i "s|^root:[^:]*:|root:$TSX_DEV_ROOT_HASH:|" $R/etc/shadow
	ROOT_PW_RESULT="TSX_DEV_ROOT_HASH (test build, do not publish)"
else
	sed -i "s|^root:[^:]*:|root:*:|" $R/etc/shadow
	ROOT_PW_RESULT="none (locked until the installer or ssh sets one)"
fi
echo "root password: $ROOT_PW_RESULT"
if [ -s "$HERE/authorized_keys" ]; then
	mkdir -p $R/root/.ssh; cp "$HERE/authorized_keys" $R/root/.ssh/; chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi

if has step cursors; then
	log "blank cursor theme"
	# The theme has one 1x1 fully transparent Xcursor image.
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
fi

log "trim"
# /etc/machine-id: the post-install trigger of the dbus apk package runs
# dbus-uuidgen (or equivalent) against this build container when `apk add`
# installs the package. That bakes one fixed id into the image. Every panel
# flashed from the same rootfs.tar.gz would then share that id until the next
# rebuild. Ship the file empty instead. The OpenRC script /etc/init.d/machine-id
# (part of the openrc package, and added to the boot runlevel above) fills it
# in only when it is empty or missing, in this check:
# `if [ -s /etc/machine-id ]; then return 0; fi`
# So the first real boot of each unit generates its own id once, straight onto
# the root fs of that unit.
: > $R/etc/machine-id
# Chromium UI locales: keep only en-US.
[ -d $R/usr/lib/chromium/locales ] && find $R/usr/lib/chromium/locales -name '*.pak' ! -name 'en-US.pak' -delete
# Man pages, docs and info: nobody reads them on a headless kiosk.
rm -rf $R/usr/share/man $R/usr/share/doc $R/usr/share/info
# The apk index cache (APKINDEX*.tar.gz, ~3 MiB). The apk info calls in the
# manifest step below fill it again, so the build clears it a second time
# just before it makes the tarball.
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar
# Locale data (gettext .mo files). Nothing in this package set ships
# /usr/share/locale now. If that changes, keep only en and C.
[ -d $R/usr/share/locale ] && find $R/usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name C -exec rm -rf {} +
# py3-numpy-tests (~13 MiB): the install_if rule of apk binds it to py3-numpy.
# So `apk del --root $R py3-numpy-tests` fails ("not removed due to:
# py3-numpy-tests: py3-numpy") while py3-numpy stays installed (verified
# against this Alpine release). Remove the test trees directly.
[ -d $R/usr/lib/python3*/site-packages/numpy ] && find $R/usr/lib/python3*/site-packages/numpy -depth -type d -name tests -exec rm -rf {} +
# sway-wallpapers (~5 MiB, /usr/share/backgrounds/sway): the same install_if
# binding to sway blocks `apk del`. The image does not use it. The sway config
# that the kiosk generates uses the boot splash as its only background
# (usr/local/bin/kiosk-session), so nothing reads a wallpaper path.
rm -rf $R/usr/share/backgrounds/sway
# Python .pyc bytecode caches (~25 MiB combined). The split -pyc subpackages
# of apk (python3-pycache-pyc0, py3-numpy-pyc) have an install_if binding to
# python3 and py3-numpy, as py3-numpy-tests has above. So `apk del` fails
# there too. The interpreter compiles the bytecode again on the first import
# of each file (a few ms), so dropping the caches is safe.
find $R/usr/lib/python3* -depth \( -type d -name '__pycache__' -o -type f -name '*.pyc' \) -exec rm -rf {} +

copied=0
for kv in ${KVER:-}; do
	if [ $TSXREPO = 1 ] && [ -d "$R/lib/modules/$kv" ]; then
		# The package tsx-xx60-kernel-<flavor> installs and owns this tree. Keep it.
		log "kernel modules $kv: from its tsx-xx60-kernel package"
		copied=$((copied + 1))
	elif [ -d "/modules/lib/modules/$kv" ]; then
		[ $TSXREPO = 1 ] && echo "WARNING: kernel modules $kv: no tsx-xx60-kernel package in $TSX_APK_LOCAL has them. Copied as unowned files"
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
	echo "profile: $PROFILE"
	echo "root password: $ROOT_PW_RESULT"
	if [ $TSXREPO = 1 ]; then echo "tsx-aports: installed from a local tree: $TSXPKGS"
	else echo "tsx-aports: no local tree (TSX_APK_LOCAL unset): local builds of sendspin-cli/TFLite, Alpine chromium + in-place patch, unowned module trees"; fi
	echo "tsx-aports: panel repository URL $TSX_APK_URL/$ALPINE/{common,xx60}"
	ls $R/lib/modules 2>/dev/null | sed 's/^/kernel modules: /'
} > "$OUT/rootfs.sizes"
cat "$OUT/rootfs.sizes"

# The apk info calls above fill $R/var/cache/apk with the index cache again,
# after the "trim" step cleared it. Clear it once more so it does not ship in
# the image.
rm -rf $R/var/cache/apk/*

log "tarball"
tar -C $R --numeric-owner -cpf - . | gzip -6 > "$OUT/rootfs.tar.gz"
log "ext4 image (${IMG_MB} MiB, label tsxroot)"
rm -f "$OUT/rootfs.ext4"
# Do not use metadata_csum_seed or orphan_file. The vendor 3.10 kernel
# (Android on the same p5) rejects them.
mke2fs -q -t ext4 -O ^metadata_csum_seed,^orphan_file -L tsxroot -m 1 -d $R "$OUT/rootfs.ext4" "${IMG_MB}M"
e2fsck -fn "$OUT/rootfs.ext4" >/dev/null && echo "e2fsck clean"
(cd "$OUT" && sha256sum rootfs.tar.gz rootfs.ext4 > rootfs.sha256)
chown "$UIDGID" "$OUT"/rootfs.*
ls -ls "$OUT"/rootfs.*
