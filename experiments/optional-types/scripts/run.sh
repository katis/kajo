#!/bin/zsh
# Build the experiment's image and run its measurements; the raw outputs land in
# $OUT (default ~/kajo-scratch/optional-types/results), work files in $WORK.
#   run.sh test                    the checker's own SUnit tests
#   run.sh <command> [option]      one OTMeasure measurement (slice, matrix, image,
#                                  live, proposals, completion, scripting; image takes
#                                  a switch name such as memberwiseNil)
#   run.sh all                     every measurement, in the order RESULTS.md quotes
set -e
REPO=${0:A:h:h:h:h}
WORK=${WORK:-$HOME/kajo-scratch/optional-types}
OUT=${OUT:-$WORK/results}
KAJO=$REPO/.build/release/kajo
mkdir -p $WORK $OUT
(cd $REPO && swift build -c release --product kajo >/dev/null)
$KAJO build-image -o $WORK/ot.img --with $REPO/tools --with $REPO/experiments/optional-types/OptionalTypes
one() {
  local R=$WORK/run
  rm -rf $R; mkdir -p $R/out $R/annotations
  cp $REPO/experiments/optional-types/annotations/*.types $R/annotations/
  print -r -- "$*" > $R/command
  gtimeout 1800 $KAJO run $WORK/ot.img --sources $R --heap 2048 | tail -1 | cut -c1-120
  [[ -f $R/out/error.txt ]] && { cat $R/out/error.txt; return 1 }
  cp $R/out/* $OUT/
}
case $1 in
  test) gtimeout 600 $KAJO test $WORK/ot.img --filter OT | tail -1 ;;
  all)
    one image memberwiseNil; mv $OUT/image.txt $OUT/image-memberwise.txt; mv $OUT/image-diagnostics.txt $OUT/image-memberwise-diagnostics.txt
    for c in slice matrix image live proposals completion scripting footprint; do one $c; done
    python3 $REPO/experiments/optional-types/scripts/syntax-scan.py $REPO > $OUT/syntax-scan.txt
    python3 $REPO/experiments/optional-types/scripts/features.py $REPO/experiments/optional-types/annotations > $OUT/features.txt ;;
  *) one "$@" ;;
esac
