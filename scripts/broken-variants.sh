#!/bin/zsh
# The by-hand broken variants that need no source change (docs/modules/
# check-time.md, part 4; the owner's approval of 2026-11-23): each runs once,
# as its doc says to run it by hand, into <out>/broken-<name>.txt, and must
# end as its doc recorded: a variant expected to fail must exit non-zero
# with its recorded message in the output; a forcing condition the fix
# bears must pass. A variant that passes where it should fail is the
# failure. One line per variant, then a summary line; exit 1 when any
# variant did not end as recorded, 2 on a usage error.
#
#   scripts/broken-variants.sh <out> [<name>...]     run them (all by default)
#   scripts/broken-variants.sh --list                the variants, one a line
#   scripts/broken-variants.sh --judge <expect> <pattern> <rc> <file>
#                                                    judge one output (the test)
#
# The variants that need a patch to the source (most modules' "Broken
# variants run by hand") are not here: broken variants are never committed,
# so there is nothing for a runner to apply. The list of those, with the
# reason each is left by hand, is in docs/modules/check-time.md.
set -uo pipefail
root=${0:A:h:h}

# name|expect|pattern|environment|swift test filter|doc
# expect: fail (non-zero exit and the pattern in the output) or pass (exit 0
# and the pattern). Patterns are fixed strings (grep -F).
variants=(
  "delay-end|fail|exited with unexpected signal code 11|KAJO_BROKEN_DELAY_END=1|brokenVariantALateTimerTouchesTheFreedVM|docs/modules/delay-outlives-vm.md"
  "shell-close|fail|close left the VM undestroyed|KAJO_BROKEN_SHELL_CLOSE=1|aShellClosedWithADelay|docs/modules/shell-close.md"
  "closed-shell-runTurn|fail|Fatal error: ShellVM.runTurn after close|KAJO_CLOSED_SHELL_CALL=runTurn|aCallAfterCloseByHand|docs/modules/closed-shell-calls.md"
  "closed-shell-spawn|fail|Fatal error: ShellVM.spawn after close|KAJO_CLOSED_SHELL_CALL=spawn|aCallAfterCloseByHand|docs/modules/closed-shell-calls.md"
  "closed-shell-liveProcessCount|fail|Fatal error: ShellVM.liveProcessCount after close|KAJO_CLOSED_SHELL_CALL=liveProcessCount|aCallAfterCloseByHand|docs/modules/closed-shell-calls.md"
  "tools-hold-install|pass|theToolsDevelopTheImageTheyRunIn() passed|KAJO_TOOLS_HOLD_INSTALL=1500|theToolsDevelopTheImageTheyRunIn|docs/modules/tools-test-fault.md"
  "tools-hold-loop|pass|aClassDefinedIntoATagFromTheBrowserMovesWithItsTag() passed|KAJO_TOOLS_HOLD_LOOP=70000|aClassDefinedIntoATagFromTheBrowserMovesWithItsTag|docs/modules/weekly-1123-failures.md"
)

# judge <expect> <pattern> <rc> <file>: ok when the run ended as recorded.
judge() {
  local expect=$1 pattern=$2 rc=$3 file=$4 found=no
  grep -qF -- "$pattern" $file 2>/dev/null && found=yes
  if [[ $expect == fail ]]; then [[ $rc != 0 && $found == yes ]]
  else [[ $rc == 0 && $found == yes ]]; fi
}

case ${1:-} in
  --list) for v in $variants; do print -r -- ${v%%|*}; done; exit 0 ;;
  --judge) (( $# == 5 )) || { print "broken-variants: --judge <expect> <pattern> <rc> <file>"; exit 2 }
           judge $2 $3 $4 $5 && { print ok; exit 0 } || { print FAILED; exit 1 } ;;
  ''|-*) print "broken-variants: <out> [<name>...] | --list | --judge ..."; exit 2 ;;
esac
out=$1; shift
want=("$@")
mkdir -p $out
cd $root
failed=() n=0
for v in $variants; do
  local -a f=("${(@s:|:)v}")
  name=${f[1]} expect=${f[2]} pattern=${f[3]} envs=${f[4]} filter=${f[5]}
  (( ${#want} )) && ! (( ${want[(Ie)$name]} )) && continue
  n=$((n + 1))
  o=$out/broken-$name.txt
  t0=$(date +%s)
  # Each is one test process; a trap ends only it. Bounded like a test gate.
  env ${=envs} gtimeout -k 60 3600 swift test --filter "$filter" > $o 2>&1
  rc=$?
  if judge $expect "$pattern" $rc $o; then result=ok; else result=FAILED; failed+=($name); fi
  print -r -- "broken-variant: $name expect=$expect rc=$rc $(( $(date +%s) - t0 ))s $result"
done
print -r -- "broken-variants: $n run, ${#failed} not as recorded${failed:+ (${failed})}"
(( ${#failed} == 0 ))
