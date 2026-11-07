# Gate tiers (docs/modules/gate-tiers.md): how one gate runs, sourced by
# scripts/check-tier.sh and scripts/weekly.sh. Each gate is a name with a
# command line, a bound and a check of its output; the command runs in the
# repository root under `gtimeout` into <out>/<gate>.txt, and gates.log gets
# a start line naming the commit and the toolchain and an end line with the
# exit status and the seconds it took (the final-mark module's pattern):
#
#   2026-11-07 08:08:11 bcee36d start clean-build (swift: Apple Swift version 6.4.2 ...)
#   2026-11-07 08:08:30 bcee36d end clean-build rc=0 19s
#
# The caller sets GL_ROOT (the repository) and GL_OUT (the output
# directory), calls gl_init, then gl_gate <name> for each gate, and
# installs gl_cleanup in its traps. GL_FUZZ_SECS (600), GL_RUNS (the
# matrix's RUNS, 3) and GL_AB_BASE (the A/B's base commit) parameterize
# the gates that take them; GL_UDID[<label>] names a device for
# matrix-<label>.

typeset -gA GL_UDID
GL_FUZZ_SECS=${GL_FUZZ_SECS:-600}
GL_RUNS=${GL_RUNS:-3}
GL_AB_BASE=${GL_AB_BASE:-}
GL_FAILED=()
GL_CHILD=
GL_LOAD=

gl_init() {
  mkdir -p $GL_OUT
  GL_LOG=$GL_OUT/gates.log
  GL_COMMIT=$(git -C $GL_ROOT rev-parse --short HEAD)
  GL_SWIFT=$(swift --version 2>&1 | head -1 | cut -c1-60)
}

gl_log() { print -r -- "$(date '+%F %T') $GL_COMMIT $*" >> $GL_LOG }

# gl_spec <gate>: sets spec_cmd (a zsh command line run in the repository
# root), spec_timeout (seconds), spec_load (1: under twelve busy loops) and
# spec_check (a gl_check_<name> run on the output when the command exits 0,
# or -). Returns 1 for an unknown gate.
gl_spec() {
  local id=$1 o=$GL_OUT
  spec_timeout=3600 spec_load=0 spec_check=- spec_cmd=
  case $id in
    clean-build)     spec_cmd="rm -rf .build/clean-check && swift build --scratch-path .build/clean-check"; spec_check=clean ;;
    swift-test)      spec_cmd="swift test" ;;
    swift-test-load) spec_cmd="swift test"; spec_load=1 ;;
    tsan)            spec_cmd="swift test --sanitize=thread --scratch-path .build/tsan-check"; spec_timeout=10800 ;;
    tsan-load)       spec_cmd="swift test --sanitize=thread --scratch-path .build/tsan-check"; spec_timeout=10800; spec_load=1 ;;
    ios-check)       spec_cmd="just ios-check"; spec_check=clean ;;
    arc-check)       spec_cmd="just arc-check" ;;
    golden)          spec_cmd="just golden" ;;
    test-release)    spec_cmd="just test-release" ;;
    model-check)     spec_cmd="just model-check" ;;
    soak)            spec_cmd="just soak" ;;
    fuzz-kasm|fuzz-snapshot|fuzz-syntax|fuzz-protocol)
                     spec_cmd="just fuzz ${id#fuzz-} $GL_FUZZ_SECS"; spec_timeout=$(( GL_FUZZ_SECS + 1800 )); spec_check=libfuzzer ;;
    apps)            spec_cmd="just apps" ;;
    kernel-test)     spec_cmd="just kernel-test" ;;
    new-check)       spec_cmd="just new-check" ;;
    build-image)     spec_cmd="swift run kajo build-image -o $o/kernel.img" ;;
    dev-image)       spec_cmd="swift run kajo build-image -o $o/dev.img --with tools" ;;
    tools-test)      spec_cmd="swift run kajo test $o/dev.img" ;;
    compiler-tests)  spec_cmd="swift test --filter KajoCompilerTests" ;;
    mac-shell-tests) spec_cmd="rm -f $o/mac-tests-rows.txt; scripts/mac-shell.sh build && scripts/mac-shell.sh run $o/mac-tests-rows.txt mode=tests; cat $o/mac-tests-rows.txt"
                     spec_check=mactests ;;
    ab)              spec_cmd="scripts/ab.sh ${GL_AB_BASE:-<merge base>} $o/ab"; spec_timeout=7200 ;;
    matrix-mac)      spec_cmd="scripts/mac-shell.sh build && { RUNS=$GL_RUNS scripts/shell-matrix.sh mac $o/matrix-mac; scripts/shell-report.py $o/matrix-mac > $o/matrix-mac/report.md; scripts/shell-report.py --bar $o/matrix-mac; }"
                     spec_timeout=$(( 7200 * GL_RUNS )) ;;
    matrix-*)        local label=${id#matrix-}
                     [[ -n ${GL_UDID[$label]:-} ]] || return 1
                     spec_cmd="RUNS=$GL_RUNS scripts/device-rows.sh ${GL_UDID[$label]} $o/matrix-$label"
                     spec_timeout=$(( 3600 + 7200 * GL_RUNS )) ;;
    *) return 1 ;;
  esac
  return 0
}

# gl_describe <gate>: one line for --dry-run.
gl_describe() {
  gl_spec $1 || { print -r -- "  $1: unknown gate"; return 1 }
  local extra=
  (( spec_load )) && extra=" (under twelve gtimeout 1500 yes loops)"
  [[ $spec_check != - ]] && extra="$extra (check: $spec_check)"
  print -r -- "  $1: $spec_cmd$extra [bound ${spec_timeout}s]"
}

gl_check_clean() {
  local w=$(grep -E ':[0-9]+:[0-9]+: warning:' $1 | sort -u | wc -l | tr -d ' ')
  local e=$(grep -cE '(:[0-9]+:[0-9]+: |^)error:' $1)
  print -r -- "gate check: warnings=$w errors=$e" >> $1
  [[ $w == 0 && $e == 0 ]]
}

# AGENTS.md: read the "libFuzzer build: ok" line before counting a fuzz gate.
gl_check_libfuzzer() {
  grep -q '^libFuzzer build: ok' $1 && return 0
  print -r -- "gate check: no 'libFuzzer build: ok' line (the fallback driver ran, no coverage)" >> $1
  return 1
}

gl_check_mactests() {
  local line=$(grep -E 'mode=tests ' $1 | grep -v FAILED | tail -1)
  local ok=0
  [[ -n $line && $line == *" failed=0 "* && $line == *" errored=0 "* && $line == *" vm_error=0 "* && $line != *" total=0 "* ]] && ok=1
  print -r -- "gate check: mac shell tests mode $([[ $ok == 1 ]] && print ok || print FAILED)" >> $1
  [[ $ok == 1 ]]
}

gl_kill_tree() {
  local p
  for p in $(pgrep -P $1 2>/dev/null); do gl_kill_tree $p; done
  kill -TERM $1 2>/dev/null
}

# Twelve busy loops for as long as load.on exists, each bounded at 1500 s
# and replaced when it ends; only this loop's own children are counted and
# killed, never another `yes` of the user.
gl_load_on() {
  touch $GL_OUT/load.on
  zsh -c 'while [[ -e $1 ]]; do
            n=$(pgrep -P $$ -x gtimeout | wc -l | tr -d " ")
            while (( n < 12 )); do gtimeout 1500 yes > /dev/null & n=$((n + 1)); done
            sleep 20
          done' gl-load $GL_OUT/load.on &
  GL_LOAD=$!
  sleep 2
}

gl_load_off() {
  [[ -n $GL_LOAD ]] || return 0
  rm -f $GL_OUT/load.on
  local kids=($(pgrep -P $GL_LOAD 2>/dev/null))
  kill -TERM $GL_LOAD 2>/dev/null
  local k
  for k in $kids; do gl_kill_tree $k; done
  GL_LOAD=
  sleep 1
}

gl_cleanup() {
  [[ -n $GL_CHILD ]] && { gl_kill_tree $GL_CHILD; GL_CHILD= }
  gl_load_off
}

# gl_gate <gate>: runs it, logs it, appends a failure to GL_FAILED.
# Answers the gate's status (the command's, or 1 when its check failed).
gl_gate() {
  local id=$1
  gl_spec $id || { gl_log "unknown gate $id"; GL_FAILED+=($id); return 1 }
  local f=$GL_OUT/$id.txt t0=$(date +%s) rc
  gl_log "start $id (swift: $GL_SWIFT)"
  (( spec_load )) && gl_load_on
  (cd $GL_ROOT && exec gtimeout -k 60 $spec_timeout zsh -c "$spec_cmd") > $f 2>&1 &
  GL_CHILD=$!
  wait $GL_CHILD
  rc=$?
  GL_CHILD=
  (( spec_load )) && gl_load_off
  if [[ $rc == 0 && $spec_check != - ]]; then gl_check_$spec_check $f || rc=1; fi
  gl_log "end $id rc=$rc $(( $(date +%s) - t0 ))s"
  (( rc )) && GL_FAILED+=($id)
  return $rc
}
