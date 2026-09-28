#!/bin/sh
# Host test: tsx-voice-run (tsx-voice, VOICE=on) and tsx-esphome-run
# (tsx-esphome, VOICE=off) must both pick up panel.conf's PANEL_NAME through
# /run/tsx/voice.conf (written by `tsx-config apply`, unconditionally, so it
# is there for either front end) for the ESPHome device name (--name) --
# same /etc default then /run/tsx override precedence as kiosk-session's
# /etc/kiosk.conf + /run/tsx/kiosk.conf (docs/rootfs.md "Panel
# configuration"). --print only builds and prints the command, so this needs
# neither linux-voice-assistant nor python3.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
O=$HERE/../overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run"
HOST=$(hostname)
fail=0

chk() {  # chk LABEL OUTPUT WANT_NAME
	case " $2 " in *" --name $3 "*) ;; *) echo "FAIL: $1: want --name $3, got: $2"; fail=1;; esac
}

# ---- no /run/tsx/voice.conf, no NAME in /etc/tsx/*.conf either: hostname ---
printf 'PORT=6053\n' > "$T/voice.conf"
printf 'PORT=6053\n' > "$T/esphome.conf"
out=$(TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" \
	sh "$O/usr/local/bin/tsx-voice-run" --print)
chk "voice, no config at all" "$out" "$HOST"
out=$(TSX_ESPHOME_CONF="$T/esphome.conf" TSX_ESPHOME_RUN_CONF="$T/run/voice.conf" \
	sh "$O/usr/local/bin/tsx-esphome-run" --print)
chk "esphome, no config at all" "$out" "$HOST"

# ---- panel.conf override (/run/tsx/voice.conf's NAME, from PANEL_NAME): ---
# both front ends must use it, whichever one is actually running
printf 'NAME="panel-override"\n' > "$T/run/voice.conf"
out=$(TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" \
	sh "$O/usr/local/bin/tsx-voice-run" --print)
chk "voice, panel.conf override" "$out" "panel-override"
out=$(TSX_ESPHOME_CONF="$T/esphome.conf" TSX_ESPHOME_RUN_CONF="$T/run/voice.conf" \
	sh "$O/usr/local/bin/tsx-esphome-run" --print)
chk "esphome, panel.conf override" "$out" "panel-override"

# ---- a NAME set directly in /etc/tsx/voice.conf still wins over hostname --
# when there is no panel.conf override (existing behaviour, must not regress)
rm -f "$T/run/voice.conf"
printf 'NAME=local-name\nPORT=6053\n' > "$T/voice.conf"
out=$(TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" \
	sh "$O/usr/local/bin/tsx-voice-run" --print)
chk "voice, /etc/tsx/voice.conf NAME, no override" "$out" "local-name"

# ---- the panel.conf override still wins over a static /etc/tsx/*.conf NAME
printf 'NAME="panel-override"\n' > "$T/run/voice.conf"
out=$(TSX_VOICE_CONF="$T/voice.conf" TSX_VOICE_RUN_CONF="$T/run/voice.conf" \
	sh "$O/usr/local/bin/tsx-voice-run" --print)
chk "voice, panel.conf override beats /etc/tsx/voice.conf NAME" "$out" "panel-override"

[ $fail = 0 ] && echo "PASS tsx-voice-run / tsx-esphome-run: panel.conf PANEL_NAME override honoured"
exit $fail
