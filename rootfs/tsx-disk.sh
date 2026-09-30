# install.sh and uninstall.sh share this file and source it (busybox ash).
# It finds the Crestron boot disk (Android "mmcblk0", any mainline number) by
# its MBR layout. The Crestron MBR layout notes and the 2026-09-25 backup
# (captures/tsw-1060/backup, sfdisk -d) confirm the layout:
#   p1 81920+81920 FAT16 (golden boot.img)   p2 206849+1638400 ext4 system
#   p3 2048+2048 U-Boot env copy             p4 1845249 extended
#   p5 1847297+3055616 ext2 "sdcard"         p6 4904961+1024000 ext2 data
#   p7 5931009+204800 ext2 cache             p8 6137857+614400 ext4 logs
# Disk identifier 0x0dc9276f (PARTUUID 0dc9276f-NN) on the TSW-1060 unit.
TSX_LAYOUT="1:81920:81920 2:206849:1638400 3:2048:2048 4:1845249:- 5:1847297:3055616 6:4904961:1024000 7:5931009:204800 8:6137857:614400"
TSX_P5_SECTORS=3055616

tsx_find_disk() {  # print the disk name (for example mmcblk0). Return 1 if no disk matches exactly.
	local d n p e st sz ok
	for d in ${TSX_DISK_GLOB:-/sys/block/mmcblk[0-9]*}; do
		[ -e "$d" ] || continue
		n=${d##*/}; ok=1
		for e in $TSX_LAYOUT; do
			p=${e%%:*}; st=${e#*:}; st=${st%%:*}; sz=${e##*:}
			[ -e "$d/${n}p$p" ] || { ok=0; break; }
			[ "$(cat $d/${n}p$p/start)" = "$st" ] || { ok=0; break; }
			[ "$sz" = - ] || [ "$(cat $d/${n}p$p/size)" = "$sz" ] || { ok=0; break; }
		done
		[ -e "$d/${n}p9" ] && ok=0
		[ $ok = 1 ] && { echo "$n"; return 0; }
	done
	return 1
}

tsx_is_mounted() { grep -q "^$1 " /proc/mounts; }
