# The tools test's fault: a method seen before its source

Built 2026-11-22 by one build agent from `docs/modules/tools-test-fault.md`
(the owner, 2026-11-22: "Yes, brief it"). Commits 4f0a550 (part 1), 0ef3b1f
(part 2, the final code commit), 6fb8c5d and c744e29 (the doc). Work files
in `~/kajo-scratch/tools-test-fault/`.

## What it was

`theToolsDevelopTheImageTheyRunIn` failed some runs of the compiler tests'
bundle under ThreadSanitizer with "nil does not understand #beginsWith:".
Three modules had counted it. The brief's suspect, the type service's key
selects, was wrong.

`Behavior>>compile:classified:` installed a method and afterwards recorded
its source. The test's own probe, `ToolsProbe class>>compiledTypedThroughTheBrowser`,
runs on the main worker while the accept runs on another. It found
`probeTyped:`, ran it, read `Smalltalk sourceOf:` in the gap, got nil and
sent it `beginsWith:`. The probe's Process stopped at the error. The
helper that drives a probe then waited its sanitizer bound (150 s), longer
than `until`'s 60 s, so the test said "never held". In a plain build the
stop costs 30 s and the step then holds, which is why the fault was seen
under the sanitizer only. It is a kernel fault that needs no sanitizer and
no preemption: two workers are enough.

## Part 1

- The failure lines of the tools tests print every standing stop with its
  frames (`ToolsProbe class>>stops`), and a probe that does not end says so.
- The stack, from the forced condition
  (`part1/forced-A/run-forced-1.txt`): process 43, main, "frames [1
  Object>>doesNotUnderstand: receiver UndefinedObject] [2 ToolsProbe
  class>>compiledTypedThroughTheBrowser receiver ToolsProbe class]".
- The condition, rule written first (`part1/rule.txt`, 18:43):
  `KAJO_TOOLS_HOLD_INSTALL=1500` on the one test in a plain debug build
  holds the install 1.5 s before the source is recorded. On 4f0a550
  forced 3 of 3 fail, unforced 0 of 3.
- The bundle under the sanitizer with twelve loops on 4f0a550: 0 of 2 for
  this test. No natural failing run gave a stack.
- Starting positions: 1 right; 2 wrong (the probe, not the type service);
  3 right (Smalltalk, not the VM); 4 right in substance (a wait forces it,
  not `preemptEveryPoll`); 5 right (the stopped Process is the probe); 6
  right by mechanism (the order is older than Types 1's probe clause).

## Part 2

- `compile:classified:` records source and category, then installs; an
  install that unwinds takes the records back.
- `ClassBuilder`: `primRedefine:` with the records that follow it, and
  `primDefineClass:` with `noteDefinition:`, each inside one
  `Smalltalk registry:` block, so a reader of the records waits.
- `SourceRecordTest` (two tests, a second Process reading at the gap):
  fails 20 of 20 on 381f57c's kernel, passes 20 of 20 on the fix. The
  forced tools test: 0 of 3 on the fix. Broken variants by hand (`broken/`):
  the order put back fails the install test; the registry block left out
  fails the redefinition test.
- The bundle under the sanitizer with twelve loops on the fix: 0 of 3.
  With 0 of 2 before, this says nothing about a rate.
- Timings, release `kajo`, five interleaved runs (`work/timing/`):
  `compile:` 137 to 136 µs; a reshape 14.3 to 14.8 ms; the longest
  `sourceOf:` wait of a second Process during reshapes 3.5 to 5.9 ms,
  under the rule's 8 ms.

## Gates

`~/kajo-scratch/tools-test-fault/check/gates.log`: `2026-11-23 00:17:03
6fb8c5d check-tier done swift failed=0 4646s` (the Swift tier, chosen by
the two files under `Tests/`; 6fb8c5d changes only the doc over 0ef3b1f,
c744e29 only the doc after). Every gate `rc=0`: clean-build 22 s,
swift-test 744, tsan 3352, kernel-test 125, apps 131, new-check 271,
against 20, 711, 3230, 122, 129, 269 on aca38de. 484 and 198 tests, 0
sanitizer reports; 264 kernel tests.

The main session read the whole diff, the gates log, both rules' times and
every summary file. It ran nothing again.

## Deviations

- The forcing tests are committed with part 2 (they fail on part 1's
  commit).
- `LocalTools.probe` no longer goes through the shell tests' `run`; it
  records "did not end" with the stops. The bound is unchanged.

## Not done, not verified

- No natural failing run with the new message. That the earlier failures
  had this stack is inferred from the same error at the same step.
- No forcing test for the new-class definition gap; that fix rests on
  reading.
- No table test of the rule: it is an order of statements.
- The forcing runs and the broken variants ran in a plain debug build.

## Found, not this module's

- `removeSelector:` and a replaced method leave a reader that already
  holds the old method with a nil source. `addSelector:withMethod:` notes
  the pragma index after the install.
- An error in the type service's recheck stops its Process in a
  development image and ends it in a batch host, where later changes queue
  with nothing to drain them.
- One counted run on 4f0a550 failed the reconnect test (the known 30 s
  margin) and `anErrorWithNoClientStopsAndALaterClientFindsIt`; the agent
  had other load running, so it is not a count.

## Open questions

1. The registry's lock is held across the reshape primitive and its
   records. A second Process's longest wait rose from 3.5 to 5.9 ms.
   Recommended: as built.
2. A release's notes. Recommended: nothing; a release image compiles
   nothing.
