#!/bin/bash
# Host test for the slider scale (src/tsx-level.h). It compiles C, so run
# it only on a build host or in CI. The compile line has no -lm on purpose:
# the panel build lines of tsx-idled and tsx-overlay need no libm for the header.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf $T' EXIT
gcc -O2 -Wall -Werror -o $T/level-check $HERE/level-check.c
$T/level-check
echo "PASS tsx-level"
