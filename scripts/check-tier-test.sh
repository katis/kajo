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
check_gates "clean-build swift-test tsan kernel-test apps new-check" scripts/gates-lib.sh
check_gates "clean-build swift-test tsan kernel-test apps new-check fuzz-protocol" Sources/KajoDev/Client.swift
check_gates "clean-build swift-test tsan kernel-test apps new-check model-check" models/Package.swift
check_gates "clean-build swift-test swift-test-load tsan tsan-load ios-check arc-check golden test-release model-check soak fuzz-kasm fuzz-snapshot fuzz-syntax fuzz-protocol apps kernel-test new-check ab matrix-mac matrix-iphone" Sources/KajoVM/Marking/Marker.swift
# docs only: exit 0 at once, saying so.
out=$(print docs/x.md | $root/scripts/check-tier.sh --paths -); rc=$?
n=$((n + 1))
[[ $rc == 0 && $out == *"nothing owed"* ]] || { print "FAIL: docs only: rc=$rc"; fail=1 }
print "check-tier-test: $n checks, $([[ $fail == 0 ]] && print ok || print FAILED)"
exit $fail
