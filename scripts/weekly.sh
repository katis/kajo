#!/bin/zsh
# The weekly run on the Mac mini (docs/modules/gate-tiers.md): every gate
# of the core tier with its load loops, then the measurement matrix on the
# Mac and on every attached device, into ~/kajo-weekly/<YYYY-MM-DD>/ with a
# gates.log and a summary.md that ends with a `weekly done` line. Run by
# the LaunchAgent scripts/launchd/dev.katajamaki.kajo.weekly.plist on
# Sundays at 02:00, or by hand (`just weekly`).
#
# It refuses to start (exit 0, one line in ~/kajo-weekly/weekly.log) when
# anything of Kajo runs: a kajo, swift-build, swift-test, xcodebuild,
# KajoShell, Kajo, Sample or yes process of this user outside its own process
# group (by exact executable name, so nothing else of the owner's matches).
# Under the swiftly toolchain `swift build` and `swift test` run as
# swift-package and the tests in swiftpm-testing-helper (ps truncates it to
# swiftpm-testing-), so those names count too (gate speed: found when a
# weekly started beside a running suite; scripts/check-tier-test.sh).
# It runs on the tree as checked out: it does not pull, switch or clean,
# and says in the log when the tree is dirty or not on master.
#
# KAJO_WEEKLY_QUICK=1: fuzzers at 60 s, one matrix run, the Mac only, into
# <date>-quick/ (the plumbing end to end). KAJO_WEEKLY_DEVICES=0|1 turns
# the device rows off or on whatever the mode. KAJO_WEEKLY_ONLY="<gate>..."
# runs only the named steps (gate names as in scripts/gates-lib.sh,
# matrix-mac, devices for every attached device, matrix-iphone or
# matrix-ipad for one). KAJO_WEEKLY_ROOT moves ~/kajo-weekly.
#
# Gate speed (docs/modules/gate-speed.md, change 6): the weekly is the
# full set again, every gate of the core tier (the device rows as
# `devices`) plus plain swift-test and check-tier-test. The fuzzers are the
# one fuzz gate (a line per target in gates.log and summary.md). The A/B's
# base is the commit of the last weekly run that finished (quick runs not
# counted, read from weekly.log); with none, or when it is this commit, the
# A/B is skipped with a line saying so in gates.log and summary.md.
# `scripts/weekly.sh --gates` prints the steps and exits (the superset check
# in scripts/check-tier-test.sh).
set -uo pipefail
root=${0:A:h:h}
gates=(check-tier-test clean-build swift-test swift-test-load tsan tsan-load ios-check arc-check golden native-golden native-kernel-test native-cc
       test-release model-check soak fuzz apps kernel-test new-check ab)
if [[ ${1:-} == --gates ]]; then print -r -- "$gates matrix-mac devices"; exit 0; fi
WROOT=${KAJO_WEEKLY_ROOT:-$HOME/kajo-weekly}
QUICK=${KAJO_WEEKLY_QUICK:-0}
ONLY=${KAJO_WEEKLY_ONLY:-}
DEVICES=${KAJO_WEEKLY_DEVICES:-$(( QUICK ? 0 : 1 ))}
mkdir -p $WROOT
wlog() { print -r -- "$(date '+%F %T') $*" | tee -a $WROOT/weekly.log }

# Anything of Kajo running, by exact executable name, outside our group.
own=$(ps -o pgid= -p $$ | tr -d ' ')
busy=$(ps -U $(id -u) -o pid=,pgid=,ucomm= | awk -v own=$own '
  { n = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", n); sub(/ +$/, "", n)
    if ($2 != own && (n == "kajo" || n == "swift-build" || n == "swift-test" || n == "xcodebuild" ||
                      n == "swift-package" || n ~ /^swiftpm-testing/ ||
                      n == "KajoShell" || n == "Kajo" || n == "Sample" || n == "yes")) { printf "%s %s(%s)", sep, n, $1; sep = "," } }')
if [[ -n $busy ]]; then
  wlog "weekly refused: Kajo is running:$busy"
  exit 0
fi

day=$(date +%F)
(( QUICK )) && day=$day-quick
out=$WROOT/$day
mkdir -p $out
cd $root
branch=$(git branch --show-current)
dirty=$(git status --porcelain | wc -l | tr -d ' ')
note=
[[ $branch == master ]] || note="$note not on master ($branch);"
[[ $dirty == 0 ]] || note="$note the tree is dirty ($dirty paths, run as it is);"
wlog "weekly start $out commit $(git rev-parse --short HEAD) quick=$QUICK devices=$DEVICES${note:+ NOTE:$note}"

GL_ROOT=$root
GL_OUT=$out
source $root/scripts/gates-lib.sh
GL_FUZZ_SECS=$(( QUICK ? 60 : 600 ))
GL_RUNS=$(( QUICK ? 1 : 3 ))
gl_init
trap 'gl_cleanup; exit 130' INT TERM
trap 'gl_cleanup' EXIT
[[ -n $note ]] && gl_log "NOTE:$note"
t0=$(date +%s)
wants() { [[ -z $ONLY || " $ONLY " == *" $1 "* ]] }

GL_AB_BASE=$(gl_weekly_ab_base $WROOT/weekly.log HEAD)
[[ -n $GL_AB_BASE ]] && gl_log "ab base $GL_AB_BASE: the last finished weekly run's commit ($WROOT/weekly.log)"
for g in $gates; do
  wants $g || continue
  if [[ $g == ab && -z $GL_AB_BASE ]]; then
    gl_skip ab "no base: no weekly run before this one finished at another commit (weekly.log)"
    continue
  fi
  gl_gate $g
done
wants matrix-mac && gl_gate matrix-mac

# Every attached device (`devicectl list devices`, state connected).
devices=()
device_wanted() { [[ -z $ONLY || " $ONLY " == *" devices "* || " $ONLY " == *" matrix-$1 "* ]] }
if (( DEVICES )) && [[ -z $ONLY || " $ONLY " == *" devices "* || " $ONLY " == *" matrix-"* ]]; then
  gtimeout 60 xcrun devicectl list devices > $out/devices.txt 2>&1
  while read -r line; do
    udid=$(print -r -- "$line" | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')
    [[ -n $udid && $line == *" connected "* ]] || continue
    label=device-$udid
    [[ $line == *iPhone* ]] && label=iphone
    [[ $line == *iPad* ]] && label=ipad
    GL_UDID[$label]=$udid
    devices+=($label)
  done < $out/devices.txt
  gl_log "devices: ${devices:-none attached}"
  for d in $devices; do device_wanted $d && gl_gate matrix-$d; done
fi

# summary.md: one line per gate from gates.log, then each matrix's bar.
{
  print "# Kajo weekly $day"
  print
  print "Commit $GL_COMMIT on $branch, $GL_SWIFT; started $(date -r $t0 '+%F %T'), $(sysctl -n hw.model)."
  [[ -n $note ]] && print "\nNOTE:$note"
  print "\n## Gates\n"
  print "| gate | result | time | note |"
  print "|---|---|--:|---|"
  grep -E " $GL_COMMIT (end|skip) " $GL_LOG | awk '
      $4 == "skip" { name = $5; sub(":$", "", name); why = $0; sub(/.* skip [^ ]*: /, "", why); reason[name] = why; next }
      { name = $5; rc = $6; sub("rc=", "", rc); t = $7; note = ""
        for (i = 8; i <= NF; i++) note = note (i > 8 ? " " : "") $i
        r = (rc == "0") ? "pass" : (rc == "3" ? "skipped (codesign waited on a prompt)" : (rc == "skip" ? "skipped" : "FAIL (rc=" rc ")"))
        res[name] = r; tm[name] = t; nt[name] = note; if (!(name in seen)) { seen[name] = 1; order[++n] = name } }
      END { for (i = 1; i <= n; i++) { k = order[i]; x = nt[k]; if (k in reason) x = reason[k]
              printf "| %s | %s | %s | %s |\n", k, res[k], tm[k], x } }'
  for m in matrix-mac ${devices/#/matrix-}; do
    [[ -d $out/$m ]] || continue
    print "\n## $m (every raw row of $m/*.txt; full tables in $m/report.md)\n"
    $root/scripts/shell-report.py --bar $out/$m
  done
  print "\nfailed: ${GL_FAILED:-none}"
  print "\nweekly done $(date '+%F %T') ($(( ($(date +%s) - t0) / 60 )) min)"
} > $out/summary.md 2>&1
gl_log "weekly done failed=${#GL_FAILED}"
wlog "weekly done $out failed=${#GL_FAILED}${GL_FAILED:+ (${GL_FAILED})}"
