#!/bin/sh
# Host test for the image profiles (rootfs/profiles/*.list, rootfs/profile.sh).
# It needs no compiler, no container and no panel. It runs the same
# profile.sh that mkrootfs.sh calls, and so checks the file list of each image:
#   - every overlay file and every package is in exactly one list
#   - ha (the default) stages the same overlay as before, with the same
#     packages, services and users
#   - console has no Home Assistant, MQTT, ESPHome, voice, Sendspin or Chromium
#     file, package or service, and no kiosk or setup page
#   - kiosk has the browser and no Home Assistant part
#   - the text login of console, the banner, and the files that only one profile has
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PS=$HERE/profile.sh
OV=$HERE/overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax =="
busybox sh -n "$PS" && ok "profile.sh passes busybox sh -n" || bad "profile.sh: busybox sh -n"
busybox sh -n "$HERE/mkrootfs.sh" && ok "mkrootfs.sh passes busybox sh -n" || bad "mkrootfs.sh: busybox sh -n"

# the build container runs profile.sh with busybox ash and busybox awk
for p in console kiosk ha; do
	eq "$(busybox sh "$PS" entries $p | md5sum)" "$(sh "$PS" entries $p | md5sum)" "busybox gives the same entries as sh for $p"
done

echo "== every overlay file is in exactly one list =="
un=$(sh "$PS" unclassified); eq "$un" "" "no overlay file is missing from the lists"
for l in console kiosk ha; do awk '$1 == "overlay" { print $2 }' "$HERE/profiles/$l.list"; done | sort > "$T/listed"
dups=$(uniq -d "$T/listed"); eq "$dups" "" "no overlay file is in two lists"
stale=
while read -r f; do [ -e "$OV/$f" ] || [ -L "$OV/$f" ] || stale="$stale $f"; done < "$T/listed"
eq "$stale" "" "every listed overlay file exists"

echo "== every package is in exactly one list =="
for l in console kiosk ha; do awk '$1 == "pkg" { print $2 }' "$HERE/profiles/$l.list"; done | sort > "$T/pkgs"
eq "$(uniq -d "$T/pkgs")" "" "no package is in two lists"
for f in packages.txt packages-tsx.txt; do grep -v '^#' "$HERE/$f" | sed 's/=.*//' | grep -v '^$'; done | sort > "$T/pkgfiles"
eq "$(comm -3 "$T/pkgs" "$T/pkgfiles" | tr -d '\t' | tr '\n' ' ')" "" "the lists and packages.txt, packages-tsx.txt name the same packages"

echo "== ha: the same image as before the profiles =="
sh "$PS" stage ha "$T/ha" >/dev/null
(cd "$OV" && find . | sort) > "$T/ov.files"
(cd "$T/ha" && find . | sort) > "$T/ha.files"
eq "$(diff "$T/ov.files" "$T/ha.files" | wc -l | tr -d ' ')" "0" "same file list as the plain overlay"
diff -r "$OV" "$T/ha" >/dev/null && ok "same file contents and modes of links" || bad "ha stage differs from the overlay"
for f in packages.txt packages-tsx.txt; do
	grep -v '^#' "$HERE/$f" > "$T/all.$f"
	sh "$PS" packages ha "$HERE/$f" > "$T/ha.$f"
	cmp -s "$T/all.$f" "$T/ha.$f" && ok "$f: same lines in the same order" || bad "$f: ha differs from the file"
done
want_default="networking chronyd sshd seatd crond watchdog tsx-idled tsx-cpufreq tsx-buttons tsx-als tsx-ledbar tsx-audio tsx-tfa-dsp dbus avahi-daemon tsx-sendspin tsx-panelctl tsx-bt tsx-esphome tsx-mqtt tsx-autoupdate tsx-setup-helper tsx-setupd kiosk tsx-boot-ok local"
eq "$(sh "$PS" entries ha svc | awk '$1 == "default" { print $2 }' | sort | tr '\n' ' ')" "$(echo $want_default | tr ' ' '\n' | sort | tr '\n' ' ')" "ha: same services in the default runlevel"
eq "$(sh "$PS" entries ha svc | awk '$1 == "boot" { print $2 }' | sort | tr '\n' ' ')" "tsx-config tsx-data tsx-hostname tsx-setup " "ha: same tsx services in the boot runlevel"
eq "$(sh "$PS" entries ha user | sort | tr '\n' ' ')" "kiosk tsx-setup " "ha: same users"
for s in compile-kiosk cursors chromium-es2 sendspin lva; do sh "$PS" has ha step $s && ok "ha: build step $s" || bad "ha: no build step $s"; done
[ ! -e "$T/ha/etc/tsx/profile" ] && ok "ha has no profile marker (a missing marker means ha)" || bad "ha has a profile marker"

echo "== console =="
sh "$PS" stage console "$T/console" >/dev/null
(cd "$T/console" && find . \( -type f -o -type l \) | sort) > "$T/console.files"
bad_names=$(grep -E 'mqtt|esphome|voice|sendspin|lva|chromium|kiosk|setupd|setup-helper|tsx-osk|tsx-overlay|kiosk-set-token|\.json$' "$T/console.files")
eq "$bad_names" "" "no Home Assistant, MQTT, ESPHome, voice, Sendspin, Chromium, kiosk or setup file in the staged tree"
for s in compile-kiosk cursors chromium-es2 sendspin lva; do sh "$PS" has console step $s && bad "console: build step $s" || ok "console: no build step $s"; done
pk=$( { sh "$PS" packages console "$HERE/packages.txt"; sh "$PS" packages console "$HERE/packages-tsx.txt"; } | grep -E 'chromium|mosquitto|py3-|mpv|sendspin|tensorflow|sway|seatd|cage|wlroots|squeekboard|wvkbd|mesa|libinput|compat-libdns' )
eq "$pk" "" "no browser, compositor, voice, MQTT or Sendspin package"
for p in openssh-server busybox tsx-keys tsx-xx60-kernel-lts alsa-utils bluez-deprecated python3 libusb; do
	sh "$PS" has console pkg $p && ok "console keeps package $p" || bad "console lacks package $p"
done
sv=$(sh "$PS" entries console svc | awk '{ print $2 }' | grep -E 'kiosk|setup-helper|setupd|mqtt|esphome|sendspin|voice|^tsx-bt$|seatd')
eq "$sv" "" "no kiosk, setup page, HA or seat service"
for s in sshd tsx-config tsx-autoupdate tsx-buttons tsx-als tsx-audio tsx-panelctl tsx-idled; do
	sh "$PS" has console svc $s && ok "console keeps service $s" || bad "console lacks service $s"
done
eq "$(sh "$PS" entries console user | tr '\n' ' ')" "" "console has no kiosk or setup user"
[ -e "$T/console/usr/local/sbin/tsx-config" ] && [ -e "$T/console/usr/local/sbin/tsx-autoupdate" ] && ok "console has tsx-config and tsx-autoupdate" || bad "console lacks tsx-config or tsx-autoupdate"
[ -e "$T/console/usr/local/lib/tsx/board.sh" ] && ok "console has the board file" || bad "console lacks the board file"
[ ! -e "$T/console/etc/kiosk.conf" ] && ok "console: no /etc/kiosk.conf (tsx-idled and tsx-buttons use their built-in defaults)" || bad "console ships /etc/kiosk.conf"
[ -e "$T/console/etc/tsx/panel-board.conf" ] && ok "console has the board values /etc/tsx/panel-board.conf" || bad "console lacks /etc/tsx/panel-board.conf"
grep -q 'command_args="-c /etc/kiosk.conf -c /etc/tsx/panel-board.conf"' "$HERE/overlay/etc/init.d/tsx-idled" && ok "tsx-idled reads the board file after /etc/kiosk.conf" || bad "tsx-idled does not read /etc/tsx/panel-board.conf"
# tsx-data moves /var/lib/sendspin only when the image has the player
dirs_for() { # dirs_for SENDSPIN-INIT-PATH: the DIRS list of tsx-data
	sed -n '/^DIRS=/,/^\[ -e \/etc\/init.d\/tsx-sendspin/p' "$HERE/overlay/etc/init.d/tsx-data" | sed "s#/etc/init.d/tsx-sendspin#$1#" > "$T/dirs.sh"
	sh -c '. "$1"; echo "$DIRS"' sh "$T/dirs.sh"
}
touch "$T/fake-sendspin"
case "$(dirs_for "$T/fake-sendspin")" in *var/lib/sendspin*) ok "tsx-data: the ha profile moves /var/lib/sendspin";; *) bad "tsx-data: no sendspin dir with the player";; esac
case "$(dirs_for "$T/no-such-sendspin")" in *sendspin*) bad "tsx-data: console gets /var/lib/sendspin";; *) ok "tsx-data: console has no /var/lib/sendspin";; esac
grep -q '\[ -r /etc/kiosk.conf \] && \. /etc/kiosk.conf' "$HERE/overlay/etc/init.d/tsx-setup" && ok "tsx-setup (base): reads /etc/kiosk.conf only when it exists" || bad "tsx-setup: unguarded /etc/kiosk.conf"
eq "$(cat "$T/console/etc/tsx/profile" 2>/dev/null)" "console" "console has the marker /etc/tsx/profile"
grep -Eq '^tty1::respawn:/sbin/getty ' "$T/console/etc/inittab" && ok "console: getty on tty1" || bad "console: no getty on tty1"
grep -Eq '^ttyAML0::respawn:/sbin/getty ' "$T/console/etc/inittab" && ok "console: getty on the serial port" || bad "console: no serial getty"
[ -e "$T/console/etc/tsx/boot-verbose" ] && ok "console: the text console is on from the root mount on (boot-verbose)" || bad "console: no boot-verbose flag"
[ -x "$T/console/usr/local/sbin/tsx-banner" ] && [ -x "$T/console/etc/local.d/tsx-banner.start" ] && [ -x "$T/console/etc/udhcpc/post-bound/tsx-banner" ] && ok "console: banner script, boot hook and DHCP hook" || bad "console: banner files missing or not executable"
[ ! -e "$T/console/etc/motd" ] && ok "console: no static motd (tsx-banner writes it)" || bad "console ships a motd of another profile"

echo "== kiosk =="
sh "$PS" stage kiosk "$T/kiosk" >/dev/null
[ -e "$T/kiosk/etc/kiosk.conf" ] && ok "kiosk: has /etc/kiosk.conf" || bad "kiosk lacks /etc/kiosk.conf"
(cd "$T/kiosk" && find . \( -type f -o -type l \) | sort) > "$T/kiosk.files"
bad_names=$(grep -E 'mqtt|esphome|voice|sendspin|lva|kiosk-set-token' "$T/kiosk.files")
eq "$bad_names" "" "no Home Assistant, MQTT, ESPHome, voice or Sendspin file"
for p in chromium sway seatd squeekboard tsx-xx60-chromium; do sh "$PS" has kiosk pkg $p && ok "kiosk has package $p" || bad "kiosk lacks package $p"; done
sh "$PS" has kiosk svc kiosk && ok "kiosk starts the kiosk service" || bad "kiosk: no kiosk service"
for s in tsx-mqtt tsx-esphome tsx-sendspin tsx-bt; do sh "$PS" has kiosk svc $s && bad "kiosk starts $s" || ok "kiosk does not start $s"; done
grep -Eq '^tty[0-9]::' "$T/kiosk/etc/inittab" && bad "kiosk: getty on tty1" || ok "kiosk: no getty on tty1 (the browser owns the screen)"
grep -Eq '^ttyAML0::respawn:/sbin/getty ' "$T/kiosk/etc/inittab" && ok "kiosk: serial getty stays" || bad "kiosk: no serial getty"
eq "$(cat "$T/kiosk/etc/tsx/profile" 2>/dev/null)" "kiosk" "kiosk has the marker /etc/tsx/profile"
[ ! -e "$T/kiosk/etc/tsx/boot-verbose" ] && ok "kiosk: no boot-verbose flag (the splash stays)" || bad "kiosk has the boot-verbose flag"
grep -Eq '^tty[0-9]::' "$T/ha/etc/inittab" && bad "ha: getty on tty1" || ok "ha: no getty on tty1"
grep -Eq '^ttyAML0::respawn:/sbin/getty ' "$T/ha/etc/inittab" && ok "ha: serial getty stays" || bad "ha: no serial getty"
for p in console kiosk ha; do
	grep -qx ttyAML0 "$T/$p/etc/securetty" 2>/dev/null && grep -qx tty1 "$T/$p/etc/securetty" 2>/dev/null \
		&& ok "$p: securetty lets root log in on the serial port and on tty1" || bad "$p: securetty has no ttyAML0 or tty1 (root cannot log in on the console)"
done

echo "== nesting: console in kiosk in ha =="
comm -23 "$T/console.files" "$T/kiosk.files" | grep -v -e etc/inittab -e etc/motd -e etc/tsx/profile -e etc/tsx/banner.art -e etc/local.d/tsx-banner.start -e etc/udhcpc/post-bound/tsx-banner -e etc/tsx/boot-verbose -e usr/local/sbin/tsx-banner > "$T/lost"
eq "$(cat "$T/lost")" "" "every console file is also in kiosk (except the files that only console has)"
(cd "$T/ha" && find . \( -type f -o -type l \) | sort) > "$T/ha.files2"
comm -23 "$T/kiosk.files" "$T/ha.files2" | grep -v etc/tsx/profile > "$T/lost2"
eq "$(cat "$T/lost2")" "" "every kiosk file is also in ha"

echo "== console banner (tsx-banner) =="
BAN=$HERE/profiles/console/overlay/usr/local/sbin/tsx-banner
ART=$HERE/profiles/console/overlay/etc/tsx/banner.art
mkdir -p "$T/run"; echo "TSS-10" > "$T/run/model"
banner() { # banner IP; the files go to $T/issue and $T/motd
	rm -f "$T/issue" "$T/motd"
	env TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP="$1" TSX_NO_RESPAWN=1 sh "$BAN"
}
banner 192.0.2.10 && ok "tsx-banner runs" || bad "tsx-banner failed"
for f in issue motd; do
	grep -q 'model:    TSS-10' "$T/$f" && ok "$f shows the model" || bad "$f lacks the model"
	grep -q 'address:  192.0.2.10' "$T/$f" && ok "$f shows the IP address" || bad "$f lacks the IP address"
	grep -q 'SSH is on' "$T/$f" && ok "$f says that SSH is on" || bad "$f lacks 'SSH is on'"
done
# getty reads \x and %x in /etc/issue as escapes (busybox: an unknown one prints the character).
# Undo that and compare with the art, so the art prints as it is.
sed 's/\\\\/\\/g; s/%%/%/g' "$T/issue" | grep -F -x -f "$ART" > "$T/issue.art"
cmp -s "$T/issue.art" "$ART" && ok "issue: every art line survives the escape rule of getty" || bad "issue: art changes under the escape rule"
grep -F -x -f "$ART" "$T/motd" | cmp -s - "$ART" && ok "motd: has the art" || bad "motd: art differs"
w=$(awk '{ if (length > m) m = length } END { print m + 0 }' "$T/motd")
[ "$w" -le 80 ] && ok "motd: at most 80 columns ($w)" || bad "motd: $w columns"
banner "" && grep -q 'none yet' "$T/issue" && grep -q 'SSH is on' "$T/issue" && ok "no address yet: the banner says so and still says SSH is on" || bad "no-address banner wrong"
before=$(cat "$T/issue"); banner 192.0.2.11; after=$(cat "$T/issue")
[ "$before" != "$after" ] && grep -q 192.0.2.11 "$T/issue" && ok "a new address changes /etc/issue" || bad "new address not in /etc/issue"
# the idle getty restarts only when /etc/issue changed
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "$*" >> "%s/pkill.log"\n' "$T" > "$T/bin/pkill"; chmod 755 "$T/bin/pkill"
run_ban() { TSX_PKILL="$T/bin/pkill" TSX_BANNER_ART="$ART" TSX_ISSUE_FILE="$T/issue" TSX_MOTD_FILE="$T/motd" TSX_RUN="$T/run" TSX_IP="$1" sh "$BAN"; }
rm -f "$T/pkill.log"; run_ban 192.0.2.12; run_ban 192.0.2.12
eq "$(cat "$T/pkill.log" 2>/dev/null | tr '\n' ' ')" "-x getty " "the idle getty ends once for a changed address, and not for the same address"
busybox sh -n "$BAN" && ok "tsx-banner passes busybox sh -n" || bad "tsx-banner: busybox sh -n"

echo "== image.list (build from packages) =="
busybox sh -n "$HERE/initramfs/mkinitramfs-switchroot.sh" && ok "mkinitramfs-switchroot.sh passes busybox sh -n" || bad "mkinitramfs-switchroot.sh: busybox sh -n"
imgs=$(awk '/^[ \t]*(#|$)/ { next } $1 == "image" { print $2 }' "$HERE/profiles/image.list" | sort | tr '\n' ' ')
eq "$imgs" "etc/fstab etc/inittab etc/tsx/profile " "image.list names fstab, inittab and the profile marker"
for p in console kiosk ha; do
	rm -rf "$T/img-$p"; sh "$PS" stage-image $p "$T/img-$p" >/dev/null
	got=$(cd "$T/img-$p" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
	case $p in ha) want="etc/fstab etc/inittab ";; *) want="etc/fstab etc/inittab etc/tsx/profile ";; esac
	eq "$got" "$want" "stage-image $p copies only the image files"
done
cmp -s "$T/img-console/etc/inittab" "$HERE/profiles/console/overlay/etc/inittab" && ok "stage-image console: the console inittab (getty on tty1)" || bad "stage-image console: wrong inittab"
cmp -s "$T/img-kiosk/etc/inittab" "$OV/etc/inittab" && ok "stage-image kiosk: the kiosk inittab" || bad "stage-image kiosk: wrong inittab"
eq "$(cat "$T/img-console/etc/tsx/profile")" console "stage-image console: profile marker"
eq "$(cat "$T/img-kiosk/etc/tsx/profile")" kiosk "stage-image kiosk: profile marker"
for f in $imgs; do [ -e "$OV/$f" ] || [ -e "$HERE/profiles/console/overlay/$f" ] || bad "image.list: $f is nowhere"; done
grep -q '^tsx-rescue-ui=' "$HERE/initramfs/packages.pin" && grep -q '^tsx-splash=' "$HERE/initramfs/packages.pin" && grep -q '^tsx-xx60-board=' "$HERE/initramfs/packages.pin" && ok "initramfs/packages.pin pins the initramfs packages" || bad "initramfs/packages.pin is incomplete"
a=$(TSX_FROM_PACKAGES=0 sh "$HERE/initramfs-stamp.sh"); b=$(TSX_FROM_PACKAGES=1 sh "$HERE/initramfs-stamp.sh")
[ "$a" != "$b" ] && ok "the initramfs stamp differs between the two build modes" || bad "same stamp in both modes"

echo "== usage errors =="
sh "$PS" includes nothing >/dev/null 2>&1 && bad "an unknown profile is accepted" || ok "an unknown profile is refused"

echo "$N passed, $F failed"
[ "$F" = 0 ]
