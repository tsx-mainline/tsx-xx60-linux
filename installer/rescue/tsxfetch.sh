#!/bin/sh
# neofetch-style system summary for the busybox initramfs. Prints to stdout.
e=$(printf '\033'); C="$e[1;36m"; Y="$e[1;33m"; W="$e[1;37m"; R="$e[0m"
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
kern=$(uname -r); up=$(awk '{s=int($1); printf "%dm %ds", s/60, s%60}' /proc/uptime)
cpu="Cortex-A9 x$(grep -c ^processor /proc/cpuinfo) ($(grep -m1 Hardware /proc/cpuinfo | sed 's/.*: //;s/^$/Amlogic Meson8m2/'))"
[ -n "$(grep -m1 Hardware /proc/cpuinfo)" ] || cpu="Amlogic Meson8m2, Cortex-A9 x$(grep -c ^processor /proc/cpuinfo)"
mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%dMiB / %dMiB", (t-a)/1024, t/1024}' /proc/meminfo)
res=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | tr , x)
gpu=$(cat /sys/class/drm/card0/device/driver/module/drivers 2>/dev/null | head -1); gpu=${gpu:-simpledrm}
ip=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}')
temp=$(awk '{printf "%.1f C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
sh=$(busybox 2>/dev/null | head -1 | cut -d' ' -f1-2)
set -- \
"${C}         _______________         " \
"${C}        |  ___________  |        " \
"${C}        | |           | |        " \
"${C}        | |  ${Y}TSW-1060${C} | |        " \
"${C}        | |  ${W}mainline${C} | |        " \
"${C}        | |___________| |        " \
"${C}        |_______________|        " \
"${C}             |_____|             " \
"${C}                                 " \
"${C}                                 " \
"${C}                                 " \
"${C}                                 "
info="${C}root${R}@${C}$(hostname)
${W}----------------
${C}Host${R}:    $model
${C}Kernel${R}:  $kern
${C}Uptime${R}:  $up
${C}Shell${R}:   $sh
${C}Display${R}: $res, $gpu (U-Boot framebuffer)
${C}CPU${R}:     $cpu
${C}Memory${R}:  $mem
${C}Network${R}: eth0 $ip
${C}Temp${R}:    ${temp:-n/a}
$e[41m   $e[42m   $e[43m   $e[44m   $e[45m   $e[46m   $e[47m   ${R}"
echo "$info" | while IFS= read -r l; do printf '%s%s  %s%s\n' "$1" "$R" "$l" "$R"; shift 2>/dev/null; done
