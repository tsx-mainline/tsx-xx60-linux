#!/bin/sh
# Runs ON THE PANEL. N blank/unblank cycles of fb0 with register and clock checks.
N=${1:-10}; R=/tmp/regdump
st() { echo "  $1: ENCL_EN=$($R v 0x1ca0 0x1ca0|cut -d= -f2) LVDS_GEN=$($R v 0x14e0 0x14e0|cut -d= -f2) PHY1..3=$($R c 0x10d9 0x10db|cut -d= -f2|tr '\n' ' ')PLL=$($R c 0x10e0 0x10e0|cut -d= -f2) VIID_DIV=$($R c 0x104b 0x104b|cut -d= -f2) VID_CLK_CNTL2=$($R c 0x1065 0x1065|cut -d= -f2) encl=$(grep -E '^ encl ' /sys/kernel/debug/meson-clk-msr/measure_summary|awk '{print $2}') gpio:$(grep -E 'regulator-panel' /sys/kernel/debug/gpio | awk '{print $6}' | tr '\n' ' ')"; }
st start
for i in $(seq $N); do
  echo 1 > /sys/class/graphics/fb0/blank; sleep 2; echo "cycle $i"; st blanked
  [ $i = 1 ] && sh /tmp/regsnap.sh nov > /tmp/blank-regs.txt
  echo 0 > /sys/class/graphics/fb0/blank; sleep 3; st unblank
done
