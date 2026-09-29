#!/bin/sh
# Host test for the network clock (no RTC on the panel): chrony.conf (DHCP
# sources first, makestep, no initstepslew), the udhcpc option request, the
# udhcpc hook tsx-dhcp-ntp (NTP servers of the lease -> chrony sources, only
# addresses, reload only on a change), the boot-clock floor in the image
# build, and the clock line of `tsx-config show`. busybox/dash sh, no compiler.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd); O=$HERE/overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

echo "== chrony.conf, interfaces, image build =="
C=$O/etc/chrony/chrony.conf
grep -q '^sourcedir /run/chrony-dhcp$' "$C" && ok "sourcedir /run/chrony-dhcp" || bad "no sourcedir"
[ "$(grep -n '^sourcedir' "$C" | cut -d: -f1)" -lt "$(grep -n '^pool' "$C" | cut -d: -f1)" ] && ok "DHCP sources before the pool" || bad "sourcedir after pool"
grep -q '^makestep 1 -1$' "$C" && ok "makestep 1 -1" || bad "no makestep 1 -1"
grep -q '^initstepslew' "$C" && bad "initstepslew is back" || ok "no initstepslew"
grep -q '^[[:space:]]*udhcpc-opts -O ntpsrv$' "$O/etc/network/interfaces" && ok "udhcpc asks for option 42" || bad "no udhcpc-opts -O ntpsrv"
for d in post-bound post-renew; do
	h=$O/etc/udhcpc/$d/tsx-ntp
	[ -x "$h" ] && grep -q '^exec /usr/local/sbin/tsx-dhcp-ntp$' "$h" && ok "udhcpc $d hook" || bad "udhcpc $d hook"
done
grep -q 'touch $R/var/lib/misc/openrc-shutdowntime' "$HERE/mkrootfs.sh" && ok "image ships the swclock file (boot clock floor = build time)" || bad "no swclock floor in mkrootfs.sh"
[ -x "$O/etc/periodic/15min/tsx-savetime" ] && ok "tsx-savetime periodic" || bad "tsx-savetime not executable"

echo "== tsx-dhcp-ntp =="
printf '#!/bin/sh\necho "$*" >> %s/chronyc.log\n' "$T" > "$T/chronyc"; chmod +x "$T/chronyc"
hook() { env TSX_CHRONY_DHCP_DIR="$T/d" TSX_CHRONYC="$T/chronyc" interface=eth0 ntpsrv="$1" sh "$O/usr/local/sbin/tsx-dhcp-ntp"; }
calls() { [ -f "$T/chronyc.log" ] && wc -l < "$T/chronyc.log" | tr -d ' ' || echo 0; }
hook "192.0.2.1 192.0.2.2"
[ "$(cat "$T/d/eth0.sources")" = "server 192.0.2.1 iburst prefer
server 192.0.2.2 iburst prefer" ] && ok "two servers -> two preferred sources" || bad "sources: $(cat "$T/d/eth0.sources" 2>/dev/null)"
[ "$(calls)" = 1 ] && grep -q '^reload sources$' "$T/chronyc.log" && ok "chronyc reload sources" || bad "reload calls: $(calls)"
hook "192.0.2.1 192.0.2.2"; [ "$(calls)" = 1 ] && ok "renew with the same servers: no reload" || bad "reloaded without a change"
hook '192.0.2.9 $(reboot) 1.2.3.4;rm example.org'
[ "$(cat "$T/d/eth0.sources")" = "server 192.0.2.9 iburst prefer" ] && ok "only addresses reach chrony" || bad "sources: $(cat "$T/d/eth0.sources")"
hook ""; [ ! -e "$T/d/eth0.sources" ] && [ "$(calls)" = 3 ] && ok "lease without option 42: sources removed + reload" || bad "no-option lease: $(calls) calls"
hook ""; [ "$(calls)" = 3 ] && ok "still none: no reload" || bad "reloaded for nothing"
[ -z "$(ls "$T/d")" ] && ok "no temp files left" || bad "left: $(ls "$T/d")"

echo "== tsx-config show: clock line =="
printf '#!/bin/sh\nprintf "Reference ID    : 2D3F360D (192.0.2.7)\\nLeap status     : %%s\\n" "$LEAP"\n' > "$T/chronyc"
LEAP=Normal TSX_CHRONYC="$T/chronyc" TSX_CONF="$T/panel.conf" sh "$O/usr/local/sbin/tsx-config" show 2> "$T/err" >/dev/null
grep -q '^# clock: .*NTP synced (192.0.2.7)$' "$T/err" && ok "synced: server shown" || bad "synced line: $(cat "$T/err")"
LEAP='Not synchronised' TSX_CHRONYC="$T/chronyc" TSX_CONF="$T/panel.conf" sh "$O/usr/local/sbin/tsx-config" show 2> "$T/err" >/dev/null
grep -q '^# clock: .*NOT synced yet' "$T/err" && ok "not synced: said so" || bad "not-synced line: $(cat "$T/err")"
TSX_CHRONYC="$T/nochronyc" TSX_CONF="$T/panel.conf" sh "$O/usr/local/sbin/tsx-config" show 2> "$T/err" >/dev/null
grep -q '^# clock' "$T/err" && bad "clock line without chronyc" || ok "no chronyc (build host): no clock line"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-clock || echo FAIL test-clock
exit $F
