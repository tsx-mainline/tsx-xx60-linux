#!/bin/bash
# Host test: the check of the host before an installer tool contacts the panel
# (installer/lib/tsx-preflight.sh).
#   1. a PATH with no sshpass: each tool stops with exit code 3, names sshpass
#      with the package names, and does not call ssh, curl or anything else,
#      and it writes no result file
#   2. all the missing commands are in ONE message
#   3. a PATH with every command: --check-requirements exits 0
#   4. the list per mode: what each mode needs and what it does not need
#   5. the parts that are not commands: bash version, python3 modules, a route,
#      the tsx-linux-common checkout
#   6. --check-requirements is in the --help text of each tool
#   7. no drift: every external command that the host scripts call is in the
#      list of the check, and every command in the list is called somewhere.
#      A new script in installer/ must be sorted into the lists below.
# The test needs no panel and no network.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }
unset TSX_ADMIN_USER TSX_ADMIN_PW TSX_MAINLINE_PW TSX_RESCUE_PW SSHPASS TSX_PANEL_KIND
. "$HERE/lib/tsx-preflight.sh"
INSTALL=$HERE/tsx-install-mainline RESTORE=$HERE/tsx-restore-factory STICK=$HERE/tsx-make-stick
CALLS=$W/calls

# The commands that a stub logs. They stand for the commands that contact the panel.
LOGGED="ssh sshpass curl wget scp"

# mkpath DIR [OMIT...]: a PATH folder with every command of the lists (a link to
# the real one, else a stub that does nothing), without the commands in OMIT.
# bash and env stay, because the tools start with /usr/bin/env bash.
mkpath() {
	local d=$1 c real omit=" ${*:2} " all
	rm -rf "$d"; mkdir -p "$d"
	all="$( { tsx_preflight_commands install; tsx_preflight_commands restore; tsx_preflight_commands stick; echo bash; echo env; echo mkdir; } | sort -u)"
	for c in $all; do
		case "$omit" in *" $c "*) continue;; esac
		case " $LOGGED " in
		*" $c "*) printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$c" "$CALLS" > "$d/$c"; chmod +x "$d/$c"; continue;;
		esac
		# pgrep says: the serial logger runs (the --uart yes checks)
		[ "$c" != pgrep ] || { printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"; continue; }
		real=$(command -v "$c" 2>/dev/null || true)
		case "$real" in /*) ln -s "$real" "$d/$c";; *) printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c";; esac
	done
	return 0
}
# the OS fixtures for the install line
mkdir -p "$W/os"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$W/os/debian"
printf 'ID=alpine\n' > "$W/os/alpine"
printf 'ID=fedora\n' > "$W/os/fedora"
printf 'ID=arch\n' > "$W/os/arch"
export TSX_CONFIG_BIN=/bin/true   # the tsx-config check has its own test (5)
export TSX_PF_SBIN_DIRS=$W/nosbin   # this host may have e2fsprogs in /sbin: the tests choose
run() {  # run PATHDIR CMD...: run a tool with a PATH; set OUT and RC
	local p=$1; shift
	OUT=$(env PATH="$p" "$@" 2>&1); RC=$?
}
nocalls() { [ ! -s "$CALLS" ]; }

echo "== 1. a PATH with no sshpass: exit 3, the name, the packages, no contact, no file"
mkpath "$W/p1" sshpass
for tool in "$INSTALL" "$RESTORE"; do
	rm -f "$CALLS" "$W/res.txt"
	if [ "$tool" = "$INSTALL" ]; then
		TSX_ADMIN_PW=x run "$W/p1" "$tool" 192.0.2.10 --payload "$W/nopayload" --kernel lts --dry-run --results "$W/res.txt" --admin-user a
	else
		run "$W/p1" "$tool" 192.0.2.10 --bundle "$W/nobundle" --dry-run --uart no --ws-ip 192.0.2.1 --results "$W/res.txt"
	fi
	[ $RC = 3 ] && ok "$(basename "$tool"): exit 3" || bad "$(basename "$tool"): rc $RC: $OUT"
	case "$OUT" in *"missing: sshpass (apt install sshpass, dnf install sshpass, pacman -S sshpass, apk add sshpass)"*) ok "$(basename "$tool"): names sshpass with the four package commands";; *) bad "$(basename "$tool"): message: $OUT";; esac
	nocalls && [ ! -e "$W/res.txt" ] && ok "$(basename "$tool"): no ssh/curl call, no result file" || bad "$(basename "$tool"): contact or file: $(cat "$CALLS" 2>/dev/null)"
done
# Alone: every tool of the PATH exists except sshpass, so sshpass is the only name.
case "$OUT" in *"missing: "*"missing: "*) bad "more than sshpass missing: $OUT";; *) ok "only sshpass is named";; esac

echo "== 2. all the missing commands are in one message"
mkpath "$W/p2" sshpass unzip gzip cpio debugfs
rm -f "$CALLS"
TSX_PF_OS_RELEASE=$W/os/debian TSX_ADMIN_PW=x run "$W/p2" "$INSTALL" 192.0.2.10 --payload "$W/nopayload" --kernel lts --dry-run --tfa-source puf --psr-source puf --results "$W/res.txt" --admin-user a
n=$(printf '%s\n' "$OUT" | grep -c '^  missing: ')
[ $RC = 3 ] && [ "$n" = 5 ] && ok "five missing commands in one run: $(printf '%s\n' "$OUT" | grep -o 'missing: [a-z0-9]*' | tr '\n' ' ')" || bad "n=$n rc $RC: $OUT"
case "$OUT" in *"sudo apt install sshpass gzip unzip cpio e2fsprogs"*) ok "one install line for this host (apt)";; *) bad "install line: $OUT";; esac
for os in alpine fedora arch; do
	TSX_PF_OS_RELEASE=$W/os/$os TSX_ADMIN_PW=x run "$W/p2" "$INSTALL" 192.0.2.10 --payload "$W/nopayload" --kernel lts --dry-run --tfa-source puf --psr-source puf --results "$W/res.txt" --admin-user a
	case "$os:$OUT" in
	alpine:*"apk add sshpass gzip unzip cpio e2fsprogs-extra"*|fedora:*"sudo dnf install sshpass gzip unzip cpio e2fsprogs"*|arch:*"sudo pacman -S sshpass gzip unzip cpio e2fsprogs"*) ok "install line for $os";; *) bad "install line for $os: $(printf '%s\n' "$OUT" | tail -n 3)";; esac
done
nocalls && ok "still no contact" || bad "contact: $(cat "$CALLS")"

echo "== 3. a PATH with every command: --check-requirements exits 0"
mkpath "$W/p3"
for tool in "$INSTALL" "$RESTORE" "$STICK"; do
	run "$W/p3" "$tool" --check-requirements
	[ $RC = 0 ] && ok "$(basename "$tool") --check-requirements: exit 0" || bad "$(basename "$tool"): rc $RC: $OUT"
done
case "$OUT" in *"has everything this mode needs"*) ok "it says so";; *) bad "no verdict: $OUT";; esac
nocalls && ok "no contact" || bad "contact: $(cat "$CALLS")"
mkpath "$W/p3b" sshpass
run "$W/p3b" "$INSTALL" --check-requirements --admin-password x
[ $RC = 3 ] && case "$OUT" in *"missing: sshpass"*) true;; *) false;; esac && ok "--check-requirements names sshpass and exits 3" || bad "check: rc $RC: $OUT"

echo "== 4. the list per mode"
mkpath "$W/pm"
# want TOOL CMD yes|no LABEL ARGS...: with CMD missing from the PATH, --check-requirements
# exits 3 (yes) or 0 (no). The environment of the call holds KIND and the like.
want() {
	local tool=$1 c=$2 exp=$3 label=$4; shift 4
	mv "$W/pm/$c" "$W/pm/.held"
	run "$W/pm" "$tool" --check-requirements "$@"
	mv "$W/pm/.held" "$W/pm/$c"
	if [ "$exp" = yes ]; then [ $RC = 3 ] && ok "$label: $c is needed" || bad "$label: $c is not needed (rc $RC): $OUT"
	else [ $RC = 0 ] && ok "$label: $c is not needed" || bad "$label: $c is needed (rc $RC): $OUT"; fi
}
NOPUF=(--tfa-source none --psr-source none)
export TSX_PANEL_KIND=android
for c in sshpass curl python3 ssh ip tar; do want "$INSTALL" $c yes "install, stock Android, --stage no" --stage no "${NOPUF[@]}"; done
for c in gzip unzip debugfs cpio; do want "$INSTALL" $c no "install, stock Android, --stage no" --stage no "${NOPUF[@]}"; done
unset TSX_PANEL_KIND
for c in ssh tar ip; do want "$INSTALL" $c yes "install --fetch" --fetch v0.0.0 "${NOPUF[@]}"; done
for c in sshpass curl python3 gzip unzip debugfs cpio; do want "$INSTALL" $c no "install --fetch, no password" --fetch v0.0.0 "${NOPUF[@]}"; done
TSX_MAINLINE_PW=x want "$INSTALL" sshpass yes "install --fetch with a password" --fetch v0.0.0 "${NOPUF[@]}"
for c in unzip gzip cpio od dd debugfs; do want "$INSTALL" $c yes "install, both sources puf" --fetch v0.0.0 --tfa-source puf --psr-source puf; done
want "$INSTALL" debugfs no "install, only the DSP files from the .puf" --fetch v0.0.0 --tfa-source puf --psr-source none
want "$INSTALL" unzip no "install, sources auto, kind not known (a note, not a stop)" --stage no
TSX_PANEL_KIND=mainline want "$INSTALL" gzip yes "install, kiosk, --stage yes" --stage yes "${NOPUF[@]}"
TSX_PANEL_KIND=mainline want "$INSTALL" python3 yes "install, kiosk, --stage yes" --stage yes "${NOPUF[@]}"
TSX_PANEL_KIND=mainline want "$INSTALL" gzip no "install, kiosk, --stage no" --stage no "${NOPUF[@]}"
for c in pgrep nohup python3; do TSX_PANEL_KIND=mainline want "$INSTALL" $c yes "install --uart yes --sshshell" --uart yes --sshshell /x/sshShell.sh --stage no "${NOPUF[@]}"; done
for c in sshpass ssh curl python3 ip tar; do want "$RESTORE" $c yes "restore --bundle" --bundle /x --uart no --ws-ip 192.0.2.1; done
for c in unzip mke2fs e2fsck debugfs cmp diff; do want "$RESTORE" $c no "restore --bundle" --bundle /x --uart no --ws-ip 192.0.2.1; done
for c in unzip mke2fs e2fsck debugfs cmp diff dd gzip truncate cksum; do want "$RESTORE" $c yes "restore, bundle built here" --puf /x/p.puf --uart no --ws-ip 192.0.2.1; done
want "$RESTORE" debugfs no "restore --stock-sshshell" --puf /x/p.puf --uart no --ws-ip 192.0.2.1 --stock-sshshell
want "$RESTORE" pgrep yes "restore --uart yes" --bundle /x --uart yes --ws-ip 192.0.2.1
for c in gzip python3; do want "$STICK" $c yes "stick" --config /x/c "${NOPUF[@]}"; done
for c in ssh sshpass ip curl tar; do want "$STICK" $c no "stick" --config /x/c "${NOPUF[@]}"; done
want "$STICK" unzip yes "stick, --tfa-source puf" --config /x/c --tfa-source puf
# the stage 2 of the install: the answer of the probe decides (no answer = assume stock Android)
mkpath "$W/p4" curl
# a payload that passes the checks of the driver before the probe
mkdir -p "$W/payload/lts"; echo r > "$W/payload/rescue.img"; for f in manifest root.img boot.img; do echo "$f" > "$W/payload/lts/$f"; done
(cd "$W/payload/lts" && sha256sum manifest root.img boot.img > SHA256SUMS)
rm -f "$CALLS" "$W/res.txt"
run "$W/p4" "$INSTALL" 192.0.2.10 --payload "$W/payload" --kernel lts --dry-run --results "$W/res.txt" --tfa-source none --psr-source none --admin-user a --stage no
if [ $RC = 3 ]; then
	case "$OUT" in *"missing: curl"*) ok "after the probe (no answer = stock Android): curl is needed, exit 3";; *) bad "stage 2 message: $OUT";; esac
else bad "stage 2: rc $RC: $OUT"; fi
nocalls && ok "stage 2: no ssh or curl call before the stop (the result file exists by then: the stop is after the probe)" || bad "stage 2 contact: $(cat "$CALLS" 2>/dev/null)"

echo "== 5. the parts that are not commands"
tsx_pf_bash_ok 3 2 && bad "bash 3.2 passed" || ok "bash 3.2 is too old"
tsx_pf_bash_ok 4 0 && bad "bash 4.0 passed" || ok "bash 4.0 is too old (no {fd} redirection)"
tsx_pf_bash_ok 4 1 && tsx_pf_bash_ok 5 0 && tsx_pf_bash_ok 5 2 && ok "bash 4.1, 5.0 and 5.2 pass" || bad "new bash"
bash -c 'case "$(bash -c "exec 3<>/dev/tcp/127.0.0.1/9" 2>&1)" in *"No such file"*) exit 1;; esac' && ok "this bash has /dev/tcp (the check passes)" || bad "no /dev/tcp in this bash"
# python3 with a missing module
cp -a "$W/p3" "$W/pypath"; rm -f "$W/pypath/python3"
printf '#!/bin/sh\ncase "$*" in *"import zlib"*) exit 1;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$W/pypath/python3"; chmod +x "$W/pypath/python3"
run "$W/pypath" "$STICK" --check-requirements
[ $RC = 3 ] && case "$OUT" in *"python3 cannot import the module(s) zlib"*) true;; *) false;; esac && ok "python3 with no zlib module: named, exit 3" || bad "python3 module: rc $RC: $OUT"
# a route: a stub ip without src
cp -a "$W/p3" "$W/ipnone"; rm -f "$W/ipnone/ip"; printf '#!/bin/sh\nexit 0\n' > "$W/ipnone/ip"; chmod +x "$W/ipnone/ip"
run "$W/ipnone" "$RESTORE" --bundle /x --uart no --check-requirements 192.0.2.10
[ $RC = 3 ] && case "$OUT" in *"no route to the panel"*) true;; *) false;; esac && ok "no route to the panel: exit 3" || bad "route: rc $RC: $OUT"
run "$W/ipnone" "$INSTALL" --check-requirements --dry-run 192.0.2.10
[ $RC = 0 ] && case "$OUT" in *"A real run (without --dry-run) stops here"*) true;; *) false;; esac && ok "install --dry-run: no route is a note" || bad "route dry-run: rc $RC: $OUT"
run "$W/ipnone" "$RESTORE" --bundle /x --uart no --ws-ip 192.0.2.1 --check-requirements 192.0.2.10
[ $RC = 0 ] && ok "--ws-ip: no route lookup" || bad "ws-ip: rc $RC: $OUT"
printf '#!/bin/sh\necho "192.0.2.10 dev eth0 src 192.0.2.99"\n' > "$W/ipnone/ip"
run "$W/ipnone" "$RESTORE" --bundle /x --uart no --check-requirements 192.0.2.10
[ $RC = 0 ] && ok "a route with a source address passes" || bad "route ok: rc $RC: $OUT"
# the tsx-linux-common checkout
run "$W/p3" env -u TSX_CONFIG_BIN TSX_COMMON="$W/nocommon" "$INSTALL" --check-requirements
[ $RC = 3 ] && case "$OUT" in *"no tsx-linux-common checkout at $W/nocommon"*) true;; *) false;; esac && ok "no tsx-linux-common checkout: named, exit 3" || bad "common: rc $RC: $OUT"
# a host that is not Linux
cp -a "$W/p3" "$W/unamex"; rm -f "$W/unamex/uname"; printf '#!/bin/sh\necho Darwin\n' > "$W/unamex/uname"; chmod +x "$W/unamex/uname"
run "$W/unamex" "$STICK" --check-requirements
[ $RC = 3 ] && case "$OUT" in *"this host is not Linux"*) true;; *) false;; esac && ok "a host that is not Linux: named, exit 3" || bad "uname: rc $RC: $OUT"
# e2fsprogs in /sbin but not in PATH: an error for the restore (mkbundle.sh looks in PATH), no error for the vendor download
mkdir -p "$W/sb"; printf '#!/bin/sh\nexit 0\n' > "$W/sb/debugfs"; chmod +x "$W/sb/debugfs"
mkpath "$W/pe" debugfs
TSX_PF_SBIN_DIRS=$W/sb run "$W/pe" "$RESTORE" --puf /x/p.puf --uart no --ws-ip 192.0.2.1 --check-requirements
[ $RC = 3 ] && case "$OUT" in *"debugfs is in /sbin or /usr/sbin, but not in PATH"*) true;; *) false;; esac && ok "restore: debugfs only in /sbin: named with the PATH hint" || bad "sbin restore: rc $RC: $OUT"
TSX_PF_SBIN_DIRS=$W/sb run "$W/pe" "$INSTALL" --fetch v0.0.0 --tfa-source puf --psr-source puf --check-requirements
[ $RC = 0 ] && ok "install: debugfs only in /sbin is fine (vendor-fetch.sh looks there)" || bad "sbin install: rc $RC: $OUT"

echo "== 6. --check-requirements is in --help"
for tool in "$INSTALL" "$RESTORE" "$STICK"; do
	OUT=$("$tool" --help 2>&1); case "$OUT" in *--check-requirements*) true;; *) false;; esac && ok "$(basename "$tool") --help names --check-requirements" || bad "$(basename "$tool") --help"
done

echo "== 7. no drift between the scripts and the list"
cat > "$W/drift.py" <<'PY'
import importlib.util, os, subprocess, sys

here = sys.argv[1]
spec = importlib.util.spec_from_file_location("preflight_scan", os.path.join(here, "tests", "preflight-scan.py"))
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)

# Commands that the scan may find. A word that is not here is a word of a
# message or a variable, not a command. A new command that is not here and not
# in a list is not seen, so add the name of an unusual command here.
VOCAB = set("""
awk base64 basename bash blkid busybox cat chmod chown cksum cmp cp cpio curl cut date dd debugfs df diff dirname docker
dumpe2fs du e2fsck env expr fdisk file find fping fuser fw_printenv fw_setenv getprop git grep gunzip gzip head hostname
id install ip kill ln logger losetup ls lsblk mcopy md5sum mke2fs mkdir mkfifo mkfs.ext4 mkfs.fat mknod mkpasswd mktemp mount mv nc nohup
od openssl pgrep pigz ping pkill ps python3 readlink reboot rm sed seq setsid sfdisk sh sha256sum sleep sort ssh sshpass
stat stty sync tail tar tee timedatectl timeout tr truncate umount uname unzip wc wget xargs xz zcat zip zstd
""".split())

# Files that the drivers use on the host. Every command in them has to be in the
# list of tsx-preflight.sh.
HOST = """tsx-install-mainline tsx-restore-factory tsx-make-stick steps/rootsh steps/crestron-admin steps/tsx-ensure-root
lib/tsx-creds.sh lib/tsx-config-prompt.sh lib/tsx-stage.sh lib/tsx-preflight.sh factory/mkbundle.sh factory/puf-tool.sh
factory/crestron-fs.sh ../rootfs/vendor-fetch.sh ../tools/bench/uc.sh""".split()
# Files with host functions and panel code in one file. PANEL_ONLY says which
# of their commands run on the panel (in the rescue or on Android).
MIXED = {
    "lib/tsx-rescue.sh": "blkid dd df e2fsck losetup mkfs.ext4 mount od readlink sync umount fw_printenv",
    "lib/tsx-tfa.sh": "awk cp cpio cut dd gzip head ls mkdir mount mv od ps rm sed sha256sum tr umount wc",
    "lib/tsx-psr.sh": "cat cp cut grep head mkdir mount mv rm sed sha256sum tr umount wc",
}
# Files that run on the panel (the rescue, Android or the kiosk), or that the
# drivers do not call. Their commands do not need the host.
PANEL = """steps/tsx-netinstall steps/tsx-rescue-arm.sh steps/tsx-rescue-install steps/tsx-rescue-staged
lib/tsx-arm-from-mainline.sh lib/tsx-ledstock.sh lib/tsx-verify-sig.py factory/tsx-emmc-restore factory/tsx-factory-restore""".split()
NOT_CALLED = """steps/mkp2rootfs.sh steps/mkpanelfetch.sh steps/tsx-deploy-tfa.sh""".split()
# Commands in HOST files that run on the panel or on another machine, with the reason.
HOST_PANEL_SIDE = {
    "factory/puf-tool.sh": "sfdisk mcopy mkfs.fat",    # the card subcommand (tests and development), not called by tsx-restore-factory
    "factory/crestron-fs.sh": "mkfs.fat",              # the same
    "steps/tsx-ensure-root": "id",                     # rootsh PANEL id runs on the panel
    "lib/tsx-stage.sh": "busybox",                     # busybox runs on the panel
    "../rootfs/vendor-fetch.sh": "apk busybox",        # apk: Alpine build container only. busybox: the unzip applet (checked as unzip)
    "lib/tsx-preflight.sh": "busybox",                 # the unzip applet of busybox counts as unzip
}
NOT_CHECKED = set("bash sh env".split())               # the shell that runs the script

def words(path):
    return {w for w in scan.scan([path])[path] if w in VOCAB}

# 1. every file of installer/ is sorted into a list. The folder steps/root-shell
# is not read: only the plain files of each folder are listed.
listed = set(HOST) | set(MIXED) | set(PANEL) | set(NOT_CALLED)
unsorted = []
for sub in ("", "steps", "lib", "factory"):
    d = os.path.join(here, sub)
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if not os.path.isfile(p) or name.startswith(".") or name.endswith((".example", ".md")):
            continue
        rel = os.path.join(sub, name) if sub else name
        if rel not in listed:
            unsorted.append(rel)
for rel in unsorted:
    print("FAIL: %s is not sorted into HOST, MIXED, PANEL or NOT_CALLED in installer/tests/test-preflight.sh" % rel)

# 2. the commands that the host files call, and the list of the check
lib = set(subprocess.run(["bash", "-c", '. "$1"; for t in install restore stick; do tsx_preflight_commands $t; done', "_",
                          os.path.join(here, "lib", "tsx-preflight.sh")], capture_output=True, text=True).stdout.split())
called = set()
bad = 0
for w in sorted(lib - VOCAB):
    print("FAIL: '%s' is in the list of tsx-preflight.sh, and not in VOCAB of this test" % w)
    bad += 1
files = [(f, set(HOST_PANEL_SIDE.get(f, "").split())) for f in HOST] + [(f, set(p.split())) for f, p in MIXED.items()]
for rel, skip in files:
    found = words(os.path.join(here, rel)) - skip - NOT_CHECKED
    if rel in MIXED:
        pass
    called |= found
    for w in sorted(found - lib):
        print("FAIL: %s calls '%s', and installer/lib/tsx-preflight.sh does not list it" % (rel, w))
        bad += 1
for w in sorted(lib - called):
    print("FAIL: installer/lib/tsx-preflight.sh lists '%s', and no host script calls it" % w)
    bad += 1

# 3. the scan itself sees what it must see
rootsh = words(os.path.join(here, "steps/rootsh"))
for w in ("sshpass", "ssh", "timeout", "stat"):
    if w not in rootsh:
        print("FAIL: the scan does not find %s in steps/rootsh" % w)
        bad += 1

# 4. the python3 modules of the host scripts
mods = set()
for rel in ("sdcard/tsx-env.py",):
    for line in open(os.path.join(here, rel)):
        line = line.strip()
        if line.startswith("import "):
            mods |= {m.strip() for m in line[7:].split(",")}
listed_mods = set("argparse json struct sys zlib os".split())
for m in sorted(mods - listed_mods):
    print("FAIL: sdcard/tsx-env.py imports %s, and the check does not test it" % m)
    bad += 1

print("scan: %d host files, %d mixed files, %d commands in the list, %d called, %d unsorted files" % (len(HOST), len(MIXED), len(lib), len(called), len(unsorted)))
sys.exit(1 if bad or unsorted else 0)
PY
OUT=$(python3 -I "$W/drift.py" "$HERE" 2>&1); RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
[ $RC = 0 ] && ok "every command of the host scripts is in the list, and the list has no extra command" || bad "drift (see above)"

echo
echo "$N ok, $F failed"
[ $F = 0 ] && echo "PASS test-preflight" || echo "FAIL test-preflight"
exit $F
