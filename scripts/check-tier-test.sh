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
expect smalltalk - types/Checker/TypeChecker.class.st kernel/Object.class.st
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
# Check time (docs/modules/check-time.md): one sanitizer gate a tier, the
# loaded one. Before: the Swift tier's was tsan, the core tier ran both.
check_gates "check-tier-test clean-build swift-test tsan-load kernel-test apps new-check" scripts/gates-lib.sh
check_gates "clean-build swift-test tsan-load kernel-test apps new-check" Package.swift
check_gates "clean-build swift-test tsan-load kernel-test apps new-check fuzz" Sources/KajoDev/Client.swift
check_gates "check-tier-test clean-build swift-test tsan-load kernel-test apps new-check fuzz" scripts/fuzz.sh
check_gates "clean-build swift-test tsan-load kernel-test apps new-check model-check" models/Package.swift
check_gates "clean-build swift-test tsan-load kernel-test apps new-check" Tests/KajoCompilerTests/TestSize.swift
core="clean-build swift-test-load tsan-load ios-check arc-check golden native-golden native-kernel-test native-cc test-release model-check soak fuzz apps kernel-test new-check ab matrix-mac matrix-iphone"
for l in "$(gates Package.swift)" "$(gates Sources/KajoVM/Marking/X.swift)"; do
  n=$((n + 1)); [[ " $l " != *" tsan "* && $(print -r -- " $l " | grep -o ' tsan-load ' | wc -l | tr -d ' ') == 1 ]] \
    || { print "FAIL: a tier does not run exactly one sanitizer gate, the loaded one: $l"; fail=1 }
done
check_gates "$core" Sources/KajoVM/Marking/Marker.swift
check_gates "check-tier-test $core" Sources/KajoVM/Marking/Marker.swift scripts/weekly.sh
for f in check-tier.sh check-tier-test.sh gates-lib.sh weekly.sh fuzz.sh fuzz-gate.sh shell-matrix.sh shell-report.py margins.py broken-variants.sh test-bundles.sh; do
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
# Check time: the weekly keeps both sanitizer gates (the tiers run the
# loaded one only) and runs the by-hand broken variants.
for g in ${=coreall} swift-test tsan broken-variants; do
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
# The weekly margins: a gate's start line ends with its bound (the fuzz
# gate's is GL_FUZZ_SECS plus 3600), and margins.py tabulates the gate's
# time against it (the target lines are not gates).
n=$((n + 1)); grep -q ' start fuzz (swift: .*) bound=3601s$' $fz/out/gates.log \
  || { print "FAIL: the fuzz gate's start line does not end with bound=3601s: $(grep ' start fuzz' $fz/out/gates.log)"; fail=1 }
mt=$($root/scripts/margins.py $fz/out)
n=$((n + 1)); [[ $(print -r -- $mt | grep -c '^| fuzz' ) == 1 && $(print -r -- $mt | grep '^| fuzz |') == "| fuzz | 0 | "<->" | 3601 | 0.00 |  |" ]] \
  || { print "FAIL: margins.py's gate table over the fuzz gate: $(print -r -- $mt | grep '^| fuzz')"; fail=1 }
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
# Gate reliability (docs/modules/gate-reliability.md): a process a gate
# started that outlives it is found by its tag, logged, sampled, killed by
# pid and counted (leftover=<n> on the end line), and it fails the gate. The
# stand-in's child leaves the gate's process group for a session of its own
# (as `swift test`'s helper leaves for a group of its own) and sleeps; once
# with the gate killed at its bound, once with a gate that exits 0 and leaves
# its child behind. A gate that leaves nothing says leftover=0.
lo=$(mktemp -d ${TMPDIR:-/tmp}/kajo-leftover-XXXXXX)
print -l 'import os, sys, time' 'os.setsid()' 'open(sys.argv[1], "w").write(str(os.getpid()))' 'time.sleep(300)' > $lo/child.py
leftgate() {
  rm -rf $lo/out; mkdir -p $lo/out
  zsh -c 'GL_ROOT=$1 GL_OUT=$2/out LO=$2; source $1/scripts/gates-lib.sh
    functions[gl_spec_real]=$functions[gl_spec]
    gl_spec() {
      case $1 in
        leftover-killed) spec_cmd="python3 -I $LO/child.py $LO/child.pid & sleep 300"
                         spec_timeout=3 spec_load=0 spec_check=- ;;
        leftover-exit)   spec_cmd="python3 -I $LO/child.py $LO/child.pid & sleep 2; exit 0"
                         spec_timeout=60 spec_load=0 spec_check=- ;;
        leftover-none)   spec_cmd="sleep 1"; spec_timeout=60 spec_load=0 spec_check=- ;;
        *) gl_spec_real "$@" ;;
      esac
    }
    gl_init; trap "gl_cleanup; exit 130" INT TERM; trap gl_cleanup EXIT; gl_gate $3' lg $root $lo $1
}
for g in leftover-killed leftover-exit; do
  rm -f $lo/child.pid
  leftgate $g > /dev/null 2>&1; rc=$?
  cp=$(cat $lo/child.pid 2>/dev/null)
  n=$((n + 1))
  [[ $rc != 0 && -n $cp && -s $lo/out/leftover-$g-$cp.txt ]] && ! kill -0 $cp 2>/dev/null \
    && grep -q " end $g rc=[1-9][0-9]* [0-9]*s leftover=1$" $lo/out/gates.log && grep -q " leftover $g pid=$cp ppid=" $lo/out/gates.log \
    || { print "FAIL: the gate $g's leftover (rc=$rc, child ${cp:-none}): $(grep -E " (end|leftover) " $lo/out/gates.log 2>/dev/null | tr '\n' '/')"; fail=1 }
  [[ -n $cp ]] && kill -KILL $cp 2>/dev/null
done
leftgate leftover-none > /dev/null 2>&1; rc=$?
n=$((n + 1)); [[ $rc == 0 ]] && grep -q " end leftover-none rc=0 [0-9]*s leftover=0$" $lo/out/gates.log \
  || { print "FAIL: a gate that leaves nothing: rc=$rc $(grep ' end ' $lo/out/gates.log 2>/dev/null)"; fail=1 }
rm -rf $lo
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
# main-flips (docs/modules/main-flips.md): --bar over mainload rows shows
# the main flips and the waits for the collector with the longest, a wait
# is shown and never folded into 0, the rows without the fields read "?",
# a row kind the report does not know is tabulated as UNKNOWN, and the
# report's mainload table has the rows.
mkdir -p $bars/ml
print 'at=1 mode=scenario run=1 tag=- scenario=storm young=offload workers=5 mainalloc=6000 mainwork=0 frames=1200 expected=1200 missed=0 main_flips=118 main_collector_waits=0 main_collector_wait_ms=0.000 main_collector_wait_max_ms=0.000 gc_ycMainCollectorWaits=0 gc_ycOnMain=0 gc_ycHost=0 thermal_start=fair thermal_end=fair' > $bars/ml/mainload.txt
print 'at=2 mode=scenario run=1 tag=- scenario=storm young=stw workers=5 mainalloc=6000 mainwork=0 frames=1200 expected=1200 missed=2 main_flips=0 main_collector_waits=0 main_collector_wait_ms=0.000 main_collector_wait_max_ms=0.000 gc_ycMainCollectorWaits=- gc_ycOnMain=- thermal_start=fair thermal_end=fair' >> $bars/ml/mainload.txt
print 'at=3 mode=scenario run=2 tag=- scenario=storm young=offload workers=5 mainalloc=6000 mainwork=0 frames=1199 expected=1200 missed=1 main_flips=121 main_collector_waits=3 main_collector_wait_ms=4.500 main_collector_wait_max_ms=2.250 gc_ycMainCollectorWaits=4 gc_ycMainCollectorWaitMaxMs=2.250 gc_ycOnMain=0 gc_ycHost=0 thermal_start=serious thermal_end=serious' >> $bars/ml/mainload.txt
print 'mode=golden kind=st kernel=fib workers=1 run=1 ok=1 checksum=5' > $bars/ml/golden.txt
print 'at=4 mode=scenario run=1 tag=- scenario=storm young=offload workers=5 missed=0 main_flips=7' > $bars/ml/brandnew.txt
bar=$($root/scripts/shell-report.py --bar $bars/ml); rc=$?
n=$((n + 1)); [[ $rc == 0 ]] || { print "FAIL: --bar over mainload rows: rc=$rc"; fail=1 }
n=$((n + 1)); [[ $bar == *"| main flips | main waits for the collector (longest ms) |"* ]] || { print "FAIL: --bar has no flips and waits columns"; fail=1 }
n=$((n + 1)); [[ $(print -r -- $bar | grep '^| mainload |') == *"| 239 | 3 (2.25) |"* ]] || { print "FAIL: --bar's mainload row does not show 239 flips and 3 waits (2.25 ms): $(print -r -- $bar | grep '^| mainload |')"; fail=1 }
n=$((n + 1)); [[ $(print -r -- $bar | grep '^| golden |') == *"| ? | ? |"* ]] || { print "FAIL: --bar's golden row does not read ? for flips and waits"; fail=1 }
n=$((n + 1)); [[ $(print -r -- $bar | grep '^| all |') == *"| 246 | 3 (2.25) |"* ]] || { print "FAIL: --bar's all row does not sum flips and waits"; fail=1 }
n=$((n + 1)); [[ $bar == *"| brandnew (UNKNOWN kind) | 1 |"* && $bar == *"does not know"*"brandnew.txt"* ]] || { print "FAIL: --bar dropped or did not name a row kind it does not know"; fail=1 }
n=$((n + 1)); [[ $bar == *"3 waits of the main worker for its collector, 4.500 ms, longest 2.250 ms"*"thermal serious->serious"* && $bar == *"1 waits for the collector outside the window"* ]] || { print "FAIL: --bar's notes do not name the row with waits"; fail=1 }
rep=$($root/scripts/shell-report.py $bars/ml); rc=$?
n=$((n + 1)); [[ $rc == 0 && $rep == *"### mainload"* && $(print -r -- $rep | grep -c '^| offload | [12] | 1[12][18] |') == 2 ]] || { print "FAIL: the report's mainload tables: rc=$rc"; fail=1 }
rm -rf $bars
# The weekly margins (docs/modules/weekly-margins.md): margins.py over its
# fixtures (a plain row, a row over THIN, a value past its bound, a line
# with a field missing and one quoted inside another line, two lines of one
# name, a name absent from a gate, an empty gate file, a missing one,
# interleaved lines, gates.log with and without bounds, --previous with a
# name gone) is the committed expected.md byte for byte; the sample line
# the Swift helpers' tests read parses to its fields; a usage error is 2.
mf=$root/Tests/KajoCompilerTests/Fixtures/margins
ms=$(mktemp -d ${TMPDIR:-/tmp}/kajo-margins-XXXXXX)
(cd $mf && $root/scripts/margins.py run --previous previous) > $ms/got.md; rc=$?
n=$((n + 1)); [[ $rc == 0 ]] && cmp -s $ms/got.md $mf/expected.md \
  || { print "FAIL: margins.py over its fixtures differs from expected.md (rc=$rc):"; diff $ms/got.md $mf/expected.md | head -20; fail=1 }
rm -f $ms/got.md
cp $mf/sample-line.txt $ms/tsan-load.txt
got=$($root/scripts/margins.py $ms); rc=$?
n=$((n + 1)); [[ $rc == 0 && $(print -r -- $got | grep '^| Sample') == "| Sample.until.ready | quiet | s | 12.5/60.0 (0.21) | 0.21 |  |" && $got != *UNKNOWN* ]] \
  || { print "FAIL: the sample line does not read as name Sample.until.ready, quiet, 12.5 of 60 s: $(print -r -- $got | grep -E '^\| Sample|UNKNOWN')"; fail=1 }
$root/scripts/margins.py > /dev/null 2>&1; rc1=$?
$root/scripts/margins.py $ms/nothing-here > /dev/null 2>&1; rc2=$?
$root/scripts/margins.py $ms --bogus > /dev/null 2>&1; rc3=$?
n=$((n + 1)); [[ $rc1 == 2 && $rc2 == 2 && $rc3 == 2 ]] || { print "FAIL: margins.py's usage errors exit $rc1 $rc2 $rc3, want 2"; fail=1 }
# summary.md's --previous: the last finished non-quick weekly run's
# directory, never this run's own, nothing when there is none.
mkdir -p $ms/w/a $ms/w/b $ms/w/c-quick
prevdir() { zsh -c 'GL_ROOT=$1; source $1/scripts/gates-lib.sh; gl_weekly_previous_dir $2 $3' pd $root $1 $2 }
print -l "2026-11-01 02:00:00 weekly start $ms/w/a commit x quick=0 devices=1" "2026-11-01 05:00:00 weekly done $ms/w/a failed=0" \
  "2026-11-02 02:00:00 weekly start $ms/w/c-quick commit x quick=1 devices=0" "2026-11-02 03:00:00 weekly done $ms/w/c-quick failed=0" \
  "2026-11-03 02:00:00 weekly start $ms/w/b commit x quick=0 devices=1" > $ms/weekly.log
n=$((n + 1)); [[ $(prevdir $ms/weekly.log $ms/w/b) == $ms/w/a ]] || { print "FAIL: the weekly's previous run is '$(prevdir $ms/weekly.log $ms/w/b)', want $ms/w/a"; fail=1 }
print "2026-11-03 05:00:00 weekly done $ms/w/b failed=0" >> $ms/weekly.log
n=$((n + 1)); [[ $(prevdir $ms/weekly.log $ms/w/b) == $ms/w/a ]] || { print "FAIL: a run was its own previous: '$(prevdir $ms/weekly.log $ms/w/b)'"; fail=1 }
: > $ms/weekly.log
n=$((n + 1)); [[ -z $(prevdir $ms/weekly.log $ms/w/b) ]] || { print "FAIL: an empty weekly.log gave a previous run"; fail=1 }
rm -rf $ms
# Check time (docs/modules/check-time.md, part 4): the by-hand variants'
# runner judges an output as recorded: a variant expected to fail fails
# with its message (a pass, or a failure without the message, is the
# runner's failure), a forcing condition passes with its line; the list
# has every variant; a usage error is 2.
bv=$(mktemp -d ${TMPDIR:-/tmp}/kajo-broken-XXXXXX)
print 'error: Process ... exited with unexpected signal code 11' > $bv/crash.txt
print '✔ Test theToolsDevelopTheImageTheyRunIn() passed after 9.1 seconds.' > $bv/pass.txt
judged() { $root/scripts/broken-variants.sh --judge "$@" }
for c in "fail|exited with unexpected signal code 11|1|crash.txt|ok" "fail|exited with unexpected signal code 11|0|crash.txt|FAILED" \
         "fail|exited with unexpected signal code 11|1|pass.txt|FAILED" "pass|theToolsDevelopTheImageTheyRunIn() passed|0|pass.txt|ok" \
         "pass|theToolsDevelopTheImageTheyRunIn() passed|1|pass.txt|FAILED" "pass|theToolsDevelopTheImageTheyRunIn() passed|0|crash.txt|FAILED"; do
  local -a w=("${(@s:|:)c}")
  got=$(judged ${w[1]} "${w[2]}" ${w[3]} $bv/${w[4]})
  n=$((n + 1)); [[ $got == ${w[5]} ]] || { print "FAIL: broken-variants judged '$c' as $got"; fail=1 }
done
n=$((n + 1)); [[ $($root/scripts/broken-variants.sh --list | tr '\n' ' ') == "delay-end shell-close closed-shell-runTurn closed-shell-spawn closed-shell-liveProcessCount tools-hold-install tools-hold-loop " ]] \
  || { print "FAIL: broken-variants --list: $($root/scripts/broken-variants.sh --list | tr '\n' ' ')"; fail=1 }
$root/scripts/broken-variants.sh > /dev/null 2>&1; rc1=$?
$root/scripts/broken-variants.sh --judge fail x > /dev/null 2>&1; rc2=$?
n=$((n + 1)); [[ $rc1 == 2 && $rc2 == 2 ]] || { print "FAIL: broken-variants' usage errors exit $rc1 $rc2, want 2"; fail=1 }
# The shards side by side (part 2): with a stand-in swift, the build runs
# once, each shard runs with --skip-build --ignore-lock and its own
# selection (together every test once: the VM tests but the random
# programs, the random programs but the resumed ones, the resumed ones,
# the compiler tests but the tools', then alone the tools'), the output is the
# shards' in order, and a failing shard fails the run.
cat > $bv/swift <<'STANDIN'
#!/bin/zsh
print -r -- "$*" >> ${0:h}/calls.txt
[[ $1 == build ]] && exit 0
print "shard ran: $*"
[[ "$*" == *${STANDIN_FAIL:-none}* ]] && exit 1
exit 0
STANDIN
chmod +x $bv/swift
KAJO_SWIFT=$bv/swift $root/scripts/test-bundles.sh $bv/out/x --sanitize=thread > $bv/run.txt 2>&1; rc=$?
want="test --skip-build --ignore-lock --sanitize=thread --filter KajoCompilerTests --skip ToolsTests|PhoneTransportTests|ProjectDirectoryTests|DebuggerProtocolTests|DevelopmentAnswersTests/test --skip-build --ignore-lock --sanitize=thread --filter KajoVMTests --skip randomPrograms/test --skip-build --ignore-lock --sanitize=thread --filter ToolsTests|PhoneTransportTests|ProjectDirectoryTests|DebuggerProtocolTests|DevelopmentAnswersTests/test --skip-build --ignore-lock --sanitize=thread --filter randomPrograms --skip randomProgramsResume/test --skip-build --ignore-lock --sanitize=thread --filter randomProgramsResume/"
n=$((n + 1)); [[ $rc == 0 && $(grep -c '^build --build-tests --sanitize=thread$' $bv/calls.txt) == 1 \
  && $(grep '^test ' $bv/calls.txt | sort | tr '\n' '/') == $want \
  && $(grep '^shard ran' $bv/run.txt | sed 's/.*--filter //' | tr '\n' '/') == "KajoVMTests --skip randomPrograms/randomPrograms --skip randomProgramsResume/randomProgramsResume/KajoCompilerTests --skip ToolsTests|PhoneTransportTests|ProjectDirectoryTests|DebuggerProtocolTests|DevelopmentAnswersTests/ToolsTests|PhoneTransportTests|ProjectDirectoryTests|DebuggerProtocolTests|DevelopmentAnswersTests/" \
  && $(grep -c '^test-bundles: phase of ' $bv/run.txt) == 2 ]] \
  || { print "FAIL: test-bundles over a stand-in (rc=$rc): $(cat $bv/calls.txt $bv/run.txt | tr '\n' '/')"; fail=1 }
STANDIN_FAIL=KajoCompilerTests KAJO_SWIFT=$bv/swift $root/scripts/test-bundles.sh $bv/out/x > $bv/run2.txt 2>&1; rc=$?
n=$((n + 1)); [[ $rc != 0 && $(grep -c '^shard ran' $bv/run2.txt) == 5 && $(grep -c 'shard compiler rc=1' $bv/run2.txt) == 1 ]] || { print "FAIL: test-bundles with a failing shard: rc=$rc"; fail=1 }
rm -rf $bv
# The weekly run sets the full size for every gate; a tier sets nothing.
n=$((n + 1)); grep -q '^export KAJO_TEST_SIZE=full$' $root/scripts/weekly.sh && ! grep -q 'KAJO_TEST_SIZE' $root/scripts/check-tier.sh $root/scripts/gates-lib.sh \
  || { print "FAIL: KAJO_TEST_SIZE=full is not the weekly's alone"; fail=1 }
# docs only: exit 0 at once, saying so.
out=$(print docs/x.md | $root/scripts/check-tier.sh --paths -); rc=$?
n=$((n + 1))
[[ $rc == 0 && $out == *"nothing owed"* ]] || { print "FAIL: docs only: rc=$rc"; fail=1 }
print "check-tier-test: $n checks, $([[ $fail == 0 ]] && print ok || print FAILED)"
exit $fail
