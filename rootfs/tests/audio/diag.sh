#!/bin/sh
# Audio diagnosis, run ON THE PANEL as root. The user approved these
# reversible register writes. Needs /tmp/regdump, /tmp/padsample.py, /tmp/ringdump.py.
#   sh /tmp/diag.sh pulldown   GPIOY_5 pull-down during capture (restored)
#   sh /tmp/diag.sh clocks     gates, AIU and AUD_CLK registers idle vs playing
#   sh /tmp/diag.sh audcntl    playback with HHI_AUD_CLK_CNTL bit 23 set (vendor
#                              "Audio DAC clock enable"), pads sampled (restored)
#   sh /tmp/diag.sh aomux      read back the AO pinmux. Set bits 27..30 again while
#                              playing and sample the pads (restored)
#   sh /tmp/diag.sh hold [-30|-20] [N]  1 kHz tone N x 1 s (default -30, 20), TFA status every 2 s
# Every write prints the old value. The step undoes the write at its end.
R=/tmp/regdump
say() { echo; echo "=== $*"; }
val() { $R "$@" | cut -d= -f2; }
hx() { printf 0x%08x "$1"; }
play_silence() { aplay -q -D plughw:TSW1060,0 -f S16_LE -r 48000 -c 2 -d "$1" /dev/zero 2>/dev/null & }
pads() { python3 /tmp/padsample.py "${1:-20000}"; }
tfa() { D=/sys/kernel/debug/regmap; echo "TFA L $(head -1 $D/1-0034/registers) R $(head -1 $D/1-0036/registers)"; }

case ${1:-} in
pulldown)
	P=$(val c 0x203d); E=$(val c 0x204b)
	say "GPIOY_5 pull: PAD_PULL_UP_REG3=$P PAD_PULL_UP_EN_REG3=$E (bit 5)"
	arecord -D hw:TSW1060,1 -f S16_LE -r 48000 -c 2 -d 8 /tmp/pd.wav 2>/dev/null & rec=$!
	sleep 1; echo "before (pull as configured):"; pads 8000; python3 /tmp/ringdump.py 64 | head -3
	$R -w c 0x203d "$(hx $((P & ~0x20)))"; $R -w c 0x204b "$(hx $((E | 0x20)))"
	echo "pull-down on: $(val c 0x203d) $(val c 0x204b)"; sleep 1.5
	pads 8000; python3 /tmp/ringdump.py 64 | head -3
	$R -w c 0x203d "$(hx $((P | 0x20)))"; sleep 1.5
	echo "pull-up on: $(val c 0x203d)"; pads 8000; python3 /tmp/ringdump.py 64 | head -3
	$R -w c 0x203d "$P"; $R -w c 0x204b "$E"
	echo "restored: $(val c 0x203d) $(val c 0x204b)"; wait $rec
	echo "interpretation: Y_5 follows the pull = pin not driven. Stays 1 with pull-down = ZL drives it high";;
clocks)
	for st in idle playing; do
		[ $st = playing ] && { play_silence 4; sleep 1.5; }
		say "$st"
		echo "HHI_GCLK_MPEG0/1/2 OTHER AO: $(val c 0x1050) $(val c 0x1051) $(val c 0x1052) $(val c 0x1054) $(val c 0x1055)"
		echo "HHI_AUD_CLK_CNTL 0x105e: $(val c 0x105e)  MPLL_CNTL7..9: $(val c 0x10a6) $(val c 0x10a7) $(val c 0x10a8)"
		echo "AIU_I2S_DAC_CFG 0x1510 $(val c 0x1510) SOURCE_DESC 0x150d $(val c 0x150d) MISC 0x1512 $(val c 0x1512) MUTE_SWAP 0x1513 $(val c 0x1513)"
		echo "AIU_CLK_CTRL 0x1516 $(val c 0x1516) CLK_CTRL_MORE 0x1519 $(val c 0x1519) DAC_LRCLK 0x1528 $(val c 0x1528) ADC_LRCLK 0x1529 $(val c 0x1529)"
		echo "AIU_MEM_I2S START/RD/END/MASKS/CONTROL 0x1560..0x1564: $($R c 0x1560 0x1564 | cut -d= -f2 | tr '\n' ' ')"
		echo "AIU_MEM_I2S_BUF_CNTL 0x1576 $(val c 0x1576)"
		echo "AO pinmux 0x05 $(val a 0x05)  AO_GPIO_O_EN_N 0x09 $(val a 0x09)"
		grep -E ' (amclk|i2s|audac|cts_aoclk)' /sys/kernel/debug/meson-clk-msr/measure_summary 2>/dev/null
		pads 10000; tfa
		wait
	done
	echo "vendor reference (aml_audio_hw.c): AIU_CLK_CTRL = aoclk inv + lrclk inv + skew 1 + i2s div /4 + enables;"
	echo "HHI_AUD_CLK_CNTL = xd 24, src MPLL0, bit 8 mclk enable, bit 23 audio DAC clock enable";;
audcntl)
	play_silence 6; sleep 1.5; O=$(val c 0x105e)
	say "HHI_AUD_CLK_CNTL before $O"; pads 8000
	$R -w c 0x105e "$(hx $((O | 0x800000)))"; sleep 0.5
	echo "with bit 23: $(val c 0x105e)"; pads 8000; tfa
	grep -E ' (amclk|audac)' /sys/kernel/debug/meson-clk-msr/measure_summary
	$R -w c 0x105e "$O"
	echo "restored: $(val c 0x105e)"; wait;;
aomux)
	O=$(val a 0x05); say "AO pinmux 0x05 = $O (bits 27..30 = i2s_ao)"
	play_silence 6; sleep 1.5
	echo "AO_RTI_PIN_MUX readback while playing: $(val a 0x05)"; pads 8000
	$R -w a 0x05 "$(hx $((O & ~0x78000000)))"; sleep 0.3
	echo "i2s_ao bits cleared (pads as GPIO): $(val a 0x05)"; pads 4000
	$R -w a 0x05 "$(hx $((O | 0x78000000)))"; sleep 0.3
	echo "i2s_ao bits set again: $(val a 0x05)"; pads 8000
	$R -w a 0x05 "$O"; echo "restored: $(val a 0x05)"; wait;;
hold)
	db=${2:--30}; n=${3:-20}
	case $db in -30|-20) ;; *) echo "refused: only -30 or -20 dBFS"; exit 1;; esac
	say "1 kHz $db dBFS, $n x 1 s on hw:TSW1060,0 (softvol bypassed), start $(date +%T)"
	i=0; while [ $i -lt "$n" ]; do aplay -q -D plughw:TSW1060,0 /tmp/tone-1k-m${db#-}dB.wav 2>/dev/null & sleep 0.5; [ $((i % 2)) = 0 ] && tfa; wait; i=$((i + 1)); done
	echo "done $(date +%T)";;
*) sed -n '2,11p' "$0"; exit 1;;
esac
