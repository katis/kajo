#!/bin/zsh
# The tier decision's test (docs/modules/gate-tiers.md): each case is a list
# of paths, the tier and the fuzzers check-tier.sh must decide for it, read
# from its --dry-run. Exit 1 on any disagreement.
#
#   scripts/check-tier-test.sh
set -uo pipefail
root=${0:A:h:h}
fail=0 n=0
# expect <tier> <fuzzers or -> <path>...
expect() {
  local want=$1 wantf=$2; shift 2
  local out=$(print -l -- "$@" | $root/scripts/check-tier.sh --dry-run --paths -)
  local got=$(print -r -- "$out" | sed -n 's/^tier: //p')
  local gotf=$(print -r -- "$out" | sed -n 's/^fuzzers: //p')
  [[ $want == swift ]] || gotf=${gotf:--}
  [[ $wantf == - && $want == swift ]] && wantf=none
  n=$((n + 1))
  if [[ $got != $want || $gotf != $wantf ]]; then
    print "FAIL: $* -> tier $got fuzzers '$gotf', want $want '$wantf'"; fail=1
  fi
}
expect none - docs/modules/gate-tiers.md
expect none - AGENTS.md experiments/large-bytes/RESULTS.md docs/adr/0001-swift.md
expect smalltalk - kernel/Object.class.st
expect smalltalk - tools/DevClient.class.st docs/x.md
expect smalltalk - apps/Shared/smalltalk/demo.st
expect swift - scripts/check-tier.sh scripts/gates-lib.sh justfile
expect swift - Sources/KajoVM/Shell/ShellVM.swift
expect swift - Sources/KajoVM/Headless.swift
expect swift - Sources/KajoApp/AppKitHost.swift kernel/Object.class.st
expect swift - apps/KajoShell-macOS/project.yml
expect swift - Package.swift
expect swift protocol Sources/KajoDev/ProtocolServer.swift
expect swift protocol Tests/KajoVMTests/Fixtures/fuzz/protocol/seed1
expect swift syntax Sources/KajoCompiler/Compiler.swift
expect swift kasm Sources/fuzz-kasm/FuzzKasm.swift
expect swift snapshot Sources/fuzz-snapshot/FuzzSnapshot.swift
expect swift "protocol syntax" Sources/KajoDev/Client.swift Sources/KajoCompiler/Parser.swift
expect swift "kasm snapshot syntax protocol" scripts/fuzz.sh
# The review fixes, part 2, item 10 (tools.F4): a Markdown fixture under
# Tests/ is Swift's, not docs.
expect swift - Tests/KajoCompilerTests/Fixtures/perf/README.golden.md
expect swift - Tests/KajoCompilerTests/Fixtures/app-project/Sample/README.md
expect swift - Tests/KajoCompilerTests/Fixtures/perf/README.in.md docs/x.md
# A rename is judged by both of its paths: a scratch repository whose one
# commit moves a file out of the core, committed and then in the working
# tree (plain mv and add, never git mv in this checkout's tree).
scratch=$(mktemp -d ${TMPDIR:-/tmp}/kajo-tier-XXXXXX)
renamed() {
  (cd $scratch && git init -q && git config user.email t@t && git config user.name t \
    && mkdir -p Sources/KajoVM/Marking Sources/KajoVM/Shell && print 'let x = 1' > Sources/KajoVM/Marking/X.swift \
    && git add . && git commit -qm base && mv Sources/KajoVM/Marking/X.swift Sources/KajoVM/Shell/X.swift \
    && git add -A . && { [[ $1 == staged ]] || git commit -qm move })
  KAJO_CHECK_REPO=$scratch $root/scripts/check-tier.sh --dry-run HEAD~${2} | sed -n 's/^tier: //p'
}
for how in committed staged; do
  rm -rf $scratch/*(N) $scratch/.git(N)
  [[ $how == committed ]] && got=$(renamed committed 1) || got=$(renamed staged 0)
  n=$((n + 1))
  [[ $got == core ]] || { print "FAIL: a $how rename out of the core -> tier '$got', want core"; fail=1 }
done
rm -rf $scratch
expect core - Sources/KajoVM/Interpreter/Interpreter.swift
expect core - Sources/KajoVM/Native/NativeInterface.swift
expect core - Sources/KajoAOT/Generator.swift docs/modules/aot.md
expect core - Sources/KajoVM/Loader/Image.swift Sources/KajoDev/Client.swift kernel/Object.class.st
for d in ObjectMemory Interpreter Loader Workers Processes Nursery Marking Relocation YoungCollection ObjectModel; do
  expect core - Sources/KajoVM/$d/X.swift
done
# The tier's gates, as the doc lists them.
gates() { print -l -- "$@" | $root/scripts/check-tier.sh --dry-run --paths - | sed -n 's/^  \([a-z0-9-]*\): .*/\1/p' | tr '\n' ' ' }
check_gates() {
  local want=$1; shift
  local got=$(gates "$@")
  n=$((n + 1))
  [[ ${got% } == $want ]] || { print "FAIL: gates for $* are '$got', want '$want'"; fail=1 }
}
check_gates "build-image dev-image kernel-test tools-test compiler-tests golden mac-shell-tests" kernel/Object.class.st
# Gate speed (docs/modules/gate-speed.md): a gate script owes
# check-tier-test first (change 8), the fuzzers are one gate (change 2),
# plain swift-test is out of the core tier (change 7).
check_gates "check-tier-test clean-build swift-test tsan kernel-test apps new-check" scripts/gates-lib.sh
check_gates "clean-build swift-test tsan kernel-test apps new-check" Package.swift
check_gates "clean-build swift-test tsan kernel-test apps new-check fuzz" Sources/KajoDev/Client.swift
check_gates "check-tier-test clean-build swift-test tsan kernel-test apps new-check fuzz" scripts/fuzz.sh
check_gates "clean-build swift-test tsan kernel-test apps new-check model-check" models/Package.swift
core="clean-build swift-test-load tsan tsan-load ios-check arc-check golden native-golden native-kernel-test native-cc test-release model-check soak fuzz apps kernel-test new-check ab matrix-mac matrix-iphone"
check_gates "$core" Sources/KajoVM/Marking/Marker.swift
check_gates "check-tier-test $core" Sources/KajoVM/Marking/Marker.swift scripts/weekly.sh
for f in check-tier.sh check-tier-test.sh gates-lib.sh weekly.sh fuzz.sh fuzz-gate.sh; do
  n=$((n + 1)); [[ $(gates scripts/$f) == check-tier-test* ]] || { print "FAIL: scripts/$f does not owe check-tier-test"; fail=1 }
done
n=$((n + 1)); [[ $(gates scripts/device.sh) != *check-tier-test* ]] || { print "FAIL: scripts/device.sh owes check-tier-test"; fail=1 }
# The fuzz gate's targets are the fuzzers owed.
n=$((n + 1))
[[ $(print -l Sources/KajoDev/X.swift Sources/KajoCompiler/Y.swift | $root/scripts/check-tier.sh --dry-run --paths - | grep '^  fuzz: ') == *" protocol syntax (check: fuzz)"* ]] \
  || { print "FAIL: the Swift tier's fuzz gate does not run the owed targets"; fail=1 }
n=$((n + 1))
[[ $(print Sources/KajoVM/Marking/X.swift | $root/scripts/check-tier.sh --dry-run --paths - | grep '^  fuzz: ') == *" kasm snapshot syntax protocol (check: fuzz)"* ]] \
  || { print "FAIL: the core tier's fuzz gate does not run the four targets"; fail=1 }
# Change 4: test-release leaves the random programs to soak, so every gate
# list that holds test-release holds soak after it: each tier's, the
# weekly's.
weekly=$($root/scripts/weekly.sh --gates)
lists=("$(gates kernel/Object.class.st)" "$(gates scripts/gates-lib.sh models/x)" "$(gates Sources/KajoVM/Marking/X.swift)" "$weekly")
for l in $lists; do
  local -a g=(${=l})
  n=$((n + 1))
  if (( ${g[(Ie)test-release]} )) && ! (( ${g[(Ie)soak]} > ${g[(Ie)test-release]} )); then
    print "FAIL: a gate list holds test-release without soak after it: $l"; fail=1
  fi
done
n=$((n + 1)); [[ " $(gates Sources/KajoVM/Marking/X.swift) " == *" test-release "*" soak "* ]] || { print "FAIL: the core tier lost test-release or soak"; fail=1 }
n=$((n + 1)); grep -q -- '--skip randomPrograms' $root/justfile && grep -q -- '--filter randomPrograms' $root/justfile \
  || { print "FAIL: test-release and soak no longer split the random programs between them"; fail=1 }
# Change 6: the weekly is the full set: every core gate (with every
# conditional one), the device rows as `devices`, and plain swift-test.
coreall=$(gates Sources/KajoVM/Marking/X.swift scripts/gates-lib.sh models/x)
for g in ${=coreall} swift-test; do
  [[ $g == matrix-iphone ]] && g=devices
  n=$((n + 1))
  [[ " $weekly " == *" $g "* ]] || { print "FAIL: the weekly run lacks $g"; fail=1 }
done
# The weekly's A/B base: the last finished non-quick run's commit, nothing
# when there is none or it is HEAD.
abase() { zsh -c 'GL_ROOT=$1; source $1/scripts/gates-lib.sh; gl_weekly_ab_base $2 HEAD' ab $root $1 }
wl=$(mktemp ${TMPDIR:-/tmp}/kajo-weekly-log-XXXXXX)
h1=$(git -C $root rev-parse --short HEAD~1) h0=$(git -C $root rev-parse --short HEAD)
print -l "2026-11-01 02:00:00 weekly start /w/a commit $h1 quick=0 devices=1" "2026-11-01 05:00:00 weekly done /w/a failed=0" > $wl
n=$((n + 1)); [[ $(abase $wl) == $h1 ]] || { print "FAIL: the weekly A/B base is '$(abase $wl)', want $h1"; fail=1 }
print -l "2026-11-02 02:00:00 weekly start /w/b commit $h0 quick=0 devices=1" "2026-11-02 05:00:00 weekly done /w/b failed=1 (x)" >> $wl
n=$((n + 1)); [[ -z $(abase $wl) ]] || { print "FAIL: a weekly A/B base that is HEAD is not skipped"; fail=1 }
print -l "2026-11-01 02:00:00 weekly start /w/a commit $h1 quick=0 devices=1" "2026-11-01 05:00:00 weekly done /w/a failed=0" \
  "2026-11-03 02:00:00 weekly start /w/c-quick commit $h0 quick=1 devices=0" "2026-11-03 03:00:00 weekly done /w/c-quick failed=0" \
  "2026-11-04 02:00:00 weekly start /w/d commit $h0 quick=0 devices=1" > $wl
n=$((n + 1)); [[ $(abase $wl) == $h1 ]] || { print "FAIL: a quick or unfinished weekly run was taken for the A/B base: '$(abase $wl)'"; fail=1 }
: > $wl
n=$((n + 1)); [[ -z $(abase $wl) ]] || { print "FAIL: an empty weekly.log gave an A/B base"; fail=1 }
rm -f $wl
# The weekly refuses beside a running suite: under swiftly `swift test` is
# swift-package and swiftpm-testing-helper, which the refusal named only as
# swift-build and swift-test (found in gate speed). A program named
# swift-package that sleeps, in a process group of its own, stands in (a
# copy of /bin/sleep is killed for its signature, a link keeps the name
# sleep). Apple's /usr/bin/clang finds the SDK by itself; swiftly's clang
# found unistd.h only when the caller's environment named the SDK.
fake=$(mktemp -d ${TMPDIR:-/tmp}/kajo-refuse-XXXXXX)
print '#include <unistd.h>\nint main(void) { sleep(60); return 0; }' | /usr/bin/clang -x c - -o $fake/swift-package
python3 -I -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' $fake/swift-package &
fp=$!
for i in {1..50}; do ps -o ucomm= -p $fp 2>/dev/null | grep -q swift-package && break; sleep 0.1; done
KAJO_WEEKLY_ROOT=$fake/w KAJO_WEEKLY_QUICK=1 KAJO_WEEKLY_DEVICES=0 KAJO_WEEKLY_ONLY=nothing gtimeout 60 $root/scripts/weekly.sh > /dev/null 2>&1
n=$((n + 1)); grep -q "weekly refused: Kajo is running:.* swift-package($fp)" $fake/w/weekly.log 2>/dev/null \
  || { print "FAIL: the weekly started beside a swift-package: $(cat $fake/w/weekly.log 2>/dev/null)"; fail=1 }
kill -TERM $fp 2>/dev/null; wait $fp 2>/dev/null
rm -rf $fake
# Change 2: the fuzz gate with stand-ins for scripts/fuzz.sh. Each target's
# behaviour is STANDIN_<target>: ok, fail (the run exits 1), fallback (no
# "libFuzzer build: ok" line), sleep (runs until killed, its pid in a file).
fz=$(mktemp -d ${TMPDIR:-/tmp}/kajo-fuzzgate-XXXXXX)
cat > $fz/fuzz.sh <<'STANDIN'
#!/bin/zsh
mode=$1 t=$2
b=${(P)${:-STANDIN_$t}:-ok}
if [[ $mode == --build ]]; then
  [[ $b == fallback ]] && { print "libFuzzer build failed: stand-in"; exit 0 }
  print "libFuzzer build: ok (stand-in)"; exit 0
fi
case $b in
  fail) print "stand-in $t fails"; exit 1 ;;
  sleep) print $$ > $STANDIN_PIDS/$t; exec sleep 300 ;;
  *) print "stat::number_of_executed_units: 12345"; exit 0 ;;
esac
STANDIN
chmod +x $fz/fuzz.sh
fuzzgate() {
  rm -rf $fz/out; mkdir -p $fz/out $fz/pids
  env "$@" KAJO_FUZZ_SH=$fz/fuzz.sh STANDIN_PIDS=$fz/pids zsh -c 'print $$ > $2/gate.pid; GL_ROOT=$1 GL_OUT=$2/out GL_FUZZ_SECS=1; source $1/scripts/gates-lib.sh; gl_init
    trap "gl_cleanup; exit 130" INT TERM; trap gl_cleanup EXIT; gl_gate fuzz' fg $root $fz
}
# killed <what> <pid file>: every stand-in started, none alive after a TERM
# to the process in the file (bounded waits).
killed() {
  for i in {1..300}; do [[ $(ls $fz/pids 2>/dev/null | wc -l | tr -d ' ') == 4 ]] && break; sleep 0.1; done
  kill -TERM $(<$2) 2>/dev/null
  for i in {1..100}; do kill -0 $(<$2) 2>/dev/null || break; sleep 0.1; done
  sleep 1
  local alive=() p started=$(ls $fz/pids | wc -l | tr -d ' ')
  for p in $fz/pids/*(N); do kill -0 $(<$p) 2>/dev/null && alive+=($(<$p)); done
  n=$((n + 1)); [[ $started == 4 && ${#alive} == 0 ]] \
    || { print "FAIL: $1: $started stand-ins started, alive after: ${alive:-none}"; fail=1 }
  for p in $alive; do kill -KILL $p 2>/dev/null; done
}
fuzzgate > /dev/null 2>&1; rc=$?
n=$((n + 1)); [[ $rc == 0 && $(grep -c ' end fuzz-[a-z]* rc=0 [0-9]*s runs=12345 build=ok$' $fz/out/gates.log) == 4 ]] \
  || { print "FAIL: the fuzz gate over four good stand-ins: rc=$rc, $(grep -c ' end fuzz-' $fz/out/gates.log) target lines"; fail=1 }
fuzzgate STANDIN_syntax=fail > /dev/null 2>&1; rc=$?
n=$((n + 1)); [[ $rc != 0 ]] && grep -q ' end fuzz-syntax rc=1 ' $fz/out/gates.log && grep -q ' end fuzz-kasm rc=0 ' $fz/out/gates.log \
  || { print "FAIL: the fuzz gate with one failing target: rc=$rc"; fail=1 }
fuzzgate STANDIN_protocol=fallback > /dev/null 2>&1; rc=$?
n=$((n + 1)); [[ $rc != 0 ]] && grep -q ' end fuzz-protocol rc=0 [0-9]*s runs=12345 build=fallback$' $fz/out/gates.log \
  || { print "FAIL: the fuzz gate counted a target without its 'libFuzzer build: ok' line: rc=$rc"; fail=1 }
# A killed gate leaves no fuzzer running: the runner's traps (gl_cleanup,
# as check-tier.sh and weekly.sh install them), and a TERM to the gate's
# script alone (what the gate's gtimeout sends at its bound).
sleepers=(STANDIN_kasm=sleep STANDIN_snapshot=sleep STANDIN_syntax=sleep STANDIN_protocol=sleep)
fuzzgate $sleepers > /dev/null 2>&1 &
killed "a fuzz gate killed through gl_cleanup" $fz/gate.pid
wait
rm -rf $fz/pids/*(N) $fz/out; mkdir -p $fz/out
( env $sleepers KAJO_FUZZ_SH=$fz/fuzz.sh STANDIN_PIDS=$fz/pids $root/scripts/fuzz-gate.sh 1 $fz/out kasm snapshot syntax protocol > /dev/null 2>&1 & print $! > $fz/script.pid; wait )  &
killed "the fuzz gate's script killed alone" $fz/script.pid
wait
rm -rf $fz
# The review fixes, part 2, item 11 (tools.F5): shell-report.py --bar over a
# directory with rows passes and over one with none fails, and the Mac
# matrix gate's command fails when its matrix step fails (the scripts stood
# in for by GL_MAC_SHELL and GL_SHELL_MATRIX).
bars=$(mktemp -d ${TMPDIR:-/tmp}/kajo-bar-XXXXXX)
mkdir -p $bars/rows $bars/none
print 'mode=golden kind=st kernel=fib workers=1 run=1 ok=1 checksum=5' > $bars/rows/golden.txt
$root/scripts/shell-report.py --bar $bars/rows > /dev/null; rc=$?
n=$((n + 1)); [[ $rc == 0 ]] || { print "FAIL: --bar over rows: rc=$rc"; fail=1 }
$root/scripts/shell-report.py --bar $bars/none > /dev/null; rc=$?
n=$((n + 1)); [[ $rc == 1 ]] || { print "FAIL: --bar over no rows: rc=$rc"; fail=1 }
rc=$( GL_ROOT=$root GL_OUT=$bars/gate GL_MAC_SHELL=true GL_SHELL_MATRIX=false zsh -c 'source $GL_ROOT/scripts/gates-lib.sh; gl_spec matrix-mac; cd $GL_ROOT; zsh -c "$spec_cmd" > /dev/null 2>&1; print $?' )
n=$((n + 1)); [[ $rc != 0 ]] || { print "FAIL: the matrix gate passed with its matrix step failing"; fail=1 }
rm -rf $bars
# docs only: exit 0 at once, saying so.
out=$(print docs/x.md | $root/scripts/check-tier.sh --paths -); rc=$?
n=$((n + 1))
[[ $rc == 0 && $out == *"nothing owed"* ]] || { print "FAIL: docs only: rc=$rc"; fail=1 }
print "check-tier-test: $n checks, $([[ $fail == 0 ]] && print ok || print FAILED)"
exit $fail
