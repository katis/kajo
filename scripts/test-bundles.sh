#!/bin/zsh
# Check time (docs/modules/check-time.md, part 2): `swift test` as shards
# side by side instead of the two bundles one after the other. It builds
# once, then runs each shard in a `swift test --skip-build` of its own (the
# build directory's lock ignored: no shard builds), each into a file of its
# own, and prints the outputs one after the other when all have ended, so a
# gate's output reads as before (scripts/margins.py, the counts of tests).
# Exit status: the build's when it fails, else non-zero when any shard's is.
#
#   scripts/test-bundles.sh <out-prefix> [swift build/test options...]
#
# The shards cover every test once: the VM tests but the random programs;
# the random programs but the resumed ones; the resumed random programs
# (randomProgramsResume...); the compiler tests but the tools'; then, alone,
# the tools' tests (ToolsTests, PhoneTransportTests, ProjectDirectoryTests). A process's tests share one pool
# of as many threads as cores (Swift Testing), and in a plain build the VM
# bundle waited on that pool, not on the cores (part 1: 655 s quiet, 705 to 725 s
# under twelve busy loops); each shard has a pool of its own.
#
# e.g. scripts/test-bundles.sh .build/check/x/bundles/tsan-load --sanitize=thread --scratch-path .build/tsan-check
# KAJO_SWIFT names the swift it runs (scripts/check-tier-test.sh gives a
# stand-in).
set -uo pipefail
root=${0:A:h:h}
(( $# >= 1 )) || { print "test-bundles: <out-prefix> [options...]"; exit 2 }
prefix=${1:a}; shift
mkdir -p ${prefix:h}
cd $root
# name and the selection, as swift test arguments. The first four run side
# by side; the tools' tests then run alone (the second phase): with the VM
# tests beside them, the remote target's frames reply in the reconnect test
# ran past the tools' 30 s request timeout under the loaded sanitizer, 2 runs
# of 2 (docs/modules/check-time.md, part 3, item 6).
tools='ToolsTests|PhoneTransportTests|ProjectDirectoryTests'
shards=("vm:--filter KajoVMTests --skip randomPrograms" "random:--filter randomPrograms --skip randomProgramsResume"
        "resume:--filter randomProgramsResume" "compiler:--filter KajoCompilerTests --skip $tools")
later=("tools:--filter $tools")
t0=$(date +%s)
${=KAJO_SWIFT:-swift} build --build-tests "$@"
rc=$?
print "test-bundles: build rc=$rc $(( $(date +%s) - t0 ))s"
(( rc == 0 )) || exit $rc
names=() rcs=()
# phase <shard>...: the shards side by side, their statuses into rcs. A TERM
# to this script (a gate's gtimeout) goes to every shard running.
phase() {
  local s p pids=()
  for s in "$@"; do
    names+=(${s%%:*})
    ${=KAJO_SWIFT:-swift} test --skip-build --ignore-lock "${(@)opts}" ${=s#*:} > $prefix.${s%%:*}.txt 2>&1 &
    pids+=($!)
  done
  trap 'kill -TERM $pids 2>/dev/null' INT TERM
  for p in $pids; do wait $p; rcs+=($?); done
  trap - INT TERM
  print "test-bundles: phase of ${#pids} ended $(( $(date +%s) - t0 ))s"
}
opts=("$@")
phase $shards
phase $later
fail=0
for i in {1..${#names}}; do
  print "test-bundles: shard ${names[$i]} rc=${rcs[$i]}"
  cat $prefix.${names[$i]}.txt
  (( rcs[$i] )) && fail=1
done
print "test-bundles: done rc=$fail $(( $(date +%s) - t0 ))s"
exit $fail
