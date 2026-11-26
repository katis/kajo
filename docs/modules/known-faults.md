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
