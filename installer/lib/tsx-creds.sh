# Host: the logins and the install config file of the installer scripts
# (bash, sourced).
#
# Every login value comes from the person who runs the script. Nothing has a
# built-in default. The sources, in this order:
#   1. a command line option
#   2. the environment variable (for automation)
#   3. the install config file (--install-config FILE)
#   4. a prompt, only in a driver script and only when stdin is a terminal
# If a needed value is still missing, the script stops with an error that
# names the key and the option. It stops before it logs in to the panel or
# changes it.
#
# Login options (tsx_creds_opt), their environment variables and their keys
# in the install config file:
#   --admin-user USER         TSX_ADMIN_USER   ADMIN_USER         the Crestron admin user
#   --admin-password PW       TSX_ADMIN_PW     ADMIN_PASSWORD     its password
#   --mainline-password PW    TSX_MAINLINE_PW  MAINLINE_PASSWORD  the root password of
#                                                                 a mainline panel
#                                                                 (else your ssh key)
#   --rescue-password PW      TSX_RESCUE_PW    RESCUE_PASSWORD    the one-time password
#                                                                 of the rescue screen
# A password on the command line shows in the process list and in the shell
# history. The install config file (mode 600) is the safe place.
#
# The install config file has one KEY=VALUE per line. Lines that start with #
# and empty lines do not count. Spaces around the = and at the end of the line
# do not count. A VALUE in double or single quotes is the text between the
# quotes, taken literally (also #, =, $ and spaces). The script never runs the
# file as shell code. A key that the script does not know stops it.
#
# The functions set and export the environment variables, so the step
# scripts (steps/crestron-admin, steps/rootsh, steps/tsx-ensure-root) get the
# values from the driver.

# tsx_creds_opt OPTION VALUE...: when OPTION is a login option, take its value,
# set TSX_CREDS_SHIFT=2 and return 0. Return 1 for any other option. On a
# missing value, print an error and exit 2.
tsx_creds_opt() {
	local opt=$1 var
	case "$opt" in
	--admin-user) var=TSX_ADMIN_USER;;
	--admin-password) var=TSX_ADMIN_PW;;
	--mainline-password) var=TSX_MAINLINE_PW;;
	--rescue-password) var=TSX_RESCUE_PW;;
	--admin-password-file|--mainline-password-file|--rescue-password-file)
		echo "$opt is gone: put the password in an install config file (--install-config FILE, mode 600)" >&2; exit 2;;
	*) return 1;;
	esac
	[ $# -ge 2 ] && [ -n "$2" ] || { echo "$opt needs a value" >&2; exit 2; }
	printf -v "$var" '%s' "$2"
	export "${var?}"
	TSX_CREDS_SHIFT=2
	return 0
}

# tsx_creds_help: the lines for the --help text of a driver.
tsx_creds_help() {
	cat <<'EOF'
Logins: an option wins over its environment variable, and the variable wins
over the install config file. Nothing has a default.
  --admin-user USER         (TSX_ADMIN_USER,  ADMIN_USER)         Crestron admin user
  --admin-password PW       (TSX_ADMIN_PW,    ADMIN_PASSWORD)     its password
  --mainline-password PW    (TSX_MAINLINE_PW, MAINLINE_PASSWORD)  root password of a
                                                                  mainline panel (else
                                                                  your ssh key)
  --rescue-password PW      (TSX_RESCUE_PW,   RESCUE_PASSWORD)    one-time password of
                                                                  the rescue screen
  --install-config FILE     KEY=VALUE lines with these keys and the other
                            options (installer/tsx-install.conf.example)
A password on the command line shows in the process list and in the shell
history. Put it in the install config file (mode 600), or give no password:
on a terminal the script asks for a needed one and offers to save the answers
in an install config file.
EOF
}

# The keys of the install config file. tsx-install-mainline and
# tsx-restore-factory read the same file, and each one uses the keys that
# apply to it (installer/tsx-install.conf.example).
TSX_INSTALL_CONFIG_KEYS="PANEL PAYLOAD KERNEL PANEL_CONF KIOSK_URL UART STAGE FETCH RELEASE_URL STAGE_WAIT TFA_SOURCE PSR_SOURCE SSHSHELL SSH_CIPHERS COMMON PUF ADMIN_USER ADMIN_PASSWORD MAINLINE_PASSWORD RESCUE_PASSWORD"

# tsx_install_config_load FILE: read FILE, a list of KEY=VALUE lines, as
# described above. Only the keys of TSX_INSTALL_CONFIG_KEYS are allowed. Each value goes to the
# variable IC_<KEY>. IC_KEYS lists the keys of the file. A file that holds a
# password must not be readable by the group or by others. On an error the
# function prints it and exits 2.
tsx_install_config_load() {
	local f=$1 line key val n=0 allowed mode haspw=0
	allowed=" $TSX_INSTALL_CONFIG_KEYS "
	for key in $TSX_INSTALL_CONFIG_KEYS; do printf -v "IC_$key" '%s' ''; done
	[ -r "$f" ] || { echo "--install-config: cannot read $f" >&2; exit 2; }
	IC_KEYS=
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line%$'\r'}
		line=${line#"${line%%[![:space:]]*}"}
		case "$line" in ''|'#'*) continue;; esac
		case "$line" in
		[A-Z]*=*) ;;
		*) echo "$f line $n: not KEY=VALUE" >&2; exit 2;;
		esac
		key=${line%%=*}
		key=${key%"${key##*[![:space:]]}"}
		case "$key" in *[!A-Z0-9_]*) echo "$f line $n: bad key '$key'" >&2; exit 2;; esac
		case "$allowed" in *" $key "*) ;; *) echo "$f line $n: unknown key $key (allowed:$allowed)" >&2; exit 2;; esac
		case " $IC_KEYS " in *" $key "*) echo "$f line $n: $key is there two times" >&2; exit 2;; esac
		val=${line#*=}
		val=${val#"${val%%[![:space:]]*}"}; val=${val%"${val##*[![:space:]]}"}
		case "$val" in
		\"*\") val=${val#\"}; val=${val%\"};;
		\'*\') val=${val#\'}; val=${val%\'};;
		*) val=${val#"${val%%[![:space:]]*}"}; val=${val%"${val##*[![:space:]]}"};;
		esac
		printf -v "IC_$key" '%s' "$val"
		IC_KEYS="$IC_KEYS $key"
		case "$key" in *PASSWORD) [ -z "$val" ] || haspw=1;; esac
	done < "$f"
	IC_KEYS=${IC_KEYS# }
	if [ "$haspw" = 1 ]; then
		mode=$(stat -L -c %a "$f") || { echo "--install-config: cannot read the mode of $f" >&2; exit 2; }
		case "$mode" in
		*00) ;;
		*) echo "$f holds a password, and other users can read it (mode $mode). Run: chmod 600 $f" >&2; exit 2;;
		esac
	fi
	return 0
}

# tsx_install_config_logins: take the logins from the loaded file where no
# option and no environment variable gave them.
tsx_install_config_logins() {
	[ -n "${TSX_ADMIN_USER:-}" ] || [ -z "${IC_ADMIN_USER:-}" ] || export TSX_ADMIN_USER=$IC_ADMIN_USER
	[ -n "${TSX_ADMIN_PW:-}" ] || [ -z "${IC_ADMIN_PASSWORD:-}" ] || export TSX_ADMIN_PW=$IC_ADMIN_PASSWORD
	[ -n "${TSX_MAINLINE_PW:-}" ] || [ -z "${IC_MAINLINE_PASSWORD:-}" ] || export TSX_MAINLINE_PW=$IC_MAINLINE_PASSWORD
	[ -n "${TSX_RESCUE_PW:-}" ] || [ -z "${IC_RESCUE_PASSWORD:-}" ] || export TSX_RESCUE_PW=$IC_RESCUE_PASSWORD
	return 0
}

# tsx_install_config_write FILE KEY=VALUE...: write an install config file with
# mode 600. Each value goes in double quotes (the parser takes the text between
# them literally). An empty value is left out.
tsx_install_config_write() {
	local f=$1 kv; shift
	( umask 077
	{
		echo "# tsx-install-mainline install config (--install-config $f)."
		echo "# It holds passwords: keep it mode 600. See installer/tsx-install.conf.example."
		for kv in "$@"; do
			[ -n "${kv#*=}" ] || continue
			case "${kv#*=}" in *$'\n'*) echo "a value of ${kv%%=*} has a line break" >&2; return 1;; esac
			printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}"
		done
	} > "$f" ) || return 1
	chmod 600 "$f"
}

# tsx_creds_need_admin PROMPT: make sure that TSX_ADMIN_USER and TSX_ADMIN_PW
# are set. With PROMPT=1 and stdin a terminal, ask for a missing value (the
# password twice) and set TSX_CREDS_PROMPTED=1. Else print an error that names
# the key and the option, and return 2.
tsx_creds_need_admin() {
	local prompt=${1:-0} a b
	if [ -z "${TSX_ADMIN_USER:-}" ] && [ "$prompt" = 1 ] && [ -t 0 ]; then
		read -r -p "Crestron admin user: " a || a=
		[ -z "$a" ] || { export TSX_ADMIN_USER=$a; TSX_CREDS_PROMPTED=1; }
	fi
	if [ -z "${TSX_ADMIN_PW:-}" ] && [ "$prompt" = 1 ] && [ -t 0 ]; then
		read -r -s -p "Crestron admin password: " a || a=; echo >&2
		if [ -n "$a" ]; then
			read -r -s -p "Crestron admin password again: " b || b=; echo >&2
			[ "$a" = "$b" ] || { echo "the two passwords are not the same" >&2; return 2; }
			export TSX_ADMIN_PW=$a; TSX_CREDS_PROMPTED=1
		fi
	fi
	if [ -z "${TSX_ADMIN_USER:-}" ]; then
		echo "the Crestron admin user is missing: give ADMIN_USER in the install config file, or --admin-user USER (or set TSX_ADMIN_USER)" >&2; return 2
	fi
	if [ -z "${TSX_ADMIN_PW:-}" ]; then
		echo "the Crestron admin password is missing: give ADMIN_PASSWORD in the install config file (mode 600), or --admin-password PW (or set TSX_ADMIN_PW)" >&2; return 2
	fi
	case "$TSX_ADMIN_USER" in *[!A-Za-z0-9._@-]*) echo "the admin user: use only letters, digits and . _ @ -" >&2; return 2;; esac
	return 0
}
