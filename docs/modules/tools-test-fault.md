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

## As built

### Part 1: named and forced (2026-11-22)

Toolchain: swiftly's swift.org Swift 6.4.2 first on PATH, its `clang`
(`~/kajo-scratch/tools-test-fault/env.txt`). Starting commit f2f5612 (the
brief's own commit over 381f57c; no code between them).

**The message.** `ToolsProbe class>>stops` (the test fixture,
`Tests/KajoCompilerTests/Fixtures/toolsprobe/ToolsProbe.class.st`) writes
every standing debugger stop: the Process's id, priority, main affinity,
reason and error, and its frames (16 at most), each the method, the
receiver's class and the arguments' printStrings (60 bytes each at most;
an argument that cannot be read says why). The kernel's Process has no
name; id, priority and main affinity are what names it. In
`ToolsTests.swift`, `LocalTools.standingStops` runs it, both `until`s add
it to their failure line (open question 2, as recommended: every `until`),
and `LocalTools.probe` no longer goes through the shell tests' `run`: a
probe Process that does not end within `drive`'s bound records "ToolsProbe
<selector> did not end: stops …" (before, the same case was the bare
`ShellTests.swift:150` expectation every recorded failure carried, with no
frame). `KAJO_TOOLS_HOLD_INSTALL=<ms>` (by hand) makes
`ToolsProbe class>>addSelector:withMethod:`, a class-side override in the
fixture, wait that long right after `probeTyped:` is installed: the
forcing switch, Smalltalk test code only.

**The reading.** The failing step's own probe is a sender:
`ToolsProbe class>>compiledTypedThroughTheBrowser` (since Types 1,
d62ec0b, 2026-11-17) reads
`(Smalltalk sourceOf: (ToolsProbe compiledMethodAt: #probeTyped:)) beginsWith: …`
right after `includesSelector: #probeTyped:` and the method's run, on the
probe's Process (main, priority 1, spawned by `LocalTools.probe`). The
method is compiled by the browser's accept on a request Process of the
same image (`DevSession`'s compile request, `Behavior>>compile:classified:`),
which runs on the other worker (`LocalTools` has two). That method
installs first (`addSelector:withMethod:`, primitive 97 in a stop) and
records the source after (`Smalltalk noteSource:of:` under the registry
lock), with nothing between the two that a reader could wait on. A probe
that runs in that gap sees the method, runs it, and reads a nil source.
The same gap has a second shape in `ClassBuilder class>>redefine:…`: the
primitive (`primRedefine:`) makes and installs the class's methods again,
and `Smalltalk replaceSources:of:` records their sources after; a reader
between them finds the new method under the old table's identity hash and
reads nil.

The senders of `beginsWith:` in the image under test outside its tests:

| sender | receiver from | lock | Process |
|---|---|---|---|
| `ToolsProbe class>>compiledTypedThroughTheBrowser` (fixture) | `Smalltalk sourceOf:` of a method another Process is installing | registry, inside `sourceOf:` only; the install is not under it | the probe (main) |
| `TypeService class>>classKeysOf:` (types/Live, l. 110) | `checker resultKeys` | not read here | the service's callers; on no failing stop's stack |
| `TypeChecker>>forgetClassNamed:`, `indexKeysOfClassNamed:` (l. 281, 299) | the checker's caches' keys | not read here | the recheck; on no failing stop's stack |
| `BrowserModel` l. 440 (`diagnosedSelectors`) | a reply's keys, `k isString` tested first | none needed | UI loop |
| `DebuggerModel` l. 120, `TestRunnerModel` l. 91, `ToolWindow` l. 142, `DevTools` l. 213, `DevClient` l. 275 | a reply's or a menu's String, nil tested first where nil can come | none | UI loop |
| `Behavior>>isObsolete` l. 438, `TonelWriter` l. 180, 215, `TestCase` l. 177, `TestRunner` l. 40 | a class name, a method body, a client name, a selector, a filter | none | caller's |

The type service's tables were not read further: the stop's own frames
(below) name the probe, not the service (starting position 2 wrong).

**The condition.** Rule written first:
`~/kajo-scratch/tools-test-fault/part1/rule.txt` (copied with its time as
`rule.copy.txt`, 18:43, before any run).

- A, the tools test alone in the plain debug build:
  `KAJO_TOOLS_HOLD_INSTALL=1500 swift test --skip-build --filter 'ToolsTests/theToolsDevelopTheImageTheyRunIn'`
  (`~/kajo-scratch/tools-test-fault/scripts/forced.sh`), interleaved with
  the same without the switch: forced 3 of 3 fail, plain 0 of 3
  (`part1/forced-A/summary.txt`; each forced run 30 s, the length of
  `drive`'s plain bound). The stop, quoted from `part1/forced-A/run-forced-1.txt`:

      ToolsProbe compiledTypedThroughTheBrowser did not end: stops 1 stops;
      process 43 priority 1 main true reason 'error' error
      'MessageNotUnderstood: nil does not understand #beginsWith:' frames
      [1 Object>>doesNotUnderstand: receiver UndefinedObject arg (unreadable:
      index 1 out of bounds)] [2 ToolsProbe class>>compiledTypedThroughTheBrowser
      receiver ToolsProbe class]

  (`part1/forced-A-no-diagnostic/` is the same three before the message
  existed: each only the `ShellTests.swift:150` line, as in every recorded
  failure; `part1/forced-A-frames-empty/` the message's first form, which
  looked the field up by a String among Symbols and printed no frame.)
- B, a kernel SUnit test, no test hook in a product class:
  `kernel/Tests/SourceRecordTest.class.st` with
  `SourceRecordSample.class.st`, whose class side stands still right after
  an install (`addSelector:withMethod:`) or, in a reshape, at the first
  `isMeta` the redefinition sends it after `primRedefine:` while the
  method has no source. A second Process then reads as the probe reads.
  On 381f57c's kernel (git archive, the two files copied in,
  `work/start/`): both tests fail, the compile test with 20 of 20 reads
  answering "nil does not understand #beginsWith:" and the redefinition
  test with its one read the same. The test files are committed with
  part 2, beside the fix they test.
- C, the bundle under ThreadSanitizer with twelve loops, for a natural
  failing run's own stack: see "Natural runs" below.

**The verdict on the starting positions.**

1. Right, with the new message: a standing stop's frames are read at the
   failure and name the sender and its receiver (a nil from `Smalltalk
   sourceOf:`, the registry's sources table, the slot of `probeTyped:`)
   (`part1/forced-A/run-forced-*.txt`).
2. Wrong. The sender is the test's own probe,
   `ToolsProbe class>>compiledTypedThroughTheBrowser`, reading a source in
   the gap `Behavior>>compile:classified:` leaves between install and
   record; the type service is not on the stack (same files).
3. Right: a Smalltalk-level order, not a VM fault. No key read as nil;
   the nil is `sourceOf:`'s own answer for a method whose source is not
   recorded yet, and no preemption is needed: the two Processes run on two
   workers at once (`work/start/` run of B, deterministic on a plain kernel).
4. Right in substance: no sanitizer needed; a wait at the one place brings
   it in a plain debug build at every run (A, 3 of 3) and in a plain
   kernel test (B, 20 of 20 reads). It is a wait at the place, not
   `preemptEveryPoll`, which would not hold a Process inside the gap.
5. Right: the stopped Process is the probe Process itself (main,
   priority 1), the one whose answer the step waits for; no reply was
   lost. Why the whole step gave up: `drive` waited for the stopped probe
   for its whole bound, 30 s times `driveScale` 5 under the sanitizer =
   150 s, past `until`'s 60 s, so `until` recorded "never held" after that
   one probe (the recorded failures took 191 s). In the plain build the
   same stop costs 30 s and the step then holds, so a plain-build
   occurrence shows only as the `drive` line.
6. Right by mechanism, not by count: the gap (8d's install-then-record
   order in `compile:`) and the probe's clause (Types 1) both predate
   part 2, and nothing in part 2's diff is on either path; the rate is a
   matter of when the probe's 2 ms turns fall against a compile under the
   sanitizer. No count here separates commits.

### Part 2: the records before the method is seen (2026-11-22)

**The fix, where the cause is.** The rule: a Process that can find a
method or a class finds its records (source, category, definition) with
it. Applied to every place the image makes a method or a class visible
from Smalltalk:

- `Behavior>>compile:classified:` (`kernel/Classes/Behavior.class.st`)
  records the source and the category first and installs after; an
  install left by an unwind takes both back (`ifCurtailed:`: the source
  forgotten, the old category restored or forgotten). No new lock, and
  no lock held longer: each record takes the registry lock as before.
- `ClassBuilder class>>redefine:…` (`kernel/Classes/ClassBuilder.class.st`):
  the new methods are made by the primitive, so their records cannot come
  first; `primRedefine:` and every record after it (definitions, types,
  sources, categories, the pragma index) run inside one
  `Smalltalk registry:` block, so a reader that finds a remade method
  waits in `sourceOf:` for its record instead of reading the old table.
  The class variables' bookkeeping stays outside it.
- `ClassBuilder class>>newClass:…`: the same for a new class and its
  definition (`primDefineClass:` and `noteDefinition:of:` in one registry
  block); a reader that finds the class and asks `Smalltalk definitionOf:`
  waits for it. No forcing test covers this one (a new class has no hook
  of its own before it exists); it is by reading.
- Looked at and left: `removeSelector:` removes and then forgets the
  source (a reader that took the method before the removal can still read
  nil afterwards; that is reading a method that is gone, not a method
  without its record); `addSelector:withMethod:` notes the pragma index
  after the install (a reader of a new method's pragmas by name can miss
  it for that moment; nothing reads both, and no nil comes of it).
- Not touched: the type service (its locks, its tables), the probe, the
  test's waits. No wait lengthened, no retry, no guard: the probe's
  clause is right as it stands once the kernel keeps the rule.

**Tests.** `kernel/Tests/SourceRecordTest.class.st` with
`kernel/Tests/SourceRecordSample.class.st` (Kernel package, tag Tests;
run by every kernel-test gate): `testAReaderAfterTheInstallFindsTheSource`
(20 compiles, a second Process reads each new method's source as the probe
does while the compiling Process stands right after the install) and
`testAReaderDuringARedefinitionFindsTheSource` (a reshape; the reader reads
the remade method's source while the redefining Process stands after the
primitive; the redefining Process waits for the reader 2 s at most, since
with the fix the reader waits for it). Counted with the debug `kajo`
(`scripts/count-B.sh`), 20 runs each:

| kernel | install test | redefinition test |
|---|---|---|
| 381f57c (`work/count-B-start/summary.txt`) | fails 20 of 20 | fails 20 of 20 |
| the fix (`work/count-B-head/summary.txt`) | passes 20 of 20 | passes 20 of 20 |

Each "fails on 381f57c". The failing line on 381f57c: "answers #('nil does
not understand #beginsWith:' …)", 20 such answers per run.

The forced tools test (condition A) on the fix: forced 0 of 3, plain 0 of
3 (`work/forced-A-head/summary.txt`), against forced 3 of 3 on part 1's
commit (`part1/forced-A/summary.txt`).

The lock rule as a table test (the brief's `ShellVM`-style test): not
built. The rule here is an order, "records before the method or class is
seen, or under the registry with the primitive", over three methods; a
source scan cannot tell a record before an install from one after it
without parsing statement order, and the two forcing tests fail on each
of the three places but one (the new class, by reading only).

**Broken variants, by hand** (`~/kajo-scratch/tools-test-fault/broken/`,
never committed): `order` puts the install back before the records in
`compile:classified:` (`order.diff`): the install test fails, "answers
#('nil does not understand #beginsWith:' …)" (`order-run.txt`); `lock`
runs the redefinition's block without the registry (`lock.diff`): the
redefinition test fails, "answers #('nil does not understand
#beginsWith:')" (`lock-run.txt`). Each fails only its own test.

**The background Process's own stops.** Today an error in the type
service's recheck (`TypeService class>>drain` on its `run` Process) is an
unhandled error of that Process: in a development image whose host lets a
debugger come it stops there, standing, with "Process N stopped (error)"
on the Transcript and a `process.stopped` event; the drain's `ensure:`
runs only when the stop is ended, so `busy` stays true and waiters wait
until then. In a batch host the error is reported and the Process ends
(`UnhandledError>>reportAndEnd`), the `ensure:` runs, and later changes
are queued with no Process to drain them. Not silent in a development
image; quiet in a batch host. The fix does not need a change there, and
none is made.

**Measured** (rule first: `~/kajo-scratch/tools-test-fault/work/timing/rule.txt`,
copied with its time before any run; raw lines `runs.txt`, table
`summary.txt`). The development image (kernel, tools, types) of 381f57c's
kernel and of the fix's, each with the scratch-only test `RegistryTiming`,
the same release `kajo` built from the working tree, `kajo test --test
RegistryTiming>>testTimes --workers 2`, five runs a side interleaved, the
machine otherwise idle (20:35, after the natural runs; no thermal state
is logged by a headless `kajo test`, and none was read). Median (min to
max) of the five:

| | 381f57c | the fix |
|---|---|---|
| `compile:` of a new method, µs (mean of 40) | 137 (135 to 137) | 136 (135 to 141) |
| a reshape of a 41-method class, µs (mean of 10) | 14283 (14083 to 14683) | 14843 (14242 to 14948) |
| longest single `Smalltalk sourceOf:` of a second Process during the reshapes, µs | 3516 (3483 to 3682) | 5906 (5629 to 5937) |

The compile path, which took no lock, is within the base's spread. The
reshape's lock now covers the primitive as well as the records, and the
longest registry wait a reader sees during a reshape rose from 3.5 to
5.9 ms (the pragma index's rebuild, image-wide, ran under the same lock
before the fix too; its share of either was not measured). Under the rule's 8 ms (one frame), so
the lock across the primitive stays as built; open question 1's choice
(the type service's `checkLock` or a published copy) does not arise: the
fix does not touch the type service, so its answering Process's wait
under a whole-image check is not measured here. The base image lacks the
two `SourceRecord` classes (the timing ran against the fix's kernel
otherwise as committed).

**Natural runs** (condition C; `~/kajo-scratch/tools-test-fault/scripts/natural.sh`,
review-3-part-2's `run.sh` condition: the compiler tests' bundle under
ThreadSanitizer with twelve `gtimeout 3300 yes` loops; raw
`part1/natural/run-p1-*.txt`, `part1/natural/summary.txt`). On part 1's
commit 4f0a550: 0 of 2 (run 1 18:54 to 19:45, run 2 to 20:33). No natural
failing run's stack was got, so bar 1 rests on the forced runs' stacks
above, whose error and step are those of every recorded natural failure.
Run 1 failed on two tests that are not this module's and printed the new
line in one of them: `theToolsReconnectAfterADroppedLink` ("remoteReady
never held: … status 'class.hierarchy got no reply within 30000 ms' …
stops 0 stops", the known class-hierarchy margin of
`50-review-3-small-fixes.md`) and
`anErrorWithNoClientStopsAndALaterClientFindsIt` ("no reply to
session.open within 30.0 s"); during that run I also built the release
`kajo` and ran the kernel tests, so its load was above the condition's,
and they are not counted. Run 2 passed whole.

**After the fix, the bundle under the sanitizer with twelve loops**
(the same script and build; the tree overlaid with 0ef3b1f's kernel/ and
docs/ at 20:33, `diff -r` against `git archive 0ef3b1f` identical outside
`.build`, the Swift sources being equal between 4f0a550 and 0ef3b1f): 0
of 3, and no other issue in any of the three (runs 3 to 5 of
`part1/natural/summary.txt`: 20:35 to 21:22, to 22:10, to 22:59, each
`rc=0 issues=0`). With 0 of 2 on part 1's commit, these counts show
nothing about a rate by themselves; the fault's evidence is the forced
counts above.
