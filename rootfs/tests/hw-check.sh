#!/bin/sh
# ALS/light-sensor hardware checks, run ON THE PANEL (read-only except a short blank/wake):
#   scp rootfs/tests/hw-check.sh tools/regs/regdump root@<ip>:/tmp/ && ssh root@<ip> sh /tmp/hw-check.sh
# Writes nothing to storage. Touches no audio output.
RD=/tmp/regdump
say() { echo; echo "== $*"; }
say kernel; uname -a; cat /proc/cmdline
say "light sensor (dmesg, iio)"
dmesg | grep -i -E 'max44009|iio' | tail -5
for d in /sys/bus/iio/devices/iio:device*; do echo "$d: $(cat $d/name)"; done
ALS=
for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name)" = max44009 ] && ALS=$d; done
if [ -n "$ALS" ]; then
	ls "$ALS"
	echo "integration time: $(cat $ALS/in_illuminance_integration_time 2>/dev/null)"
	BL=$(ls -d /sys/class/backlight/* | head -1)
	echo "backlight $(cat $BL/brightness)"
	for i in 1 2 3 4 5; do printf '%s ' "$(cat $ALS/in_illuminance_input)"; sleep 1; done; echo "lx (screen lit)"
	grep -i max44009 /proc/interrupts
	if command -v tsx-blank >/dev/null; then
		tsx-blank on; sleep 3
		for i in 1 2 3 4 5; do printf '%s ' "$(cat $ALS/in_illuminance_input)"; sleep 1; done; echo "lx (backlight 0)"
		tsx-blank off; sleep 3
		echo 23 > $BL/brightness; sleep 2
		for i in 1 2 3; do printf '%s ' "$(cat $ALS/in_illuminance_input)"; sleep 1; done; echo "lx (backlight 23)"
		echo 17 > $BL/brightness; sleep 2
		for i in 1 2 3; do printf '%s ' "$(cat $ALS/in_illuminance_input)"; sleep 1; done; echo "lx (backlight 17)"
	fi
fi
say "i2c-1 scan (read mode)"; i2cdetect -y -r 1
say "TFA9890 revision (reg 0x03, expect 0x80 in the low byte)"
for a in 0x34 0x36; do echo "$a: rev $(i2cget -y 1 $a 0x03 w 2>&1)  status $(i2cget -y 1 $a 0x00 w 2>&1)  sysctrl $(i2cget -y 1 $a 0x09 w 2>&1)"; done
say "ZLS38051 at 0x45 (HBI direct reads: 0x0020 hw rev, 0x0022 fw product, 0x0024 fw rev, 0x0204 samples/ms, 0x0260/0x0262 TDMA cfg/clk, 0x0278/0x027A TDMB)"
command -v i2ctransfer >/dev/null && for r in 0x0020 0x0022 0x0024 0x0204 0x0202 0x0214 0x021C 0x0260 0x0262 0x0264 0x0278 0x027A 0x02B0 0x0300; do
	off=$(( (r & 0xff) >> 1 )); page=$(( r >> 8 ))
	if [ $page = 0 ]; then cmd=$(( 0x8000 | (off << 8) )); v=$(i2ctransfer -y 1 w2@0x45 $((cmd >> 8)) $((cmd & 0xff)) r2 2>&1)
	else v=$(i2ctransfer -y 1 w4@0x45 0xfe $((page - 1)) $off 0x00 r2 2>&1); fi
	echo "$r: $v"
done
say "unknown device 0x0e (first 16 registers)"; i2cdump -y -r 0x00-0x0f 1 0x0e b 2>&1 | tail -2
say "USB"; lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null | grep -E '^T:|^P:|^S:'
for d in /sys/bus/usb/devices/*; do [ -r $d/idVendor ] && echo "$(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done
dmesg | grep -i -E 'uvc|video|camera|ov56' | tail -5
say ALSA; cat /proc/asound/cards 2>&1; ls /dev/snd 2>&1
say "AIU / AUDIN / BSD_EN registers (regdump)"
if [ -x $RD ]; then
	$RD c 0x1500 0x1540 2>&1 | head -80      # AIU
	$RD c 0x2810 0x2830 2>&1                 # AUDIN
	$RD c 0x200c 0x200e 2>&1                 # PREG_PAD_GPIO0 EN_N/O/I (BSD_EN = O bits 29..31)
	$RD c 0x202e 0x2038 2>&1                 # PERIPHS_PIN_MUX_0..9 (reg 1: GPIOY_5 i2s_in; reg 3: GPIOH_9)
	$RD a 0x09 0x0a 2>&1                       # AO_GPIO_O_EN_N, AO_GPIO_I
	$RD a 0x05 0x06 2>&1                       # AO_RTI_PIN_MUX (reg 10 in vendor terms)
else echo "no $RD"; fi
say "GPIO"; cat /sys/kernel/debug/gpio 2>/dev/null | grep -E 'GPIOX_7|GPIOH_4|GPIOH_6|GPIO_BSD|GPIOAO_(8|9|10|11) |GPIOY_5 ' 
