#!/bin/bash
# Run the tests of this folder one by one and print a summary. The tests run
# the shared panel software of tsx-linux-common with the xx60 board files of
# this repository.
#   rootfs/tests/common/run.sh
# TSX_COMMON names the top of the tsx-linux-common checkout. The default is the
# folder tsx-linux-common next to this repository (see lib.sh).
# TSX_TEST_LOGDIR names the folder for the logs. The default is a temporary
# folder that the script removes at the end.
# The lists are explicit. A new test goes into the list.
set -u
cd "$(dirname "$0")"
TESTS="mqtt-dry test-board-xx60 test-brightness-xx60 test-bt-csr8811 test-buttons-xx60 test-ledbar-xx60 test-panel-board test-rescue-backlight test-rescue-screen test-tsx-config-apply test-tsx-setup-mac"
if [ -n "${TSX_TEST_LOGDIR:-}" ]; then LOG=$TSX_TEST_LOGDIR; else LOG=$(mktemp -d); trap 'rm -rf "$LOG"' EXIT; fi
pass=0 failed=
for t in $TESTS; do
	echo "=== $t"
	if bash "./$t.sh" > "$LOG/xx60-common-$t.log" 2>&1; then
		pass=$((pass + 1)); tail -n 1 "$LOG/xx60-common-$t.log"
	else
		failed="$failed $t"; tail -n 15 "$LOG/xx60-common-$t.log"
	fi
done
echo "== $pass passed, failed:${failed:- none}"
[ -z "$failed" ]
