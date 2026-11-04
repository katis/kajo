#!/bin/zsh
# Module 9c: write kernel/ and tools/ out of a development image built from
# them, in the canonical form the image writes (8e's rule: the tool's output
# is the canonical form), and copy back what differs. Run after editing
# Tonel files by hand; the round-trip tests then hold.
#
#   scripts/canonical-tonel.sh [--check]
#
# --check only lists the files that are not in the canonical form.
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
  for f in $work/out/$d/*.st; do
    if ! cmp -s $f $d/${f:t}; then
      print "$d/${f:t}"
      changed=1
      [[ ${1:-} == --check ]] || cp $f $d/${f:t}
    fi
  done
done
exit $changed
