alias ll='ls -la'
export PAGER=less
# login banner: the dynamic line under /etc/motd (interactive shells only)
case $- in *i*)
	[ -r /etc/tsx/build-id ] && printf '   build %s, kernel %s\n\n' "$(cat /etc/tsx/build-id)" "$(uname -r)"
	# Root password (tsx-rootpw, docs/rootfs.md "Root login"). The console
	# profile shows this in its own banner (tsx-banner).
	if [ "$(id -u)" = 0 ] && [ -x /usr/local/bin/tsx-rootpw ]; then
		[ "$(cat /etc/tsx/profile 2>/dev/null)" = console ] || { /usr/local/bin/tsx-rootpw note; echo; }
		# With no password yet, a login on a text console (the panel screen, the
		# serial port) must choose one. A login over ssh is not asked.
		case $(tty 2>/dev/null) in
		/dev/tty*) /usr/local/bin/tsx-rootpw login || exit 1;;
		esac
	fi;;
esac
