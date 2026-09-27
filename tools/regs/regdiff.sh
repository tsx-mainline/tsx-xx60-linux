#!/bin/bash
# regdiff.sh snapshot.txt [reference] : print registers that differ from the vendor capture
REF=${2:-$(dirname "$0")/../../../captures/tsw-1060/regs-live.txt}
join -j1 <(tr -d '\r' < "$REF" | grep -E '^[A-Z]+\[' | sed 's/=/ /' | sort -u) \
         <(tr -d '\r' < "$1" | grep -E '^[A-Z]+\[' | sed 's/=/ /' | sort -u) | awk '$2!=$3{print $1, "vendor=" $2, "now=" $3}'
