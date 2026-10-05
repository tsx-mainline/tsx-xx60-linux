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
TESTS="mqtt-dry test-board-xx60 test-brightness-xx60 test-bt-csr8811 test-buttons-xx60 test-camera test-ledbar-xx60 test-panel-board test-rescue-backlight test-rescue-screen test-tsx-config-apply test-tsx-setup-mac"
CLEAN=
trap '[ -z "$CLEAN" ] || rm -rf $CLEAN' EXIT
if [ -n "${TSX_TEST_LOGDIR:-}" ]; then LOG=$TSX_TEST_LOGDIR; else LOG=$(mktemp -d); CLEAN="$CLEAN $LOG"; fi
# The panel scripts run under busybox ash. The sh of Debian and Ubuntu is dash.
# It has no read -t and other parts that the scripts use. Put an sh that runs
# busybox sh at the front of PATH, so that every test runs the scripts as the
# panel does.
if command -v busybox >/dev/null 2>&1; then
	SHDIR=$(mktemp -d); CLEAN="$CLEAN $SHDIR"
	printf '#!/bin/sh\nexec busybox sh "$@"\n' > "$SHDIR/sh"
	chmod 755 "$SHDIR/sh"
	if "$SHDIR/sh" -c 'exit 0'; then
		PATH=$SHDIR:$PATH
		echo "sh for the tests: busybox sh ($SHDIR/sh)"
	else
		echo "sh for the tests: $(command -v sh) (the busybox sh wrapper does not run in $SHDIR)"
	fi
else
	echo "sh for the tests: $(command -v sh) (no busybox on this host)"
fi
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
