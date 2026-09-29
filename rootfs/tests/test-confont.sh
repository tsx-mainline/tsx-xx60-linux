#!/bin/sh
# Host test for the text console font and the ASCII banners (no panel needed):
#   - tsx-confont picks the Terminus font by the framebuffer size (fake sysfs:
#     fb0/modes or fb0/virtual_size) so the console is at least 80x25, falls
#     back to the kernel's default font when nothing fits / no fb / no font,
#     calls setfont on the right tty and never fails;
#   - every text-console path loads it (/init text_console, tsx-autoinstall,
#     tsx-rescue-status) and the initramfs build ships the fonts;
#   - the rescue screen banner and /etc/motd: Tux + figlet smslant
#     "TSX - LINUX" (spaces around the dash), at most 80 columns, the same art
#     in both; a whole rescue frame fits 80x25.
# busybox/dash sh, no compiler. figlet (optional) re-checks the art itself.
set -eu
HERE=$(cd "$(dirname "$0")/../.." && pwd)
CF=$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-confont
RS=$HERE/installer/rescue-v2/overlay/usr/sbin/tsx-rescue-status
MOTD=$HERE/rootfs/overlay/etc/motd
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

# fake font dir: the files only have to exist (tsx-confont never parses them)
mkdir -p "$T/fonts"
for f in ter-116b ter-118b ter-120b ter-122b ter-124b ter-128b ter-132b; do echo x > "$T/fonts/$f.psf"; done
# fakesys NAME [modes-line] [virtual_size]
fakesys() {
	mkdir -p "$T/$1/class/graphics/fb0"
	[ -z "${2:-}" ] || echo "$2" > "$T/$1/class/graphics/fb0/modes"
	[ -z "${3:-}" ] || echo "$3" > "$T/$1/class/graphics/fb0/virtual_size"
}
pick() { TSX_SYSFS=$T/$1 TSX_CONFONT_DIR=${2:-$T/fonts} sh "$CF" -n; }
expect() { # SYS WANT [FONTDIR]
	got=$(pick "$1" "${3:-}")
	[ "$got" = "$2" ] && ok "$1 -> $got" || bad "$1: want '$2', got '$got'"
}

echo "== font choice by framebuffer size =="
fakesys s1280 "U:1280x800p-0"; expect s1280 "ter-132b 80x25"
fakesys s1024 "U:1024x600p-0"; expect s1024 "ter-124b 85x25"
fakesys v1024 "" "1024,600";    expect v1024 "ter-124b 85x25"
fakesys s800 "U:800x480p-0";    expect s800 "ter-118b 80x26"
fakesys s600 "U:600x400p-0";    expect s600 "default"
fakesys nofb;                   expect nofb "default"
# ORIENTATION portrait / portrait-flipped: /init turns the console a quarter
# (fbcon rotate 3 / 1) before tsx-confont, which then sees the width and
# height swapped; landscape-flipped (2) keeps them
rotsys() { fakesys "$1" "$2"; mkdir -p "$T/$1/class/graphics/fbcon"; echo "$3" > "$T/$1/class/graphics/fbcon/rotate"; }
rotsys p1280 "U:1280x800p-0" 3; expect p1280 "ter-120b 80x64"
rotsys q1280 "U:1280x800p-0" 1; expect q1280 "ter-120b 80x64"
rotsys p1024 "U:1024x600p-0" 3; expect p1024 "default"
rotsys f1280 "U:1280x800p-0" 2; expect f1280 "ter-132b 80x25"
rotsys z1024 "U:1024x600p-0" 0; expect z1024 "ter-124b 85x25"
mkdir -p "$T/few"; echo x > "$T/few/ter-116b.psf"
got=$(pick s1280 "$T/few"); [ "$got" = "ter-116b 160x50" ] && ok "only ter-116b shipped -> $got" || bad "few fonts: got '$got'"
got=$(pick s1280 "$T/none"); [ "$got" = "default" ] && ok "no font dir -> default" || bad "no font dir: got '$got'"

echo "== setfont call =="
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" > "%s/setfont.args"\nexit ${SETFONT_RC:-0}\n' "$T" > "$T/bin/setfont"
chmod 755 "$T/bin/setfont"
TSX_SETFONT=$T/bin/setfont TSX_SYSFS=$T/s1024 TSX_CONFONT_DIR=$T/fonts sh "$CF" /dev/tty7 && rc=0 || rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
[ "$(cat "$T/setfont.args" 2>/dev/null)" = "-C /dev/tty7 $T/fonts/ter-124b.psf" ] && ok "setfont -C /dev/tty7 .../ter-124b.psf" || bad "setfont args: $(cat "$T/setfont.args" 2>/dev/null)"
rm -f "$T/setfont.args"
TSX_SETFONT=$T/bin/setfont TSX_SYSFS=$T/s1280 TSX_CONFONT_DIR=$T/fonts sh "$CF" && rc=0 || rc=$?
[ "$(cat "$T/setfont.args" 2>/dev/null)" = "-C /dev/tty0 $T/fonts/ter-132b.psf" ] && ok "default tty /dev/tty0" || bad "setfont args: $(cat "$T/setfont.args" 2>/dev/null)"
TSX_SETFONT=$T/bin/setfont SETFONT_RC=1 TSX_SYSFS=$T/s1280 TSX_CONFONT_DIR=$T/fonts sh "$CF" && rc=0 || rc=$?
[ "$rc" = 0 ] && ok "setfont failing -> still exit 0 (default font stays)" || bad "setfont failure: exit $rc"
rm -f "$T/setfont.args"
TSX_SETFONT=$T/bin/setfont TSX_SYSFS=$T/nofb TSX_CONFONT_DIR=$T/fonts sh "$CF" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/setfont.args" ] && ok "no framebuffer -> no setfont, exit 0" || bad "no fb: rc $rc, setfont called: $(cat "$T/setfont.args" 2>/dev/null)"

echo "== every text-console path loads the font =="
sed -n '/^text_console() {/,/^}/p' "$HERE/rootfs/initramfs/overlay/init" | tr '\n' ' ' > "$T/tc"
grep -q 'tsx-splash console.*rotate_all.*/usr/sbin/tsx-confont' "$T/tc" && ok "/init text_console: bind, turn (fbcon rotate_all), then the font" || bad "/init text_console does not bind + rotate + run tsx-confont in that order"
grep -q '^rescue() {' "$HERE/rootfs/initramfs/overlay/init" && sed -n '/^rescue() {/,/^}/p' "$HERE/rootfs/initramfs/overlay/init" | tr '\n' ' ' | grep -q 'fbrot=0.*text_console' && ok "/init rescue(): landscape text console" || bad "/init rescue() does not reset the console orientation"
for f in "$HERE/installer/initramfs/tsx-autoinstall" "$HERE/rootfs/initramfs/overlay/usr/sbin/tsx-autoinstall"; do
	grep -q 'tsx-splash console.*/usr/sbin/tsx-confont' "$f" && ok "${f#"$HERE"/}" || bad "${f#"$HERE"/} binds the console without tsx-confont"
done
grep -q '^loop) .*lcd_font' "$RS" && ok "tsx-rescue-status loop" || bad "tsx-rescue-status loop does not load the font"
MK=$HERE/rootfs/initramfs/mkinitramfs-switchroot.sh
for f in ter-124b ter-132b; do
	grep -q "for f in .*$f" "$MK" && ok "initramfs ships $f" || bad "initramfs does not ship $f"
done

echo "== banners: Tux + \"TSX - LINUX\" =="
( sed -n '/^splash() {/,/^}/p' "$RS"; echo splash ) > "$T/splash.sh"
sh "$T/splash.sh" > "$T/rescue-banner"
sed -n '/\.--\./,/^\\___)/p' "$MOTD" > "$T/motd-banner"
for b in rescue-banner motd-banner; do
	w=$(awk '{ if (length > m) m = length } END { print m + 0 }' "$T/$b")
	[ "$w" -gt 0 ] && [ "$w" -le 80 ] && ok "$b: $w columns" || bad "$b: $w columns (want 1..80)"
	[ "$(wc -l < "$T/$b")" -eq 7 ] && ok "$b: 7 lines" || bad "$b: $(wc -l < "$T/$b") lines"
done
head -n 6 "$T/rescue-banner" > "$T/a"; head -n 6 "$T/motd-banner" > "$T/b"
cmp -s "$T/a" "$T/b" && ok "rescue screen and motd show the same art" || bad "rescue and motd banners differ"
grep -q '/_/ /___/_/|_|       /____/___/_/|_/\\____/_/|_|' "$T/a" && ok "spaced dash (TSX - LINUX)" || bad "not the \"TSX - LINUX\" art"
if command -v figlet >/dev/null 2>&1 && figlet -f smslant x >/dev/null 2>&1; then
	figlet -f smslant "TSX - LINUX" | sed 's/[[:space:]]*$//' | grep . > "$T/fig"
	sed -n '2,5p' "$T/a" | cut -c15- > "$T/art"
	cmp -s "$T/fig" "$T/art" && ok "art == figlet -f smslant \"TSX - LINUX\" (column 15)" || bad "art differs from figlet output"
else
	echo "  skip: figlet smslant not installed"
fi

echo "== a whole rescue frame fits 80x25 =="
mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\necho "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' > "$T/sbin/ip"
printf '#!/bin/sh\necho 7.2.8-00116-gb5862166389d\n' > "$T/sbin/uname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname"
echo "00:10:7f:00:00:01" > "$T/mac"
echo "v2 2026-09-28T21:30:00-06:00 flavor=stable" > "$T/rver"
printf 'tsx_find_disk() { WHOLE=/dev/null; }\ntsx_pick_fwenv() { :; }\ntsx_env() { echo TSW-1060; }\ntsx_unit_id() { echo 0123456789AB; }\n' > "$T/lib.sh"
echo "rescue image active" > "$T/run/rescue-reason"
echo uboot > "$T/run/tsx-eth0-mac-src"
echo "writing eMMC root (p8)" > "$T/run/tsx-install-state"
echo "314572800 0 838860800 eMMC root" > "$T/run/tsx-progress"
sed -e "s|/usr/share/tsx/tsx-lib.sh|$T/lib.sh|; s|^VERFILE=.*|VERFILE=$T/rver|" \
    -e "s|ip -4 -o addr show eth0|$T/sbin/ip|; s|uname -r|$T/sbin/uname|; s|/sys/class/net/eth0/address|$T/mac|" \
    -e 's|> /dev/kmsg|> /dev/null|' "$RS" > "$T/rs.sh"
TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw sh "$T/rs.sh" once
sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
rows=$(wc -l < "$T/frame"); cols=$(awk '{ if (length > m) m = length } END { print m + 0 }' "$T/frame")
[ "$rows" -le 24 ] && ok "frame: $rows rows (+ the cursor row <= 25)" || bad "frame: $rows rows"
[ "$cols" -le 80 ] && ok "frame: $cols columns" || bad "frame: $cols columns"
grep -q '^kernel            : 7.2.8-00116-gb5862166389d$' "$T/frame" && ok "frame shows the kernel" || bad "no kernel line in the frame"

echo "$N ok, $F failed"
[ "$F" -eq 0 ]
