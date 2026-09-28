#!/bin/bash
# Host test: installer/tsx-install-mainline --dry-run against a synthetic
# payload directory (no docker, no panel, no network beyond argument
# validation). Checks that the v2 driver validates the payload (missing
# files, sha256 mismatches) before it would ever touch a panel, and that
# --dry-run prints the step list without needing $TSX_ADMIN_PW or a real IP.
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
echo "$OUT" | grep -q "dry-run\] 1:" && ok "prints step 1 (ensure root)"
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

echo "== 5. --help exits 0 with no payload at all"
"$DRIVER" --help >/dev/null 2>&1 && ok "--help exits 0"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-install-mainline-dryrun || echo FAIL test-install-mainline-dryrun
exit $F
