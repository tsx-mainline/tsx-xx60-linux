#!/bin/bash
# Host test: installer/tsx-install-mainline --dry-run against a synthetic
# payload directory. The test needs no docker, no panel and no network beyond
# argument validation. It checks that the v2 driver validates the payload
# (missing files, sha256 mismatches) before it would touch a panel. It also
# checks that --dry-run prints the step list and needs neither $TSX_ADMIN_PW
# nor a real IP.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
DRIVER="$HERE/tsx-install-mainline"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

mkpayload() {   # a minimal but sha256-consistent v2 payload dir
	local p=$1
	mkdir -p "$p/lts"
	echo fake-rescue > "$p/rescue.img"
	sha256sum < "$p/rescue.img" | awk '{print $1"  rescue.img"}' > "$p/rescue.img.sha256"
	echo fake-root > "$p/lts/root.img"
	echo fake-boot > "$p/lts/boot.img"
	echo "format=tsx-rescue-install-1
kernel_flavor=lts
root_bytes=10
root_sha256=$(sha256sum < "$p/lts/root.img" | cut -d' ' -f1)
boot_sha256=$(sha256sum < "$p/lts/boot.img" | cut -d' ' -f1)" > "$p/lts/manifest"
	(cd "$p/lts" && sha256sum root.img boot.img > SHA256SUMS)
}

echo "== 1. --dry-run with a valid payload: no PANEL_IP needed error, but usage is required"
mkpayload "$W/good"
OUT=$("$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --dry-run 2>&1) && ok "dry-run exits 0" || bad "dry-run failed: $OUT"
echo "$OUT" | grep -q "dry-run done" && ok "prints 'dry-run done'"
echo "$OUT" | grep -q "dry-run\] 1:" && ok "prints step 1 (get root)"
echo "$OUT" | grep -q "dry-run\] 3:" && ok "prints step 3 (discover the rescue)"

echo "== 2. --kernel is required"
"$DRIVER" 10.0.0.1 --payload "$W/good" --dry-run >"$W/o2.txt" 2>&1 && bad "missing --kernel accepted" || ok "missing --kernel refused"
grep -qi "kernel lts|stable is required" "$W/o2.txt" && ok "error names the missing option"

echo "== 3. a missing payload file is refused before any network use"
mkpayload "$W/broken"; rm -f "$W/broken/lts/boot.img"
"$DRIVER" 10.0.0.1 --payload "$W/broken" --kernel lts --dry-run >"$W/o3.txt" 2>&1 && bad "missing boot.img accepted" || ok "missing boot.img refused"
grep -q "missing payload file" "$W/o3.txt" && ok "error names the missing payload file"

echo "== 4. a tampered root.img (sha256 mismatch) is refused"
mkpayload "$W/tampered"; echo different > "$W/tampered/lts/root.img"
"$DRIVER" 10.0.0.1 --payload "$W/tampered" --kernel lts --dry-run >"$W/o4.txt" 2>&1 && bad "sha256 mismatch accepted" || ok "sha256 mismatch refused"
grep -qi "SHA256SUMS mismatch" "$W/o4.txt" && ok "error names the SHA256SUMS mismatch"

echo "== 5. a panel that already runs the mainline kiosk: the reinstall path (TSX_PANEL_KIND skips the probe)"
OUT=$(TSX_PANEL_KIND=mainline "$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run 2>&1) && ok "reinstall dry-run exits 0" || bad "reinstall dry-run failed: $OUT"
echo "$OUT" | grep -q "already the mainline kiosk" && ok "names the reinstall path" || bad "reinstall path not named"
echo "$OUT" | grep -q "tsx-arm-from-mainline.sh" && ok "step 2 arms from the kiosk (lib/tsx-arm-from-mainline.sh)" || bad "step 2 does not use tsx-arm-from-mainline.sh"
echo "$OUT" | grep -q "golden slot" && ok "step 3 updates the golden slot" || bad "no golden-slot update in step 3"
echo "$OUT" | grep -q "tsx-ensure-root\|rootsh" && bad "the reinstall plan still mentions Android root" || ok "no Android root in the reinstall plan"
echo "$OUT" | grep -q "panel's own /data/tsx/panel.conf would be kept" && ok "--yes without --config keeps the panel's panel.conf" || bad "panel.conf carry-over not reported"
echo "$OUT" | grep -q "kept if it is a clean tsxdata" && ok "the reinstall keeps /data by default" || bad "/data keep not reported"
echo "$OUT" | grep -q "dry-run\] 4: tsx-rescue-install check /tmp/b --keep-data" && ok "step 4 passes --keep-data" || bad "step 4 has no --keep-data"
echo "$OUT" | grep -q "kept in place on the kept tsxdata" && ok "panel.conf stays in place (not re-sent)" || bad "panel.conf in-place keep not reported"
OUT=$(TSX_PANEL_KIND=mainline "$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --wipe-data --dry-run 2>&1) && ok "--wipe-data dry-run exits 0" || bad "--wipe-data dry-run failed: $OUT"
echo "$OUT" | grep -q -- "--wipe-data: formatted again" && ok "--wipe-data formats /data" || bad "--wipe-data not reported"
echo "$OUT" | grep -q -- "--keep-data" && bad "--wipe-data still passes --keep-data" || ok "--wipe-data drops --keep-data"
echo "$OUT" | grep -q "copied onto the new tsxdata" && ok "--wipe-data carries panel.conf over" || bad "--wipe-data panel.conf carry-over not reported"
OUT=$(TSX_PANEL_KIND=rescue "$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run 2>&1)
echo "$OUT" | grep -q -- "--keep-data" && ok "a resume in the rescue keeps /data too" || bad "resume does not keep /data: $OUT"
OUT=$(TSX_PANEL_KIND=android "$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run 2>&1)
echo "$OUT" | grep -q "dry-run\] 1: steps/tsx-ensure-root" && ok "stock Android keeps the Android path" || bad "Android path changed: $OUT"
echo "$OUT" | grep -q "tsx-arm-from-mainline" && bad "Android plan mentions the mainline arm" || ok "Android plan has no mainline arm"
echo "$OUT" | grep -q -- "--keep-data" && bad "the Android path passes --keep-data" || ok "the Android path formats /data (no --keep-data)"
echo "$OUT" | grep -q "card fold + tsxdata mkfs" && ok "the Android plan folds + formats" || bad "Android plan does not fold + format"

echo "== 6. TFA9890 DSP files: the panel first, the .puf download as the fallback (--tfa-source)"
OUT=$(TSX_PANEL_KIND=android "$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run 2>&1)
echo "$OUT" | grep -q "tfa-source=auto" && ok "default --tfa-source is auto" || bad "default tfa-source not auto: $OUT"
echo "$OUT" | grep -q "tsx-rescue-install tfa /tmp/b (read-only: the current root on eMMC p8, then stock Android's boot image on eMMC p7" && ok "auto: the panel is searched first" || bad "auto plan does not search the panel: $OUT"
echo "$OUT" | grep -q "Only if that finds no valid set: rootfs/vendor-fetch.sh" && ok "auto: the .puf download only as the fallback" || bad "auto plan has no .puf fallback"
echo "$OUT" | grep -q "tsx-tfa.sh" && ok "the bundle carries lib/tsx-tfa.sh" || bad "tsx-tfa.sh not in the bundle"
OUT=$(TSX_PANEL_KIND=mainline "$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run --tfa-source puf 2>&1)
echo "$OUT" | grep -q "(--tfa-source puf): rootfs/vendor-fetch.sh here" && ok "puf: the download only" || bad "puf plan wrong: $OUT"
echo "$OUT" | grep -q "tsx-rescue-install tfa" && bad "puf still searches the panel" || ok "puf: the panel is not searched"
OUT=$("$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run --tfa-source panel 2>&1)
echo "$OUT" | grep -q "No .puf download" && ok "panel: no .puf download" || bad "panel plan wrong: $OUT"
OUT=$("$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --yes --dry-run --tfa-source none 2>&1)
echo "$OUT" | grep -q "(--tfa-source none): none" && ok "none: no DSP files" || bad "none plan wrong: $OUT"
"$DRIVER" 10.0.0.1 --payload "$W/good" --kernel lts --dry-run --tfa-source cloud >"$W/o6.txt" 2>&1 && bad "--tfa-source cloud accepted" || ok "--tfa-source cloud refused"
grep -q "tfa-source must be auto, panel, puf, or none" "$W/o6.txt" && ok "error names the valid values" || bad "no useful error: $(cat "$W/o6.txt")"

echo "== 7. --help exits 0 with no payload at all"
"$DRIVER" --help >/dev/null 2>&1 && ok "--help exits 0"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-mainline-dryrun || echo FAIL test-install-mainline-dryrun
exit $F
