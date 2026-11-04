#!/bin/zsh
# Module 9a's app gate: both shells built from clean by xcodebuild (Release;
# the iOS shell for a generic device without signing, so the check does not
# need an account), exit status, error count and compiler warning count read
# from the logs (AGENTS.md: a gate reads the exit status and the error count
# first). DD overrides the DerivedData root.
set -uo pipefail
root=${0:A:h:h}
DD=${DD:-${TMPDIR:-/tmp}/kajo-apps-check}
fail=0
check() {
  local name=$1; shift
  local log=$DD-$name.log
  gtimeout 3600 xcodebuild "$@" -configuration Release -derivedDataPath $DD-$name clean build > $log 2>&1
  local rc=$?
  local errors=$(grep -cE "(^|: )error:" $log)
  local warnings=$(grep -E "^/.*: warning:" $log | sort -u | wc -l | tr -d ' ')
  print "$name: exit=$rc errors=$errors warnings=$warnings log=$log"
  grep -E "^/.*: (warning|error):" $log | sort -u | head -20
  [[ $rc == 0 && $errors == 0 && $warnings == 0 ]] || fail=1
}
check macos -project $root/apps/KajoShell-macOS/KajoShell-macOS.xcodeproj -scheme KajoShell
check ios -project $root/apps/KajoShell-iOS/KajoShell-iOS.xcodeproj -scheme KajoShell -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
exit $fail
