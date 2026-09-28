#!/usr/bin/env bash
# installer/lib/tsx-config-prompt.sh: interactive panel.conf prompts for
# tsx-install-mainline, sourced (not run). Builds the file with the exact
# same tsx-config script the panel runs (rootfs/overlay/usr/local/sbin/tsx-config),
# so a value that is accepted here is guaranteed to be accepted by `tsx-config
# apply` on the panel too -- one parser/validator, not two (docs/rootfs.md
# "Panel configuration").
#
#   tsx_config_prompt OUTFILE [DEFAULTS_FILE]
#
# DEFAULTS_FILE (optional): an existing panel.conf (e.g. pulled from a panel
# being reinstalled) whose values are offered as the default answer instead
# of the built-in ones. Reads from this process's own stdin (a real terminal
# for an interactive install, or answers piped/fed in for a scripted one, one
# per line, in the order printed -- installer/tests/test-install-mainline-config.sh);
# a blank answer keeps the current default (which may be "unset").
#
# Sets TSX_NEW_API_KEY when it generated a new ESPHome API encryption key
# (HA_API_KEY): the caller prints it once, at the very end, with what to do
# with it in Home Assistant (tsx_config_print_api_key). A key already in
# DEFAULTS_FILE (a reinstall) is kept as it is, Home Assistant already has it.
set -u
TSX_CONFIG_BIN=${TSX_CONFIG_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../../rootfs/overlay/usr/local/sbin/tsx-config" 2>/dev/null && pwd -P)/tsx-config"}
[ -x "$TSX_CONFIG_BIN" ] || TSX_CONFIG_BIN=$(dirname "${BASH_SOURCE[0]}")/../../rootfs/overlay/usr/local/sbin/tsx-config

_tcp_default() {  # _tcp_default KEY -> stdout (empty if unset), never fails
	local key=$1
	[ -n "${TCP_DEFAULTS:-}" ] || { echo ""; return 0; }
	TSX_CONF="$TCP_DEFAULTS" "$TSX_CONFIG_BIN" get "$key" 2>/dev/null || true
}

# _tcp_ask KEY PROMPT [DEFAULT] [SECRET(0|1)]: prompt on stdin, retry on
# tsx-config's own validation failure, write via tsx-config set (skips the
# key entirely on a blank answer with no default: it then keeps whatever
# built-in default the service applies at boot).
_tcp_ask() {
	local key=$1 prompt=$2 dflt=${3:-} secret=${4:-0} ans=
	[ -n "$dflt" ] || dflt=$(_tcp_default "$key")
	while :; do
		if [ "$secret" = 1 ]; then
			read -r -s -p "$prompt${dflt:+ [saved value; Enter keeps it]}: " ans; echo >&2
		else
			read -r -p "$prompt${dflt:+ [$dflt]}: " ans
		fi
		[ -n "$ans" ] || ans=$dflt
		[ -n "$ans" ] || return 0   # nothing to set: leave the key unset (built-in default applies)
		if TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set "$key" "$ans" 2>/tmp/tcp-err.$$; then
			rm -f /tmp/tcp-err.$$; return 0
		fi
		cat /tmp/tcp-err.$$ >&2; rm -f /tmp/tcp-err.$$
		echo "  (try again, or leave blank to skip $key)" >&2
	done
}

tsx_config_prompt() {
	OUTFILE=$1; TCP_DEFAULTS=${2:-}
	: > "$OUTFILE"; chmod 600 "$OUTFILE"
	echo "== Panel configuration (blank = built-in default; docs/rootfs.md, installer/panel.conf.example) ==" >&2

	_tcp_ask PANEL_NAME "Panel name (letters/digits/-, shown in HA/sendspin/voice; blank = <model>-<MAC>)"
	_tcp_ask KIOSK_URL "Home Assistant dashboard URL" "$(_tcp_default KIOSK_URL)"
	url=$(TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" get KIOSK_URL 2>/dev/null || true)
	if [ -n "$url" ] && command -v curl >/dev/null 2>&1; then
		if curl -m 3 -sf -o /dev/null "$url" 2>/dev/null; then
			echo "  $url: reachable from this host" >&2
		else
			echo "  WARNING: $url did not answer within 3s from this host (may still be fine: HA may be on a VPN/VLAN the panel reaches but this host does not)" >&2
		fi
	fi

	while :; do
		method=$(_tcp_default HA_LOGIN_METHOD); [ -n "$method" ] || method=trusted
		read -r -p "HA login method, token or trusted [$method]: " ans
		[ -n "$ans" ] || ans=$method
		case "$ans" in token|trusted) TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set HA_LOGIN_METHOD "$ans"; break;; esac
		echo "  enter 'token' or 'trusted'" >&2
	done
	if [ "$ans" = token ]; then
		_tcp_ask HA_TOKEN "Home Assistant long-lived access token" "" 1
	fi

	while :; do
		tz=$(_tcp_default TZ_NAME); [ -n "$tz" ] || tz=$(cat /etc/timezone 2>/dev/null || echo UTC)
		read -r -p "Time zone (e.g. America/Denver) [$tz]: " ans
		[ -n "$ans" ] || ans=$tz
		if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$ans" ]; then
			echo "  no such zone on this host's /usr/share/zoneinfo (still accepted: the panel has its own copy)" >&2
		fi
		TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set TZ_NAME "$ans" 2>/tmp/tcp-err.$$ && { rm -f /tmp/tcp-err.$$; break; }
		cat /tmp/tcp-err.$$ >&2; rm -f /tmp/tcp-err.$$
	done

	while :; do
		voice=$(_tcp_default VOICE); [ -n "$voice" ] || voice=off
		read -r -p "Voice assistant (Assist satellite), on or off [$voice]: " ans
		[ -n "$ans" ] || ans=$voice
		case "$ans" in on|off) TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set VOICE "$ans"; break;; esac
		echo "  enter 'on' or 'off'" >&2
	done
	if [ "$ans" = on ]; then
		_tcp_ask WAKE_WORD "Wake word (okay_nabu, hey_jarvis, ...)" "$(_tcp_default WAKE_WORD)"
	fi

	TSX_NEW_API_KEY=
	key=$(_tcp_default HA_API_KEY)
	if [ -n "$key" ]; then
		TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set HA_API_KEY "$key"
		echo "  ESPHome API encryption: keeping this panel's existing HA_API_KEY (Home Assistant already has it)" >&2
	else
		while :; do
			read -r -p "Encrypt the panel's ESPHome API (port 6053) with a new random key? You paste it into Home Assistant once; without it any LAN host can use the API. yes or no [yes]: " ans
			[ -n "$ans" ] || ans=yes
			case "$ans" in
			y|yes)
				TSX_NEW_API_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
				TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set HA_API_KEY "$TSX_NEW_API_KEY" || { TSX_NEW_API_KEY=; echo "  could not generate a key" >&2; continue; }
				echo "  generated HA_API_KEY: it is shown once, at the end of the install" >&2
				break;;
			n|no) break;;
			esac
			echo "  enter 'yes' or 'no'" >&2
		done
	fi

	_tcp_ask HA_ALLOW_FROM "Home Assistant host's address (or a comma list; CIDRs OK) allowed to use the panel's ESPHome API -- defence in depth on top of the encryption key, and the only protection without one (then any other LAN host could reboot the panel or change its URL). NOTE: if Home Assistant is reached through a reverse proxy, use the proxy/HA HOST's real LAN address here, which may differ from the dashboard URL's host. Blank = allow any" "$(_tcp_default HA_ALLOW_FROM)"

	_tcp_ask MQTT_HOST "MQTT broker host (blank = no MQTT bridge, use ESPHome/HA API instead)" "$(_tcp_default MQTT_HOST)"
	if [ -n "$(TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" get MQTT_HOST 2>/dev/null || true)" ]; then
		_tcp_ask MQTT_PORT "MQTT port" "$(_tcp_default MQTT_PORT)"
		_tcp_ask MQTT_USER "MQTT user"  "$(_tcp_default MQTT_USER)"
		_tcp_ask MQTT_PASSWORD "MQTT password" "" 1
	fi

	# KERNEL_FLAVOR is not prompted here: it is set by the caller from the
	# installer's own --kernel (already required, already validated) so
	# panel.conf never disagrees with what --kernel actually installed.

	_tcp_ask SSH_AUTHORIZED_KEY "SSH public key to add to root's authorized_keys (blank = password login only)"

	echo "== panel.conf built (secrets masked): ==" >&2
	TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" show >&2
}

# tsx_config_print_api_key PANEL: show a key tsx_config_prompt generated, once
# (stderr only: never into the installer's results log).
tsx_config_print_api_key() {
	[ -n "${TSX_NEW_API_KEY:-}" ] || return 0
	{
		echo
		echo "== Home Assistant: the panel's ESPHome API is encrypted. Its key (shown only now):"
		echo
		echo "     $TSX_NEW_API_KEY"
		echo
		echo "   In Home Assistant: Settings > Devices & services, then the discovered ESPHome"
		echo "   device (or Add integration > ESPHome, host $1, port 6053). When it asks for"
		echo "   the encryption key, paste the line above. On the panel it is also in"
		echo "   'tsx-config get HA_API_KEY'."
		echo
	} >&2
}
