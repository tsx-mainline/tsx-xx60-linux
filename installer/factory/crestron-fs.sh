# crestron-fs.sh: the Crestron factory file systems of the xx60 SD card, as
# measured on two factory-state cards (captures/tsw-1060/backup = unit A,
# xx60-FACTORY.img = a TSW-760): identical superblock parameters on both.
# Sourced by factory/puf-tool.sh (host, image files) and tsx-factory-restore
# (rescue system, block devices). POSIX sh.
#
# part start(sector) sectors  type bs   isize inodes  features                                  label   uuid
CRESTRON_FS="
5 1847297 3055616 ext2 4096 256 95616  none,dir_index,filetype,sparse_super sdcard -
6 4904961 1024000 ext2 1024 128 128016 none,dir_index,filetype,sparse_super data -
7 5931009 204800  ext2 1024 128 25688  none,dir_index,filetype,sparse_super cache -
8 6137857 614400  ext4 1024 128 76912  none,has_journal,ext_attr,resize_inode,dir_index,filetype,flex_bg,sparse_super,huge_file,uninit_bg,dir_nlink,extra_isize logs 0ef5a846-c875-4b53-8cb3-1a751c0c25bb
"
# p1: FAT16, 81920 sectors, 4 sectors per cluster, volume id 1D14-2256 (all known cards)
CRESTRON_P1_START=81920 CRESTRON_P1_SECTORS=81920 CRESTRON_P1_VOLID=1D142256
CRESTRON_P2_START=206849 CRESTRON_P2_SECTORS=1638400
CRESTRON_ENV_OFFSET=1048576 CRESTRON_ENV_SIZE=65536
CRESTRON_DISK_SECTORS=7774208
# crestron_mke2fs PART TARGET [OFFSET_BYTES]: make partition PART's file system on
# TARGET (a block device, or an image file with the partition at OFFSET_BYTES)
crestron_mke2fs() {
	local part=$1 tgt=$2 off=${3:-} line p st n ty bs is ino feat lab uuid
	line=$(echo "$CRESTRON_FS" | awk -v p="$part" '$1 == p')
	[ -n "$line" ] || return 1
	set -- $line; p=$1 st=$2 n=$3 ty=$4 bs=$5 is=$6 ino=$7 feat=$8 lab=$9 uuid=${10}
	mke2fs -q -F -t "$ty" -b "$bs" -I "$is" -N "$ino" -O "$feat" -m 5 -L "$lab" \
		$( [ "$uuid" != - ] && echo "-U $uuid" ) ${off:+-E offset=$off} "$tgt" $(( n * 512 / bs ))
}
# crestron_mkfat TARGET: p1's FAT16 exactly as on the factory cards (mkdosfs:
# 4 sectors/cluster, 4 reserved, 2 FATs of 80 sectors, 512 root entries, media
# 0xf8, geometry 123/62, 0 hidden sectors, volume id 1D14-2256). TARGET = the
# p1 block device, or a file of 81920 sectors.
crestron_mkfat() {
	mkfs.fat -a -F 16 -s 4 -R 4 -f 2 -r 512 -M 0xf8 -h 0 -g 123/62 -D 0 -i $CRESTRON_P1_VOLID "$1" $((CRESTRON_P1_SECTORS / 2)) >/dev/null
}
