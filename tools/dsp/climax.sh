#!/bin/sh
# Run the vendor climax_hostsw under qemu-arm user mode.
# Old bionic keeps the owner tid in 16 bits of its recursive mutexes: host tids
# > 65535 deadlock the linker, so run inside a fresh PID namespace (unshare -Urp).
# Use only with "-d dummy90" (NXP's built-in TFA9890 simulator), never with a real bus.
P=$(cd "$(dirname "$0")/.." && pwd)
exec unshare -Urp --fork qemu-arm -L "$P/vendor-bin" "$P/vendor-bin/system/bin/climax_hostsw" "$@"
