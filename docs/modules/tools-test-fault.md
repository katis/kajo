# The tools test's fault under the sanitizer

## Status

Brief. The owner, 2026-11-22, to "Shall I brief a module that finds why
the tools test fails under the loaded sanitizer?": "Yes, brief it".
Starting commit 381f57c.

## What it is

`theToolsDevelopTheImageTheyRunIn` (`Tests/KajoCompilerTests/ToolsTests.swift`)
fails some runs of the compiler tests' bundle under ThreadSanitizer with
one line: a Process of the image stops on "MessageNotUnderstood: nil does
not understand #beginsWith:" and the step `compiledTypedThroughTheBrowser`
never holds. Three modules have counted it and none has named its sender.
This module names the Process and the sender from a failing run's own
stack, finds a condition that makes the fault come at will, and fixes the
fault where it is, if it is in Smalltalk. It is not a module that makes
the test pass: a longer wait, a retry or a guard at the test is not a fix.

## What is known

Check each before building on it.

- The line, the same in every failure: "compiledTypedThroughTheBrowser
  never held: client #open lost nil pending 0 browsers 1 hierarchy 239
  status 'compiled ToolsProbe>>probeTyped:' loop errors 0 transcript
  OrderedCollection ('Process 606 stopped (error): MessageNotUnderstood:
  nil does not understand #beginsWith:')" (`ToolsTests.swift:354`;
  `~/kajo-scratch/review-3-part-2/work/tools-count/run-head-1.txt:525`).
  The Process id differs per run (508, 549, 606). The status says the
  method was compiled; what did not happen comes after the compile.
- Counts, all on the compiler tests' bundle under the sanitizer:
  - the small fixes, part 1 (`50-review-3-small-fixes.md`): seen, not
    looked at (its Found 3);
  - the verifier's faults (`51-verifier-faults.md`): failed the `tsan`
    gate (no busy loops) on 2c13ed3; counted with twelve loops, head 0 of
    2, its starting commit 1 of 2;
  - part 2 (`52-review-3-small-fixes-part-2.md`): failed `tsan-load` 2 of
    2 on aeecb55 (the tier and the gate alone), then counted head 1 of 2,
    8c24c05 0 of 2 (`work/tools-count/summary.txt`, `run.sh` is the
    condition); d3ac36c passed its one `tsan-load`.
  So: it comes with and without the busy loops, on at least three
  commits, at a rate between 0 of 2 and 3 of 4. No count separates two
  commits. It has not been seen outside the sanitizer; nobody has looked
  for it there.
- One run of the bundle under the sanitizer and twelve loops takes 2850 to
  2950 s; the `ToolsTests` suite inside it 1270 to 1420 s
  (`work/tools-count/run-*.txt`).
- "stopped (error)" says the Process stands at a debugger stop. A standing
  stop has frames (`DebugStop`, the `frames` request, `session.open`'s
  list of standing stops). The test's failure message prints none of
  them.
- A reading, not checked (part 2's agent): `TypeService class>>classKeysOf:`
  (`types/Live/TypeService.class.st:110`), `TypeChecker>>indexKeysOfClassNamed:`
  and `forgetClassNamed:` (`types/Checker/TypeChecker.class.st:281, 299`)
  select with `beginsWith:` over a Dictionary's keys; the service has two
  locks (`lock`, `checkLock`) and a background Process
  (`userBackgroundPriority`); a caller outside `checkLock` could read a
  table the background Process is changing. Nobody has checked which
  callers hold which lock, whether `Dictionary>>keys` can answer a nil
  under such a change, or whether these are the senders at all: `tools/`
  has six more senders of `beginsWith:` and `kernel/` others.
- The image under test holds the tools and their target in one image
  (`LocalTools`); which of the types package's classes it has, and which
  Process answers the browser's accept, is part 1's to read.

## Starting positions

To be measured or read in part 1. Say where one was wrong.

1. The stopped Process's frames can be read at the failure and name the
   sender of `beginsWith:` and the receiver's source (which table, which
   slot).
2. The sender is one of the type service's key selects, run outside
   `checkLock` while the background Process changes the table.
3. The fault is a Smalltalk-level race between Processes (a preemption at
   a poll inside `keys` or a rehash), not a fault of the VM. If a key that
   was never nil in any table reads as nil (a lost object, a cleared weak
   slot, a native or fused path), position 3 is wrong and the module stops
   at part 1: that is a core module and the evidence is its brief.
4. The fault does not need the sanitizer: it needs a preemption at one
   place, and `preemptEveryPoll` or a forced yield there brings it in a
   plain debug build in seconds.
5. The step never holds because the Process that stopped was the one that
   would have made it hold (name it), not because a reply was lost.
6. Part 2's change made it no more frequent: 3 of 4 against 0 of 2 is
   within what a rate near one in two gives.

## Parts

### Part 1: name it, force it (fixes nothing)

Committed before part 2, with its section of this doc.

1. **The message.** Make the failure print what it has: for every
   standing stop at the moment `until` gives up, the Process's name and
   priority, and its frames (class, selector, the receiver's class; the
   arguments' printStrings bounded). A diagnostic of `ToolsProbe` beside
   `remoteState`, used by the test's failure line only. Check on a stop
   you make on purpose that it prints.
2. **The reading.** A table of every sender of `beginsWith:` the image
   under test can reach from the accept of a typed method and from the
   type service's recheck: the sender, where its receiver comes from, the
   lock held, the Process it runs on. And of the type service's tables:
   every reader and writer, the lock each holds.
3. **The condition.** A rule written first (its file copied with its
   time before any run): what counts as the fault (the same error from
   the same sender), the candidates in order, how many runs each gets. Go
   from cheap to dear: a kernel or types SUnit test or a `kajo` script
   with a forced yield or `preemptEveryPoll` at the suspected place; the
   `ToolsTests` suite alone; the smallest set of suites that has the
   bundle's load; the bundle under the sanitizer (48 minutes a run) only
   to get one stack if nothing cheaper gives it. A forcing switch in
   Smalltalk test code is allowed; a product class gets no test hook
   unless part 2 keeps it as a broken variant's switch.
4. **The verdict on positions 1 to 6**, each right or wrong with its
   file. If position 3 is wrong, stop here and hand back.

### Part 2: the fix

Only with a named sender and a condition that brings the fault.

- Fix where the cause is. If it is a table read outside its lock, the fix
  is the lock's rule, applied to every reader and writer of part 1's
  table in the same commit ("closing one escape, look beside it for the
  same shape"), not a nil guard in one select.
- A lock taken on the path that answers the browser is measured: the
  class-scope `diagnostics` request and an accept, before and after, on
  the Mac's development image (five interleaved runs), and the longest
  time the answering Process waits for the background Process's lock
  under a whole-image check. The main thread never waits on a
  whole-image check; if the fix would make it, stop and bring the
  choice back.
- The background Process's own stops are looked at: an error in the
  recheck must not end the service silently. Say what happens to it today
  and change it only if the fix needs it.

## Tests

Written before the fix and run on 381f57c: each "fails on 381f57c" or
"passes there".

- The forcing test from part 1, in the package that owns the code
  (`types/Tests/` or `kernel/Tests/`), failing N of N on 381f57c at its
  forced condition and 0 of N after, N at least 20.
- The lock rule as a test: every reader and writer of the type service's
  tables named in a table the test checks, in the manner of
  `ShellVM`'s table test, if the rule can be read from the source; if
  not, say why.
- Broken variant: the fix's lock left out at the one reader that part 1
  named; run by hand, the forcing test fails; its output in `broken/`.
- The tools test keeps its new failure message.

## The bar

1. A failing run's own stack names the Process and the sender; the doc
   quotes it.
2. Positions 1 to 6 each answered with a file.
3. A condition that brings the fault at will, its command in the doc, and
   the count on 381f57c under it.
4. After the fix: 0 of N under that condition, and the compiler tests'
   bundle under the sanitizer with twelve loops (`run.sh`'s condition) 0
   of 3 on the head. If the clock (below) does not allow three, say how
   many ran; the main session runs the rest.
5. No wait lengthened, no retry added, no assertion weakened.
6. The measurements of part 2 with their spread.
7. The tier's gates on the final code commit, `failed=0`, or each failure
   with its line and counted.
8. `scripts/canonical-tonel.sh --check` passes for every package changed.

## Rules of the house that bind here

From `AGENTS.md`'s lessons: a failure message prints every clause of the
condition it waited for; a rare path gets a switch that forces it before
it gets a fix; a failure seen only in the full suite is reproduced with
the suite's load; a verifier's message says what each entry is; closing
one escape, look beside it for the same shape; an unwind block covers
everything from the first state change, and the test terminates at every
poll in turn; a thin test that is not the module's is counted with both
rates; a gate failure is counted under a rule written first; a brief's
premise is measured before it is built; a hand-back's explanation is
checked against the row it explains; two Transcript sends per line
interleave; a wait that runs out is a failed check before anything reads
the result; a brief's tier is decided by where its tests live.

The tier: the diagnostic and any test in `Tests/` owe the Swift tier
(about 72 minutes, with the sanitizer once alone); a change in `types/`,
`tools/` or `kernel/` alone owes the Smalltalk tier. `just check` decides;
run its `--dry-run` first and say what it said.

The clock: the weekly run starts Monday 2026-11-23 02:00. Nothing of Kajo
is alive from 01:30 until `~/kajo-weekly/weekly.log` has a `weekly done`
after its `weekly start`. Do not start a sanitizer run after 00:30 or a
Swift tier after 00:10. If the module is not done by then, commit what is
done, say in the doc where it stands, and hand back; that is a complete
hand-back.

## Not in this module

- `randomProgramsAgreeWithTheirModel`'s "the configuration must scavenge"
  assertion, thin on its own.
- Eight workers that each intern a million Symbols.
- The reconnect test's margins; the VM's Delay timers.
- Any change under the core directories. If the cause is there, part 1's
  evidence is the deliverable.
- The checker's rules, its diagnostics, the tools' marks.

## Deliverables

- Part 1 and part 2 as separate commits on master, this doc's "As built"
  with each.
- Work files under `~/kajo-scratch/tools-test-fault/` (`part1/`, `work/`,
  `broken/`, `check/`), the raw output of every counted run kept.
- The hand-back map of `docs/PROCESS.md`.

## Open questions

Build the recommended option; bring the decision back.

1. If the cause is a table read outside its lock: one lock for the
   checker's tables, or the answering path reads a copy the background
   Process publishes whole? Recommended: the lock that exists
   (`checkLock`), unless part 2's measurement shows the answering Process
   waiting longer than one frame (8 ms); then the copy, and say so.
2. Does the diagnostic of standing stops stay in the test's failure
   message for every `until` of `ToolsTests`, or only this test's?
   Recommended: every `until`; it costs nothing until a wait runs out.
3. If the fault needs no sanitizer and a plain build can hit it, is it
   said in a release's notes? Recommended: no; the checker is in no
   release image.
