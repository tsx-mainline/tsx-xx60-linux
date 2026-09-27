#!/bin/sh
# Hardware checks for the TSW-1060 audio (run ON THE PANEL as root).
#   scp rootfs/tests/audio/audio-test.sh rootfs/tests/audio/tone-*.wav tools/regs/regdump root@<panel-ip>:/tmp/
#   ssh root@<panel-ip> sh /tmp/audio-test.sh STEP
#
# Steps (in this order; each one prints what to look for):
#   info        read only: kernel, dmesg of every audio driver, ALSA cards and
#               controls, amplifier revisions (from dmesg), ZL38051 versions,
#               speaker enable state, registers (regs). No sound.
#   regs        register dump only (AIU, AUDIN, clocks, MPLL, BSD_EN bits)
#   spk-en      toggle GPIO_BSD_EN through a 3 s silent playback and dump the
#               BSD_EN registers while on and after (no sound: zeros)
#   tone [DB]   ONE 1 kHz tone, 1 s, straight to hw:TSW1060,0 (no softvol) at
#               DB dBFS: -30 (default) or -20 (tests/tone-1k-m30dB.wav /
#               tone-1k-m20dB.wav); nothing louder is possible here.
#               Needs a person at the panel to confirm it is heard.
#   lr          440 Hz on the LEFT only, then 880 Hz on the RIGHT only, -30 dBFS
#   rec [S]     S seconds (default 5) from hw:TSW1060,1 to /tmp/rec.wav while
#               someone speaks; prints peak/RMS per channel (tsx-peak)
#   raw [S]     same with the AUDIN driver's raw=1 layout check (S32 words)
#   all-quiet   info + spk-en + rec (no audible output at all)
#
# Nothing here writes storage; the only register writes are none (reads only);
# the only module parameter change is "raw" (restored). Output also goes to
# /tmp/audio-test-<step>.log.
set -u
STEP=${1:-info}; ARG=${2:-}
CARD=TSW1060
D=/tmp
LOG=$D/audio-test-$STEP.log
RD=${RD:-$D/regdump}
if [ -z "${AUDIO_TEST_LOGGED:-}" ]; then
	AUDIO_TEST_LOGGED=1 sh "$0" "$@" 2>&1 | tee "$LOG"; exit 0
fi
say() { echo; echo "=== $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

regs() {
	if [ ! -x "$RD" ]; then echo "(no $RD: copy tools/regs/regdump to /tmp)"; return; fi
	say "AIU 0x1500..0x152f (CBUS 0xc1105400)"; "$RD" c 0x1500 0x152f
	say "AIU_MEM_I2S 0x1560..0x1570"; "$RD" c 0x1560 0x1570
	say "AUDIN 0x2800..0x2852 (I2SIN_CTRL 0x2810, FIFO0 0x2820..0x2826)"; "$RD" c 0x2800 0x2852
	say "HHI_GCLK_MPEG0..2 0x1050..0x1052 (MPEG1 bit2 AUD_IN, bit13 AIU_ADC, bit6..15 AIU)"; "$RD" c 0x1050 0x1052
	say "HHI_AUD_CLK_CNTL 0x105e, HHI_MPLL_CNTL..CNTL9 0x10a0..0x10a8"; "$RD" c 0x105e; "$RD" c 0x10a0 0x10a8
	say "BSD_EN: PREG_PAD_GPIO0_EN_N/O/I 0x200c..0x200e (O bits 29/30/31), PAD_PULL_UP_REG2 0x203c (bit 0), PULL_UP_EN_REG2 0x204a"
	"$RD" c 0x200c 0x200e; "$RD" c 0x203c; "$RD" c 0x204a
	say "AO_GPIO_O_EN_N 0x09 (AOBUS 0xc8100024), pinmux AO 0x05"; "$RD" a 0x09; "$RD" a 0x05
	say "pinmux REG1 0x202d (GPIOY_5 = bit 5 i2s_in_ch01)"; "$RD" c 0x202d
	if have devmem; then say "AO_SECURE_REG0 0xda004000 (bit 0 = BSD_EN/TEST_N output enable)"; devmem 0xda004000 32
	else echo "(no devmem: AO_SECURE_REG0 not read)"; fi
}

bsd() {  # short BSD_EN view
	[ -x "$RD" ] && { "$RD" c 0x200d; "$RD" c 0x203c; }
	have devmem && echo "AO_SECURE_REG0=$(devmem 0xda004000 32)"
	grep -i 'bsd\|enable' /sys/kernel/debug/gpio 2>/dev/null | head -3
}

info() {
	say "kernel"; uname -a; cat /proc/cmdline
	say "dmesg: audio drivers"
	dmesg | grep -iE 'aiu|audin|zl38|tfa98|asoc|snd|sound|simple-amp|amplifier|pinctrl|TSW-1060|i2c 1-00(34|36|45)' | tail -80
	say "deferred probes"; cat /sys/kernel/debug/devices_deferred 2>/dev/null
	say "ALSA"; cat /proc/asound/cards; ls /proc/asound/$CARD 2>/dev/null
	for p in /proc/asound/$CARD/pcm*/info; do [ -r "$p" ] && { echo "-- $p"; cat "$p"; }; done
	say "controls"; amixer -c $CARD contents 2>&1 | head -120
	say "DAPM (debugfs)"; for f in /sys/kernel/debug/asoc/TSW-1060/*/dapm/*; do [ -r "$f" ] && { echo "-- $f"; head -3 "$f"; }; done 2>/dev/null | head -150
	say "i2c-1 devices"; ls /sys/bus/i2c/devices/ | grep '^1-'; for d in 1-0034 1-0036 1-0045; do echo "$d: $(cat /sys/bus/i2c/devices/$d/name 2>/dev/null) driver=$(basename "$(readlink /sys/bus/i2c/devices/$d/driver 2>/dev/null)")"; done
	say "gpio"; grep -iE 'bsd|amp|enable' /sys/kernel/debug/gpio 2>/dev/null; grep -A3 -i 'ao-bank' /sys/kernel/debug/gpio 2>/dev/null | head -5
	regs
}

spk_en() {
	say "BSD_EN before"; bsd
	say "3 s of silence on hw:$CARD,0 via the speaker path (SPK_EN should go high)"
	aplay -q -D plughw:$CARD,0 -f S16_LE -r 48000 -c 2 -d 3 /dev/zero & p=$!
	sleep 1.5; say "BSD_EN while playing"; bsd
	amixer -c $CARD cget name='Left Amp Input' 2>/dev/null | tail -1
	wait $p; sleep 7   # pmdown time 5 s
	say "BSD_EN 7 s after stop (should be low again)"; bsd
}

tone() {
	db=${ARG:--30}
	case $db in -30|-20) ;; *) echo "refused: only -30 or -20 dBFS"; exit 1;; esac
	f=$D/tone-1k-m${db#-}dB.wav
	[ -r "$f" ] || { echo "copy rootfs/tests/audio/$(basename "$f") to /tmp"; exit 1; }
	say "playing 1 kHz at $db dBFS for 1 s on hw:$CARD,0 (softvol bypassed)"
	aplay -D plughw:$CARD,0 "$f"; echo "aplay exit $?"
	dmesg | tail -15
	echo "ASK THE PERSON AT THE PANEL: heard? left, right or both? distorted?"
}

lr() {
	for f in tone-left-440-m30dB.wav tone-right-880-m30dB.wav; do
		[ -r $D/$f ] || { echo "copy rootfs/tests/audio/$f to /tmp"; exit 1; }
		say "$f"; aplay -D plughw:$CARD,0 $D/$f; sleep 1
	done
	echo "ASK: 440 Hz (lower) on the LEFT speaker, 880 Hz on the RIGHT?"
}

rec() {
	s=${ARG:-5}
	say "recording $s s from hw:$CARD,1 (48 kHz S16 stereo) to $D/rec.wav: SPEAK NOW"
	arecord -D hw:$CARD,1 -f S16_LE -r 48000 -c 2 -d "$s" $D/rec.wav; echo "arecord exit $?"
	have tsx-peak && tsx-peak -i 500 $D/rec.wav || echo "(tsx-peak not installed: copy the rootfs build)"
	regs 2>/dev/null | sed -n '/AUDIN/,/HHI_GCLK/p'
	dmesg | grep -i audin | tail -5
}

raw() {
	s=${ARG:-3}; P=/sys/module/snd_soc_meson_audin/parameters/raw
	[ -w $P ] || P=$(ls /sys/module/*/parameters/raw 2>/dev/null | head -1)
	[ -w "$P" ] || { echo "no audin raw parameter"; exit 1; }
	echo 1 > "$P"
	say "raw FIFO words, $s s, S32_LE stereo -> $D/raw.bin (expect 8 L words then 8 R words per 64 bytes, 24-bit samples in bits 23..0)"
	arecord -D hw:$CARD,1 -f S32_LE -r 48000 -c 2 -d "$s" -t raw $D/raw.bin; echo "arecord exit $?"
	echo 0 > "$P"
	hexdump -C $D/raw.bin | sed -n '1000,1016p'
}

case $STEP in
info) info;;
regs) regs;;
spk-en) spk_en;;
tone) tone;;
lr) lr;;
rec) rec;;
raw) raw;;
all-quiet) info; spk_en; rec;;
*) sed -n '2,30p' "$0"; exit 1;;
esac
echo; echo "log: $LOG"
