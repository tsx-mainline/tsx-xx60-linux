#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test for "tsx-audio mic-check" (rootfs/overlay/usr/local/bin/tsx-audio).
# The ZL38051 echo canceller gates a quiet room to digital silence. A plain
# capture then looks like a dead microphone. mic-check must tell the two
# cases apart: it records the raw microphone (crosspoint TDMA-2 = MIC3) beside
# the processed signal, and it must always restore the crosspoint.
# Stand-ins: i2ctransfer (a register file), arecord (writes a WAV from the
# register state), the sound card directory and the zl38060 driver directory.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
AUDIO=$HERE/overlay/usr/local/bin/tsx-audio
export TSX_BOARD_CONF=$HERE/overlay/usr/local/lib/tsx/board.sh
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-audio-miccheck: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-audio-miccheck: no python3 on this host"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

CARD=$(. "$TSX_BOARD_CONF"; echo "$TSX_SOUND_CARD")
mkdir -p "$T/asound/$CARD" "$T/zl/1-0045" "$T/run" "$T/tmp" "$T/bin"

# i2ctransfer stand-in: "-f -y BUS wN@ADDR 0xfe PAGE-1 OFFS/2 CMD [HI LO] [r2]".
# CMD 0x80 writes one word, CMD 0x00 with r2 reads it. The registers live in
# $T/regs (one "ADDR VALUE" line each). Every call goes to $T/i2c.log.
cat > "$T/bin/i2ctransfer" <<'EOF'
#!/usr/bin/env python3
import os, sys
T = os.environ['FAKE_DIR']
open(T + '/i2c.log', 'a').write(' '.join(sys.argv[1:]) + '\n')
if os.environ.get('FAKE_I2C_FAIL'):
    sys.exit(1)
a = [x for x in sys.argv[1:] if x not in ('-f', '-y')]
bus, msg, b = a[0], a[1], a[2:]
if bus != '1' or not msg.endswith('@0x45') or b[0] != '0xfe':
    sys.exit(1)
reg = ((int(b[1], 16) + 1) << 8) | (int(b[2], 16) << 1)
regs = dict(l.split() for l in open(T + '/regs'))
key = '0x%04x' % reg
if int(b[3], 16) & 0x80:
    regs[key] = '0x%04x' % ((int(b[4], 16) << 8) | int(b[5], 16))
    open(T + '/regs', 'w').write(''.join('%s %s\n' % kv for kv in regs.items()))
else:
    v = int(regs.get(key, '0x0000'), 16)
    print('0x%02x 0x%02x' % (v >> 8, v & 0xff))
EOF
# arecord stand-in: the left slot is the processed signal ($FAKE_PROC rms),
# the right slot is what crosspoint 0x0216 selects: MIC3 (0x0003) gives the
# raw microphone ($FAKE_RAW rms), the processed source (0x000e) gives the
# left signal again. It notes the 0x0216 value that it saw.
cat > "$T/bin/arecord" <<'EOF'
#!/usr/bin/env python3
import math, os, random, struct, sys, time, wave
T = os.environ['FAKE_DIR']
regs = dict(l.split() for l in open(T + '/regs'))
xp = regs.get('0x0216', '?')
open(T + '/arecord.log', 'a').write('0x0216=%s %s\n' % (xp, ' '.join(sys.argv[1:])))
time.sleep(float(os.environ.get('FAKE_SLEEP', '0')))
if os.environ.get('FAKE_ARECORD_FAIL'):
    sys.exit(1)
args = sys.argv[1:]
secs = int(args[args.index('-d') + 1]); path = args[-1]
proc = float(os.environ.get('FAKE_PROC', '0')); raw = float(os.environ.get('FAKE_RAW', '0'))
random.seed(7)
w = wave.open(path, 'w'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
fr = []
for i in range(48000 * secs):
    l = int(random.gauss(0, proc)) if proc else 0
    r = (int(random.gauss(0, raw)) if raw else 0) if xp == '0x0003' else l
    fr.append(struct.pack('<hh', l, r))
w.writeframes(b''.join(fr)); w.close()
EOF
chmod +x "$T/bin/i2ctransfer" "$T/bin/arecord"

reset_regs() { printf '0x0214 0x000e\n0x0216 0x000e\n0x0224 0x0003\n' > "$T/regs"; rm -f "$T/i2c.log" "$T/arecord.log"; }
# Each variable can be changed for one call: VAR=value mc ...
fakeenv() {
	export FAKE_DIR=$T TSX_ASOUND_DIR=${TSX_ASOUND_DIR:-$T/asound} TSX_ZL_SYSFS=${TSX_ZL_SYSFS:-$T/zl} \
		TSX_RUN_DIR=$T/run TMPDIR=$T/tmp TSX_AUDIO_CONF=/nonexistent \
		I2CTRANSFER=$T/bin/i2ctransfer ARECORD=$T/bin/arecord
}
mc() { ( fakeenv; exec busybox sh "$AUDIO" mic-check "$@" ); }
reg() { sed -n "s/^$1 //p" "$T/regs"; }

echo "== quiet room: processed capture is digital zero, raw microphone has room noise"
reset_regs
out=$(FAKE_PROC=0 FAKE_RAW=45 mc 2 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
[ $rc = 0 ] && ok "exit 0 with a live microphone and a gated capture" || bad "exit $rc"
echo "$out" | grep -q '^result: microphone OK' && ok "result line says the microphone works" || bad "no OK result"
echo "$out" | grep -Eq '^raw microphone \(right, MIC3\): rms 4[0-9]\.' && ok "raw microphone level printed (rms about 45)" || bad "raw level wrong"
echo "$out" | grep -Eq '^processed .*: rms 0\.0 .*3 of 3 windows below rms 1' && ok "processed level shows the gated capture" || bad "processed level wrong"
echo "$out" | grep -q '^note: the echo canceller gates' && ok "note explains the gating" || bad "no gating note"
grep -q '^0x0216=0x0003 ' "$T/arecord.log" && ok "capture ran with TDMA-2 = MIC3" || bad "capture saw $(cat "$T/arecord.log")"
grep -q -- '-D tsx_dsnoop ' "$T/arecord.log" && ok "capture uses the shared tsx_dsnoop device" || bad "wrong capture device"
[ "$(reg 0x0216)" = 0x000e ] && ok "crosspoint 0x0216 restored to 0x000e" || bad "0x0216 is $(reg 0x0216)"
[ "$(reg 0x0214)" = 0x000e ] && ok "left slot (0x0214) never changed" || bad "0x0214 is $(reg 0x0214)"
ls "$T/tmp" | grep -q . && bad "temp WAV left behind" || ok "temp WAV removed"

echo "== dead microphone: raw microphone is zero too"
reset_regs
out=$(FAKE_PROC=0 FAKE_RAW=0 mc 2 2>&1); rc=$?
[ $rc = 1 ] && ok "exit 1 with no microphone signal" || bad "exit $rc: $out"
echo "$out" | grep -q '^result: FAIL, no signal from the raw microphone' && ok "FAIL result line" || bad "no FAIL line: $out"
[ "$(reg 0x0216)" = 0x000e ] && ok "crosspoint restored after the failed check" || bad "0x0216 is $(reg 0x0216)"

echo "== panel without a microphone (hw.conf MIC=no, the TSW-760-NC)"
reset_regs; printf 'GOVERNMENT=1\nMIC=no\n' > "$T/run/hw.conf"
out=$(FAKE_PROC=0 FAKE_RAW=0 mc 2 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'This panel has no microphone' && ok "no-microphone panel: exit 0 and an explanation" || bad "exit $rc: $out"
rm -f "$T/run/hw.conf"

echo "== processed signal present (speech near the panel)"
reset_regs
out=$(FAKE_PROC=300 FAKE_RAW=400 mc 2 2>&1); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q '^note:' && ok "no gating note when the processed signal is present" || bad "exit $rc: $out"

echo "== arecord fails"
reset_regs
out=$(FAKE_ARECORD_FAIL=1 mc 2 2>&1); rc=$?
[ $rc = 2 ] && ok "exit 2 when the capture fails" || bad "exit $rc: $out"
[ "$(reg 0x0216)" = 0x000e ] && ok "crosspoint restored after the capture failure" || bad "0x0216 is $(reg 0x0216)"

echo "== TERM during the capture"
reset_regs
( fakeenv; export FAKE_RAW=45 FAKE_SLEEP=1.5; exec busybox sh "$AUDIO" mic-check 2 >"$T/term.out" 2>&1 ) & P=$!
sleep 0.7; kill -TERM $P; wait $P; rc=$?
[ $rc = 130 ] && ok "exit 130 after TERM" || bad "exit $rc after TERM: $(cat "$T/term.out")"
[ "$(reg 0x0216)" = 0x000e ] && ok "crosspoint restored after TERM" || bad "0x0216 is $(reg 0x0216) after TERM"

echo "== bad arguments and missing parts"
reset_regs
mc x >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ ! -e "$T/i2c.log" ] && ok "bad duration: exit 1, no I2C access" || bad "bad duration: exit $rc"
mc 61 >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ ! -e "$T/i2c.log" ] && ok "duration above 60 s refused" || bad "61 s: exit $rc"
out=$(TSX_ZL_SYSFS=$T/none mc 2 2>&1); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q 'no ZL38051' && ok "no bound ZL38051: exit 2" || bad "no ZL: exit $rc $out"
out=$(FAKE_I2C_FAIL=1 mc 2 2>&1); rc=$?
[ $rc = 2 ] && [ ! -e "$T/arecord.log" ] && ok "I2C read failure: exit 2, no capture" || bad "I2C failure: exit $rc $out"
out=$(TSX_ASOUND_DIR=$T/nocard mc 2 2>&1); rc=$?
[ $rc = 2 ] && [ ! -e "$T/arecord.log" ] && ok "no sound card: exit 2" || bad "no card: exit $rc $out"

echo "== help text lists the command"
usage=$(busybox sh "$AUDIO" 2>/dev/null)
echo "$usage" | grep -q 'tsx-audio mic-check \[SECONDS\]' && ok "usage lists mic-check" || bad "usage has no mic-check"

echo "$N ok, $F failed"
[ $F = 0 ]
