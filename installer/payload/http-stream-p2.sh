#!/bin/bash
# Host: write the raw p2 rootfs image into /dev/block/mmcblk0p2 of a stock-Android
# xx60 at LAN speed: the panel fetches 64 MiB chunk files from an HTTP server
# on the workstation (busybox wget) and pipes them into dd with fsync; each chunk
# is hash-verified on the panel, adb (root adbd over TCP) is only the control
# channel. Faster than adb-stream-p2.sh (adb exec-in is ~1.2 MB/s, wget runs at
# the card's write speed, ~6.5 MB/s). Chunks: split -b 64M -d -a 2 IMAGE DIR/NAME.part
# and serve DIR's parent: (cd out && python3 -m http.server 8080 --bind 0.0.0.0).
#   stick/http-stream-p2.sh IMAGE CHUNKDIR URLBASE HOST[:PORT] [--from-chunk N] [--sha256 HASH]
#   e.g. stick/http-stream-p2.sh out/rootfs-p2.ext4 out/p2-chunks http://<workstation-ip>:8080/p2-chunks <panel-ip>
set -euo pipefail
IMG=${1:?IMAGE}; CDIR=${2:?CHUNKDIR}; URL=${3:?URLBASE}; HP=${4:?HOST}; shift 4
FROM=0; WANT=
while [ $# -gt 0 ]; do case "$1" in --from-chunk) FROM=$2; shift 2;; --sha256) WANT=$2; shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
case "$HP" in *:*) ;; *) HP=$HP:5555;; esac
DEV=/dev/block/mmcblk0p2; BB=/system/bin/busybox
say() { echo "http-stream-p2: $(date '+%T') $*" >&2; }
adb connect "$HP" >/dev/null 2>&1 || true
[ "$(adb -s "$HP" shell id | tr -d '\r' | cut -c1-5)" = "uid=0" ] || { say "adbd is not root on $HP"; exit 1; }
CHUNKS=$(cd "$CDIR" && /bin/ls | sort); N=$(echo "$CHUNKS" | wc -l); i=0; off=0
say "$IMG in $N chunks from $CDIR via $URL -> $HP:$DEV (from chunk $FROM)"
for c in $CHUNKS; do
	sz=$(stat -c %s "$CDIR/$c"); cnt=$((sz / 1048576))
	if [ $i -ge $FROM ]; then
		want=$(sha256sum "$CDIR/$c" | cut -d' ' -f1); try=0
		while :; do
			try=$((try + 1))
			adb -s "$HP" shell "$BB wget -q -O - '$URL/$c' | $BB dd of=$DEV bs=1048576 seek=$off conv=notrunc,fsync 2>&1 | tail -1" | tr -d '\r' | sed 's/^/    /' >&2
			got=$(adb -s "$HP" shell "$BB dd if=$DEV bs=1048576 skip=$off count=$cnt 2>/dev/null | $BB sha256sum" | tr -d '\r' | cut -d' ' -f1)
			if [ "$got" = "$want" ]; then say "  chunk $i/$((N-1)) ok ($c, MiB $off..$((off+cnt-1)))"; break; fi
			say "  chunk $i: verify MISMATCH $got != $want (try $try)"
			[ $try -lt 3 ] || { say "giving up at chunk $i; resume with --from-chunk $i"; exit 1; }
			adb connect "$HP" >/dev/null 2>&1 || true
		done
	fi
	off=$((off + cnt)); i=$((i + 1))
done
say "all chunks written; full readback hash of $off MiB (sync + drop_caches first)"
full=$(adb -s "$HP" shell "sync; echo 3 > /proc/sys/vm/drop_caches; $BB dd if=$DEV bs=1048576 count=$off 2>/dev/null | $BB sha256sum" | tr -d '\r' | cut -d' ' -f1)
[ -n "$WANT" ] || WANT=$(sha256sum "$IMG" | cut -d' ' -f1)
[ "$full" = "$WANT" ] && say "p2 = $IMG ($full)" || { say "FULL HASH MISMATCH $full != $WANT"; exit 1; }
