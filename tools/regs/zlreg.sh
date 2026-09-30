#!/bin/sh
# zlreg.sh ADDR [WORDS]       read ZL38051 HBI registers over I2C (1-0045), 16-bit BE
# zlreg.sh -w ADDR VALUE      write one register (diagnostic, the caller restores)
# Paged command [0xFE, page-1, offs/2, words-1(|0x80 write)]. Page 0: [0x80|offs/2, n-1]
cmdhdr() { a=$(($1)); p=$((a >> 8)); o=$(((a & 0xff) >> 1))
  if [ $p -eq 0 ]; then printf '0x%02x' $((o | 0x80)); else printf '0xfe 0x%02x 0x%02x' $((p - 1)) $o; fi; }
if [ "$1" = -w ]; then
  a=$2; v=$(($3)); h=$(cmdhdr $a); n=$(echo $h | wc -w)
  i2ctransfer -f -y 1 w$((n + 3))@0x45 $h 0x80 $(printf '0x%02x 0x%02x' $((v >> 8)) $((v & 0xff)))
  exit $?
fi
a=$1; w=${2:-1}; h=$(cmdhdr $a); n=$(echo $h | wc -w)
out=$(i2ctransfer -f -y 1 w$((n + 1))@0x45 $h $(printf '0x%02x' $((w - 1))) r$((2 * w))) || exit 1
set -- $out; i=0
while [ $# -ge 2 ]; do printf '%04x: %s%s\n' $(( $a + 2 * i )) $1 ${2#0x}; shift 2; i=$((i + 1)); done
