#!/bin/bash
# Syntax / smoke lint for the whole repo, no hardware and no build needed.
# Run locally exactly like CI does: ci/lint.sh
#   - every script with a "#!/bin/sh" shebang must pass `busybox sh -n`
#     (this is the shell that runs on the panel and in the Alpine build
#     containers -- no bash-only syntax allowed there)
#   - every script with a "#!/bin/bash" shebang must pass `bash -n`
#   - every *.py file must byte-compile
#   - the host installer drivers must support --help
# work/ (old per-session reports, not part of the shipped tree) is skipped.
# Run in docker as the calling user (-u "$(id -u):$(id -g)"), so any file this
# leaves behind is owned by that user, not root. `python3 -m py_compile`
# always writes a __pycache__/*.pyc next to each file regardless of
# PYTHONDONTWRITEBYTECODE, so those are removed again at the end.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# Classify by the file's actual first line (not a content grep: some scripts
# embed a "#!/bin/sh" heredoc for a script they generate, which is not their
# own shebang).
sh_files=() bash_files=()
while IFS= read -r -d '' f; do
	case "$(head -c 4096 "$f" 2>/dev/null | tr -d '\0' | head -n1)" in
	'#!/bin/sh') sh_files+=("$f");;
	'#!/bin/bash') bash_files+=("$f");;
	esac
done < <(find . -type f -not -path './work/*' -not -path './.git/*' -print0)

echo "== busybox sh -n (${#sh_files[@]} scripts) =="
for f in "${sh_files[@]}"; do
	busybox sh -n "$f" || { echo "FAIL: busybox sh -n $f"; fail=1; }
done

echo "== bash -n (${#bash_files[@]} scripts) =="
for f in "${bash_files[@]}"; do
	bash -n "$f" || { echo "FAIL: bash -n $f"; fail=1; }
done

echo "== python3 -m py_compile =="
while IFS= read -r f; do
	python3 -m py_compile "$f" || { echo "FAIL: py_compile $f"; fail=1; }
done < <(find . -name '*.py' -not -path './work/*' -not -path './.git/*')
find . -name __pycache__ -not -path './work/*' -not -path './.git/*' -exec rm -rf {} + 2>/dev/null

echo "== installer driver --help =="
for f in installer/steps/legacy/tsx-android-to-card installer/tsx-restore-factory \
         installer/tsx-install-mainline installer/steps/legacy/tsx-card-to-emmc \
         installer/steps/tsx-ensure-root \
         installer/payload/mkpayload installer/emmc/tsx-usb-recovery \
         installer/emmc/tsx-update-boot installer/steps/tsx-deploy-tfa.sh; do
	"$f" --help >/dev/null 2>&1 || { echo "FAIL: $f --help"; fail=1; }
done

echo "== docs: relative links + anchors resolve =="
python3 ci/check-doc-links.py || { echo "FAIL: doc links"; fail=1; }

echo "== on-panel tools shipped by the rootfs overlay =="
# one source file, copied into the image by rootfs/mkrootfs.sh (cp -a overlay)
[ -x rootfs/overlay/usr/local/sbin/tsx-update-boot ] || { echo "FAIL: rootfs/overlay/usr/local/sbin/tsx-update-boot missing or not executable"; fail=1; }
[ "$(readlink -f installer/emmc/tsx-update-boot)" = "$(readlink -f rootfs/overlay/usr/local/sbin/tsx-update-boot)" ] \
	|| { echo "FAIL: installer/emmc/tsx-update-boot is not a link to the rootfs overlay copy"; fail=1; }
# OpenRC refuses a service script without the x bit (rc-update add fails
# and mkrootfs.sh stops with "MISSING service")
for f in rootfs/overlay/etc/init.d/*; do
	[ -x "$f" ] || { echo "FAIL: $f is not executable"; fail=1; }
done

[ $fail -eq 0 ] && echo "lint OK" || echo "lint FAILED"
exit $fail
