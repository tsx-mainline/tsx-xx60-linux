#!/bin/bash
# Build the FULL factory-restore bundle for one xx60 unit: the SD
# card part (puf-tool.sh (installer/factory) bundle: Crestron table, golden boot.img,
# system.img for p2, empty p5..p8, the unit's env with the mainline hook removed)
# plus the eMMC part (the eMMC-boot migration puts mainline on the eMMC; stock
# Android needs its boot/system/recovery/cache/data/misc regions back):
#   boot.img, logo.img, system.img      from the .puf (what crestronLocalUpgrade.sh
#                                       writes: boot <- boot.img, logo <- logo.img,
#                                       system <- system.img; nothing else)
#   recovery/cache/data/misc            NOT in the .puf. With a backup (--emmc-raw): the
#                                       unit's own regions (gzipped; misc = zeros).
#                                       WITHOUT a backup (default): stock Android uses none
#                                       of them (fstab.amlogic mounts only /system from the
#                                       eMMC; the env has no recovery command), so recovery,
#                                       misc, data and the alignment gaps are zeroed, cache
#                                       gets an EMPTY ext4 with the factory parameters (Amlogic
#                                       "dig" may use /dev/block/cache), logo is checked on
#                                       the size of logo.img only (head:)
#   u-boot.bin                          NEVER written; compared with the unit's boot0
#                                       backup -> uboot-check.txt (finding, no action);
#                                       without --boot0 the manifest says boot0_sha256=any and
#                                       tsx-emmc-restore checks boot0 is unchanged by the run
#
#   mkbundle.sh --puf FILE --env SRC --out DIR [--emmc-raw FILE --boot0 FILE]
#               [--puf-sha256 HEX] [--emmc-sha256 HEX] [--boot0-sha256 HEX]
#               [--sshshell FILE | --stock-sshshell]
#
#   --puf       the Crestron package (pristine: sha256 96438108...; the copy at the
#               project root, b027097c..., has a modified system.img)
#   --env       the unit's env: a 64 KiB block (dd of mmcblk0 at 1 MiB; tsx-restore-factory
#               reads it live from the card), p1:tsxenv.bak, or a full card image
#               (tsx-env.py reads it at 0x100000). Carries the unit's identity (MAC, tsid,
#               model); the mainline hook is removed (tsx-env.py unhook)
#   --emmc-raw  optional: the unit's raw eMMC image (zcat of captures/tsw-1060-unitB/emmc/*.img.gz)
#   --boot0     optional (with --emmc-raw): the unit's mmcblk1boot0 image
# Root over ssh (DEFAULT): /system/bin/sshShell.sh inside the .puf's own system.img
#               gets a `rootsh` branch: the interactive (tty) branch's single line
#                 /system/bin/telnetSSHProxy SSH $1
#               becomes
#                 if [ "$command" == "rootsh" ]; then /system/bin/bash -l;
#                 else /system/bin/telnetSSHProxy SSH $1; fi
#               (5 lines, same indentation); the rest of the file is unchanged and this is
#               verified (diff against the stock file). A firmware whose sshShell.sh does not
#               have that line right after `if [ -t $fd ]; then` is refused (unknown or
#               already modified image: use the pristine .puf, --sshshell or --stock-sshshell).
#               Nothing from the firmware is kept in this repo: the patch is the awk recipe
#               below. `ssh -tt $TSX_ADMIN_USER@panel rootsh` then gets root right after the
#               restore, no UART (installer/steps/rootsh); the Crestron console is unchanged.
#   --sshshell  optional: put FILE (your own sshShell.sh) in as is instead of patching the
#               image's copy. (Old forms `--root-ssh` / `--root-ssh FILE` still work.)
#   --stock-sshshell  optional: leave system.img byte-identical to the .puf (no rootsh; root
#               over ssh after the restore then needs the UART)
#               Either way a new file goes into system.img with debugfs -w (no mount, no root
#               needed on the host); the original inode's mode/uid/gid and all extended
#               attributes (security.selinux) are read first and put back on the new inode,
#               then verified (e2fsck -fn, byte compare, stat, ea_list). system.img is used both
#               for the eMMC "system" region and for card p2 (golden /system): the patch is in both.
# Output DIR: everything tsx-factory-restore (card) and tsx-emmc-restore (eMMC)
# need, plus factory.manifest (card, puf-tool format; rootsh patch: system.img's file line
# reflects the patched image, plus a harmless system_patch= line), emmc.manifest (ditto),
# uboot-check.txt, env-identity.txt, puf.info, SHA256SUMS. Nothing here touches a panel.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); WORK=$(cd "$HERE/.." && pwd)
ENVPY="python3 $WORK/sdcard/tsx-env.py"
die() { echo "mkbundle: ERROR: $*" >&2; exit 1; }
say() { echo "mkbundle: $*" >&2; }
PUF= RAW= BOOT0= ENVSRC= OUT= PUFSHA= RAWSHA= B0SHA= ROOTSSH=1 SSHSHELL=
while [ $# -gt 0 ]; do case $1 in
	--puf) PUF=$2; shift;; --emmc-raw) RAW=$2; shift;; --boot0) BOOT0=$2; shift;; --env) ENVSRC=$2; shift;;
	--out) OUT=$2; shift;; --puf-sha256) PUFSHA=$2; shift;; --emmc-sha256) RAWSHA=$2; shift;; --boot0-sha256) B0SHA=$2; shift;;
	--root-ssh) ROOTSSH=1; case ${2:-} in ""|--*) ;; *) SSHSHELL=$2; shift;; esac;;   # old form: --root-ssh FILE
	--sshshell) ROOTSSH=1; SSHSHELL=$2; shift;; --stock-sshshell) ROOTSSH=; SSHSHELL=;;
	*) sed -n '2,61p' "$0" >&2; exit 2;; esac; shift; done
[ -n "$PUF" ] && [ -n "$ENVSRC" ] && [ -n "$OUT" ] || { sed -n '2,61p' "$0" >&2; exit 2; }
[ -n "$RAW" ] && [ -n "$BOOT0" ] && BACKUP=1 || BACKUP=0
[ -z "$RAW$BOOT0" ] || [ $BACKUP = 1 ] || die "--emmc-raw and --boot0 go together"
for f in "$PUF" "$ENVSRC" $RAW $BOOT0 $SSHSHELL; do [ -f "$f" ] || die "$f: no such file"; done
sha() { sha256sum < "$1" | cut -d' ' -f1; }
M=1048576
# eMMC layout as U-Boot prints it (the eMMC-migration notes): name offset_MiB length_MiB
EMMC_MIB=3728; EMMC_SECTORS=$((EMMC_MIB * 2048))
REG_CACHE="108 512" REG_LOGO="628 48" REG_RECOVERY="684 32" REG_MISC="716 32" REG_BOOT="764 32" REG_SYSTEM="804 1024" REG_DATA="1836 1892"
UBOOT_LEN=441504

say "checking inputs ($([ $BACKUP = 1 ] && echo "with the unit's eMMC backup" || echo "no backup: generic eMMC regions"))"
if [ $BACKUP = 1 ]; then
[ "$(stat -c %s "$RAW")" = $((EMMC_MIB * M)) ] || die "$RAW is not $((EMMC_MIB * M)) bytes (a raw 3728 MiB eMMC image)"
[ "$(stat -c %s "$BOOT0")" = $((4 * M)) ] || die "$BOOT0 is not 4 MiB (mmcblk1boot0)"
fi
if [ -n "$PUFSHA" ]; then [ "$(sha "$PUF")" = "$PUFSHA" ] || die "$PUF sha256 != $PUFSHA"; fi
if [ -n "$RAWSHA" ]; then [ "$(sha "$RAW")" = "$RAWSHA" ] || die "$RAW sha256 != $RAWSHA"; fi
if [ -n "$B0SHA" ]; then [ "$(sha "$BOOT0")" = "$B0SHA" ] || die "$BOOT0 sha256 != $B0SHA"; fi

mkdir -p "$OUT"
say "1/7 card bundle (puf-tool.sh extract + bundle, env unhooked)"
"$HERE/puf-tool.sh" extract "$PUF" "$OUT/.extract" > "$OUT/extract.log" 2>&1 || { cat "$OUT/extract.log" >&2; die "puf-tool extract failed"; }
"$HERE/puf-tool.sh" bundle "$OUT/.extract" --env "$ENVSRC" --out "$OUT" > "$OUT/bundle.log" 2>&1 || { cat "$OUT/bundle.log" >&2; die "puf-tool bundle failed"; }
cp "$OUT/.extract/puf.info" "$OUT/puf.info"
cp "$OUT/.extract/img/boot.img" "$OUT/.extract/img/logo.img" "$OUT/"
rm -rf "$OUT/.extract"
UNIT=$(sed -n 's/^unit=//p' "$OUT/factory.manifest")

ROOTSSH_NOTE=
if [ -n "$ROOTSSH" ]; then
say "2/7 rootsh patch of sshShell.sh in system.img (debugfs -w: no mount, no root; lands on card p2 too)"
command -v debugfs >/dev/null || die "debugfs (e2fsprogs) missing (rootsh patch; --stock-sshshell skips it)"
SIMG=$OUT/system.img; SPATH=/bin/sshShell.sh
stat_field() { sed -n "s/.*$2: *\\([0-9]\\{1,7\\}\\).*/\\1/p" <<<"$1" | head -n1; }   # $1=stat output $2=field name
STOCKF=$OUT/.sshShell.stock; NEWF=$OUT/.sshShell.new
debugfs -R "cat $SPATH" "$SIMG" > "$STOCKF" 2>/dev/null && [ -s "$STOCKF" ] || die "debugfs cat $SPATH failed (no such file in system.img?)"
STOCK_SHA=$(sha "$STOCKF")
if [ -n "$SSHSHELL" ]; then
	cp "$SSHSHELL" "$NEWF"; NEWSRC="$SSHSHELL (--sshshell, used as is)"
else
	# the image's own file + the rootsh branch (see "Root over ssh" above)
	grep -qF 'command=${2%%" "*}' "$STOCKF" || die "$SPATH in system.img does not set \$command the stock way: unknown firmware (use --sshshell FILE)"
	grep -qF '"rootsh"' "$STOCKF" && die "$SPATH in system.img already mentions rootsh: already modified image (use the pristine .puf, or --sshshell FILE)"
	debugfs -R "stat /bin/bash" "$SIMG" 2>/dev/null | grep -q 'Type: regular' || die "system.img has no /system/bin/bash for the rootsh branch"
	awk '
		tty && /^[ \t]*\/system\/bin\/telnetSSHProxy SSH [$]1[ \t]*$/ {
			match($0, /^[ \t]*/); i = substr($0, 1, RLENGTH)
			print i "if [ \"$command\" == \"rootsh\" ]; then"; print i "  /system/bin/bash -l"; print i "else"
			print i "  /system/bin/telnetSSHProxy SSH $1"; print i "fi"; n++; tty = 0; next }
		{ tty = ($0 ~ /^if \[ -t [$]fd \]; then[ \t]*$/); print }
		END { exit(n == 1 ? 0 : 3) }' "$STOCKF" > "$NEWF" || die "$SPATH in system.img has no single '/system/bin/telnetSSHProxy SSH \$1' line right after 'if [ -t \$fd ]; then': unknown or already modified firmware (use the pristine .puf, or --sshshell FILE)"
	# verify: exactly that one line replaced by the 5-line block, nothing else changed
	D=$(diff "$STOCKF" "$NEWF" || true); IND=$(grep -m1 '^[[:space:]]*/system/bin/telnetSSHProxy SSH \$1[[:space:]]*$' "$STOCKF" | sed 's|/system/bin/telnetSSHProxy.*||')
	EXP=$(printf '< %s\n---\n> %s\n> %s\n> %s\n> %s\n> %s' "$(grep -m1 '^[[:space:]]*/system/bin/telnetSSHProxy SSH \$1[[:space:]]*$' "$STOCKF")" \
		"${IND}if [ \"\$command\" == \"rootsh\" ]; then" "${IND}  /system/bin/bash -l" "${IND}else" "${IND}  /system/bin/telnetSSHProxy SSH \$1" "${IND}fi")
	grep -qE '^[0-9]+c[0-9]+,[0-9]+$' <<<"$(head -n1 <<<"$D")" && [ "$(tail -n +2 <<<"$D")" = "$EXP" ] || die "rootsh patch verification failed: diff stock/patched is not the expected one-line -> 5-line change: $D"
	[ "$(wc -l < "$NEWF")" = $(( $(wc -l < "$STOCKF") + 4 )) ] || die "rootsh patch verification failed: line count"
	NEWSRC="the image's own $SPATH + rootsh branch (diff verified: 1 line -> 5)"
	say "  rootsh patch (diff stock -> patched):"; printf '%s\n' "$D" | sed 's/^/mkbundle:     /' >&2
fi
ST=$(debugfs -R "stat $SPATH" "$SIMG" 2>&1)
OMODE=$(stat_field "$ST" Mode); OUID=$(stat_field "$ST" User); OGID=$(stat_field "$ST" Group)
[ -n "$OMODE" ] && [ -n "$OUID" ] && [ -n "$OGID" ] || die "could not parse stat of $SPATH in system.img"
EANAMES=$(debugfs -R "ea_list $SPATH" "$SIMG" 2>&1 | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.]*\) (.*/\1/p')
XD=$OUT/.xattr; rm -rf "$XD"; mkdir -p "$XD"
for ea in $EANAMES; do debugfs -R "ea_get -f $XD/$ea $SPATH $ea" "$SIMG" >/dev/null 2>&1 || die "ea_get $ea on $SPATH failed"; done
say "  stock $SPATH: mode=0$OMODE uid=$OUID gid=$OGID xattrs=[${EANAMES:-none}] sha256=$STOCK_SHA"
debugfs -w -R "rm $SPATH" "$SIMG" >/dev/null 2>&1 || die "debugfs rm $SPATH failed"
debugfs -w -R "write $NEWF $SPATH" "$SIMG" >/dev/null 2>&1 || die "debugfs write $SPATH failed"
FULLMODE=$(( 8#100000 + 8#$OMODE ))
debugfs -w -R "sif $SPATH mode $FULLMODE" "$SIMG" >/dev/null 2>&1 || die "sif mode failed"
debugfs -w -R "sif $SPATH uid $OUID" "$SIMG" >/dev/null 2>&1 || die "sif uid failed"
debugfs -w -R "sif $SPATH gid $OGID" "$SIMG" >/dev/null 2>&1 || die "sif gid failed"
for ea in $EANAMES; do debugfs -w -R "ea_set -f $XD/$ea $SPATH $ea" "$SIMG" >/dev/null 2>&1 || die "ea_set $ea on $SPATH failed"; done
rm -rf "$XD"
e2fsck -fn "$SIMG" >/dev/null 2>&1 || die "system.img fails e2fsck -fn after the rootsh patch"
debugfs -R "cat $SPATH" "$SIMG" 2>/dev/null | cmp -s - "$NEWF" || die "$SPATH in system.img does not match the new file byte for byte after the patch"
ST2=$(debugfs -R "stat $SPATH" "$SIMG" 2>&1)
NMODE=$(stat_field "$ST2" Mode); NUID=$(stat_field "$ST2" User); NGID=$(stat_field "$ST2" Group)
[ "$NMODE" = "$OMODE" ] && [ "$NUID" = "$OUID" ] && [ "$NGID" = "$OGID" ] || die "mode/uid/gid of $SPATH changed by the patch (was 0$OMODE/$OUID/$OGID, now 0$NMODE/$NUID/$NGID)"
NEANAMES=$(debugfs -R "ea_list $SPATH" "$SIMG" 2>&1 | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.]*\) (.*/\1/p')
[ "$NEANAMES" = "$EANAMES" ] || die "xattrs of $SPATH changed by the patch (was [$EANAMES], now [$NEANAMES])"
NEWFILE_SHA=$(sha "$NEWF"); rm -f "$STOCKF" "$NEWF"
say "  patched $SPATH: sha256=$NEWFILE_SHA (from $NEWSRC); mode/uid/gid/xattrs unchanged, e2fsck -fn clean, content verified byte-for-byte"
# factory.manifest's 'file system.img ...' line was written by puf-tool.sh from the
# stock image (size is unchanged, only content); fix it up so tsx-factory-restore's
# bundle-file sha256 check still passes
sed -i "s|^file system\\.img .*|file system.img $(stat -c %s "$SIMG") $(sha "$SIMG")|" "$OUT/factory.manifest"
ROOTSSH_NOTE="system_patch=root-ssh sshShell.sh $NEWFILE_SHA stock=$STOCK_SHA"
echo "$ROOTSSH_NOTE" >> "$OUT/factory.manifest"
else
say "2/7 --stock-sshshell: system.img is stock (byte-identical to the .puf) (root over ssh after the restore needs the UART; see installer/steps/rootsh)"
fi

say "3/7 env identity check (unhook must change state only)"
$ENVPY unit "$ENVSRC" > "$OUT/.unit-src.txt"; $ENVPY unit "$OUT/env.bin" > "$OUT/.unit-out.txt"
{
	echo "# env identity: source $(basename "$ENVSRC") vs bundle env.bin (tsx-env.py unit)"
	echo "source_sha256=$(sha "$ENVSRC")"; echo "env_bin_sha256=$(sha "$OUT/env.bin")"
	if cmp -s <(grep -E '^(identity|hw) ' "$OUT/.unit-src.txt") <(grep -E '^(identity|hw) ' "$OUT/.unit-out.txt"); then echo "identity_and_hw=identical"; else echo "identity_and_hw=DIFFER"; fi
	grep -E '^(identity|hw) ' "$OUT/.unit-out.txt"
	echo "# variable-level diff source -> env.bin:"; $ENVPY diff "$ENVSRC" "$OUT/env.bin" || true
} > "$OUT/env-identity.txt"; rm -f "$OUT/.unit-src.txt" "$OUT/.unit-out.txt"
grep -q '^identity_and_hw=identical$' "$OUT/env-identity.txt" || die "unhook changed identity/hw variables (see $OUT/env-identity.txt)"

say "4/7 U-Boot check (never written): .puf u-boot.bin vs boot0 backup vs eMMC bootloader area"
{
	echo "# u-boot check, mkbundle.sh $(date -Iseconds). U-Boot is NEVER rewritten by this tooling."
	echo "puf_uboot_bin_sha256=$(sha "$OUT/u-boot.bin") size=$(stat -c %s "$OUT/u-boot.bin")"
	if [ $BACKUP = 1 ]; then
	echo "boot0_sha256=$(sha "$BOOT0")"
	echo "boot0_first_${UBOOT_LEN}_sha256=$(head -c $UBOOT_LEN "$BOOT0" | sha256sum | cut -d' ' -f1)"
	if cmp -s -n $UBOOT_LEN "$OUT/u-boot.bin" "$BOOT0"; then echo "uboot_bin_matches_boot0=yes"; else
		echo "uboot_bin_matches_boot0=no first_diff_byte=$(cmp -n $UBOOT_LEN "$OUT/u-boot.bin" "$BOOT0" | sed -n 's/.*byte \([0-9]*\),.*/\1/p') differing_bytes=$(cmp -l -n $UBOOT_LEN "$OUT/u-boot.bin" "$BOOT0" | wc -l)"; fi
	if cmp -s -n $UBOOT_LEN "$BOOT0" "$RAW"; then echo "boot0_matches_emmc_bootloader_area=yes"; else echo "boot0_matches_emmc_bootloader_area=no"; fi
	else echo "boot0: no backup given; tsx-emmc-restore hashes boot0 before and after the run (must not change)"; fi
	echo "uboot_version_puf=$(sed -n 's/^uboot_version=//p' "$OUT/puf.info")"
	echo "uboot_version_env=$($ENVPY show "$OUT/env.bin" crestron_uboot_version | sed -n 's/^crestron_uboot_version=//p')"
	echo "# crestronLocalUpgrade.sh writes u-boot.bin only when crestronUbootVersion.txt != env crestron_uboot_version"
} > "$OUT/uboot-check.txt"
cat "$OUT/uboot-check.txt" >&2

ZERO_SHA() { head -c $(( $1 * M )) /dev/zero | sha256sum | cut -d' ' -f1; }
ZERO32_SHA=$(ZERO_SHA 32)
set -- $REG_BOOT; BOOT_LEN=$(stat -c %s "$OUT/boot.img")
BOOT_REG_SHA=$( { cat "$OUT/boot.img"; head -c $(( $2 * M - BOOT_LEN )) /dev/zero; } | sha256sum | cut -d' ' -f1)
set -- $REG_SYSTEM; SYS_LEN=$(stat -c %s "$OUT/system.img")
SYS_REG_SHA=$( { cat "$OUT/system.img"; head -c $(( $2 * M - SYS_LEN )) /dev/zero; } | sha256sum | cut -d' ' -f1)
if [ $BACKUP = 1 ]; then
say "5/7 eMMC regions from the backup (recovery, cache, data gzipped; misc must be zero)"
reg() { dd if="$RAW" bs=$M skip=$1 count=$2 status=none; }
set -- $REG_MISC; MISC_SHA=$(reg $1 $2 | sha256sum | cut -d' ' -f1)
[ "$MISC_SHA" = "$ZERO32_SHA" ] || die "the backup's misc region is not all zeros ($MISC_SHA): update the recipe"
for r in recovery cache data; do
	case $r in recovery) set -- $REG_RECOVERY;; cache) set -- $REG_CACHE;; data) set -- $REG_DATA;; esac
	reg $1 $2 | gzip -1 > "$OUT/$r.img.gz"
	eval "${r^^}_SHA=\$(gzip -dc '$OUT/$r.img.gz' | sha256sum | cut -d' ' -f1)"
done
set -- $REG_LOGO; LOGO_REG_SHA=$(reg $1 $2 | sha256sum | cut -d' ' -f1)
LOGO_LEN=$(stat -c %s "$OUT/logo.img")
[ "$(reg $1 $2 | head -c "$LOGO_LEN" | sha256sum | cut -d' ' -f1)" = "$(sha "$OUT/logo.img")" ] && LOGO_HEAD=yes || LOGO_HEAD=no
set -- $REG_BOOT
[ "$(reg $1 $2 | head -c "$BOOT_LEN" | sha256sum | cut -d' ' -f1)" = "$(sha "$OUT/boot.img")" ] && BOOT_HEAD=yes || BOOT_HEAD=no

else
	say "5/7 eMMC regions without a backup: recovery/misc/data/gaps zero, cache = empty factory ext4, logo head"
	# cache: the factory ext4 parameters (Jabil's mke2fs, read from unit B's region: 512 MiB,
	# 4 KiB blocks, 32768 inodes of 256 bytes, 0 reserved, no flex_bg/metadata_csum: the
	# 3.10 kernel mounts it), fixed UUID/hash seed/time so the image is reproducible
	command -v mke2fs >/dev/null || die "mke2fs (e2fsprogs) missing"
	set -- $REG_CACHE; rm -f "$OUT/.cache.img"; truncate -s $(( $2 * M )) "$OUT/.cache.img"
	E2FSPROGS_FAKE_TIME=1446500000 mke2fs -q -F -T default -t ext4 -b 4096 -I 256 -N 32768 -m 0 \
		-O none,has_journal,ext_attr,resize_inode,filetype,extent,sparse_super,large_file,uninit_bg \
		-U 7c3d1e50-0000-4000-8000-000000cac4e0 -E hash_seed=7c3d1e50-0000-4000-8000-000000cac4e0,lazy_itable_init=0,nodiscard \
		"$OUT/.cache.img" > /dev/null || die "mke2fs cache failed"
	e2fsck -fn "$OUT/.cache.img" > /dev/null 2>&1 || die "the new cache ext4 does not pass e2fsck"
	CACHE_SHA=$(sha "$OUT/.cache.img"); gzip -9n < "$OUT/.cache.img" > "$OUT/cache.img.gz"; rm -f "$OUT/.cache.img"
	rm -f "$OUT/recovery.img.gz" "$OUT/data.img.gz"
fi
say "6/7 scripts + manifests"
cp "$HERE/tsx-emmc-restore" "$OUT/tsx-emmc-restore"; cp "$HERE/tsx-factory-restore" "$OUT/tsx-factory-restore"
{
	echo "# xx60 eMMC factory-restore bundle, mkbundle.sh $(date -Iseconds)"
	echo "format=tsx-emmc-bundle-1"
	echo "unit=$UNIT"
	echo "emmc_sectors=$EMMC_SECTORS"
	if [ $BACKUP = 1 ]; then
		echo "boot0_sha256=$(sha "$BOOT0")"
		echo "emmc_backup_sha256=$(sha "$RAW")"
		echo "backup_logo_region_head_matches_puf=$LOGO_HEAD backup_boot_region_head_matches_puf=$BOOT_HEAD"
	else
		echo "boot0_sha256=any"
		echo "emmc_backup=none (recovery/misc/data/gaps zeroed, cache = empty ext4, logo head only)"
	fi
	echo "# region NAME OFFSET_MIB LENGTH_MIB SOURCE SHA256_OF_WHOLE_REGION_AFTER_RESTORE"
	echo "#   SOURCE: zero | keep:FILE (verify, rewrite from FILE+zero if it differs) | head:FILE (only the first size(FILE) bytes) | FILE+zero | FILE.gz"
	set -- $REG_MISC;     echo "region misc $1 $2 zero $ZERO32_SHA"
	if [ $BACKUP = 1 ]; then
	set -- $REG_RECOVERY; echo "region recovery $1 $2 recovery.img.gz $RECOVERY_SHA"
	set -- $REG_CACHE;    echo "region cache $1 $2 cache.img.gz $CACHE_SHA"
	set -- $REG_LOGO;     echo "region logo $1 $2 keep:logo.img $LOGO_REG_SHA"
	set -- $REG_DATA;     echo "region data $1 $2 data.img.gz $DATA_SHA"
	else
	set -- $REG_RECOVERY; echo "region recovery $1 $2 zero $(ZERO_SHA $2)"
	set -- $REG_CACHE;    echo "region cache $1 $2 cache.img.gz $CACHE_SHA"
	set -- $REG_LOGO;     echo "region logo $1 $2 head:logo.img $(sha "$OUT/logo.img")"
	set -- $REG_DATA;     echo "region data $1 $2 zero $(ZERO_SHA $2)"
	fi
	set -- $REG_SYSTEM;   echo "region system $1 $2 system.img+zero $SYS_REG_SHA"
	set -- $REG_BOOT;     echo "region boot $1 $2 boot.img+zero $BOOT_REG_SHA"
	# alignment gaps between U-Boot's partitions (zero on the factory unit; the eMMC-boot migration's
	# root started at 796M = right after boot, so its ext4 head sat in the 796M gap)
	for g in "100 8" "620 8" "676 8" "748 16" "796 8" "1828 8"; do set -- $g
		[ $BACKUP = 0 ] || [ "$(reg $1 $2 | tr -d '\0' | wc -c)" = 0 ] || die "the backup's gap ${1}M+${2}M is not zero: update the recipe"
		echo "region gap$1 $1 $2 zero $(ZERO_SHA $2)"
	done
	echo "# uboot: bootloader area 0..4M, reserved 36M+64M: never written"
	for f in boot.img logo.img system.img recovery.img.gz cache.img.gz data.img.gz tsx-emmc-restore tsx-factory-restore; do [ -f "$OUT/$f" ] && echo "file $f $(stat -c %s "$OUT/$f") $(sha "$OUT/$f")"; done
	[ -z "$ROOTSSH_NOTE" ] || echo "$ROOTSSH_NOTE"
} > "$OUT/emmc.manifest"
say "7/7 SHA256SUMS"
(cd "$OUT" && sha256sum $(ls boot.img logo.img system.img recovery.img.gz cache.img.gz data.img.gz 2>/dev/null) boot-golden.img u-boot.bin env.bin crestron-mbr.sfdisk crestron-fs.sh tsx-emmc-restore tsx-factory-restore factory.manifest emmc.manifest > SHA256SUMS)
say "bundle $OUT for unit $UNIT: $(du -sh "$OUT" | cut -f1)"
cat "$OUT/emmc.manifest" >&2
