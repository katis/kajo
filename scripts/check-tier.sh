#!/bin/zsh
# The gates a diff owes (docs/modules/gate-tiers.md, AGENTS.md
# "Verification"): decides the tier from the files the diff touches, prints
# it with the files that chose it, then runs the tier's gates one after
# another through scripts/gates-lib.sh, each into <out>/<gate>.txt with a
# start and an end line in <out>/gates.log. Exit status 0 when every gate
# passed (or nothing is owed), 1 when any failed, 2 on a usage error.
#
#   scripts/check-tier.sh [--dry-run] [--tier none|smalltalk|swift|core] [--paths <file>|-] [base]
#
# The files are `git diff --name-only <base>...HEAD`, the working tree's
# changes against HEAD and its untracked files; base is origin/master by
# default. --paths reads the file list from a file (or stdin) instead of
# git, for deciding a tier of any list (the decision's test uses it).
# --tier overrides the decision. KAJO_CHECK_OUT chooses the output directory
# (default .build/check/<date>/, gitignored; gates.log appends).
#
# The tiers, highest first; a diff owes the highest tier any of its files
# asks for:
#   core       Sources/KajoVM/{ObjectMemory,Interpreter,Loader,Workers,Processes,
#              Nursery,Marking,Relocation,YoungCollection,ObjectModel}/
#   swift      anything that is in no other tier (Swift outside the core,
#              Package.swift, Tests/, scripts/, justfile, apps/ but its
#              Smalltalk, models/, experiments/ code ...)
#   smalltalk  kernel/, tools/, apps/Shared/smalltalk/
#   none       docs/, any *.md (experiments/*/RESULTS.md among them)
set -uo pipefail
root=${0:A:h:h}
dry=0 tier= paths= base=
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --tier) tier=${2:?--tier none|smalltalk|swift|core}; shift ;;
    --paths) paths=${2:?--paths <file>|-}; shift ;;
    -h|--help) sed -n '2,26p' $0; exit 0 ;;
    -*) print "check-tier: unknown option $1"; exit 2 ;;
    *) base=$1 ;;
  esac
  shift
done
[[ -z $tier || $tier == (none|smalltalk|swift|core) ]] || { print "check-tier: --tier is none, smalltalk, swift or core"; exit 2 }

# classify <path>: the tier one file asks for.
classify() {
  case $1 in
    Sources/KajoVM/(ObjectMemory|Interpreter|Loader|Workers|Processes|Nursery|Marking|Relocation|YoungCollection|ObjectModel)/*) print core ;;
    kernel/*|tools/*|apps/Shared/smalltalk/*) print smalltalk ;;
    docs/*|*.md) print none ;;
    *) print swift ;;
  esac
}

# fuzzers_for <path>: the fuzzers a file outside the core owes (tier swift).
fuzzers_for() {
  case $1 in
    Sources/KajoDev/*|Sources/fuzz-protocol/*|Tests/KajoVMTests/Fixtures/fuzz/protocol/*) print protocol ;;
    Sources/KajoCompiler/*|Sources/fuzz-syntax/*|Tests/KajoVMTests/Fixtures/fuzz/syntax/*) print syntax ;;
    Sources/fuzz-kasm/*|Tests/KajoVMTests/Fixtures/fuzz/kasm/*) print kasm ;;
    Sources/fuzz-snapshot/*|Tests/KajoVMTests/Fixtures/fuzz/snapshot/*) print snapshot ;;
    scripts/fuzz.sh) print kasm snapshot syntax protocol ;;
  esac
}

rank() { case $1 in none) print 0 ;; smalltalk) print 1 ;; swift) print 2 ;; core) print 3 ;; esac }

cd $root
if [[ -n $paths ]]; then
  if [[ $paths == - ]]; then files=("${(@f)$(cat)}"); else files=("${(@f)$(cat $paths)}"); fi
  source_desc="the paths in $paths"
else
  base=${base:-origin/master}
  git rev-parse -q --verify "$base^{commit}" > /dev/null || { print "check-tier: no commit $base"; exit 2 }
  files=("${(@f)$( { git diff --name-only $base...HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)}")
  source_desc="$base...HEAD ($(git rev-parse --short $base)...$(git rev-parse --short HEAD)) and the working tree"
fi
files=(${files:#})

decided=none
for f in $files; do
  t=$(classify $f)
  (( $(rank $t) > $(rank $decided) )) && decided=$t
done
chosen=()
for f in $files; do [[ $(classify $f) == $decided ]] && chosen+=($f); done
fuzzers=()
for f in $files; do fuzzers+=($(fuzzers_for $f)); done
fuzzers=(${(u)fuzzers})
models=0
for f in $files; do [[ $f == models/* ]] && models=1; done

print "check-tier: ${#files} files from $source_desc"
if [[ -z $tier ]]; then
  tier=$decided
  print "tier: $tier"
  if (( ${#files} == 0 )); then
    print "  (no changes)"
  else
    print "chosen by (${#chosen} of ${#files}):"
    for f in ${chosen[1,20]}; do print "  $f"; done
    (( ${#chosen} > 20 )) && print "  ... and $(( ${#chosen} - 20 )) more"
  fi
else
  print "tier: $tier (--tier; the files ask for $decided)"
fi

# The tier's gates, in order.
gates=()
case $tier in
  none)
    print "nothing owed: docs only"
    exit 0 ;;
  smalltalk)
    gates=(build-image dev-image kernel-test tools-test compiler-tests golden mac-shell-tests) ;;
  swift)
    gates=(clean-build swift-test tsan kernel-test apps new-check)
    for z in $fuzzers; do gates+=(fuzz-$z); done
    (( models )) && gates+=(model-check) ;;
  core)
    gates=(clean-build swift-test swift-test-load tsan tsan-load ios-check arc-check golden test-release model-check soak
           fuzz-kasm fuzz-snapshot fuzz-syntax fuzz-protocol apps kernel-test new-check ab matrix-mac matrix-iphone) ;;
esac
[[ $tier == swift ]] && print "fuzzers: ${fuzzers:-none}"

GL_ROOT=$root
GL_OUT=${KAJO_CHECK_OUT:-$root/.build/check/$(date +%F)}
source $root/scripts/gates-lib.sh
[[ $tier == swift ]] && GL_FUZZ_SECS=${KAJO_CHECK_FUZZ_SECS:-120}
if [[ $tier == core ]]; then
  GL_FUZZ_SECS=${KAJO_CHECK_FUZZ_SECS:-600}
  GL_AB_BASE=$(git merge-base ${base:-origin/master} HEAD 2>/dev/null | cut -c1-7)
  GL_UDID[iphone]=${DEVICE:-00008110-001855C63642801E}
fi

print "gates (${#gates}), output in $GL_OUT:"
for g in $gates; do gl_describe $g; done
(( dry )) && exit 0

gl_init
trap 'gl_cleanup; exit 130' INT TERM
trap 'gl_cleanup' EXIT
gl_log "check-tier $tier: ${#files} files from $source_desc"
t0=$(date +%s)
for g in $gates; do
  gl_gate $g
  print "$(date '+%T') $g: $(tail -1 $GL_LOG | sed 's/.* end //')"
done
gl_log "check-tier done $tier failed=${#GL_FAILED} $(( $(date +%s) - t0 ))s"
if (( ${#GL_FAILED} )); then print "check-tier: FAILED ${GL_FAILED}"; exit 1; fi
print "check-tier: every gate of tier $tier passed in $(( $(date +%s) - t0 ))s"
