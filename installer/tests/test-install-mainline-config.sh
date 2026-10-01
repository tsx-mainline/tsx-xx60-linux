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
off
correct horse
correct horse
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
GOT=$(TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get AUTO_BRIGHTNESS 2>/dev/null)
[ "$GOT" = off ] && ok "AUTO_BRIGHTNESS answer landed" || bad "AUTO_BRIGHTNESS wrong: got '$GOT'"
TSX_CONF="$PCONF" "$TSX_CONFIG_BIN" get SSH_AUTHORIZED_KEY >/dev/null 2>&1 && ok "the SSH key prompt after it still works" || bad "SSH_AUTHORIZED_KEY not set"
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

echo "== 6. no panel.conf temp copies are left next to --results (the run ends early here: no panel) =="
# A stub sshpass stands in for the kiosk: it serves a panel.conf and then
# fails the eth0 MAC read, so the driver stops with an error in step 2 --
# after it made its temp copy of panel.conf. Both copies (the --yes
# --wipe-data carry-over and the prompted one) must be gone afterwards.
mkdir -p "$W/bin" "$W/res"
cat > "$W/bin/sshpass" <<'STUB'
#!/bin/sh
case "$*" in *"cat /data/tsx/panel.conf"*) echo "KIOSK_URL=https://ha.example.org/";; *) exit 1;; esac
STUB
chmod +x "$W/bin/sshpass"
OUT=$(PATH="$W/bin:$PATH" TSX_MAINLINE_PW=tsx TSX_PANEL_KIND=mainline "$DRIVER" 10.0.0.1 --payload "$W/payload" --kernel lts --yes --wipe-data \
	--results "$W/res/wipe.txt" </dev/null 2>&1)
[ $? -ne 0 ] && ok "--yes --wipe-data run stops at the (stubbed) MAC read" || bad "--yes --wipe-data run did not fail as staged: $OUT"
echo "$OUT" | grep -q "keeping the panel's own /data/tsx/panel.conf" && ok "the panel's panel.conf was carried over (temp copy made)" || bad "no carry-over seen: $OUT"
LEFT=$(ls "$W/res" | grep -c 'panel-conf\|reinstall-conf')
[ "$LEFT" = 0 ] && ok "no panel-conf temp file left after the --wipe-data run" || bad "$LEFT temp file(s) left: $(ls "$W/res")"
OUT=$(cd "$HERE" && PATH="$W/bin:$PATH" TSX_MAINLINE_PW=tsx TSX_PANEL_KIND=mainline "$DRIVER" 10.0.0.1 --payload "$W/payload" --kernel lts \
	--results "$W/res/prompt.txt" 2>&1 <<'EOF'
TSS-10-ABCDEF
https://ha.example.org/lovelace/home
trusted
UTC
off
no






EOF
)
echo "$OUT" | grep -q "could not read the panel's eth0 MAC" && ok "prompted run got past the prompts and stopped at the MAC read" || bad "prompted run did not reach step 2: $OUT"
LEFT=$(ls "$W/res" | grep -c 'panel-conf\|reinstall-conf')
[ "$LEFT" = 0 ] && ok "no panel-conf temp file left after the prompted run" || bad "$LEFT temp file(s) left: $(ls "$W/res")"
[ -s "$W/res/prompt.txt" ] && ok "the results file itself is kept" || bad "results file missing"

echo "== 7. root password: asked at install, only its hash is stored =="
# pre prints the answers to the questions that come before the root password
pre() { printf 'TSS-10-ABCDEF\nhttps://ha.example.org/x\ntrusted\nUTC\noff\nno\n\n\n\n'; }
rp() {   # rp CONF DEFAULTS [ENV=VALUE...] < answers: run the prompt flow
	local conf=$1 defaults=$2; shift 2
	(cd "$HERE" && env TSX_CONFIG_BIN="$TSX_CONFIG_BIN" "$@" bash -c '. lib/tsx-config-prompt.sh; tsx_config_prompt "'"$conf"'" "'"$defaults"'"' 2>&1)
}
note() {  # note CONF: the root login note at the end of the install
	(cd "$HERE" && TSX_CONFIG_BIN="$TSX_CONFIG_BIN" bash -c '. lib/tsx-config-prompt.sh; tsx_config_print_root_login "'"$1"'"' 2>&1)
}
# a wrapper that records the arguments of the hash tool, then runs the real one
mkdir -p "$W/spy"
for tool in openssl mkpasswd; do
	real=$(command -v $tool 2>/dev/null) || continue
	printf '#!/bin/sh\necho "$*" >> "%s/args.log"\nexec %s "$@"\n' "$W/spy" "$real" > "$W/spy/$tool"; chmod 755 "$W/spy/$tool"
done
if command -v openssl >/dev/null 2>&1 || command -v mkpasswd >/dev/null 2>&1; then
	P7="$W/p7.conf"; : > "$W/spy/args.log"
	OUT=$({ pre; printf 'correct horse battery\ncorrect horse battery\n\n'; } | rp "$P7" "" PATH="$W/spy:$PATH")
	H=$(TSX_CONF="$P7" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH 2>/dev/null)
	case "$H" in '$6$'*) ok "ROOT_PASSWORD_HASH is a sha512-crypt hash";; *) bad "no hash stored (got '$H'). Output: $OUT";; esac
	salt=$(printf '%s' "$H" | cut -d'$' -f3)
	if command -v openssl >/dev/null 2>&1 && printf 'x\n' | openssl passwd -6 -stdin >/dev/null 2>&1; then
		RE=$(printf '%s\n' "correct horse battery" | openssl passwd -6 -salt "$salt" -stdin)
		[ "$RE" = "$H" ] && ok "the hash matches the password that was typed" || bad "the hash does not match the password"
	fi
	grep -q 'correct horse' "$P7" && bad "the password is in panel.conf" || ok "the plain password is not in panel.conf"
	case "$OUT" in *"correct horse"*) bad "the password was printed";; *) ok "the password is not printed";; esac
	grep -q 'correct\|horse\|battery' "$W/spy/args.log" && bad "the password was an argument of the hash tool" || ok "the hash tool got the password on stdin, not as an argument"
	echo "$OUT" | grep -q '^ROOT_PASSWORD_HASH=\*\*\*\*' && ok "the printed summary masks ROOT_PASSWORD_HASH" || bad "summary does not mask ROOT_PASSWORD_HASH"
	OUT=$(note "$P7")
	case "$OUT" in *"password that you gave is set"*) ok "the end of the install says that the password is set";; *) bad "root login note (set): $OUT";; esac

	P8="$W/p8.conf"
	OUT=$({ pre; printf 'short\ncorrect horse battery\nsomething else\ncorrect horse battery\ncorrect horse battery\n\n'; } | rp "$P8" "" PATH="$W/spy:$PATH")
	echo "$OUT" | grep -q 'too short' && ok "a password under 8 characters is refused" || bad "short password accepted"
	echo "$OUT" | grep -q 'two entries differ' && ok "two different entries are refused" || bad "mismatch accepted"
	TSX_CONF="$P8" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH >/dev/null 2>&1 && ok "after the retries the hash is stored" || bad "no hash after the retries"

	P9="$W/p9.conf"
	OUT=$({ pre; printf '\n\n'; } | rp "$P9" "$P7")
	[ "$(TSX_CONF="$P9" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH 2>/dev/null)" = "$H" ] && ok "reinstall: a blank answer keeps the saved hash" || bad "reinstall lost the hash"
	echo "$OUT" | grep -q 'keeping the saved root password' && ok "reinstall says that it keeps the password" || bad "no keep message"
else
	echo "  skip: no openssl or mkpasswd on this host (the hash cases)"
fi
P10="$W/p10.conf"
OUT=$({ pre; printf '\n'; } | rp "$P10" "")
TSX_CONF="$P10" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH >/dev/null 2>&1 && bad "a blank answer stored a hash" || ok "a blank answer stores no password (none)"
echo "$OUT" | grep -q 'no root password' && echo "$OUT" | grep -q 'asks for one' && ok "the prompt says what no password means" || bad "no explanation for a blank answer"
OUT=$(note "$P10")
case "$OUT" in *"no root password was set"*"no SSH key was given"*) ok "no password and no key: the end of the install says that ssh accepts nothing";; *) bad "root login note (none, no key): $OUT";; esac
P11="$W/p11.conf"; TSX_CONF="$P11" "$TSX_CONFIG_BIN" set SSH_AUTHORIZED_KEY "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host" >/dev/null
OUT=$(note "$P11")
case "$OUT" in *"no root password was set"*"ssh accepts the SSH key"*) ok "no password with a key: ssh accepts the key";; *) bad "root login note (none, key): $OUT";; esac
P12="$W/p12.conf"
OUT=$({ pre; printf 'correct horse battery\ncorrect horse battery\n\n'; } | rp "$P12" "" TSX_HASH_DISABLE=1)
TSX_CONF="$P12" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH >/dev/null 2>&1 && bad "a hash without a tool" || ok "no hash tool: nothing is stored"
echo "$OUT" | grep -q 'no tool to hash' && ok "no hash tool: the prompt says so" || bad "no message for a missing hash tool"
case "$OUT" in *"correct horse"*) bad "the password was printed";; *) ok "the password is not printed (no tool case)";; esac

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-install-mainline-config || echo FAIL test-install-mainline-config
exit $F
