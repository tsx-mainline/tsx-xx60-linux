# Host: the logins of the installer scripts (bash, sourced).
#
# Every login value comes from the person who runs the script. Nothing has a
# built-in default. The sources, in this order:
#   1. a command line option (it wins over the environment variable)
#   2. the environment variable (for automation)
#   3. a prompt, only in a driver script and only when stdin is a terminal
# If a needed value is still missing, the script stops with an error that
# names the option. It stops before it logs in to the panel or changes it.
#
# Options (tsx_creds_opt) and their environment variables:
#   --admin-user USER               TSX_ADMIN_USER   the Crestron admin user
#   --admin-password-file FILE      TSX_ADMIN_PW     the Crestron admin password
#   --admin-password PW             TSX_ADMIN_PW
#   --mainline-password-file FILE   TSX_MAINLINE_PW  the root password of a
#   --mainline-password PW          TSX_MAINLINE_PW  mainline panel (else your
#                                                    ssh key)
#   --rescue-password-file FILE     TSX_RESCUE_PW    the one-time password of
#   --rescue-password PW            TSX_RESCUE_PW    the rescue screen (else
#                                                    your ssh key)
# A password on the command line shows in the process list and in the shell
# history. Use the -file form or the prompt. A FILE holds the password on its
# first line. FILE can be /dev/stdin.
#
# The functions set and export the environment variables, so the step
# scripts (steps/crestron-admin, steps/rootsh, steps/tsx-ensure-root) get the
# values from the driver.

# tsx_creds_opt OPTION VALUE...: when OPTION is a login option, take its value,
# set TSX_CREDS_SHIFT=2 and return 0. Return 1 for any other option. On a
# missing value or an unreadable file, print an error and exit 2.
tsx_creds_opt() {
	local opt=$1 var file=0
	case "$opt" in
	--admin-user) var=TSX_ADMIN_USER;;
	--admin-password) var=TSX_ADMIN_PW;;
	--admin-password-file) var=TSX_ADMIN_PW file=1;;
	--mainline-password) var=TSX_MAINLINE_PW;;
	--mainline-password-file) var=TSX_MAINLINE_PW file=1;;
	--rescue-password) var=TSX_RESCUE_PW;;
	--rescue-password-file) var=TSX_RESCUE_PW file=1;;
	*) return 1;;
	esac
	[ $# -ge 2 ] && [ -n "$2" ] || { echo "$opt needs a value" >&2; exit 2; }
	if [ "$file" = 1 ]; then
		[ -r "$2" ] || { echo "$opt: cannot read $2" >&2; exit 2; }
		local v=
		IFS= read -r v < "$2" || [ -n "$v" ] || { echo "$opt: $2 is empty" >&2; exit 2; }
		v=${v%$'\r'}
		[ -n "$v" ] || { echo "$opt: the first line of $2 is empty" >&2; exit 2; }
		printf -v "$var" '%s' "$v"
	else
		printf -v "$var" '%s' "$2"
	fi
	export "${var?}"
	TSX_CREDS_SHIFT=2
	return 0
}

# tsx_creds_help: the lines for the --help text of a driver.
tsx_creds_help() {
	cat <<'EOF'
Logins: an option wins over its environment variable. Nothing has a default.
  --admin-user USER              (TSX_ADMIN_USER)  Crestron admin user
  --admin-password-file FILE     (TSX_ADMIN_PW)    Crestron admin password
  --admin-password PW            (TSX_ADMIN_PW)
  --mainline-password-file FILE  (TSX_MAINLINE_PW) root password of a mainline
  --mainline-password PW         (TSX_MAINLINE_PW) panel (else your ssh key)
  --rescue-password-file FILE    (TSX_RESCUE_PW)   one-time password of the
  --rescue-password PW           (TSX_RESCUE_PW)   rescue screen (else your key)
A password on the command line shows in the process list and in the shell
history. Use the -file form, or give no password: on a terminal the script
asks for a needed password. A FILE holds the password on its first line.
EOF
}

# tsx_creds_need_admin PROMPT: make sure that TSX_ADMIN_USER and TSX_ADMIN_PW
# are set. With PROMPT=1 and stdin a terminal, ask for a missing value (the
# password twice). Else print an error that names the options and return 2.
tsx_creds_need_admin() {
	local prompt=${1:-0} a b
	if [ -z "${TSX_ADMIN_USER:-}" ] && [ "$prompt" = 1 ] && [ -t 0 ]; then
		read -r -p "Crestron admin user: " a || a=
		[ -z "$a" ] || export TSX_ADMIN_USER=$a
	fi
	if [ -z "${TSX_ADMIN_PW:-}" ] && [ "$prompt" = 1 ] && [ -t 0 ]; then
		read -r -s -p "Crestron admin password: " a || a=; echo >&2
		if [ -n "$a" ]; then
			read -r -s -p "Crestron admin password again: " b || b=; echo >&2
			[ "$a" = "$b" ] || { echo "the two passwords are not the same" >&2; return 2; }
			export TSX_ADMIN_PW=$a
		fi
	fi
	if [ -z "${TSX_ADMIN_USER:-}" ]; then
		echo "the Crestron admin user is missing: give --admin-user USER (or set TSX_ADMIN_USER)" >&2; return 2
	fi
	if [ -z "${TSX_ADMIN_PW:-}" ]; then
		echo "the Crestron admin password is missing: give --admin-password-file FILE (or --admin-password PW, or set TSX_ADMIN_PW)" >&2; return 2
	fi
	case "$TSX_ADMIN_USER" in *[!A-Za-z0-9._@-]*) echo "--admin-user: use only letters, digits and . _ @ -" >&2; return 2;; esac
	return 0
}
