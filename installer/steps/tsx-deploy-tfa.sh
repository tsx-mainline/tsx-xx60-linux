#!/usr/bin/env bash
# Host: fetch the TFA9890 speaker-amplifier DSP tuning files (.cnt containers;
# Crestron/NXP proprietary, never committed to the repository) with
# rootfs/vendor-fetch.sh ON THIS MACHINE, then copy them onto an already-
# mainline panel at /usr/local/share/tsx/tfa9890/<variant>/stereo.cnt (the
# path tsx-tfa-dsp / tfa_dsp.py expects). Called by tsx-install-mainline
# after the eMMC migration; safe to re-run by hand later (e.g. if the first
# fetch failed and the panel is running with no DSP tuning: the speakers
# still work, just without the vendor EQ/volume-step presets).
#   steps/tsx-deploy-tfa.sh PANEL_IP [--dry-run]
# Exit 0 even if the fetch or deploy fails (the DSP is optional): callers
# that want a hard failure should check the printed WARNING/ERROR lines.
# Needs: rootfs/vendor-fetch.sh (this repo, unmodified; see docs/rootfs.md),
# sshpass, ssh, scp. Panel login: root / $TSX_MAINLINE_PW (default tsx).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FETCH="$HERE/../../rootfs/vendor-fetch.sh"
PANEL= DRY=0
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1; shift;; -h|--help) sed -n '2,15p' "$0"; exit 0;; --*) echo "unknown $1" >&2; exit 2;; *) PANEL=$1; shift;; esac; done
[ -n "$PANEL" ] || { sed -n '2,15p' "$0" >&2; exit 2; }
say() { echo "tsx-deploy-tfa: $*" >&2; }
VARIANTS="settings_yushan settings_yushan_2nd settings_yushan_3rd"
LOCAL=${TFA_VENDOR_LOCAL:-"$HERE/../../rootfs/vendor-local/tfa9890"}
MPW=${TSX_MAINLINE_PW:-tsx}
SSH="sshpass -p $MPW ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@$PANEL"
SCP="sshpass -p $MPW scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

if [ ! -x "$FETCH" ]; then say "WARNING: $FETCH not found/executable; skipping DSP file deployment"; exit 0; fi
if [ "$DRY" = 1 ]; then
	say "[dry-run] would run: $FETCH (fetch/verify the .cnt files locally)"
	for v in $VARIANTS; do say "[dry-run] would copy $LOCAL/$v/stereo.cnt -> root@$PANEL:/usr/local/share/tsx/tfa9890/$v/stereo.cnt"; done
	exit 0
fi
if ! "$FETCH"; then
	say "WARNING: rootfs/vendor-fetch.sh failed (no network, or Crestron's firmware CDN unreachable); the panel will run without DSP tuning. Retry later: $FETCH && $0 $PANEL"
	exit 0
fi
FAILS=0
for v in $VARIANTS; do
	f="$LOCAL/$v/stereo.cnt"
	[ -f "$f" ] || { say "WARNING: $f missing after vendor-fetch.sh; skipping $v"; FAILS=$((FAILS+1)); continue; }
	want=$(sha256sum < "$f" | cut -d' ' -f1)
	if ! $SSH "mkdir -p /usr/local/share/tsx/tfa9890/$v" >/dev/null 2>&1; then say "WARNING: cannot create /usr/local/share/tsx/tfa9890/$v on $PANEL"; FAILS=$((FAILS+1)); continue; fi
	if ! $SCP "$f" "root@$PANEL:/usr/local/share/tsx/tfa9890/$v/stereo.cnt" >/dev/null 2>&1; then say "WARNING: scp of $v/stereo.cnt to $PANEL failed"; FAILS=$((FAILS+1)); continue; fi
	got=$($SSH "sha256sum < /usr/local/share/tsx/tfa9890/$v/stereo.cnt" 2>/dev/null | cut -d' ' -f1)
	if [ "$got" = "$want" ]; then say "ok: $v/stereo.cnt deployed to $PANEL ($want)"
	else say "WARNING: $v/stereo.cnt readback mismatch on $PANEL ($got != $want)"; FAILS=$((FAILS+1))
	fi
done
[ $FAILS = 0 ] && say "done: all TFA9890 DSP files deployed" || say "WARNING: $FAILS of 3 DSP variant(s) not deployed (see above); the panel works without them"
exit 0
