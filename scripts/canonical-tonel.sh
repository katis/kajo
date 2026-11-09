#!/bin/zsh
# Module 9c: write kernel/ and tools/ out of a development image built from
# them, in the canonical form the image writes (8e's rule: the tool's output
# is the canonical form), and copy back what differs. Run after editing
# Tonel files by hand; the round-trip tests then hold.
#
#   scripts/canonical-tonel.sh [--check]
#
# --check only lists the files that are not in the canonical form.
#
# Tags as subdirectories (docs/modules/tags-as-subdirectories.md): a class
# with a tag is written into <package dir>/<Tag>/, so the comparison walks
# one level of subdirectories both ways: a written file that differs or is
# missing is listed (and copied), and a checked-in .st file the image did
# not write (a class whose tag changed leaves its old file behind) is
# listed as stale (and removed, with its directory when that empties).
set -uo pipefail
root=${0:A:h:h}
cd $root
work=$(mktemp -d)
sock=${TMPDIR:-/tmp}/kajo-canon-$$.sock
trap 'pkill -f "kajo run $work/dev.img" 2>/dev/null; rm -rf $work; rm -f $sock' EXIT
swift build --product kajo > /dev/null || exit 1
kajo=$(swift build --show-bin-path)/kajo
$kajo build-image -o $work/dev.img --with tools > /dev/null || exit 1
mkdir -p $work/out/kernel $work/out/tools
gtimeout 120 $kajo run $work/dev.img --protocol $sock --sources $work/out > $work/target.out 2>&1 &
for i in {1..100}; do grep -q token $work/target.out 2> /dev/null && break; sleep 0.1; done
token=$(awk '/token/ {print $3}' $work/target.out)
KAJO_TOKEN=$token gtimeout 60 $kajo eval --target $sock \
  "(Smalltalk writePackage: 'Kernel' into: 'kernel') size + (Smalltalk writePackage: 'Tools' into: 'tools') size" > /dev/null || exit 1
changed=0
for d in kernel tools; do
  for f in $work/out/$d/*.st(N) $work/out/$d/*/*.st(N); do
    rel=${f#$work/out/}
    if ! cmp -s $f $rel; then
      print "$rel"
      changed=1
      if [[ ${1:-} != --check ]]; then
        mkdir -p ${rel:h}
        cp $f $rel
      fi
    fi
  done
  for f in $d/*.st(N) $d/*/*.st(N) $d/*/*/*.st(N); do
    if [[ ! -e $work/out/$f ]]; then
      print "stale: $f"
      changed=1
      if [[ ${1:-} != --check ]]; then
        rm $f
        [[ ${f:h} != $d ]] && rmdir ${f:h} 2> /dev/null
      fi
    fi
  done
done
exit $changed
