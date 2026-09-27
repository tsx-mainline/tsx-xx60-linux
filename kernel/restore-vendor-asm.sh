#!/bin/bash
# The android-crestron/kernel GPL drop has no .S files at all (the repo's .gitignore
# has "*.s", apparently committed on a case-insensitive file system). Make a build
# copy of the vendor tree and restore them:
#   - files that exist in linux-stable v3.10.33 (same base version) from there,
#   - Amlogic-only files (mach-meson*, drivers/amlogic, ...) from endlessm/linux-meson
#     (Amlogic 3.10.101 tree with the same mach-meson6/8/8b/g9 layout).
# Output: srcfix/vendor-kernel, and srcfix/restored-asm.txt listing every file and its source.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
V=$HERE/../../../android-crestron/kernel
S=$HERE/srcfix
[ -d $S/linux-3.10.33 ] || git clone -q --depth 1 -b v3.10.33 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git $S/linux-3.10.33
[ -d $S/endless-meson ] || git clone -q --depth 1 https://github.com/endlessm/linux-meson $S/endless-meson
rsync -a --delete --exclude .git "$V/" $S/vendor-kernel/
: > $S/restored-asm.txt
(cd $S/linux-3.10.33 && find . -name '*.S' -o -name '*.s' | grep -v '^./Documentation') | while read f; do
  [ -d "$S/vendor-kernel/$(dirname $f)" ] && [ ! -e "$S/vendor-kernel/$f" ] || continue
  cp $S/linux-3.10.33/$f $S/vendor-kernel/$f; echo "stable-3.10.33 $f" >> $S/restored-asm.txt
done
(cd $S/endless-meson && find . -name '*.S' -o -name '*.s' | grep -v '^./Documentation') | while read f; do
  [ -d "$S/vendor-kernel/$(dirname $f)" ] && [ ! -e "$S/vendor-kernel/$f" ] || continue
  cp $S/endless-meson/$f $S/vendor-kernel/$f; echo "endless-3.10.101 $f" >> $S/restored-asm.txt
done
awk '{print $1}' $S/restored-asm.txt | sort | uniq -c

# Same cause: of two paths that differ only in case (xt_CONNMARK.h / xt_connmark.h),
# only one survived. Restore the missing twin from v3.10.33.
(cd $S/vendor-kernel && find . -type f | tr 'A-Z' 'a-z' | sort) > $S/.vendor-lc
(cd $S/linux-3.10.33 && find . -type f -not -path './.git/*') | while read f; do
  [ -e "$S/vendor-kernel/$f" ] && continue
  lc=$(echo "$f" | tr 'A-Z' 'a-z')
  grep -qxF "$lc" $S/.vendor-lc || continue
  cp $S/linux-3.10.33/$f $S/vendor-kernel/$f; echo "stable-3.10.33-casetwin $f" >> $S/restored-asm.txt
done
rm -f $S/.vendor-lc
grep -c casetwin $S/restored-asm.txt || true
