#!/bin/sh
# Runs IN THE GUEST (qemu VM or panel). Prints memory use of the kiosk:
# PSS/RSS summed per program (from /proc/PID/smaps_rollup) and MemAvailable.
# Usage: measure-mem.sh [label]
echo "== ${1:-kiosk} $(date +%T) uptime $(cut -d' ' -f1 /proc/uptime)s"
awk '/MemTotal|MemAvailable|SwapTotal|SwapFree|Shmem:/{printf "%s %d MiB  ", $1, $2/1024} END{print ""}' /proc/meminfo
for p in /proc/[0-9]*; do
	c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null | cut -c1-200); [ -n "$c" ] || continue
	case "$c" in
	*cage*) n=cage;;
	sway*|/usr/bin/sway*) n=sway;;
	*squeekboard*) n=squeekboard;;
	*wvkbd*) n=wvkbd;;
	*dbus-daemon*) n=dbus-daemon;;
	*chromium*|*chrome*) case "$c" in *--type=renderer*) n=chromium-renderer;; *--type=gpu*) n=chromium-gpu;; *--type=utility*) n=chromium-utility;; *--type=zygote*) n=chromium-zygote;; *--type=*) n=chromium-other;; *) n=chromium-browser;; esac;;
	*firefox*) case "$c" in *-contentproc*) n=firefox-content;; *) n=firefox-main;; esac;;
	*WebKitWebProcess*) n=webkit-web;; *WebKitNetworkProcess*) n=webkit-net;; *webkit-kiosk*) n=webkit-ui;;
	*seatd*) n=seatd;; *tsx-idled*) n=tsx-idled;;
	*) continue;;
	esac
	awk -v n=$n '/^Pss:/{p=$2} /^Rss:/{r=$2} END{print n, p, r}' $p/smaps_rollup 2>/dev/null
done | awk '{p[$1]+=$2; r[$1]+=$3; c[$1]++; tp+=$2} END{for (k in p) printf "  %-20s x%-2d PSS %6.1f MiB  RSS %6.1f MiB\n", k, c[k], p[k]/1024, r[k]/1024; printf "  %-24s PSS %6.1f MiB\n", "TOTAL kiosk", tp/1024}' | sort
