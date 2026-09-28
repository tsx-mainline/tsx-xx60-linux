alias ll='ls -la'
export PAGER=less
# login banner: the dynamic line under /etc/motd (interactive shells only)
case $- in *i*)
	[ -r /etc/tsx/build-id ] && printf '   build %s, kernel %s\n\n' "$(cat /etc/tsx/build-id)" "$(uname -r)";;
esac
