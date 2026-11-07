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
# KajoShell, Sample or yes process of this user outside its own process
# group (by exact executable name, so nothing else of the owner's matches).
# It runs on the tree as checked out: it does not pull, switch or clean,
# and says in the log when the tree is dirty or not on master.
#
# KAJO_WEEKLY_QUICK=1: fuzzers at 60 s, one matrix run, the Mac only, into
# <date>-quick/ (the plumbing end to end). KAJO_WEEKLY_DEVICES=0|1 turns
# the device rows off or on whatever the mode. KAJO_WEEKLY_ONLY="<gate>..."
# runs only the named steps (gate names as in scripts/gates-lib.sh,
# matrix-mac, devices). KAJO_WEEKLY_ROOT moves ~/kajo-weekly.
set -uo pipefail
root=${0:A:h:h}
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
                      n == "KajoShell" || n == "Sample" || n == "yes")) { printf "%s %s(%s)", sep, n, $1; sep = "," } }')
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

gates=(clean-build swift-test swift-test-load tsan tsan-load ios-check arc-check golden test-release model-check soak
       fuzz-kasm fuzz-snapshot fuzz-syntax fuzz-protocol apps kernel-test new-check)
for g in $gates; do wants $g && gl_gate $g; done
wants matrix-mac && gl_gate matrix-mac

# Every attached device (`devicectl list devices`, state connected).
devices=()
if (( DEVICES )) && wants devices; then
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
  for d in $devices; do gl_gate matrix-$d; done
fi

# summary.md: one line per gate from gates.log, then each matrix's bar.
{
  print "# Kajo weekly $day"
  print
  print "Commit $GL_COMMIT on $branch, $GL_SWIFT; started $(date -r $t0 '+%F %T'), $(sysctl -n hw.model)."
  [[ -n $note ]] && print "\nNOTE:$note"
  print "\n## Gates\n"
  print "| gate | result | time |"
  print "|---|---|--:|"
  grep " end " $GL_LOG | grep -E " $GL_COMMIT end " | awk '{ name = $5; rc = $6; sub("rc=", "", rc); t = $7;
      r = (rc == "0") ? "pass" : (rc == "3" ? "skipped (codesign waited on a prompt)" : "FAIL (rc=" rc ")");
      res[name] = r; tm[name] = t; if (!(name in seen)) { seen[name] = 1; order[++n] = name } }
      END { for (i = 1; i <= n; i++) printf "| %s | %s | %s |\n", order[i], res[order[i]], tm[order[i]] }'
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
