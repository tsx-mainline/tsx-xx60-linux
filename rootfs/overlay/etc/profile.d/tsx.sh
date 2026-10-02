alias ll='ls -la'
export PAGER=less
# login banner: the dynamic line under /etc/motd (interactive shells only)
case $- in *i*)
	[ -r /etc/tsx/build-id ] && printf '   build %s, kernel %s\n\n' "$(cat /etc/tsx/build-id)" "$(uname -r)"
	# Lines of the board for the login banner (the boot status command, for example).
	[ -r /etc/tsx/motd.board ] && { cat /etc/tsx/motd.board; echo; }
	# Root password (tsx-rootpw, docs/rootfs.md "Root login"). The console
	# profile shows this in its own banner (tsx-banner).
	if [ "$(id -u)" = 0 ] && [ -x /usr/local/bin/tsx-rootpw ]; then
		[ "$(cat /etc/tsx/profile 2>/dev/null)" = console ] || { /usr/local/bin/tsx-rootpw note; echo; }
	fi;;
esac
