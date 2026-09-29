#!/bin/bash
# Host test: rootfs/overlay/usr/local/sbin/tsx-config's get/set/unset/show
# parser (docs/rootfs.md "Panel configuration"). No panel, no docker: runs
# the exact same script the panel runs, under busybox ash (the panel's
# shell), against a throwaway file via $TSX_CONF.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/overlay/usr/local/sbin/tsx-config"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-tsx-config: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
CFG="$W/panel.conf"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
run() { TSX_CONF="$CFG" busybox sh "$SCRIPT" "$@"; }

busybox sh -n "$SCRIPT" && ok "busybox sh -n" || bad "busybox sh -n"

echo "== missing file =="
run get KIOSK_URL >/dev/null 2>&1 && bad "get on a missing file should exit non-zero" || ok "get on a missing file exits non-zero"
run show >/dev/null 2>&1 && ok "show on a missing file does not crash" || bad "show on a missing file failed"

echo "== set + get: spaces, '=' in the value, quoting round-trip =="
run set KIOSK_URL "https://ha.example.org/lovelace/default_view?a=1&b=2" || bad "set KIOSK_URL"
[ "$(run get KIOSK_URL)" = "https://ha.example.org/lovelace/default_view?a=1&b=2" ] && ok "get returns the '='-and-query value unchanged" || bad "KIOSK_URL round-trip"
run set MQTT_PASSWORD 'p@ss "word" with \backslash\ and a $dollar `tick and spaces' || bad "set MQTT_PASSWORD"
[ "$(run get MQTT_PASSWORD)" = 'p@ss "word" with \backslash\ and a $dollar `tick and spaces' ] && ok "quotes/backslash/\$/backtick round-trip" || bad "MQTT_PASSWORD round-trip"
[ "$(stat -c '%a' "$CFG")" = 600 ] && ok "file mode 600" || bad "file mode not 600"

echo "== comments and blank lines are tolerated =="
printf '\n# a comment\nPANEL_NAME="Comment-Test"\n' >> "$CFG"
[ "$(run get PANEL_NAME)" = "Comment-Test" ] && ok "get reads a key after blank lines/comments" || bad "comment tolerance"
run show >/dev/null 2>&1 && ok "show does not choke on comments" || bad "show choked on comments"

echo "== HA_TRANSPORT accepts the three valid values =="
for v in esphome mqtt both; do
	run set HA_TRANSPORT "$v" || bad "set HA_TRANSPORT $v"
	[ "$(run get HA_TRANSPORT)" = "$v" ] || bad "get HA_TRANSPORT after set $v"
done
ok "HA_TRANSPORT esphome|mqtt|both round-trip"

echo "== re-set stays a single line (no duplicate KEY=) =="
run set KIOSK_URL "https://ha.example.org/new" || bad "re-set KIOSK_URL"
[ "$(grep -c '^KIOSK_URL=' "$CFG")" = 1 ] && ok "exactly one KIOSK_URL= line" || bad "duplicate KIOSK_URL= lines"

echo "== unset =="
run unset PANEL_NAME || bad "unset PANEL_NAME"
run get PANEL_NAME >/dev/null 2>&1 && bad "PANEL_NAME still readable after unset" || ok "PANEL_NAME gone after unset"

echo "== invalid keys/values rejected =="
run set BOGUS_KEY somevalue >/dev/null 2>&1 && bad "unknown key accepted" || ok "unknown key rejected"
run get BOGUS_KEY >/dev/null 2>&1 && bad "unknown key accepted by get" || ok "unknown key rejected by get"
run set VOICE maybe >/dev/null 2>&1 && bad "VOICE=maybe accepted" || ok "VOICE=maybe rejected"
run set HA_LOGIN_METHOD carrier-pigeon >/dev/null 2>&1 && bad "bad HA_LOGIN_METHOD accepted" || ok "bad HA_LOGIN_METHOD rejected"
run set KERNEL_FLAVOR beta >/dev/null 2>&1 && bad "bad KERNEL_FLAVOR accepted" || ok "bad KERNEL_FLAVOR rejected"
run set HA_TRANSPORT websocket >/dev/null 2>&1 && bad "bad HA_TRANSPORT accepted" || ok "bad HA_TRANSPORT rejected"
run set HA_ALLOW_FROM "192.0.2.5,192.168.1.0/24" && ok "valid HA_ALLOW_FROM (v4 + CIDR) accepted" || bad "valid HA_ALLOW_FROM (v4 + CIDR) rejected"
run set HA_ALLOW_FROM "" && ok "empty HA_ALLOW_FROM (allow any) accepted" || bad "empty HA_ALLOW_FROM rejected"
run set HA_ALLOW_FROM "fe80::1,2001:db8::/32" && ok "valid HA_ALLOW_FROM (v6 + CIDR) accepted" || bad "valid HA_ALLOW_FROM (v6 + CIDR) rejected"
run set HA_ALLOW_FROM "192.0.2.5,*" >/dev/null 2>&1 && bad "HA_ALLOW_FROM with a glob accepted" || ok "HA_ALLOW_FROM with a glob rejected"
run set HA_ALLOW_FROM "999.1.1.1" >/dev/null 2>&1 && bad "HA_ALLOW_FROM with an out-of-range octet accepted" || ok "HA_ALLOW_FROM out-of-range octet rejected"
run set HA_ALLOW_FROM "192.0.2.0/99" >/dev/null 2>&1 && bad "HA_ALLOW_FROM with a bad prefix length accepted" || ok "HA_ALLOW_FROM bad prefix length rejected"
run set HA_ALLOW_FROM "192.0.2.5,-x" >/dev/null 2>&1 && bad "HA_ALLOW_FROM with a leading-dash entry accepted" || ok "HA_ALLOW_FROM leading-dash entry rejected"
run set PANEL_NAME "has spaces" >/dev/null 2>&1 && bad "PANEL_NAME with spaces accepted" || ok "PANEL_NAME with spaces rejected"

echo "== HA_API_KEY: base64 of exactly 32 bytes, or empty =="
K=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
run set HA_API_KEY "$K" && [ "$(run get HA_API_KEY)" = "$K" ] && ok "a generated key is accepted and round-trips" || bad "a generated key was rejected/changed ($K)"
run set HA_API_KEY "" && ok "empty HA_API_KEY (plaintext) accepted" || bad "empty HA_API_KEY rejected"
run set HA_API_KEY "$(head -c 16 /dev/urandom | base64)" >/dev/null 2>&1 && bad "a 16-byte key accepted" || ok "a 16-byte key rejected"
run set HA_API_KEY "$(head -c 33 /dev/urandom | base64)" >/dev/null 2>&1 && bad "a 33-byte key accepted" || ok "a 33-byte key rejected"
run set HA_API_KEY "${K%?}" >/dev/null 2>&1 && bad "a key without its '=' accepted" || ok "a key without its '=' rejected"
run set HA_API_KEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=" >/dev/null 2>&1 && bad "non-canonical base64 accepted" || ok "non-canonical base64 (stray low bits) rejected"
run set HA_API_KEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-_=" >/dev/null 2>&1 && bad "url-safe base64 accepted" || ok "url-safe base64 alphabet rejected (ESPHome uses standard base64)"
run set HA_API_KEY "$K" >/dev/null

echo "== ORIENTATION: the four names of tsx-orientation, nothing else =="
ORI="$HERE/overlay/usr/local/bin/tsx-orientation"
for v in landscape portrait landscape-flipped portrait-flipped; do
	run set ORIENTATION "$v" && [ "$(run get ORIENTATION)" = "$v" ] && busybox sh "$ORI" check "$v" \
		&& ok "ORIENTATION $v accepted (and by tsx-orientation)" || bad "ORIENTATION $v"
done
for v in sideways Portrait 90 "portrait " "" "landscape;reboot"; do
	run set ORIENTATION "$v" >/dev/null 2>&1 && bad "ORIENTATION '$v' accepted" || ok "ORIENTATION '$v' rejected"
	busybox sh "$ORI" check "$v" && bad "tsx-orientation check '$v' accepted" || true
done
run validate ORIENTATION portrait && ok "validate ORIENTATION portrait (the setup page's check)" || bad "validate ORIENTATION portrait"

echo "== a value containing a literal newline is rejected =="
V=$(printf 'line1\nline2')
run set MQTT_USER "$V" >/dev/null 2>&1 && bad "embedded newline accepted" || ok "embedded newline rejected"

echo "== show masks secrets =="
run set HA_TOKEN "abcdefghijklmnopqrstuvwxyz0123456789ABCDEF" || bad "set HA_TOKEN"
# captured into a variable first, not `run show | grep -q ...` directly: under
# pipefail, grep -q's early exit on the first match can SIGPIPE the still-writing
# upstream process, which would make the PIPELINE's exit status that SIGPIPE
# (nonzero) instead of grep's own result (the same class of bug documented in
# installer/emmc/mk-tsxroot-emmc.sh).
SHOWN=$(run show); RC=$?
[ $RC = 0 ] && ok "show itself exits 0 (even though the last known key, SSH_AUTHORIZED_KEY, is unset)" || bad "show exited non-zero ($RC)"
printf '%s\n' "$SHOWN" | grep -q '^HA_TOKEN=abcdefgh' && bad "show printed the raw token" || ok "show masks HA_TOKEN"
printf '%s\n' "$SHOWN" | grep -q '^HA_TOKEN=\*\*\*\*' && ok "show prints a masked placeholder for HA_TOKEN" || bad "show did not mask HA_TOKEN"
printf '%s\n' "$SHOWN" | grep -q '^HA_API_KEY=\*\*\*\*' && ok "show masks HA_API_KEY" || bad "show did not mask HA_API_KEY"
printf '%s\n' "$SHOWN" | grep -q '^KIOSK_URL=https://ha.example.org/new$' && ok "show prints non-secret values in the clear" || bad "show did not print KIOSK_URL in the clear"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-tsx-config || echo FAIL test-tsx-config
exit $F
