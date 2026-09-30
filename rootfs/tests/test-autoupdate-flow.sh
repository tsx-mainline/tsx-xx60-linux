#!/bin/sh
# End-to-end host test of tsx-autoupdate. Two fakes drive the real check,
# install, status and healthcheck code against temp dirs:
#  - a fake apk with canned output for "update", "upgrade --simulate",
#    "list -a chromium" and "info -v". It logs every call.
#  - a fake date with a fixed "now" and real day-math (-d passthrough)
# The test touches nothing on the host. /etc/apk/world, the chromium binary,
# rc-service, curl and reboot are all stubs under $T/bin.
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
"update ") cat "$T/update.txt" 2>/dev/null; exit "\${APK_UPDATE_RC:-0}";;
"upgrade --simulate") cat "$T/sim.txt" 2>/dev/null; exit 0;;
"upgrade chromium") exit "\${APK_UPGRADE_RC:-0}";;
"upgrade ") exit "\${APK_UPGRADE_RC:-0}";;
"upgrade --force-missing-repositories") exit "\${APK_UPGRADE_RC:-0}";;
"info -e") [ "\${3:-}" = tsx-xx60-chromium ] && exit "\${TSXCHROM_INSTALLED:-1}"; exit 0;;
"list -a") if [ "\${3:-}" = tsx-xx60-chromium ]; then cat "$T/tsxchrom.txt" 2>/dev/null; else cat "$T/chromlist.txt" 2>/dev/null; fi; exit 0;;
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
cat > "$T/bin/curl" <<EOF
#!/bin/sh
echo "CALL curl \$*" >> "$T/calls"
echo "\${CURL_CODE:-200}"
EOF
chmod +x "$T/bin/curl"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=200 run healthcheck >/dev/null
chk "$(jf "$T/run/update.json" .health)" OK "9: healthy after reboot"
[ -e "$T/state/reboot-marker" ] && { echo "FAIL: 9: reboot-marker not cleared"; fail=1; }

: > "$T/state/reboot-marker"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=000 RC_SERVICE_RC=1 run healthcheck >/dev/null
h=$(jf "$T/run/update.json" .health)
case $h in FAILED*) : ;; *) echo "FAIL: 9: expected a FAILED health after a bad reboot, got '$h'"; fail=1;; esac

# ---- 9b: panel.conf override (/run/tsx/kiosk.conf) wins over KIOSK_CONF for
# the health-check URL, same precedence as kiosk-session
: > "$T/state/reboot-marker"; : > "$T/calls"
echo 'KIOSK_URL="https://panel.example.net/lovelace/0"' > "$T/run/kiosk.conf"
NOWDATE=2026-01-09 NOWHHMM=04:00 CURL_CODE=200 run healthcheck >/dev/null
grep -q 'CALL curl.*https://panel.example.net/lovelace/0' "$T/calls" || { echo "FAIL: 9b: health check did not use /run/tsx/kiosk.conf's KIOSK_URL override"; fail=1; }
rm -f "$T/run/kiosk.conf"

# ---- 10: this project's repository unreachable: warning, Alpine still installs
rm -f "$T/state/reboot-marker"
printf 'chromium=3.0.0-r0\nsome-other-pkg\n' > "$T/world"
printf 'chromium-3.0.0-r0 armv7 {chromium} (BSD-3-Clause)\n' > "$T/chromlist.txt"
cat > "$T/update.txt" <<'U'
WARNING: updating and opening https://tsx-aports.example.org/v3.24/common/armv7/APKINDEX.tar.gz: DNS: name does not exist
WARNING: updating and opening https://tsx-aports.example.org/v3.24/xx60/armv7/APKINDEX.tar.gz: DNS: name does not exist
v3.24.2-50-g2d91fef52d8 [https://dl-cdn.alpinelinux.org/alpine/v3.24/main]
2 unavailable, 0 stale; 6093 distinct packages available
U
printf '(1/1) Upgrading libfoo (1.1-r0 -> 1.2-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-10 NOWHHMM=04:00 APK_UPDATE_RC=2 run >/dev/null
rw=$(jf "$T/run/update.json" .repo_warning)
case $rw in "tsx-aports repository unreachable (https://tsx-aports.example.org/v3.24/common, https://tsx-aports.example.org/v3.24/xx60)"*) :;; *) echo "FAIL: 10: repo_warning '$rw'"; fail=1;; esac
grep -q '^APK upgrade --simulate --force-missing-repositories$' "$T/apk.calls" || { echo "FAIL: 10: check did not force past our missing repositories"; fail=1; }
grep -q '^APK upgrade --force-missing-repositories$' "$T/apk.calls" || { echo "FAIL: 10: Alpine updates not installed while our repository is unreachable"; fail=1; }
chk "$(jf "$T/run/update.json" .pending_count)" 1 "10: Alpine update still counted"
jf "$T/run/update-ha-state.json" .release_summary | grep -q 'WARNING: tsx-aports repository unreachable' || { echo "FAIL: 10: HA summary lacks the repository warning"; fail=1; }
run status | grep -q '^repositories:   tsx-aports repository unreachable' || { echo "FAIL: 10: status lacks the repository warning"; fail=1; }

# ---- 11: an Alpine repository unreachable: check only, no install -------------
printf 'WARNING: updating and opening https://dl-cdn.alpinelinux.org/alpine/v3.24/main/armv7/APKINDEX.tar.gz: Connection refused\n' > "$T/update.txt"
reset_calls
NOWDATE=2026-01-10 NOWHHMM=04:00 APK_UPDATE_RC=1 run >/dev/null
grep -E '^APK upgrade( --force-missing-repositories)?$' "$T/apk.calls" && { echo "FAIL: 11: installed while an Alpine repository is unreachable"; fail=1; }
chk "$(jf "$T/run/update.json" .repo_warning | grep -c 'not installing until it is back')" 1 "11: Alpine repository warning"

# ---- 12: all repositories fine again: warning cleared ---------------------------
: > "$T/update.txt"; : > "$T/sim.txt"
NOWDATE=2026-01-10 NOWHHMM=12:00 run check >/dev/null
chk "$(jf "$T/run/update.json" .repo_warning)" "" "12: warning cleared once reachable"
run status | grep -q '^repositories:   ok$' || { echo "FAIL: 12: status does not say repositories ok"; fail=1; }

# ---- 13: pinned Alpine chromium + tsx-xx60-chromium offered: migrate ------------
printf 'tsx-xx60-chromium-3.0.0-r0 armv7 {tsx-xx60-chromium} (BSD-3-Clause)\n' > "$T/tsxchrom.txt"
echo "old sidecar" > "$T/es2marker"; echo "package sidecar" > "$T/es2marker.apk-new"
reset_calls
NOWDATE=2026-01-10 NOWHHMM=04:00 run >/dev/null
grep -q '^APK add tsx-xx60-chromium$' "$T/apk.calls" || { echo "FAIL: 13: tsx-xx60-chromium not added"; fail=1; }
grep -q '^APK del chromium$' "$T/apk.calls" || { echo "FAIL: 13: chromium= pin not dropped"; fail=1; }
chk "$(cat "$T/es2marker")" "package sidecar" "13: the package's ES2 sidecar took over"
grep -q '^CALL rc-service kiosk stop' "$T/calls" || { echo "FAIL: 13: kiosk not stopped for the switch"; fail=1; }
grep -q 'now tsx-xx60-chromium' "$T/tsx-autoupdate.log" || { echo "FAIL: 13: switch not logged"; fail=1; }

# ---- 14: tsx-xx60-chromium installed: an ordinary package, no hold/patch logic ---
printf 'chromium=3.0.0-r0\nsome-other-pkg\n' > "$T/world"   # (a leftover pin must not matter)
printf 'chromium-4.0.0-r0 armv7 {chromium} (BSD-3-Clause)\n' > "$T/chromlist.txt"
printf '(1/1) Upgrading tsx-xx60-kernel-lts (6.18.54_git20260928-r1 -> 6.18.55_git20261005-r0)\n' > "$T/sim.txt"
reset_calls
NOWDATE=2026-01-11 NOWHHMM=12:00 TSXCHROM_INSTALLED=0 run check >/dev/null
chk "$(jf "$T/run/update.json" .chromium_decision)" none "14: tsx-xx60-chromium installed -> none"
chk "$(jf "$T/run/update.json" .reboot_pending)" true "14: a kernel package update needs a reboot"
chk "$(jf "$T/run/update.json" .chromium_pinned)" tsx-xx60-chromium "14: status names the package"
TSXCHROM_INSTALLED=0 run status | grep -q '^chromium:       tsx-xx60-chromium (ES2 patch built in' || { echo "FAIL: 14: status chromium line"; fail=1; }
[ -e "$T/state/chromium-hold" ] && { echo "FAIL: 14: hold file written for a packaged chromium"; fail=1; }

[ $fail = 0 ] && echo "PASS tsx-autoupdate flow (check/install/window/idle/chromium/status/healthcheck/repositories/tsx-xx60-chromium)"
exit $fail
