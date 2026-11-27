# The VM's known faults

## Status

Brief, 2026-11-27. Not built.

The owner, 2026-11-25: "I need you to independently get the VM and the
checks to a good shape so we can do other stuff next. I trust you with
these fiddly details, keep in mind that this needs to be reliable, but we
can't spend a whole week (hyperbole) running just checks. Go ahead and
implement and fix what is needed."

This is the second of the two modules the main session made of that. The
first (`docs/decisions/56-check-time.md`) made the checks shorter. This
one closes the faults that the records list as found and not briefed. It
is a core module: it owes the core tier once, on its final code commit.

The owner delegated the decisions. Each one made here is listed at the end
so the owner can reverse it.

## What it is

Seven items. Two are in the core, four are Smalltalk, one is measured
only. Each has a part 1 that reproduces or measures before anything is
changed, and each can end at "measured, not a fault, not changed" under a
rule written first.

1. The VM's Delay timers on a queue of their own (approved by the owner
   on 2026-11-23, after a counter of how late a Delay fires).
2. Eight workers that each intern a million Symbols: every `asSymbol`
   fails after 390 s.
3. `removeSelector:` and a replaced method leave a reader that already
   holds the old method with a nil source; `addSelector:withMethod:` notes
   the pragma index after the install.
4. An error in the type service's recheck ends its Process in a batch
   host, and later changes queue with nothing to drain them.
5. A class removal that is refused because another Process holds the
   class on its stack names no Process.
6. A frames reply compiles every frame's method again.
7. Measured only: a main turn that acknowledges a young round can overrun
   its budget (0.219 ms against 0.2).

## What is known (check these before building on them)

- Item 1: `startDelay` in `Sources/KajoVM/Processes/External.swift` arms
  each Delay with `DispatchQueue.global().asyncAfter`. The host's timers
  had this shape and fired 4.7 to 26.8 s late in the sanitizer suite, all
  overdue timers in the same millisecond; on a serial queue of their own
  they fired 57 ms late (`docs/decisions/50-review-3-small-fixes.md`).
  A Delay's timer holds the VM's life cell (`VMLife`,
  `docs/modules/delay-outlives-vm.md`); that rule stays. Gate speed
  wrote that five kernel-test VMs starved the timers a client waits on
  and that this limits the number of kernel-test parts
  (`docs/decisions/34-gate-speed.md`); check time then measured 0
  failures at 2, 3, 4 and 6 parts.
- Item 2: `docs/modules/review-3-small-fixes-part-2.md`, "Found, not this
  module's". The program is in
  `~/kajo-scratch/review-3-part-2/part1/symbols/` (if it is still there),
  run as `kajo run symbols.img --workers 8 --slice-ms 0`; the outputs
  `part1/weak/symbols-8.txt` and `symbols-8-again.txt`. The message is
  "Unhandled PrimitiveFailed: a primitive failed in String>>asSymbol",
  eight times. A million on one worker passes with `cycles=0`: a Symbol
  is an old allocation and a million of them start no marking cycle. A
  million split over eight workers passes. Not investigated. The lessons
  that have this shape: "every allocation path decides the collector's
  trigger" and "a trigger must watch every resource a fallback can
  exhaust". The insert is `Machine.internSlow` under `internLock`
  (`docs/modules/symbol-interning.md`); the table is weak.
- Item 3: `docs/decisions/53-tools-test-fault.md`, "Found". The tools
  test's fault fixed the install order of `compile:classified:` (records
  first, then the install); the removal and the replacement were left.
- Item 4: the same record. `types/Live/TypeService.class.st`.
- Item 5: `docs/decisions/56-check-time.md`, the thin waits, item 5. The
  refusal comes from the remove primitive (147,
  `ObjectModel/LiveClasses.swift`), which refuses while any frame runs a
  method of the class. The tag test's failure line could not say who.
- Item 6: the same record, "Found". The third review's small fixes kept a
  stop's frame variables per method (`DebugStop>>variablesOf:`); check
  time still read frames replies of 12 s quiet under the sanitizer and
  28 to 49 s beside the VM tests. Which is right now is not known.
- Item 7: `MainThreadTests.aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond`
  failed 1 in 15 loaded runs, then 1 in 100 forced; the failing turn
  acknowledged a young round (module 7's 28 to 44 µs acknowledgement).
  The test prints its three largest turns now.

## Starting positions (candidates; say where one was wrong)

- Item 1: one serial queue for a VM's Delay timers, made with the VM and
  ended with it, at a QoS decided from the counter. One queue for the
  process is the other shape. The counter is a relaxed sum and maximum of
  (fired - due), on the run line.
- Item 2: the entry table or old space runs out because no cycle starts,
  and the primitive answers a failure where an allocation would stall or
  fall back. If so the fix is the trigger and the stall on this path, not
  a retry in Smalltalk.
- Item 3: the source of a removed or replaced method is taken away after
  nothing can reach the method through the class, and a reader that holds
  the old method gets its old source or a clean answer, never nil.
- Item 4: the recheck runs under a handler that records the error, keeps
  the Process and drains the queue; the count of such errors is readable.
- Item 5: the refusal's reason names the Process (its id and the method
  of the frame). A refusal is a value, not a trap.
- Item 6: the reply reads what the stop already keeps.

## Parts

Part 1 measures and reproduces only, and is a commit of its own (the doc).
Before any number, write the rules to `part1/rules.txt` and copy the file
with its time: for each item, what result means "fix", what means "not a
fault", and what the fix's evidence will be.

- 1a. The lateness counter. This is the one code change part 1 may make
  in the core, because the owner asked for the counter first; it is a
  commit of its own. Then: how late a Delay fires alone, under twelve
  loops, in the kernel tests at three and six parts, and in the loaded
  sanitizer suite.
- 1b. Reproduce item 2 with the run line's records: what ran out, which
  allocation failed, the cycles, the fallbacks, the stalls. A shorter
  reproduction is wanted (a smaller heap, fewer Symbols): 390 s a run is
  too long for a test.
- 1c. Items 3 to 6: a forcing test or switch for each, run on the
  starting commit, with its count.
- 1d. Item 7: the turn's time by phase for the turns that acknowledge a
  round, alone and loaded, 100 runs. Nothing is changed in this module;
  the rule says what the next step would be.

Part 2: the Delay queue. Part 3: the Symbols. Part 4: items 3 to 6.
Part 5: the gates.

If part 1 shows that the Symbols fault needs a new protocol (a change to
a model under `models/`), stop that item there, write what is known and
hand it back as a brief of its own. The other items go on.

## Tests

- A test for each fix that fails on the starting commit, with its count
  there. A test that cannot fail there says so and has a broken variant
  run by hand, its output kept in `broken/`.
- Item 1: a Delay under a full global queue fires within a bound that is
  a value against a bound through `printMargin`, not a clock on the
  suite. The end-of-VM tests (`DelayEndTests`) pass unchanged.
- Item 2: the short reproduction as a suite test at a tier size; the
  full one by hand, quoted.
- A new primitive or a changed one is added to `ExtremeIntegerTests`
  where it takes an integer. A new test switch has a row
  (`SwitchTableTests`). A new sized test has a row (`sizedTests`).
- A model changes in the same commit as its protocol.

## The bar

1. The rules file is older than every number it decides.
2. Each of items 1 to 6 is fixed with its evidence, or is "not a fault"
   under its rule, or is stopped with what is known. Nothing is fixed by
   a longer wait, a retry or a weaker assertion.
3. `just check` on the final code commit: the core tier, `failed=0`,
   into `~/kajo-scratch/known-faults/check`. The A/B table read on every
   kernel, not only on the tier's exit status. `just arc-check` passes.
   The matrices' `--bar` columns read over every row.
4. The loaded sanitizer gate three times on the final commit, rc=0, 0
   reports, the margins tables with no PAST row.
5. The gate times beside check time's (`~/kajo-scratch/check-time/`).

## Rules of the house that bind here

From `AGENTS.md`: a timer handed to a queue holds what it will signal; a
lifetime is decided under a lock in a cell that outlives the object;
idle threads wait untimed (a queue of timers must add no timed wait to an
idle VM: measure the idle wakeups before and after); every allocation
path decides the collector's trigger; a fallback carries its record; a
refusal is a value; what other workers can find is complete when it
becomes findable; a slow path stays out of the dispatch loop; the
toolchains differ on which Darwin calls are unsafe (`just ios-check` and
`just apps` before the long run); a stop per operation is measured at 8
workers.

## Not in this module

- A tier size for the VM tests under the sanitizer, and any other change
  to the gates.
- The turn overrun's fix.
- The bucket scan's cost at a million Symbols.
- Anything user-visible.

## Deliverables

The commits, this doc's "As built", the tests, and the hand-back map of
`docs/PROCESS.md`.

## Decided under the owner's delegation (reversible)

1. The seven items are one module with one core-tier run.
2. Item 7 is measured and not fixed here.
3. A fault that needs a new protocol is handed back, not built here.

## Open questions

1. The Delay queue: one per VM or one per process? Recommended: one per
   VM, unless part 1 shows a cost.
2. The Symbols fault at a size no app reaches: fix, or record as a known
   limit? Recommended: fix when the cause is a missing trigger; record
   when it needs a new protocol.

## As built

Built from 7ba9643 by one build agent, 2026-11-27 onwards. Toolchain:
swift.org 6.4.2 through swiftly, first on PATH, its `clang` too
(`~/kajo-scratch/known-faults/env.txt`). Work files in
`~/kajo-scratch/known-faults/`. The rules of part 1 were written at 00:48:51
on 2026-11-27, before any number (`part1/rules.txt`, copied with its time as
`part1/rules-copy-20261127-004854.txt`, `part1/rules-stamp.txt`).

### Part 1a: the lateness counter (its own commit)

Each Delay's timer notes fired minus due, both on the uptime clock, the
fired time taken where the timer's block begins: `DelayLateness` in
`Sources/KajoVM/Processes/External.swift`, kept in `VMLife`'s state under
the lock the timer takes anyway (not a relaxed atomic as the brief's
candidate had it: the lock is already there, and the cell outlives the VM, so
the counter is readable after `destroy`). `VM.delayLateness` reads it. The
run line carries `delaysFired`, `delayLateMeanMs`, `delayLateMaxMs`,
`delaysLate10ms` and `delaysLate100ms`; the gc summary event `delaysFired`,
`delayLateSumUs`, `delayLateMaxUs`, `delaysLate10ms`, `delaysLate100ms`;
`kajo test` prints them on a line of its own and each kernel test part on its
`kernel part N:` line.

### Part 1: what was measured and reproduced (before any fix)

Every number below names its file under `~/kajo-scratch/known-faults/`.
The starting code was built in a scratch copy of 183b5db (7ba9643 plus the
counter), `work/src-183b5db/`. The forcing tests of items 3 to 6 are
scratch SUnit classes (`part1/forcing/KnownFaults/`), built into an image
of that copy's kernel and types and run by `kajo test`.

**Item 1, the Delay timers.** Lateness is fired minus due.

| setting | Delays | mean ms | max ms | 10 ms late | 100 ms late | file |
|---|--:|--:|--:|--:|--:|---|
| A alone, `kajo run`, 8 workers, 5 runs | 800 each | 3.6 to 4.7 | 10.1 | 15 to 56 | 0 | `part1/item1/ab-before.txt` |
| B twelve busy loops, 5 runs | 800 each | 3.2 to 4.2 | 11.5 to 18.3 | 20 to 47 | 0 | same |
| C kernel tests, 3 parts | 9 to 1031 a part | 1.0 to 2.3 | 5.0 | 0 | 0 | `part1/item1/kernel-parts-3.txt` |
| C kernel tests, 6 parts | 0 to 1300 a part | 1.2 to 1.7 | 5.2 | 0 | 0 | `part1/item1/kernel-parts-6.txt` |
| D `tsan-load` (rc=0, 2548 s, 0 reports) | 128 to 1409 a part | 1.0 to 2.0 | 22.7 | 2 | 0 | `part1/item1/tsan-load/` |

Alone the lateness tops out at 10.1 ms in every run: that is GCD's timer
leeway (coalescing), not a queue waiting for a thread. The forcing test
(`aDelayFiresWhileTheGlobalQueueIsFull`: the default global queue held full
by 48 spinning blocks and a canary that has not run, a 50 ms Delay) passed
3 of 3 on the starting code (`part1/item1/full-queue-before/`): the Delay
fired 1.1 to 5.7 ms late while the canary still waited. The host's timers
on the same queue never fired in 20 s on 0b53285; a Delay's do. Why the two
differ is not established (both are `asyncAfter` on `DispatchQueue.global()`).

Under the rule this is neither "fix" (no Delay 100 ms late, the forcing
test passes on the starting code) nor "not a fault" (D's maximum, 22.7 ms,
is above the 20 ms the rule set for it): the rule did not decide. Decided
here: nothing is built, because the one condition that would justify the
queue, a Delay waiting behind a full global queue, does not happen; the
counter stays on the run line and in the gates, and the forcing test stays
in the suite as a guard. The queue as written (`VMLife.timers`, a serial
queue per VM at user-initiated) is kept in `work/queue-not-built.patch`.
Open question 1 is answered by that: neither shape.

**Item 2, eight workers and a million Symbols each.** Reproduced on the
starting code with the failure caught (`part1/item2/symbols-8.txt`, release,
`--workers 8 --slice-ms 0`, 104 s): every worker's `asSymbol` failed, the
first failures summing to 4 012 060 (about 501 500 each), with
`symbolsInterned=4012052 primitiveFailures=8 cycles=0 cyclesDone=0
fallbacks=0 stalls=0 weakSlotsNiled=0 oldEndMB=207.7 internBucketFilled=51`.
The table is 1024 buckets of at most 4095 slots (4 193 280); a Symbol is
old at birth and a dead one's weak slot is nil only after a collection has
marked; 208 MB of old space started no cycle, and the first bucket to reach
4095 slots failed the primitive (`growBucket`, "the bucket is at its
largest"). A missing trigger, so "fix" under the rule, and the fix needs no
change under the intern lock (part 3). The short reproduction: buckets of at
most 4 slots, eight Processes of 2000 Symbols each, on the starting code with
only `maxBucket = 4` changed (`part1/item2/short-before/`): 12 044 of 16 000
failed, `cycles=0`, 3 of 3.

**Items 3 to 5** (`part1/forcing/before/`, 5 runs; item 4 3 runs):

| item | forcing test | starting code |
|---|---|---|
| 3a | a held method replaced, its source read | nil, 5 of 5 |
| 3b | a held method removed, its source read | nil, 5 of 5 |
| 3c | a pragma reader at the install (hook after primitive 97, 2 s) | `#()`, 5 of 5 |
| 4 | a recheck that raises (a change naming 42), then a valid change, in `kajo test` | Process ended (`alive=false`), the change never checked, 3 of 3 |
| 5 | another Process holds the class in a temporary while it waits | "another Process holds KFRemovable on its stack: try again when it has let go", 5 of 5 |

So 3, 4 and 5 are "fix".

**Item 6, a frames reply.** A stop over 35 frames of 33 methods
(`part1/item6/`; cold is the first reply, warm the second in the same stop,
new stop the first reply of a second stop over the same frames, compile the
time of `Compiler frameVariablesOf:` alone over the 33 methods):

| build | cold | warm | new stop | compile |
|---|--:|--:|--:|--:|
| release | 38.1 to 38.8 ms | 1.7 to 1.8 | 38.1 to 38.6 | 36.2 to 36.4 |
| debug | 0.93 to 1.05 s | 0.042 to 0.043 | 0.96 to 1.06 | 1.00 to 1.14 |
| ThreadSanitizer (debug, verify=all) | 26.5 to 27.3 s | 1.25 to 1.28 | 26.7 to 27.3 | 26.1 to 27.0 |

A new stop takes 21 to 23 times the warm reply and compiling is 94 to 98
percent of it: "fix" (the variables kept per method across stops).

**Item 7, measured only** (`part1/item7/`, `part1/item7.out`; the
turn-overrun test in the scratch copy's debug build, 100 runs alone, then
100 under twelve busy loops; the three largest turns of each run by CPU
overrun past the 1 ms budget):

| | runs passed | median of the maxima | largest | largest turns with acks > 0: past 0.1 ms | with acks = 0: past 0.1 ms |
|---|--:|--:|--:|--:|--:|
| alone | 100 of 100 | 0.020 ms | 0.081 ms | 0 of 9 | 0 of 291 |
| loaded | 100 of 100 | 0.076 ms | 0.169 ms | 9 of 72 (12.5 %) | 17 of 228 (7.5 %) |

No run passed 0.2 ms (check time's one failure in 100 was 0.219). Turns
that acknowledged a round pass 0.1 ms 1.7 times as often as turns that did
not, under the rule's three times: the overrun is not the
acknowledgement's. The next step, under the rule, is a turn profile by
phase (the poll interval and the slice's end), not the acknowledgement's
place; nothing is changed here.

### Part 2: the Delay timers (nothing built but tests)

The queue is not built (part 1). `Tests/KajoVMTests/Processes/DelayQueueTests.swift`:
`aDelayFiresWhileTheGlobalQueueIsFull` (the guard; its lateness through
`printMargin` as `delay.globalQueueFull`, ceiling 1000 ms; it passed 3 of 3
on the starting code and cannot fail there) and
`theLatenessCounterNotesEveryDelay`. `DelayEndTests` are unchanged and pass.
No idle-wakeup measurement was needed: nothing that runs changed.

### Part 3: the Symbols (item 2)

`Machine.internSlow` (`ObjectModel/Strings.swift`): `growBucket` answers
`grown`, `noRoom` or `atLargest`. At `atLargest`, outside the intern lock
and holding no Symbol (as before, a Symbol made for nothing is discarded
first), `bucketAtLargest` decides with the allocation stalls' own rule: a
background worker stalls for the collector, resource `symbols`
(`StallResource.symbols`, no sweep stop for it: the holes come with the
final mark's weak slots), the stall starting a cycle when none runs; a
stall a cycle justified, the main and the host worker, and a VM with no
marker thread take one full collection in a stop, counted as a fallback of
cause `symbols` (`FullCause.symbols`) with its requester, avoided when the
bucket has a hole in the stop. The insert then looks again; it fails only
when the bucket had no hole in the stop right after a full collection (a
table full of live Symbols). The first version looked again once and then
failed: in the short reproduction other workers took the holes first and 2
of 16 000 failed after three justified stalls; the rule is now "a
collection left it full", which is a fact, not a count.

Nothing changed under the intern lock or in the order of the lookups, the
growth or the publication, so the model (`models/Sources/SymbolInterningModel`)
is unchanged: waiting outside the lock is what `allocateOld` already did
on the same path.

New run-line fields: `stallsSymbols`, `stallSymbolsMs`, `fallbacksSymbols`.
Test switches: `VMTestSwitches.symbolBucketMax` (not a broken variant: a
bucket's largest size, so 4096 Symbols fill the table) and
`symbolFullFailsAtOnce` (the broken variant, the starting code's path), with
rows in `SwitchTableTests`. `SymbolTable.grownBucketSize(_:max:)`.

Tests (`Tests/KajoVMTests/ObjectModel/SymbolTableFullTests.swift`, buckets
of 4): eight Processes on seven background workers intern and drop 16 000
Symbols, none fails (36 to 93 stalls, 0 or 1 justified, 0 unjustified
fallbacks; 3 runs); with no marker 9 to 11 full collections of cause
`symbols`, none fails; the broken variant fails 12 044 of 16 000 (the
starting code with `maxBucket = 4`: 12 044, `part1/item2/short-before/`);
2850 live Symbols past the room still fail (215 nil answers) after one
collection each. The full program by hand on the fix
(`work/item2/symbols-8-fix1.txt`, release, 8 workers):
`checksum=0 symbolsInterned=8000000 primitiveFailures=0 cycles=1 cyclesDone=1
stalls=1 stallsSymbols=1 stallSymbolsMs=14.258 fallbacks=0 oldEndMB=134.4`,
236 s (the bucket scans at four million Symbols, not in this module).

### Part 4: items 3 to 6

- Item 3. `Smalltalk retireSourceOf:` takes a replaced or removed method's
  source out of the sources table and keeps it in a `WeakIdentityTable`
  (new, `kernel/Collections/`: keys weak, values strong, pruned when a
  record is added, a scan, an optional limit) for as long as something
  holds the method; `sourceOf:` reads it there when the table has none;
  `retiredSourceCount`. `compile:classified:` and `removeSelector:` retire
  instead of forgetting. `addSelector:withMethod:` and `removeSelector:` run
  the primitive and the pragma index's note inside one `Smalltalk
  registry:` block, the lock the index's readers take.
- Item 4. `TypeService class>>run` drains under `on: Error do:`; the
  error is counted (`errors`) and its text kept (`lastError`), the Process
  goes on; `isAlive`. The changes of the failed recheck are not checked
  again until they change (said in `errors`' comment).
- Item 5. Primitive 147's refusal for a class held on another Process's
  stack names the Process and the method of the frame whose words hold
  it: "the Process 4 holds KFRemovable on its stack
  (KFHolder>>hold:until:): try again when it has let go"
  (`frameHolding` in `ObjectModel/LiveClasses.swift`, which walks the
  caller links and answers nil, naming the Process only, when they do not
  lead there).
- Item 6. `Compiler class>>frameVariablesOf:` keeps each method's frame
  variables in a `WeakIdentityTable` of at most 1024 methods, found outside
  `Smalltalk registry:` and kept under it; the old body is
  `findFrameVariablesOf:`.

Tests: `kernel/Tests/KnownFaultsTest.class.st` (six tests, with
`KnownFaultsSample`) and `TypeServiceTest>>testAnErrorInARecheckIsCountedAndTheServiceGoesOn`.
On the starting kernel (`part1/new-tests-before/`, 5 runs) the six fail or
error 6 of 6 each run (the retired-count test errors: its selector is new);
after, 270 of 270 kernel tests pass in release at `verify=off` and at
`verify=all` (`work/kt/`), and the three TypeService tests pass. The
scratch forcing tests after (`work/forcing-after/`, 5 runs): 3a, 3b, 4, 5,
6 pass 5 of 5; 3c's scratch version compared the pragma's keyword with the
method's selector (a test bug, fixed in the committed test) and read
`#(#kfMark)`, one pragma found, against `#()` before. Item 6 after: new stop
1.8 ms against 38.6 before, warm 1.75 (release).

### Before the tier

- `just arc-check` on 7bc4db9: "OK: no retain or release on the checked
  paths; the dispatch loop is one jump table" (`work/pre/arc-check.txt`).
- The aligned A/B against 7ba9643 (`work/pre/ab/table.md`, five runs a
  side, checksums the same): time 0.956 to 1.012, cycles 0.991 to 1.004,
  instructions 0.999 to 1.006 on every kernel at 1 and 8 workers. Nothing
  on the dispatch loop, the send or the allocation fast path changed.
- The changed and new Swift tests once under ThreadSanitizer with twelve
  busy loops at full size (`work/tsan-changed/`): every one passed, 0
  reports; `liveSymbolsPastTheTablesRoomStillFail` took 62 s there (4.3 s
  plain), the stalled test 10.8 s. The kernel parts there: one Delay 96.5
  ms late (part 2), none 100 ms late.
- `TypeCheckerTests.theTypesPackageBuildsAndItsTestsPass` counts 34 SUnit
  tests now (33 before; the new TypeService test).
