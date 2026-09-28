#!/bin/sh
# End-to-end host test of tsx-autoupdate: a fake apk (canned "upgrade
# --simulate" / "list -a chromium" / "info -v" output, every call logged)
# and a fake date (fixed "now", real day-math via -d passthrough) drive the
# real check/install/status/healthcheck code against temp dirs. Nothing on
# the host is touched: /etc/apk/world, the chromium binary, rc-service,
# curl and reboot are all stubs under $T/bin.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); BIN=$HERE/../../rootfs/overlay/usr/local/sbin/tsx-autoupdate
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
fail=0
REALDATE=$(command -v date)

cat > "$T/bin/apk" <<EOF
#!/bin/sh
echo "APK \$*" >> "$T/apk.calls"
case "\$1 \${2:-}" in
"update ") exit 0;;
"upgrade --simulate") cat "$T/sim.txt" 2>/dev/null; exit 0;;
"upgrade chromium") exit "\${APK_UPGRADE_RC:-0}";;
"upgrade ") exit "\${APK_UPGRADE_RC:-0}";;
"list -a") cat "$T/chromlist.txt" 2>/dev/null; exit 0;;
"info -v") printf 'chromium-%s-r0\nmusl-1.2.5-r0\n' "\${CHROMIUM_INSTALLED:-1.0.0-r0}"; exit 0;;
esac
exit 0
EOF
cat > "$T/bin/date" <<EOF
#!/bin/sh
if [ "\$1" = -d ]; then shift; exec "$REALDATE" -d "\$@"; fi
case "\$1" in
'+%F') echo "\${NOWDATE:-2026-01-01}";;
'+%H:%M') echo "\${NOWHHMM:-04:00}";;
'+%Y-%m-%dT%H:%M:%S') echo "\${NOWDATE:-2026-01-01}T\${NOWHHMM:-04:00}:00";;
*) exec "$REALDATE" "\$@";;
esac
EOF
for c in rc-service curl reboot python3 tsx-chromium-es2 hostname; do
	printf '#!/bin/sh\necho "CALL %s $*" >> "%s/calls"\nexit "${%s_RC:-0}"\n' "$c" "$T" "$(echo "$c" | tr 'a-z-' 'A-Z_')" > "$T/bin/$c"
done
echo hostname-test >/dev/null   # (fake hostname's own $* is empty, fine either way)
chmod +x "$T/bin"/*

: > "$T/sim.txt"; : > "$T/chromlist.txt"; : > "$T/calls"; : > "$T/apk.calls"
printf 'chromium=1.0.0-r0\nsome-other-pkg\n' > "$T/world"
printf '{"x":{"package":"chromium-2.0.0-r0 (Alpine v3.24 community, armv7)"}}\n' > "$T/sigs.json"
: > "$T/nopatch.py"
printf 'ENABLED=1\nWINDOW=03:00-05:00\nHOLD_DAYS=7\nREBOOT=auto\n' > "$T/autoupdate.conf"
echo blank > "$T/idled"
echo 'KIOSK_URL="https://ha.example.org"' > "$T/kiosk.conf"

run() {  # run SUBCOMMAND  (env NOWDATE/NOWHHMM/APK_UPGRADE_RC/etc already exported)
	PATH="$T/bin:$PATH" \
	TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" \
	TSX_LOG="$T/tsx-autoupdate.log" TSX_IDLED_STATE="$T/idled" TSX_KIOSK_CONF="$T/kiosk.conf" \
	TSX_WORLD="$T/world" TSX_SIGS="$T/sigs.json" TSX_PATCH_TOOL="$T/nopatch.py" \
	TSX_ES2_MARKER="$T/es2marker" TSX_CHROMIUM_BIN="$T/chromium-bin" TSX_BUILD_ID_FILE="$T/buildid" \
	sh "$BIN" "$@"
}
jf() { jq -r "$2" "$1"; }   # jf FILE .jqfilter
chk() { [ "$1" = "$2" ] || { echo "FAIL: $3: got '$1', want '$2'"; fail=1; }; }
reset_calls() { : > "$T/calls"; : > "$T/apk.calls"; }

# ---- 1: nothing pending, chromium candidate == pinned: no-op --------------
printf 'chromium-1.0.0-r0 armv7 {chromium} (BSD-3-Clause)\n' > "$T/chromlist.txt"
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 0 "1: nothing pending"
chk "$(jf "$T/run/update.json" .reboot_pending)" false "1: no reboot pending"
chk "$(jf "$T/run/update.json" .chromium_decision)" none "1: chromium candidate == pinned"
chk "$(jf "$T/run/update.json" .chromium_held_since)" "" "1: no hold date while candidate == pinned"
[ -e "$T/state/chromium-hold" ] && { echo "FAIL: 1: hold file written with no newer candidate"; fail=1; }
: > "$T/chromlist.txt"
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 1: installed with nothing pending"; fail=1; }

# ---- 2: a reboot-needing package pending, in window + idle: installs and reboots
printf '(1/2) Upgrading musl (1.2.5-r0 -> 1.2.5-r1)\n(2/2) Upgrading libfoo (1.0-r0 -> 1.1-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .pending_count)" 2 "2: two pending packages"
chk "$(jf "$T/run/update.json" .reboot_pending)" true "2: musl -> reboot needed"
grep -q '^APK upgrade$' "$T/apk.calls" || { echo "FAIL: 2: apk upgrade not run"; fail=1; }
grep -q '^CALL reboot' "$T/calls" || { echo "FAIL: 2: reboot not called inside the window"; fail=1; }
[ -e "$T/state/reboot-marker" ] || { echo "FAIL: 2: reboot-marker not written"; fail=1; }
chk "$(jf "$T/run/update.json" .last_result)" ok "2: last_result ok"

# ---- 3: same pending list, outside the window: must not install -----------
rm -f "$T/state/reboot-marker"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=12:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 3: installed outside the window"; fail=1; }
grep -q 'not installing now' "$T/tsx-autoupdate.log" || { echo "FAIL: 3: no 'not installing' log line"; fail=1; }

# ---- 4: in window but the screen is not idle: must not install ------------
echo "on 17" > "$T/idled"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
grep -q '^APK upgrade$' "$T/apk.calls" && { echo "FAIL: 4: installed while not idle"; fail=1; }
echo blank > "$T/idled"

# ---- 5: chromium candidate with a known ES2 signature: upgrade + patch ----
: > "$T/sim.txt"
printf 'chromium-2.0.0-r0 armv7 {chromium} (BSD-3-Clause)\n' > "$T/chromlist.txt"
reset_calls
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .chromium_decision)" patch "5: signature known -> patch"
grep -q '^CALL rc-service kiosk stop' "$T/calls" || { echo "FAIL: 5: kiosk not stopped"; fail=1; }
grep -q '^CALL python3 ' "$T/calls" || { echo "FAIL: 5: patch-chromium.py not invoked"; fail=1; }
grep -q '^chromium=2.0.0-r0$' "$T/world" || { echo "FAIL: 5: world not re-pinned to the new version"; fail=1; }
grep -q 'ES2 patch applied' "$T/tsx-autoupdate.log" || { echo "FAIL: 5: patch-applied not logged"; fail=1; }

# ---- 6: chromium candidate with NO known signature: held, not upgraded ----
printf 'chromium=2.0.0-r0\nsome-other-pkg\n' > "$T/world"   # reset the pin from step 5
printf 'chromium-3.0.0-r0 armv7 {chromium} (BSD-3-Clause)\n' > "$T/chromlist.txt"
: > "$T/sigs.json"; echo '{}' > "$T/sigs.json"
reset_calls; rm -f "$T/state/chromium-hold"
NOWDATE=2026-01-01 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .chromium_decision)" "hold 0" "6: unknown signature: held"
chk "$(jf "$T/run/update.json" .chromium_held_since)" 2026-01-01 "6: held_since recorded"
grep -q '^chromium=3.0.0-r0$' "$T/world" && { echo "FAIL: 6: must not upgrade while held"; fail=1; }

# ---- 7: same candidate, HOLD_DAYS later: taken unpatched -------------------
reset_calls
NOWDATE=2026-01-08 NOWHHMM=04:00 run >/dev/null
chk "$(jf "$T/run/update.json" .chromium_decision)" unpatched "7: hold expired -> unpatched"
grep -q '^chromium=3.0.0-r0$' "$T/world" || { echo "FAIL: 7: world not re-pinned after taking it unpatched"; fail=1; }
grep -q '^CALL tsx-chromium-es2 check' "$T/calls" || { echo "FAIL: 7: tsx-chromium-es2 check not run"; fail=1; }
grep -q 'taking the update with no known ES2 signature' "$T/tsx-autoupdate.log" || { echo "FAIL: 7: unpatched decision not logged clearly"; fail=1; }
[ -e "$T/state/chromium-hold" ] && { echo "FAIL: 7: hold file not cleared"; fail=1; }

# ---- 8: status --------------------------------------------------------------
out=$(run status); rc=$?
chk "$rc" 0 "8: status exits 0"
echo "$out" | grep -q '^pending:' || { echo "FAIL: 8: status missing 'pending:'"; fail=1; }
echo "$out" | grep -q '^chromium:' || { echo "FAIL: 8: status missing 'chromium:'"; fail=1; }

# ---- 9: post-reboot health check, OK then FAILED ---------------------------
: > "$T/state/reboot-marker"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo "CALL curl $*" >> "$T/calls"
echo "${CURL_CODE:-200}"
EOF
chmod +x "$T/bin/curl"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=200 run healthcheck >/dev/null
chk "$(jf "$T/run/update.json" .health)" OK "9: healthy after reboot"
[ -e "$T/state/reboot-marker" ] && { echo "FAIL: 9: reboot-marker not cleared"; fail=1; }

: > "$T/state/reboot-marker"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=000 RC_SERVICE_RC=1 run healthcheck >/dev/null
h=$(jf "$T/run/update.json" .health)
case $h in FAILED*) : ;; *) echo "FAIL: 9: expected a FAILED health after a bad reboot, got '$h'"; fail=1;; esac

[ $fail = 0 ] && echo "PASS tsx-autoupdate flow (check/install/window/idle/chromium/status/healthcheck)"
exit $fail
