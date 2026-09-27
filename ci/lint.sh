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

echo "== installer driver --help =="
for f in installer/steps/tsx-android-to-card installer/tsx-restore-factory \
         installer/tsx-install-mainline installer/steps/tsx-card-to-emmc \
         installer/payload/mkpayload installer/emmc/tsx-usb-recovery \
         installer/emmc/tsx-update-boot installer/steps/tsx-deploy-tfa.sh; do
	"$f" --help >/dev/null 2>&1 || { echo "FAIL: $f --help"; fail=1; }
done

[ $fail -eq 0 ] && echo "lint OK" || echo "lint FAILED"
exit $fail
