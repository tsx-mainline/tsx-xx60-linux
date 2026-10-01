#!/usr/bin/env bash
# installer/lib/tsx-config-prompt.sh: interactive panel.conf prompts for
# tsx-install-mainline. Source this file, do not run it. It builds the file
# with the same tsx-config script that the panel runs
# (rootfs/overlay/usr/local/sbin/tsx-config). So `tsx-config apply` on the
# panel accepts every value that this script accepts. There is one parser and
# validator, not two (docs/rootfs.md "Panel configuration").
#
#   tsx_config_prompt OUTFILE [DEFAULTS_FILE]
#
# DEFAULTS_FILE (optional) is an existing panel.conf, for example one pulled
# from a panel that is being reinstalled. The prompts offer its values as the
# default answers instead of the built-in ones. The function reads from the own
# stdin of this process. That is a real terminal for an interactive install.
# A scripted install feeds one answer per line, in the order printed (see
# installer/tests/test-install-mainline-config.sh). A blank answer keeps the
# current default (which can be "unset").
#
# When the function generates a new ESPHome API encryption key (HA_API_KEY), it
# sets TSX_NEW_API_KEY. The caller prints the key once, at the very end, with
# the steps to take in Home Assistant (tsx_config_print_api_key). A key that is
# already in DEFAULTS_FILE (a reinstall) stays as it is, because Home Assistant
# already has it.
set -u
TSX_CONFIG_BIN=${TSX_CONFIG_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../../rootfs/overlay/usr/local/sbin/tsx-config" 2>/dev/null && pwd -P)/tsx-config"}
[ -x "$TSX_CONFIG_BIN" ] || TSX_CONFIG_BIN=$(dirname "${BASH_SOURCE[0]}")/../../rootfs/overlay/usr/local/sbin/tsx-config

_tcp_default() {  # _tcp_default KEY: print the default (empty if unset), never fail
	local key=$1
	[ -n "${TCP_DEFAULTS:-}" ] || { echo ""; return 0; }
	TSX_CONF="$TCP_DEFAULTS" "$TSX_CONFIG_BIN" get "$key" 2>/dev/null || true
}

# _tcp_ask KEY PROMPT [DEFAULT] [SECRET(0|1)]: prompt on stdin. Ask again if
# the validation of tsx-config fails. Write the answer with tsx-config set. On
# a blank answer with no default, skip the key. The panel then uses the
# built-in default that the service applies at boot.
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
		[ -n "$ans" ] || return 0   # nothing to set: leave the key unset (the built-in default applies)
		if TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set "$key" "$ans" 2>/tmp/tcp-err.$$; then
			rm -f /tmp/tcp-err.$$; return 0
		fi
		cat /tmp/tcp-err.$$ >&2; rm -f /tmp/tcp-err.$$
		echo "  (try again, or leave blank to skip $key)" >&2
	done
}

# _tcp_hash_password PASSWORD: print the sha512-crypt hash of PASSWORD. The
# password goes to the hash tool on its standard input, never as an argument,
# so it does not show in the process list. It tries openssl, mkpasswd, and the
# crypt module of python3, in that order. It prints nothing and fails when the
# host has none of them. Test hook: TSX_HASH_DISABLE=1 acts as if none is there.
_tcp_hash_password() {
	local h=
	[ "${TSX_HASH_DISABLE:-}" != 1 ] || return 1
	if command -v openssl >/dev/null 2>&1 && printf 'x\n' | openssl passwd -6 -stdin >/dev/null 2>&1; then
		h=$(printf '%s\n' "$1" | openssl passwd -6 -stdin 2>/dev/null)
	elif command -v mkpasswd >/dev/null 2>&1; then
		h=$(printf '%s\n' "$1" | mkpasswd -m sha-512 -s 2>/dev/null)
	elif command -v python3 >/dev/null 2>&1; then
		h=$(printf '%s\n' "$1" | python3 -c 'import crypt, sys; print(crypt.crypt(sys.stdin.readline().rstrip("\n"), crypt.mksalt(crypt.METHOD_SHA512)))' 2>/dev/null)
	fi
	case "$h" in \$6\$*) printf '%s\n' "$h";; *) return 1;; esac
}

# _tcp_ask_root_password: ask for the root password (twice, with no echo) and
# store only its hash as ROOT_PASSWORD_HASH. A blank answer sets no password.
# Then the install needs an SSH key (tsx_config_prompt asks for it next), and
# the root password stays locked until a person sets one over ssh
# (docs/rootfs.md "Root login"). On a reinstall, a blank answer keeps the
# saved hash. The function never prints or logs the password.
_tcp_ask_root_password() {
	local saved pw pw2 hash
	saved=$(_tcp_default ROOT_PASSWORD_HASH)
	while :; do
		read -r -s -p "Root password, 8 characters or more${saved:+ [saved; Enter keeps it]} (blank = SSH key only, you give the key next): " pw || return 1; echo >&2
		if [ -z "$pw" ]; then
			if [ -n "$saved" ]; then
				TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set ROOT_PASSWORD_HASH "$saved"
				echo "  keeping the saved root password" >&2
			else
				echo "  no root password. The install then needs an SSH key. The password stays locked until you set one over ssh" >&2
			fi
			return 0
		fi
		if [ "${#pw}" -lt 8 ]; then
			echo "  too short: use 8 characters or more, or leave it blank for an SSH key only" >&2; continue
		fi
		read -r -s -p "Root password again: " pw2 || return 1; echo >&2
		if [ "$pw" != "$pw2" ]; then
			echo "  the two entries differ, try again" >&2; continue
		fi
		if hash=$(_tcp_hash_password "$pw"); then
			pw= pw2=
			TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" set ROOT_PASSWORD_HASH "$hash" && return 0
			echo "  the hash was not accepted, try again" >&2; continue
		fi
		pw= pw2=
		echo "  this host has no tool to hash a password (openssl, mkpasswd or python3). Install one and run this again, or leave the answer blank and give an SSH key" >&2
	done
}

# tsx_config_has_root_login CONFIG: true when the panel.conf CONFIG has a root
# password hash or an SSH key. The install stops without one of them.
tsx_config_has_root_login() {
	[ -n "${1:-}" ] && [ -f "$1" ] || return 1
	local hash key
	hash=$(TSX_CONF="$1" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH 2>/dev/null || true)
	key=$(TSX_CONF="$1" "$TSX_CONFIG_BIN" get SSH_AUTHORIZED_KEY 2>/dev/null || true)
	[ -n "$hash" ] || [ -n "$key" ]
}

# tsx_config_root_login_message: the text of the stop when there is neither.
tsx_config_root_login_message() {
	echo "No root password and no SSH public key. The install needs at least one of them, because a panel with no way to log in cannot be used."
	echo "Give a password hash (ROOT_PASSWORD_HASH) or a public key (SSH_AUTHORIZED_KEY) in the panel.conf (installer/panel.conf.example), or answer the two prompts."
}

tsx_config_prompt() {
	OUTFILE=$1; TCP_DEFAULTS=${2:-}
	: > "$OUTFILE"; chmod 600 "$OUTFILE"
	echo "== Panel configuration (blank = built-in default, see docs/rootfs.md and installer/panel.conf.example) ==" >&2

	_tcp_ask PANEL_NAME "Panel name (letters/digits/-, shown in HA/sendspin/voice; blank = <model>-<MAC>)"
	_tcp_ask KIOSK_URL "Home Assistant dashboard URL" "$(_tcp_default KIOSK_URL)"
	url=$(TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" get KIOSK_URL 2>/dev/null || true)
	if [ -n "$url" ] && command -v curl >/dev/null 2>&1; then
		if curl -m 3 -sf -o /dev/null "$url" 2>/dev/null; then
			echo "  $url: reachable from this host" >&2
		else
			echo "  WARNING: $url did not answer within 3 s from this host. This can be normal. The panel may reach HA over a VPN or VLAN that this host does not" >&2
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
			read -r -p "Encrypt the ESPHome API of the panel (port 6053) with a new random key? You paste it into Home Assistant once. Without it, any LAN host can use the API. yes or no [yes]:" ans
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

	_tcp_ask HA_ALLOW_FROM "Address of the Home Assistant host (or a comma list, CIDRs OK) that may use the ESPHome API of the panel. This adds defense in depth on top of the encryption key. Without a key it is the only protection: any other LAN host could reboot the panel or change its URL. NOTE: if you reach Home Assistant through a reverse proxy, use the real LAN address of the proxy or HA HOST here. It can differ from the host in the dashboard URL. Blank = allow any" "$(_tcp_default HA_ALLOW_FROM)"

	_tcp_ask MQTT_HOST "MQTT broker host (blank = no MQTT bridge, use ESPHome/HA API instead)" "$(_tcp_default MQTT_HOST)"
	if [ -n "$(TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" get MQTT_HOST 2>/dev/null || true)" ]; then
		_tcp_ask MQTT_PORT "MQTT port" "$(_tcp_default MQTT_PORT)"
		_tcp_ask MQTT_USER "MQTT user"  "$(_tcp_default MQTT_USER)"
		_tcp_ask MQTT_PASSWORD "MQTT password" "" 1
	fi

	# Sensors (docs/rootfs.md "Ambient light sensor"). A blank answer keeps
	# the default of the panel.
	_tcp_ask AUTO_BRIGHTNESS "Backlight follows the ambient light sensor, on or off" "$(_tcp_default AUTO_BRIGHTNESS)"

	# This function does not prompt for KERNEL_FLAVOR. The caller sets it from
	# --kernel of the installer (already required and validated). So panel.conf
	# never disagrees with the kernel that --kernel installs.

	# The install needs a root password or an SSH key. Ask again until it has
	# one. Without a terminal (a script that feeds answers) there is no second
	# round, and the function fails.
	while :; do
		_tcp_ask_root_password || return 1
		_tcp_ask SSH_AUTHORIZED_KEY "SSH public key for root's authorized_keys (needed when there is no password)"
		tsx_config_has_root_login "$OUTFILE" && break
		tsx_config_root_login_message >&2
		[ -t 0 ] || return 1
	done

	echo "== panel.conf built (secrets masked): ==" >&2
	TSX_CONF="$OUTFILE" "$TSX_CONFIG_BIN" show >&2
}

# tsx_config_print_root_login CONFIG: tell which root login case applies to the
# panel.conf that the install carries. It prints to stderr only.
tsx_config_print_root_login() {
	[ -n "${1:-}" ] && [ -f "$1" ] || return 0
	local hash key
	hash=$(TSX_CONF="$1" "$TSX_CONFIG_BIN" get ROOT_PASSWORD_HASH 2>/dev/null || true)
	key=$(TSX_CONF="$1" "$TSX_CONFIG_BIN" get SSH_AUTHORIZED_KEY 2>/dev/null || true)
	if [ -n "$hash" ]; then
		echo "== Root login: the password that you gave is set at the first boot of the panel." >&2
		[ -z "$key" ] || echo "   ssh also accepts the SSH key that you gave." >&2
	elif [ -n "$key" ]; then
		echo "== Root login: no root password was set. ssh accepts the SSH key that you gave." >&2
		echo "   The login on the panel screen and the serial port stays off. Log in over ssh and run passwd to open it." >&2
	else
		echo "== Root login: this install has no root password and no SSH key." >&2
	fi
}

# tsx_config_print_api_key PANEL: show the key that tsx_config_prompt
# generated, once. Print to stderr only, never into the results log of the
# installer.
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
