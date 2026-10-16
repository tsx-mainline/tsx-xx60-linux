# tsx-preflight.sh: the check of the host before an installer tool contacts the
# panel or writes a file (bash, sourced FIRST by the tool). It checks the
# commands that the chosen mode of the tool needs, and the parts that are not
# commands but still stop a run: the bash version, /dev/tcp in bash, the
# modules of python3, a route to the panel, the tsx-linux-common checkout.
# It reports every problem in one message, with the package names for
# Debian and Ubuntu (apt), Fedora (dnf), Arch (pacman) and Alpine (apk), and
# then returns 3.
#
#   tsx_preflight TOOL [KEY=VALUE]...
#
# TOOL is install (tsx-install-mainline), restore (tsx-restore-factory) or
# stick (tsx-make-stick). The keys say what the run will do:
#   kind=       android, mainline, rescue, rescue-locked, unreachable or other
#               (the answer of the panel probe), or empty before the probe.
#               With no kind, the check cannot know if the panel runs stock
#               Android, so the tools for stock Android are only "maybe".
#   fetch=1     --fetch: the panel downloads the release. No payload here.
#   stage=      auto, yes or no (--stage)
#   uart=       auto, yes or no (--uart)
#   tfa=, psr=  auto, panel, puf or none (--tfa-source, --psr-source)
#   pw=1        a password is known (Crestron, mainline or rescue login)
#   prompts=1   the run asks questions for panel.conf
#   sshshell=1  --sshshell FILE with the UART
#   build=1     restore: build the bundle here (no --bundle)
#   rootssh=1   restore: patch rootsh into the system image (needs debugfs)
#   panel=ADDR  check the route to ADDR ("none" or empty: no route check)
#   routesoft=1 a missing route is a note, not an error (--dry-run)
#   wsip=1      the address of this host is given: no route lookup needed
#   check=1     --check-requirements: print everything and do not stop the tool
#   all=1       every command that the tool can need (for the host tests)
#
# The result: 0 when nothing is missing, 3 when something is. The messages go
# to stderr. In a normal run the function is silent when all is well. With
# check=1 it prints the whole list.
#
# installer/tests/test-preflight.sh checks this list against the scripts, so a
# new command in a script that is not in the list here fails the test.

# ---------------------------------------------------------------- bash ------
# tsx_pf_bash_ok MAJOR MINOR: true for bash 4.1 or newer. steps/rootsh needs
# coproc (4.0) and {fd} redirections (4.1), and factory/mkbundle.sh needs ${x^^}.
tsx_pf_bash_ok() { [ "$1" -gt 4 ] || { [ "$1" -eq 4 ] && [ "$2" -ge 1 ]; }; }
if ! tsx_pf_bash_ok "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
	echo "$(basename "$0"): this host has bash ${BASH_VERSION:-(unknown)}. The installer needs bash 4.1 or newer (steps/rootsh uses coproc and {fd} redirections). Install a newer bash and run the command again. The panel was not contacted." >&2
	exit 3
fi

# The standard tools that every driver uses.
TSX_PF_CORE="awk basename cat chmod cp cut date dirname du find grep head install ln ls mkdir mktemp mv rm sed seq sha256sum sleep sort stat tail tee timeout tr uname wc xargs"

# tsx_pf_pkg COMMAND: print "apt dnf pacman apk" package names for COMMAND.
# A "-" means: no package of that name (the command is part of the base).
tsx_pf_pkg() {
	case "$1" in
	sshpass) echo "sshpass sshpass sshpass sshpass";;
	ssh) echo "openssh-client openssh-clients openssh openssh-client";;
	python3) echo "python3 python3 python python3";;
	curl) echo "curl curl curl curl";;
	wget) echo "wget wget wget wget";;
	unzip) echo "unzip unzip unzip unzip";;
	debugfs) echo "e2fsprogs e2fsprogs e2fsprogs e2fsprogs-extra";;
	mke2fs|e2fsck) echo "e2fsprogs e2fsprogs e2fsprogs e2fsprogs";;
	ip) echo "iproute2 iproute iproute2 iproute2";;
	tar) echo "tar tar tar tar";;
	gzip) echo "gzip gzip gzip gzip";;
	cpio) echo "cpio cpio cpio cpio";;
	cmp|diff) echo "diffutils diffutils diffutils diffutils";;
	find|xargs) echo "findutils findutils findutils findutils";;
	grep) echo "grep grep grep grep";;
	sed) echo "sed sed sed sed";;
	awk) echo "gawk gawk gawk gawk";;
	pgrep) echo "procps procps-ng procps-ng procps";;
	ping) echo "iputils-ping iputils iputils iputils";;
	fping) echo "fping fping fping fping";;
	openssl) echo "openssl openssl openssl openssl";;
	pigz) echo "pigz pigz pigz pigz";;
	pymod:*|route) echo "- - - -";;
	timedatectl) echo "systemd systemd systemd -";;
	bash) echo "bash bash bash bash";;
	*) echo "coreutils coreutils coreutils coreutils";;
	esac
}

# tsx_pf_have COMMAND: true if COMMAND is in PATH. With SBIN=1, a command in
# /sbin or /usr/sbin counts too (the tool that runs it looks there itself).
# A command that is only in /sbin sets TSX_PF_SBIN_ONLY=1.
tsx_pf_have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	if [ "${2:-}" = sbin ]; then
		local d
		for d in ${TSX_PF_SBIN_DIRS:-/sbin /usr/sbin /usr/local/sbin}; do [ -x "$d/$1" ] && { TSX_PF_SBIN_ONLY=1; return 0; }; done
	fi
	return 1
}
# The busybox unzip applet counts as unzip.
tsx_pf_have_unzip() { command -v unzip >/dev/null 2>&1 || busybox --list 2>/dev/null | grep -qx unzip; }

# ------------------------------------------------------------- the lists ----
# tsx_pf_add LEVEL ITEM WHY: add one requirement. LEVEL: need (stops the run),
# maybe (the mode may need it: a note in the check list), opt (an option that
# makes a path faster or nicer). ITEM is a command, or ALT1|ALT2 for "one of".
PF_ITEMS=()
tsx_pf_add() { PF_ITEMS+=("$1	$2	$3"); }

# tsx_pf_collect TOOL KEY=VALUE...: fill PF_ITEMS and PF_ENV for the mode.
tsx_pf_collect() {
	local tool=$1; shift
	local kind= fetch=0 stage=auto uart=auto tfa=auto psr=auto pw=0 prompts=0 sshshell=0 build=0 rootssh=0 all=0 kv
	PF_PANEL= PF_ROUTESOFT=0 PF_WSIP=0 PF_CHECK=0 PF_ALL=0
	for kv in "$@"; do case "$kv" in
		kind=*) kind=${kv#kind=};; fetch=1) fetch=1;; stage=*) stage=${kv#stage=};; uart=*) uart=${kv#uart=};;
		tfa=*) tfa=${kv#tfa=};; psr=*) psr=${kv#psr=};; pw=1) pw=1;; prompts=1) prompts=1;; sshshell=1) sshshell=1;;
		build=1) build=1;; rootssh=1) rootssh=1;; panel=*) PF_PANEL=${kv#panel=};; routesoft=1) PF_ROUTESOFT=1;;
		wsip=1) PF_WSIP=1;; check=1) PF_CHECK=1;; all=1) all=1; PF_ALL=1;;
	esac; done
	[ "$all" = 0 ] || { fetch=0 stage=yes uart=yes tfa=puf psr=puf pw=1 prompts=1 sshshell=1 build=1 rootssh=1 kind=android; }
	PF_ITEMS=()
	local c android=maybe
	case "$kind" in
	android|unreachable|other) android=yes;;
	mainline|rescue|rescue-locked) android=no;;
	*) [ "$fetch" = 1 ] && android=no;;
	esac
	for c in $TSX_PF_CORE; do tsx_pf_add need "$c" "standard tool"; done

	case "$tool" in
	install|restore)
		tsx_pf_add need ssh "every connection to the panel"
		tsx_pf_add need tar "send files to the panel"
		tsx_pf_add need ip "find the address of this host and the rescue ('ip route get', 'ip neigh')"
		tsx_pf_add opt "fping|ping" "find the rescue by its MAC on the network (a sweep of the /24)"
		;;
	esac

	case "$tool" in
	install)
		# stock Android: the Crestron login, the web UI, the JSON of crestron-admin
		case "$android" in
		yes) tsx_pf_add need sshpass "the Crestron login of stock Android"
		     tsx_pf_add need curl "the web UI of stock Android (steps/crestron-admin)"
		     tsx_pf_add need python3 "steps/crestron-admin and the check of the rescue image";;
		maybe) tsx_pf_add maybe sshpass "the Crestron login, if the panel runs stock Android"
		       tsx_pf_add maybe curl "the web UI, if the panel runs stock Android"
		       tsx_pf_add maybe python3 "steps/crestron-admin, if the panel runs stock Android";;
		esac
		if [ "$pw" = 1 ] || [ "$kind" = rescue-locked ]; then tsx_pf_add need sshpass "a password login (Crestron, root or rescue)"
		elif [ "$android" = no ]; then tsx_pf_add maybe sshpass "a password login, if you give a root or rescue password"; fi
		if [ "$stage" != no ] && [ "$fetch" = 0 ]; then
			tsx_pf_add need gzip "compress root.img for the stage on the panel"
			tsx_pf_add opt pigz "compress root.img faster (gzip does it without)"
			tsx_pf_add need python3 "check that the rescue image can run a stage"
		fi
		;;
	restore)
		tsx_pf_add need sshpass "password logins (the rescue, the Crestron console)"
		tsx_pf_add need curl "poll the web UI of the panel after the restore"
		tsx_pf_add need python3 "tools/env: the U-Boot env of the unit (installer/sdcard/tsx-env.py)"
		if [ "$build" = 1 ]; then
			tsx_pf_add need unzip "open the .puf (installer/factory/puf-tool.sh)"
			tsx_pf_add need mke2fs "make the cache image (installer/factory/mkbundle.sh)"
			tsx_pf_add need e2fsck "check the images (installer/factory/mkbundle.sh)"
			tsx_pf_add need cmp "compare images (installer/factory/mkbundle.sh)"
			tsx_pf_add need diff "check the patch of sshShell.sh (installer/factory/mkbundle.sh)"
			tsx_pf_add need dd "cut the eMMC regions"
			tsx_pf_add need gzip "compress the eMMC regions"
			tsx_pf_add need truncate "make image files"
			tsx_pf_add need cksum "check the files of the .puf (installer/factory/puf-tool.sh)"
			[ "$rootssh" = 0 ] || tsx_pf_add need debugfs "patch rootsh into the system image (e2fsprogs; --stock-sshshell skips it)"
		fi
		;;
	stick)
		tsx_pf_add need gzip "compress root.img for the stage"
		tsx_pf_add need python3 "check that the rescue image can run a stage"
		;;
	esac

	# the UART
	if [ "$tool" != stick ]; then
		case "$uart" in
		yes) tsx_pf_add need "file:tools/bench/uc.sh" "the UART commands (tools/bench/uc.sh)"
		     tsx_pf_add need "serlog" "the serial logger tools/bench/serlog.py must run (--uart yes)"
		     tsx_pf_add need pgrep "see if the serial logger runs"
		     tsx_pf_add maybe "pymod:serial" "serlog.py needs the python3 module serial (pyserial)"
		     [ "$sshshell" = 0 ] || [ "$tool" != install ] || { tsx_pf_add need nohup "start the web server for sshShell.sh (--sshshell)"; tsx_pf_add need python3 "serve sshShell.sh to the panel (python3 -m http.server)"; };;
		auto) tsx_pf_add opt pgrep "see if the serial logger runs (--uart auto)";;
		esac
	fi

	# the vendor files from the .puf (speaker DSP files, Bluetooth PSR file):
	# rootfs/vendor-fetch.sh runs here when a source is puf. With auto, it runs
	# only if the panel has no file (a fetch run uses only a cached file).
	if [ "$tool" != restore ]; then
		local lvl=
		if [ "$tfa" = puf ] || [ "$psr" = puf ]; then lvl=need
		elif [ "$fetch" = 0 ] && { [ "$tfa" = auto ] || [ "$psr" = auto ]; }; then lvl=maybe; fi
		if [ -n "$lvl" ]; then
			tsx_pf_add $lvl "curl|wget" "download the Crestron .puf, 357 MB (rootfs/vendor-fetch.sh)"
			tsx_pf_add $lvl unzip "open the .puf (rootfs/vendor-fetch.sh; the unzip applet of busybox also works)"
			tsx_pf_add $lvl gzip "unpack the boot image from the .puf"
			tsx_pf_add $lvl cpio "unpack the boot image from the .puf"
			tsx_pf_add $lvl od "read the header of the boot image"
			tsx_pf_add $lvl dd "cut the boot image"
			if [ "$psr" = puf ]; then tsx_pf_add need debugfs "read the PSR file from the system image (e2fsprogs)"
			elif [ "$psr" = auto ] && [ "$fetch" = 0 ]; then tsx_pf_add maybe debugfs "read the PSR file from the system image (e2fsprogs)"; fi
		fi
	fi

	# the password prompt of panel.conf
	if [ "$prompts" = 1 ] && [ "$tool" != restore ]; then
		tsx_pf_add maybe "hash:openssl|mkpasswd|pymod:crypt" "hash a root password at the prompt (leave the password blank and give an SSH key to skip it)"
		tsx_pf_add maybe base64 "make the ESPHome API key at the prompt"
		tsx_pf_add opt readlink "read the time zone of this host for the prompt default"
		tsx_pf_add opt timedatectl "read the time zone of this host for the prompt default"
		tsx_pf_add opt curl "check the Home Assistant URL at the prompt"
	fi

	# not commands
	tsx_pf_add need "bash:/dev/tcp" "bash with /dev/tcp (the probe of the ssh banner of the panel)"
	case "$tool" in install|stick) [ -n "${TSX_CONFIG_BIN:-}" ] || tsx_pf_add need "common" "the tsx-linux-common checkout for tsx-config (--common DIR or TSX_COMMON)";; esac
}

# tsx_pf_os: print the package manager of this host: apt, dnf, pacman, apk or
# nothing.
tsx_pf_os() {
	local id= like= f=${TSX_PF_OS_RELEASE:-/etc/os-release}
	[ -r "$f" ] || return 0
	id=$(sed -n 's/^ID=//p' "$f" | tr -d '"' | head -n 1)
	like=$(sed -n 's/^ID_LIKE=//p' "$f" | tr -d '"' | head -n 1)
	case " $id $like " in
	*" debian "*|*" ubuntu "*) echo apt;;
	*" fedora "*|*" rhel "*|*" centos "*) echo dnf;;
	*" arch "*) echo pacman;;
	*" alpine "*) echo apk;;
	esac
}

# tsx_pf_describe COMMAND: one line "(apt install X, dnf install X, ...)".
tsx_pf_describe() {
	set -- $(tsx_pf_pkg "$1")
	local out= sep=
	[ "$1" = - ] || { out="apt install $1"; sep=", "; }
	[ "$2" = - ] || { out="$out${sep}dnf install $2"; sep=", "; }
	[ "$3" = - ] || { out="$out${sep}pacman -S $3"; sep=", "; }
	[ "$4" = - ] || out="$out${sep}apk add $4"
	printf '%s' "$out"
}

# tsx_pf_check_item ITEM: print nothing, return 0 if ITEM is present. Else set
# PF_MISS_CMD (the command to name) and return 1. PF_NOTE gets an extra hint.
tsx_pf_check_item() {
	local item=$1 alt
	PF_NOTE= PF_MISS_CMD=
	case "$item" in
	file:*)
		[ -x "${TSX_PF_TOP:-.}/${item#file:}" ] && return 0
		PF_MISS_CMD=; PF_NOTE="the file ${item#file:} is not in this checkout (--uart yes needs it)"; return 1;;
	serlog)
		if tsx_pf_have pgrep && pgrep -f 'serlog\.py' >/dev/null 2>&1; then return 0; fi
		tsx_pf_have pgrep || return 0   # pgrep has its own line
		PF_NOTE="the serial logger tools/bench/serlog.py does not run (--uart yes). Start it first: python3 tools/bench/serlog.py LOGFILE"; return 1;;
	pymod:*)
		tsx_pf_have python3 || return 0
		python3 -I -c "import ${item#pymod:}" >/dev/null 2>&1 && return 0
		PF_NOTE="python3 cannot import the module ${item#pymod:} (pip install pyserial)"; return 1;;
	hash:*)
		item=${item#hash:}
		if tsx_pf_have openssl && printf 'x\n' | openssl passwd -6 -stdin >/dev/null 2>&1; then return 0; fi
		tsx_pf_have mkpasswd && return 0
		tsx_pf_have python3 && python3 -I -c "import crypt" >/dev/null 2>&1 && return 0
		PF_MISS_CMD=openssl; return 1;;
	bash:/dev/tcp)
		case "$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/9' 2>&1)" in *"No such file"*) PF_NOTE="this bash was built without /dev/tcp"; return 1;; esac
		return 0;;
	common)
		local top=${TSX_PF_TOP:-.} common
		common=${TSX_COMMON:-$top/../tsx-linux-common}
		[ -x "$common/base/usr/local/sbin/tsx-config" ] && [ -f "$top/rootfs/overlay/usr/local/lib/tsx/board.sh" ] && return 0
		PF_NOTE="no tsx-linux-common checkout at $common. Set TSX_COMMON (or --common DIR) to the top of a checkout. The installer also needs a full checkout of tsx-xx60-linux (rootfs/overlay)"; return 1;;
	*"|"*)
		local first=${item%%|*} rest=$item
		while [ -n "$rest" ]; do
			alt=${rest%%|*}
			case "$alt" in unzip) tsx_pf_have_unzip && return 0;; *) tsx_pf_have "$alt" && return 0;; esac
			case "$rest" in *"|"*) rest=${rest#*|};; *) rest=;; esac
		done
		PF_MISS_CMD=$first; return 1;;
	unzip) tsx_pf_have_unzip && return 0; PF_MISS_CMD=unzip; return 1;;
	debugfs|mke2fs|e2fsck)
		TSX_PF_SBIN_ONLY=
		if tsx_pf_have "$item" sbin; then
			if [ "${TSX_PF_SBIN_ONLY:-}" = 1 ]; then
				[ "$PF_TOOL" = restore ] || return 0
				PF_NOTE="$item is in /sbin or /usr/sbin, but not in PATH. Add that folder to PATH (export PATH=\$PATH:/sbin:/usr/sbin)"; PF_MISS_CMD=; return 1
			fi
			return 0
		fi
		PF_MISS_CMD=$item; return 1;;
	*) tsx_pf_have "$item" && return 0; PF_MISS_CMD=$item; return 1;;
	esac
}

# tsx_preflight TOOL KEY=VALUE...
tsx_preflight() {
	local tool=$1 line level item why miss=() notes=() maybes=() opts=() oks=() cmds_missing=() n=0
	local self; self=$(basename "$0")
	TSX_PF_TOP=${TSX_PF_TOP:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
	PF_TOOL=$tool
	tsx_pf_collect "$@"
	# the bash version is checked at the top of this file
	if [ "$(uname -s 2>/dev/null)" != Linux ]; then
		miss+=("problem: this host is not Linux. The installer uses 'ip route get', GNU stat and /proc, which other systems do not have. Run it on Linux (a virtual machine or a container).")
	fi
	# The levels in order: need, maybe, opt. An item that a higher level has
	# already named is not named again.
	local seen=" " py_needed=0 lv
	for lv in need maybe opt; do
		for line in "${PF_ITEMS[@]}"; do
			level=${line%%	*}; line=${line#*	}; item=${line%%	*}; why=${line#*	}
			[ "$level" = "$lv" ] || continue
			case "$seen" in *" $item "*) continue;; esac
			seen="$seen$item "
			n=$((n + 1))
			if tsx_pf_check_item "$item"; then oks+=("$item"); [ "$item" != python3 ] || py_needed=1; continue; fi
			local name=${PF_MISS_CMD:-}
			case "$level" in
			need)
				if [ -n "$name" ]; then
					case " ${cmds_missing[*]:-} " in *" $name "*) continue;; esac
					cmds_missing+=("$name")
					miss+=("missing: $name ($(tsx_pf_describe "$name")). $why.")
				else miss+=("problem: ${PF_NOTE:-$why}"); fi;;
			maybe) maybes+=("${name:-$item}|$why|${PF_NOTE:-}");;
			opt) opts+=("${name:-$item}|$why|${PF_NOTE:-}");;
			esac
		done
	done
	# the python3 modules that the scripts import
	if { tsx_pf_have python3 && [ "$py_needed" = 1 ]; } || { tsx_pf_have python3 && [ "$PF_ALL" = 1 ]; }; then
		local mod missmod=
		for mod in argparse json struct sys zlib; do python3 -I -c "import $mod" >/dev/null 2>&1 || missmod="$missmod $mod"; done
		[ -z "$missmod" ] || miss+=("problem: python3 cannot import the module(s)${missmod}. The scripts need these standard modules. Install the full python3 package ($(tsx_pf_describe python3)).")
	fi
	# a route to the panel
	if [ -n "$PF_PANEL" ] && [ "$PF_PANEL" != none ] && [ "$PF_WSIP" = 0 ] && tsx_pf_have ip; then
		local src
		src=$(ip route get "$PF_PANEL" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
		if [ -z "$src" ]; then
			if [ "$PF_ROUTESOFT" = 1 ]; then notes+=("'ip route get $PF_PANEL' shows no address of this host. A real run (without --dry-run) stops here.")
			else miss+=("problem: 'ip route get $PF_PANEL' shows no address of this host, so there is no route to the panel. Connect this host to the network of the panel, or fix the address."); fi
		fi
	fi

	if [ "$PF_CHECK" = 1 ]; then
		echo "$self --check-requirements: $n requirements for this mode" >&2
		[ "${#oks[@]}" = 0 ] || echo "  present: ${oks[*]}" >&2
		local m
		for m in "${miss[@]:-}"; do [ -z "$m" ] || echo "  $m" >&2; done
		local d
		for m in "${notes[@]:-}"; do [ -z "$m" ] || echo "  note: $m" >&2; done
		for m in "${maybes[@]:-}"; do
			[ -z "$m" ] || { d=$(tsx_pf_describe "${m%%|*}"); echo "  note: ${m%%|*} is missing. A path of this mode may need it: $(printf '%s' "$m" | cut -d'|' -f2)${d:+. Install: $d}$(printf '%s' "$m" | cut -d'|' -f3 | sed 's/^./. &/')" >&2; }
		done
		for m in "${opts[@]:-}"; do
			[ -z "$m" ] || { d=$(tsx_pf_describe "${m%%|*}"); echo "  optional: ${m%%|*} is missing: $(printf '%s' "$m" | cut -d'|' -f2)${d:+. Install: $d}" >&2; }
		done
		if [ "${#miss[@]}" = 0 ]; then echo "$self: this host has everything this mode needs." >&2; return 0; fi
		tsx_pf_fixline "${cmds_missing[@]:-}"
		echo "$self: this host is missing requirements (exit 3)." >&2
		return 3
	fi
	[ "${#miss[@]}" != 0 ] || return 0
	echo "$self: this host is missing requirements. The panel was not contacted and nothing was changed." >&2
	local m
	for m in "${miss[@]}"; do echo "  $m" >&2; done
	tsx_pf_fixline "${cmds_missing[@]:-}"
	echo "Fix this and run the same command again. To test the host first, add --check-requirements to the command." >&2
	return 3
}

# tsx_pf_fixline CMD...: one install line for the package manager of this host.
tsx_pf_fixline() {
	local mgr c pk list= idx
	mgr=$(tsx_pf_os)
	[ -n "$mgr" ] || return 0
	case "$mgr" in apt) idx=1;; dnf) idx=2;; pacman) idx=3;; apk) idx=4;; esac
	for c in "$@"; do
		[ -n "$c" ] || continue
		pk=$(set -- $(tsx_pf_pkg "$c"); eval "echo \${$idx}")
		case " $list " in *" $pk "*) ;; *) list="$list $pk";; esac
	done
	[ -n "$list" ] || return 0
	case "$mgr" in
	apt) echo "This host uses apt. Run: sudo apt install$list" >&2;;
	dnf) echo "This host uses dnf. Run: sudo dnf install$list" >&2;;
	pacman) echo "This host uses pacman. Run: sudo pacman -S$list" >&2;;
	apk) echo "This host uses apk. Run: apk add$list" >&2;;
	esac
}

# tsx_preflight_commands TOOL: print every command that the mode "all" of TOOL
# checks, one per line (the test uses it). An alternative like curl|wget prints
# both names. Items that are not commands (file:, pymod:, hash:, serlog,
# bash:/dev/tcp, common) are left out.
tsx_preflight_commands() {
	local line item
	tsx_pf_collect "$1" all=1
	for line in "${PF_ITEMS[@]}"; do
		line=${line#*	}; item=${line%%	*}
		case "$item" in hash:*) printf 'openssl\nmkpasswd\n'; continue;; file:*|pymod:*|serlog|bash:*|common) continue;; esac
		echo "$item" | tr '|' '\n'
	done | sort -u
}
