#!/bin/bash
# Host test: the panel.conf side of tsx-install-mainline (docs/rootfs.md
# "Panel configuration"). The test needs no docker, no panel and no network.
# It only uses the --dry-run argument validation that tsx-install-mainline
# already does on its own (test-install-mainline-dryrun.sh covers that side).
#   1. --dry-run --config FILE: the script uses the file and skips the prompts.
#      It refuses a missing file up front.
#   2. --dry-run --yes with no --config: the script skips the prompts and
#      notes no panel.conf.
#   3. The prompt flow of installer/lib/tsx-config-prompt.sh, with answers on
#      stdin (a scripted or piped install, or this test). It uses the tsx-config
#      of the panel. So `tsx-config apply` on the panel accepts every value
#      that this flow accepts. The flow asks again after a bad answer and does
#      not accept it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
DRIVER="$HERE/tsx-install-mainline"
TSX_CONFIG_BIN="$HERE/../rootfs/overlay/usr/local/sbin/tsx-config"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-install-mainline-config: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkpayload() {   # a minimal but sha256-consistent v2 payload dir (as test-install-mainline-dryrun.sh)
	local p=$1
	mkdir -p "$p/lts"
	echo fake-rescue > "$p/rescue.img"
	sha256sum < "$p/rescue.img" | awk '{print $1"  rescue.img"}' > "$p/rescue.img.sha256"
	echo fake-root > "$p/lts/root.img"
	echo fake-boot > "$p/lts/boot.img"
	echo "format=tsx-rescue-install-1
kernel_flavor=lts
root_bytes=10
root_sha256=$(sha256sum < "$p/lts/root.img" | cut -d' ' -f1)
boot_sha256=$(sha256sum < "$p/lts/boot.img" | cut -d' ' -f1)" > "$p/lts/manifest"
	(cd "$p/lts" && sha256sum root.img boot.img > SHA256SUMS)
}
mkpayload "$W/payload"

echo "== 1. --dry-run --config FILE: uses the file, prompts skipped =="
TSX_CONF="$W/mine.conf" "$TSX_CONFIG_BIN" set KIOSK_URL "https://ha.example.org/lovelace/home" >/dev/null
OUT=$("$DRIVER" 10.0.0.1 --payload "$W/payload" --kernel lts --config "$W/mine.conf" --dry-run </dev/null 2>&1)
RC=$?
[ $RC = 0 ] && ok "dry-run --config exits 0 (no stdin needed: prompts are skipped)" || bad "dry-run --config failed: $OUT"
echo "$OUT" | grep -q -- "--config $W/mine.conf" && ok "dry-run reports it will use --config verbatim" || bad "dry-run did not mention --config"
echo "$OUT" | grep -qi "prompts would be skipped" && ok "dry-run confirms prompts are skipped with --config" || bad "dry-run did not say prompts are skipped"

echo "== 2. --config with a missing file is refused before anything else =="
OUT=$("$DRIVER" 10.0.0.1 --payload "$W/payload" --kernel lts --config "$W/does-not-exist.conf" --dry-run </dev/null 2>&1)
[ $? -ne 0 ] && ok "missing --config file refused" || bad "missing --config file accepted"
echo "$OUT" | grep -qi "config file not found" && ok "error names the missing file" || bad "error did not name the missing file"

echo "== 3. --dry-run --yes with no --config: prompts skipped, no panel.conf =="
OUT=$("$DRIVER" 10.0.0.1 --payload "$W/payload" --kernel lts --yes --dry-run </dev/null 2>&1)
[ $? = 0 ] && ok "dry-run --yes (no --config) exits 0 with no stdin" || bad "dry-run --yes failed"
echo "$OUT" | grep -qi "no panel.conf would be written" && ok "dry-run --yes reports no panel.conf" || bad "dry-run --yes did not report skipping panel.conf"

echo "== 4. interactive prompts, answers fed on stdin (installer/lib/tsx-config-prompt.sh) =="
PCONF="$W/prompted.conf"
PROMPT_OUT=$(cd "$HERE" && TSX_CONFIG_BIN="$TSX_CONFIG_BIN" bash -c '. lib/tsx-config-prompt.sh; tsx_config_prompt "'"$PCONF"'" ""' 2>&1 <<'EOF'
TSS-10-ABCDEF
https://ha.example.org/lovelace/home
trusted
America/Denver
off

192.0.2.9
192.0.2.5
1883
tss10
hunter2
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host
EOF
)
[ -s "$PCONF" ] && ok "prompt flow produced a panel.conf" || bad "no panel.conf produced (output: $PROMPT_OUT)"
[ "$(stat -c '%a' "$PCONF" 2>/dev/null)" = 600 ] && ok "prompted panel.conf is mode 600" || bad "prompted panel.conf mode wrong"
GOT=$(TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get PANEL_NAME 2>/dev/null)
[ "$GOT" = TSS-10-ABCDEF ] && ok "PANEL_NAME answer landed" || bad "PANEL_NAME wrong: got '$GOT'"
GOT=$(TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get HA_LOGIN_METHOD 2>/dev/null)
[ "$GOT" = trusted ] && ok "HA_LOGIN_METHOD=trusted (no HA_TOKEN prompt followed it)" || bad "HA_LOGIN_METHOD wrong: got '$GOT'"
TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get HA_TOKEN >/dev/null 2>&1 && bad "HA_TOKEN got set despite trusted login" || ok "HA_TOKEN correctly left unset (trusted login)"
GOT=$(TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get HA_ALLOW_FROM 2>/dev/null)
[ "$GOT" = 192.0.2.9 ] && ok "HA_ALLOW_FROM answer landed" || bad "HA_ALLOW_FROM wrong: got '$GOT'"
GOT=$(TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get MQTT_PASSWORD 2>/dev/null)
[ "$GOT" = hunter2 ] && ok "MQTT_PASSWORD answer landed unmasked in the actual file" || bad "MQTT_PASSWORD wrong"
echo "$PROMPT_OUT" | grep -q '^MQTT_PASSWORD=\*\*\*\*' && ok "the printed summary masks MQTT_PASSWORD" || bad "printed summary did not mask MQTT_PASSWORD"
GOT=$(TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get HA_API_KEY 2>/dev/null)
[ ${#GOT} = 44 ] && ok "a blank answer to the encryption prompt generated an HA_API_KEY (default yes)" || bad "no HA_API_KEY generated (got '$GOT')"
case "$PROMPT_OUT" in *"$GOT"*) bad "the prompt printed the key before the end of the install";; *) ok "the key is not printed during the prompts";; esac
echo "$PROMPT_OUT" | grep -q '^HA_API_KEY=\*\*\*\*' && ok "the printed summary masks HA_API_KEY" || bad "printed summary did not mask HA_API_KEY"
OUT=$(cd "$HERE" && TSX_CONFIG_BIN="$TSX_CONFIG_BIN" bash -c '. lib/tsx-config-prompt.sh; TSX_NEW_API_KEY='"$GOT"'; tsx_config_print_api_key 10.0.0.1' 2>&1)
case "$OUT" in *"$GOT"*"Add integration > ESPHome"*) ok "tsx_config_print_api_key shows the key with the Home Assistant steps";; *) bad "tsx_config_print_api_key output wrong: $OUT";; esac

echo "== reinstall: an existing HA_API_KEY is kept, not asked again =="
PCONF3="$W/prompted3.conf"
PROMPT_OUT3=$(cd "$HERE" && TSX_CONFIG_BIN="$TSX_CONFIG_BIN" bash -c '. lib/tsx-config-prompt.sh; tsx_config_prompt "'"$PCONF3"'" "'"$PCONF"'"; echo "NEW=[$TSX_NEW_API_KEY]"' 2>&1 <<'EOF'
TSS-10-ABCDEF
https://ha.example.org/lovelace/home
trusted
America/Denver
off
192.0.2.9
EOF
)
[ "$(TSX_CONF="$PCONF3" "$TSX_CONFIG_BIN" get HA_API_KEY 2>/dev/null)" = "$GOT" ] && ok "the reinstall kept the panel's HA_API_KEY" || bad "the reinstall changed/dropped HA_API_KEY"
echo "$PROMPT_OUT3" | grep -q "keeping this panel's existing HA_API_KEY" && ok "the reinstall says it keeps the key" || bad "no keep message"
echo "$PROMPT_OUT3" | grep -q '^NEW=\[\]$' && ok "nothing to show at the end of a reinstall that kept the key" || bad "TSX_NEW_API_KEY set on a reinstall"

echo "== answering 'no' leaves the API unencrypted =="
PCONF4="$W/prompted4.conf"
(cd "$HERE" && TSX_CONFIG_BIN="$TSX_CONFIG_BIN" bash -c '. lib/tsx-config-prompt.sh; tsx_config_prompt "'"$PCONF4"'" ""' >/dev/null 2>&1 <<'EOF'
TSS-10-ABCDEF
https://ha.example.org/lovelace/home
trusted
America/Denver
off
no
EOF
)
TSX_CONF="$PCONF4" "$TSX_CONFIG_BIN" get HA_API_KEY >/dev/null 2>&1 && bad "HA_API_KEY set despite 'no'" || ok "'no' leaves HA_API_KEY unset"

echo "== 5. a bad answer is re-prompted, not silently accepted =="
PCONF2="$W/prompted2.conf"
PROMPT_OUT2=$(cd "$HERE" && TSX_CONFIG_BIN="$TSX_CONFIG_BIN" bash -c '. lib/tsx-config-prompt.sh; tsx_config_prompt "'"$PCONF2"'" ""' 2>&1 <<'EOF'
has spaces
TSS-10-ABCDEF
https://ha.example.org/x
trusted
UTC
maybe
off
EOF
)
GOT=$(TSX_CONF="$PCONF2" "$TSX_CONFIG_BIN" get PANEL_NAME 2>/dev/null)
[ "$GOT" = TSS-10-ABCDEF ] && ok "bad PANEL_NAME answer was re-prompted and the retry landed" || bad "re-prompt did not land the corrected value (got '$GOT')"
echo "$PROMPT_OUT2" | grep -qi "try again" && ok "the re-prompt message was shown" || bad "no re-prompt message seen"
echo "$PROMPT_OUT2" | grep -qi "enter 'on' or 'off'" && ok "VOICE=maybe was rejected and re-asked" || bad "VOICE=maybe was not rejected"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-install-mainline-config || echo FAIL test-install-mainline-config
exit $F
