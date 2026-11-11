# Module 8c: Processes saved in the image

Status: built 2026-11-04. The owner's decision "images hold Processes"
(ADR 0009, Built (8a)). New: `Sources/KajoVM/Processes/SavedProcesses.swift`
(the save, primitive 142, the poll trigger, the resume),
`Sources/KajoVM/Loader/SavedProcessRules.swift` (the loader's rules), the
kernel's `Smalltalk snapshot:` and Delay list (`kernel/`), the model
`models/Sources/SaveHoldModel/` (`docs/models/save-hold.md`). Changes to
modules 2, 3 and 8 below. Tests in `Tests/KajoVMTests/Processes/`
(`SavedProcessTests`, `SavedProcessLoaderTests`), the random programs'
snapshot mode (`Tests/KajoVMTests/Workers/RandomPrograms.swift`),
`Tests/KajoCompilerTests/SnapshotScenarioTests.swift` with its Smalltalk
fixture, `kernel/SnapshotTest.class.st`.

## What it hides

- What an image holds of a running system: which Processes, in what form,
  and what the scheduler needs to continue them. The form is independent
  of addresses, worker count and the order the loader rebuilds things in.
- How a save brings every Process to a point where its registers are
  exact while the others keep running until they get there.
- What the loader checks before a saved frame may run: every saved word is
  untrusted input.
- What the kernel re-arms on resume (the Delays' timers) and what the VM
  does (the finalization Semaphore, the records, the queues).

## The saved form

An image with saved Processes has a **scheduler state** at special object
8 (`SpecialObjects.scheduler`; nil in an image without, and set back to nil
once a VM has resumed them). The image format's version is 2 (9 special
objects); version 1 images (8b's, 8 special objects) still load, and are
written back as version 1, but cannot save Processes.

| scheduler state slot | |
|---|---|
| 0 queues | an Array of 12: the six ready queues' heads, then their tails, nil for empty (`queueIndex` order) |
| 1 finalization | the Semaphore the VM signals when ephemerons are queued, or nil |
| 2 processes | an Array of chunks; each chunk an Array of pairs: a Process and its **saved stack** |
| 3 saver | the Process that sent `snapshot:` (resumes after the send with true), or nil for a save the VM made at a poll (tests) |
| 4 nextId | the next Process id the saving VM would have given |

| a saved Process | |
|---|---|
| the Process object | as it is: priority, state (ready or waiting, never running), waitingOn, affinity, next, sp, pc, fp, hdr, result (nil), exitSemaphore, id; `record` written as -1 |
| its saved stack | an Array of chunks, each an Array of 4095 words but the last, holding the stack words `[0, sp]` verbatim |

Every word on a stack is already a valid oop or a SmallInteger
(receivers, arguments, temps, operands, methods, closures, caller pc, fp
and hdr as indices and offsets, context words), so the words are copied as
they are: no frame is rebuilt, no Context de-materialized, and a
materialized Context keeps its frame index. Arrays rather than a sealed
class: nothing in Smalltalk can reach them (special object 8 is not
reachable from the image, and is nil again once resumed), and the heap
verifier and the collectors already cover every word of an Array.
Terminated Processes are ordinary objects (state 3, record -1, in no
list) and may be anywhere in an image (provisional, question 3).

Not saved: the record index, the worker a Process runs on, `runnableSince`,
`hopStart`, the stuck report, pending external signals (the save drains
them first, so the image and the running system agree), and outstanding
`delay:signal:` timers (the kernel re-arms them).

## The save

`Smalltalk snapshot: aPathOrNil` (kernel) sends primitive 142
(`savePrimitive`); `VMConfig.snapshotAtPoll` (tests, `kajo run
--snapshot-at`) makes the n-th slow poll save the same way. Both call
`saveImageWithProcesses(vm, w, form)`:

1. **Hold the scheduler.** Under the scheduler lock, `saveHold` (refused
   if another save holds it: the primitive fails); its mirror
   `vm.saveHold`, a relaxed atomic, and the flag's bit 0, so every poll
   takes its slow path, as module 4 keeps the bit for a due full
   collection. While held, `dequeueLocked` answers nothing and idle
   workers wait (their untimed wait's predicate includes the hold).
2. **Every other Process leaves its worker at a poll.** `pollSlow`, after
   its park, reads the mirror: held, the running Process is put back at
   the end of its ready queue exactly as a preemption puts it (module 3's
   saved-pc conventions: the send rewound, or the jump's target), and the
   worker runs nothing more. Its registers in its Process object are then
   exact.
3. **Wait.** The saver waits in module 7's `waitServicing` (servicing
   rounds, parking in other workers' stops) until no other main or
   background worker is inside the VM; each leaves once its Process is
   back in a queue and nothing can be dequeued.
4. **Stop.** Module 8a's method-install stop is the model: `stopWorld`,
   every other worker parked. The stop first checks that no record but
   the saver's runs on a worker (if one does, the stop ends and the saver
   waits again: `snapshotRetries`; the model shows it cannot happen while
   dequeue refuses, so it is a verifier). Then: drain the external signals;
   module 1's collection (promote-all first, so nothing young and no
   garbage goes into the image; the entry table's peak still sets the
   image's size, the 8b lesson); copy every live Process's stack words
   into Arrays hung from special object 8 at once (a root, so an
   allocation that collects keeps them); write the slots the image sees
   differently (every saved record -1; the saver ready at the back of its
   queue, its registers the resume point, after the primitive with its
   receiver and argument replaced by true, or at its poll rewound); take
   module 1's snapshot and the method table; put back every slot it
   changed; nil special object 8; release the hold in the stop (so the
   stop's end clears the flag's bit).
5. **Release.** Broadcast the idle workers' condition under the scheduler
   lock, wake the main worker if a main-affine Process is ready. The
   running system answers false.

Is the hold a new cross-thread protocol? Yes: a save is a stop of the
scheduler, not of the world, and module 8a's install stop alone would
catch other workers mid-instruction (in an allocation's stop, a young
collection's wait, a primitive's own stop), where no register set is a
resume point. `docs/models/save-hold.md` model-checks it: no save sees a
Process mid-slice, every Process finishes; the stop's check, the poll that
leaves and the release's broadcast each break a claim when turned off.

Frame pins: module 1's snapshot strips frame pins in the bytes it writes
(unchanged) and its loader refuses them; the running system keeps its own.
At the save's stop no worker runs a Process, so no frame holds an address.

The image goes to the file the String names (written after the stop, in
a module 7 blocking region), or for nil to the VM's host
(`VM.takeSavedImages`, the last eight). The primitive fails when the file
cannot be written; the save happened all the same.

## The load and the resume

`Image.load` runs module 1's snapshot loader, `verifyImage` (8a's rules,
now with Processes, Semaphores and live Contexts collected in its walk
over every object) and then the saved-Process rules below, all before
anything runs, all or nothing. A `VM` over an image with saved Processes
installs them in its initializer, before any worker starts
(`installSavedProcesses`, on the host worker): per Process a record, a
malloc'ed stack of `stackWords` doubled until it holds every saved frame's
deepest operand (`hdr + 5 + maxStack + 8`) and 64 words past sp, the words
copied back, `record` set; the ready queues from the scheduler state; the
next id; the finalization Semaphore registered as a pending root and, if
the finalization queue is not empty, signalled once (its signal was not
saved); special object 8 set to nil. The record table grows to hold every
saved Process. The resumed Processes are rooted for the host
(`VM.resumedProcesses`, `resumedSaver`).

`kajo run image.img` with saved Processes resumes them instead of sending
the entry point, runs main-affine ones in turns on its thread, and ends
when nothing can happen without the host (`VM.isQuiescent` twice in a row:
no Process ready or running, no external signal queued, no Delay
outstanding): Processes still waiting then are terminated. The checksum is
the sum of what the resumed Processes that ended answered. `kajo test` on
such an image refuses (provisional, question 2). Images without saved
Processes start at the entry point as in 8b.

The kernel's side: `Smalltalk snapshot:` takes each pending Delay's time
left (`Delay prepareSnapshot`), sends the primitive, and on true runs
`Smalltalk resumeAfterSnapshot`: `Delay resumeAfterSnapshot` arms each
pending Delay's timer again for the time it had left (provisional,
question 1: the time on disk is not counted), `Ephemeron
resumeAfterSnapshot` makes sure the finalization Process exists. A Delay
registers itself with its class while it is waited on (`Delay>>wait`,
unregistering in an `ensure:`), under a Mutex. The Transcript and the
event stream need nothing: their primitives reach the new host.

## The loader's rules

`verifySavedProcesses`, each refused by name and each with a corrupt
image in `theLoaderRefusesASavedProcess` (33 cases, the message checked):

- the scheduler state an Array of 5; the queues an Array of 12; the
  finalization slot nil or a Semaphore; the Process list Arrays of pairs,
  each a Process and an Array, no Process twice; the next id a positive
  SmallInteger;
- every Process in the heap saved, or terminated (state 3, record -1, next
  and waitingOn nil); a saved one ready or waiting, priority and affinity
  in range, record -1, an id unique and below the next id, result nil, its
  exit Semaphore nil or a Semaphore, `next` nil or a saved Process, ready
  with waitingOn nil, waiting on a Semaphore;
- the ready queues: head and tail both nil or both set; walking `next`
  from each head, every Process saved, ready, of that queue's priority and
  affinity, in no other list, the last one the tail; every Semaphore in
  the heap: excess signals a non-negative SmallInteger, none while it has
  waiters, its waiter list of saved Processes waiting on it, in no other
  list, ending at its last waiter; every saved Process in exactly one list;
- the saver a saved ready Process that has run, whose stack's top word is
  true after a send;
- its stack: registers SmallIntegers, sp at least 1, chunks exactly
  covering `[0, sp]`; a Process that has never run (pc -1): fp and hdr 0,
  word 0 a method of the method table (not a block) taking sp - 1
  arguments, word 1 a receiver that fits it; a primitive at the bottom
  that suspended (hdr 0): pc 0, sp 1, word 0 nil; otherwise
  `0 < fp < hdr`, `hdr + 4 <= sp`, and the frames, walked from the top
  through each callee's caller links to the bottom frame (caller fp 0):
  - the method a CompiledMethod of the method table, traced again by the
    bytecode verifier; fp equal to `hdr - 1 - argc - temps` of it and at
    least 1; the header inside its frame's region;
  - a block activation's `hdr[-1]` a BlockClosure of that block method
    whose receiver is the frame's receiver; the receiver an instance of a
    class whose chain reaches the method's class, with its instance
    variables (pointer slots);
  - the context word an empty frame's 0, a return marker (discard 1,
    cascade 2), or a Context whose frame is this header, process this
    Process, method, receiver and closure this frame's, pc nil, marker 0
    to 2, named by no other frame;
  - the top frame's pc an instruction the verifier reached, with the
    operand depth there `sp - hdr - 4`; a caller's pc (`hdr[1]` of its
    callee) an instruction the verifier reached with the depth that puts
    the callee's receiver where the answer goes (`calleeFp - hdr - 4`, one
    less for the discard marker); for the cascade marker, the instruction
    ending at that pc a `nonlocal_return` whose depth puts its value where
    the callee begins;
  - the caller links SmallIntegers, the caller's header below this
    frame's fp; the bottom frame's links 0, its fp 1, no marker, word 0 nil;
- every live Context (frame not nil) named by a saved frame, or of a
  terminated Process (which can never run again; 8a answers such a Context
  dead).

The bytecode verifier already gave every reachable instruction one depth
(paths meeting with two depths are refused); it now hands the per
instruction depths out (`VerifiedCode.depths`, `verifyHeapMethod(traced:)`).
The rules also guard every slot read by the holder's class and size first.

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-04 00:30 to 00:41 (load average 2.2 to 2.9
1-minute, the agent session the busiest other process).

### The kernels against the starting commit

The starting commit's `kajo` (5ddd8f4, from a worktree) against this
module's, both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`; median (min to max) ms. The Smalltalk kernels run from
images each binary built itself (the starting commit cannot read a
version 2 image). Every checksum is the published one on both sides.

| kernel | workers | 5ddd8f4 ms | 8c ms | 8c / start | checksums |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1689.9 (1688 to 1696) | 1720.0 (1718 to 1722) | **1.018** | 24682992 |
| fib | 8 | 221.1 (218 to 228) | 238.0 (227 to 245) | **1.076** | 24682992 |
| arith | 1 | 2532.5 (2531 to 2544) | 2550.0 (2548 to 2564) | **1.007** | 372800000 |
| arith | 8 | 336.5 (336 to 338) | 350.9 (338 to 356) | **1.043** | 372800000 |
| sends | 1 | 2565.2 (2557 to 2580) | 2588.2 (2572 to 2594) | **1.009** | 1066666666666668 |
| sends | 8 | 332.3 (331 to 343) | 349.7 (348 to 360) | **1.052** | 133333335000001 |
| ivars | 1 | 1970.1 (1966 to 1971) | 1978.6 (1973 to 1983) | **1.004** | 36383626 |
| ivars | 8 | 253.0 (253 to 261) | 265.0 (253 to 267) | **1.047** | 71714128 |
| storeheavy | 1 | 2409.1 (2406 to 2415) | 2401.0 (2395 to 2403) | **0.997** | 512000 |
| storeheavy | 8 | 324.2 (322 to 334) | 308.9 (308 to 318) | **0.953** | 512000 |
| alloc | 1 | 2958.3 (2951 to 2972) | 2958.4 (2953 to 2977) | **1.000** | 41950911 |
| alloc | 8 | 492.4 (460 to 514) | 472.7 (437 to 488) | **0.960** | 42008248 |
| Smalltalk sends | 1 | 2286.2 (2267 to 2304) | 2267.3 (2258 to 2274) | **0.992** | 1066666666666668 |
| Smalltalk sends | 8 | 303.3 (292 to 311) | 307.7 (303 to 315) | **1.015** | 133333335000001 |
| Smalltalk ivars | 1 | 1974.0 (1962 to 1977) | 1975.1 (1969 to 1976) | **1.001** | 36383626 |
| Smalltalk ivars | 8 | 252.5 (252 to 257) | 270.4 (259 to 279) | **1.071** | 71714128 |
| Smalltalk closures | 1 | 3822.0 (3815 to 3841) | 3822.7 (3817 to 3831) | **1.000** | 210210000 |
| Smalltalk closures | 8 | 502.1 (494 to 508) | 513.4 (500 to 514) | **1.023** | 209214000 |

- One worker: 0.99 to 1.02 (fib 1.018 the largest).
- Eight workers: 0.95 to 1.08, both ways (storeheavy and alloc faster,
  fib, sends and ivars slower). `interpret` is the same code in both
  aligned binaries: its disassembly (1321 lines) differs only in the page
  offset of the jump table's `adrp` (four lines). What 8c adds to a
  running worker is in `pollSlow`, reached every 1024 polls: one relaxed
  load of the hold's mirror inside the branch a stop takes, and one load
  of `snapshotAtPoll` (the trigger is out of line); `dequeueLocked` gained
  one load under the scheduler lock. A second interleaved A/B of the three
  slowest eight-worker kernels, seven runs each, right after it:
  fib 221.8 (217 to 246) against 225.4 (223 to 242), **1.016**; ivars
  260.2 (252 to 281) against 261.5 (253 to 274), **1.005**; sends 339.1
  (331 to 354) against 335.5 (332 to 354), **0.989**. The first run's
  eight-worker gaps are the session's, not the code's.

### The save, the image, the load

Release build with `-enable-testing` (`measureTheSave`), the kernel image
with the scenario class, 4 workers, five saves each; the saving Process
forks n Processes that wait on one Semaphore, then sends `Smalltalk
snapshot: nil`:

| | 0 other Processes | 300 Processes waiting |
|---|--:|--:|
| the save's stop (p50 of 5; first 0.96 ms both) | 0.45 ms | 0.56 ms |
| image | 2 567 576 bytes | 2 663 576 bytes |
| `Image.load` (verify all, p50) | 12.7 ms | 14.9 ms |
| `VM` init with the install | 0.07 ms | 0.16 ms |

The stop is the whole save's work: the drain, the full collection with
promote-all, the copies, module 1's snapshot and the method table; it does
not include the hold's wait (each Process's next poll). The kernel image
without saved Processes is 2 566 968 bytes and loads in 12.4 ms; 300
saved Processes add 96 000 bytes (320 per Process: its object, its two
chunk Arrays and its pair) and 2.2 ms of loading (the frame rules
retrace each distinct frame method once). The fib image saved by `kajo run
--snapshot-at 3` is 158 704 bytes and resumes to the published checksum.

## Changes to earlier modules

- Module 2 (`Loader/`): `ImageFile.swift` version 2 (version 1 still read),
  `encodedImage(snapshot:)` split out of `saveImage`, `verifyImage` collects
  Processes, Semaphores and live Contexts and calls the saved-Process rules
  (8a's "no Process, no live Context" rule replaced by them);
  `BytecodeVerifier.swift` `VerifiedCode.depths`; `Image.swift`
  `SpecialObjects.scheduler` (8) and `size` 9, `savedScheduler`,
  `hasSavedProcesses`; `FuzzEntry.image` installs an image's saved
  Processes in a VM it does not start, then destroys it (the fuzzer's leak
  test covers the stacks). `Primitives.swift`: 142.
- Module 3 (`Workers/`, `Processes/`): `VMState.saveHold`, `slowPolls`,
  `savedImages`; `SchedulerState.saveHold`; `dequeueLocked` refuses while
  held; the background workers' idle wait waits while held; `stopWorld`'s
  end keeps the flag's bit while held; `pollSlow` puts a held Process back
  and calls the poll trigger (out of line); `VMConfig.snapshotAtPoll`; the
  VM installs saved Processes in its initializer (`resumedProcesses`,
  `resumedSaver`, `takeSavedImages`, `isQuiescent`); counters
  `snapshots`, `snapshotsRefused`, `snapshotRetries`, `snapshotNs`,
  `holdPreemptions`, `processesResumed`.
- Module 8a (`ObjectModel/ObjectModelPrimitives.swift`):
  `verifyHeapMethod(traced:)`.
- Module 8b: `Headless` resumes images with saved Processes, `kajo test`
  refuses them, `--snapshot-at N --snapshot-to path`; kernel: `Smalltalk
  snapshot:`, `primSnapshot:`, `resumeAfterSnapshot`; Delay's pending list,
  `prepareSnapshot`, `resumeAfterSnapshot`, `isPending:`, `pendingFor:`;
  `Ephemeron resumeAfterSnapshot`, `finalizationProcess`; SnapshotTest.
- Module 8b (`Loader/Assembler.swift`): the second operand of a send, a
  closure or a temp-vector instruction is checked to fit its byte (a
  `CompileError`, `badOperand`). The syntax fuzzer's gate run on ab180a6
  found a keyword send of more than 255 arguments trapping there ("Not
  enough bits to represent the passed value", `assembleBody`); it is as old
  as 8b. The input is a seed and a regression test
  (`Fixtures/fuzz/syntax/crash-many-keywords.st`,
  `aSendOfMoreThan255ArgumentsIsRefused`).
- Tests changed on purpose: `theImageLoaderRejects`' bad version is 3 (2 is
  valid now). `backToBackStopsDoNotLetReleasedWorkersRun` churns long enough
  in release builds that the host's 20 stops land while workers run, and
  terminates the Processes after them: in the same gate run's `just
  test-release` the full suite (with this module's random programs beside
  it) let the seven Processes of 150 000 iterations finish before 20 stops
  ("stops >= 20" failed); alone it passed six runs of six.
  `sharedYoungObjectsAreClaimedOnceByParallelScavengers` (stw) runs its
  eight sharers again, at most three rounds, until a scavenge had four
  participants: the gate run on 1a4bf66's `just test-release` had none
  with four (the suite in release is about 8 s with this module's random
  programs beside it, and parked workers are what join a scavenge); three
  full release runs after it passed.

## Deviations from the brief

- **The save holds the scheduler before its stop** (a new protocol, with a
  model), where the brief named module 8a's install stop as the model: in
  a stop other workers may be parked mid-instruction (an allocation's stop,
  a young collection's wait, a primitive's own stop), and no register set
  of such a Process is a resume point. The hold brings each to a poll,
  where module 3's preemption already makes its registers exact; the stop
  itself is the install stop.
- **The saver's answer is in the image's copy of its stack** (true where
  the primitive's receiver was) rather than pushed on resume: the frame
  then is an ordinary suspended-after-a-primitive frame, and the loader's
  depth rule covers it like any other; the extra rule is that its top word
  is true after a send.
- **A save the VM triggers at a poll** (`snapshotAtPoll`) exists beside the
  primitive: the random programs need saves at arbitrary points, not only
  where a program asks; there the Process at the poll is saved as
  preempted and no saver is named.
- **Version 1 images still load** (no saved Processes, 8 special objects),
  so the snapshot fuzzer's v1 regression fixtures keep exercising the
  rules they were found by.
- **A primitive at the bottom of a Process that suspended** (a
  host-spawned `wait`, hdr 0) is a saved form of its own: module 3 already
  resumes it to the leave code.
- **kajo run of a resumed image ends when quiescent**, not when every
  Process ended: a kernel image always has a finalization Process waiting.
- **The finalization Semaphore is signalled once on resume** when the
  finalization queue is not empty: the signal that a collection sent went
  through the external queue, which is not saved.
- **`SnapshotTest>>testSnapshotAnswersFalseInTheSaver` saves to the host
  (nil)**, so `kajo test` leaves no file behind.
- **The fuzz seeds are kasm images** (`saved-states.img`: waiting, ready,
  never run, a live Context below a block frame, the saver;
  `saved-shapes.img`: discard and cascade frames, a grown stack): a kernel
  image does not fit the fuzz entry's 2 MiB heap. A pending non-local
  return and an `ensure:` mid-unwind are covered by the Smalltalk round
  trips, not by seeds.

## Tests

310 `KajoVMTests` (8b: 300; 10 new: 4 in `SavedProcessTests`, 5 in
`SavedProcessLoaderTests`, `randomProgramsResumeFromASnapshot`) and 26
`KajoCompilerTests` (8b: 20; `SnapshotScenarioTests`' 4, the gated
`measureTheSave`, and the syntax fuzzer's regression); 4 new kernel SUnit tests (`SnapshotTest`); 5 model
tests.

**Round trips** (each run to its end where it saved and again from the
image in a fresh VM, with another worker count): `oneReadyProcessRoundTrips`,
`theBaseImageLoadsAndResumes` (two waiters, a live Context in a method
frame below a waiting block frame, a Process that never ran, the saver),
`markedFramesAndAGrownStackRoundTrip` (a discard frame from a read-only
store, a cascade frame from `cannotReturn:`, a stack of 3000 frames grown
past 8192 words), `readyQueuesKeepPriorityAffinityAndFIFO` (seven
Processes over every priority and both affinities: the same run order
before and after), `excessSignalsSurviveTheSave`; in Smalltalk
(`aScenarioResumesWithTheSameAnswer`): a Mutex held with three queued, a
Monitor with two waiting, a SharedQueue with three producers and two
consumers mid-stream, a Delay pending at the save (the resumed run would
never end without its re-arm), `ensure:` pending, a non-local return
through two frames, an `on:do:` whose exception is signalled after the
resume, the finalization Process mourning an ephemeron whose key dies
after the resume; `savingTwiceAndSavingAResumedImage` (1, 10, 101, 110);
`kajoTestRefusesAnImageWithSavedProcessesAndRunResumesIt`;
`anImageWithoutProcessesStartsAtTheEntryPoint`.

**The loader**: `theLoaderRefusesASavedProcess` (33 corruptions, each
refused with its rule's message), `theBaseImageReencodedLoads`,
`mutatedSavedProcessImagesLoadCleanOrAreRejected` (300 mutated copies
through the fuzz entry, which installs what loads),
`savedProcessFuzzSeedsLoadThroughTheFuzzEntry`.

**The random programs** (`randomProgramsResumeFromASnapshot`, six modes:
one worker, eight, `stopEveryPoll`, collect at every allocation,
`preemptEveryPoll`, perturbation): each seed's program saved at a slow
poll chosen from the seed, run to its end, and resumed from the image on
another worker count; both answers must be the model's. 100 seeds per mode
in the suite (10, and 2 for the two costliest, under ThreadSanitizer),
1000 in `just soak`.

**Kernel** (SUnit, `SnapshotTest`): `snapshot: nil` answers false in the
saver; a Delay is pending only while waited on; `prepareSnapshot` takes
the time left; the resume hook re-arms a pending Delay.

**Model** (`cd models && swift test --filter SaveHold`): 5 tests,
`docs/models/save-hold.md`.

## Broken variants run by hand

Debug builds, 2026-11-04, each restored afterwards.

| rule | broken variant | test | result |
|---|---|---|---|
| the loader checks the traced depth at every saved pc | both depth guards always pass | `theLoaderRefusesASavedProcess` | 3 of 33 corruptions load: pcInsideAnInstruction, depthDisagrees, callerPcDisagrees |
| a save waits until no other Process runs | no wait, no check in the stop (module 8a's install stop alone) | `randomProgramsResumeFromASnapshot`, 20 seeds | five of six modes save images the loader refuses: "Process @1549 is saved with state 1 (ready or waiting only)" (a Process caught running mid-slice); one worker saves cleanly (no other worker) |

The hold's other two rules (the poll that puts a held Process back, the
release's broadcast) are broken in the model (`docs/models/save-hold.md`),
where a test fails without each.

## Unsafe surface

Lines with `unsafe` (comments excluded): `SavedProcesses.swift` 87 new (the
VM, worker and record pointers, the stacks' malloc and copy), 0 in
`SavedProcessRules.swift` (safe code over module 1's checked loads);
`VM.swift` 166 to 178 (installation, `isQuiescent`), `Poll.swift` 42 to 48
(the hold's preemption, the trigger), `Scheduling.swift` 187 to 188,
`Headless.swift` 22 to 26 (the resume run's hooks). The whole
`Sources/KajoVM` has 4377 such lines (4267 at the start). Counted on the
final commit's clean build (0 warnings).

## Hot-path check

`just arc-check` on the final code: zero `swift_retain`/`swift_release` on
every checked path; `interpret` 1056 instructions, one indirect branch, one
jump table (unchanged). Its first run on this module found `pollSlow` with
ARC 3: the poll trigger, inlined, brought the save's Swift arrays into it;
`snapshotAtPoll` is `@inline(never)` now. `dequeueLocked`, `pollSlow`,
`requeueCurrent` and `runSlice` are on the list and free of ARC. The save,
the loader's rules and the install are not on the hot path.

## Not done

- A save from the host (with Processes): the host worker runs no Process;
  the poll trigger is the tests' way in.
- Delays of a poll-triggered save are not re-armed (no kernel code runs);
  the random programs use none.
- `Process>>terminate` still runs no unwind blocks; a terminated Process's
  Contexts with frame indices stay in images as dead Contexts.
- A save that does not fit the heap fails the primitive
  (`snapshotsRefused`); there is no reserve for it.
- Device runs.

## Open questions for the owner

The owner agreed with every provisional answer on 2026-11-04; 5 and 6 as
built (no save timeout, `kajo run` ends when quiescent) stand until a
server image needs otherwise.

The brief's four, built to their provisional answers:

1. A Delay's remaining time continues from the resume (time on disk not
   counted).
2. `kajo test` refuses an image with saved Processes.
3. Terminated Processes may appear in an image as ordinary objects.
4. The saved stack as Array chunks; ADR 0009 amended.

New from the build:

5. The hold is a scheduler-level stop: while a save waits for every
   Process to reach a poll, a Process in a long blocking region (a shell
   call) delays the save. Acceptable, or should a save time out and fail?
6. `kajo run` of a resumed image ends when nothing can happen without the
   host, terminating Processes still waiting then. Is that the CLI's
   contract, or should it wait (a server image)?

## Gates

On the final code commit (`5fb848b`; the commit after it adds only this
table), the whole sequence, on the Mac mini (M2 Pro) with the swift.org
6.4.2 toolchain, every output in a file, each step logged with the commit
it ran on:

| gate | result |
|---|---|
| `swift test` | 310 + 26 passed, 159 + 17 s |
| under load (12 busy loops) | 310 + 26 passed, 192 + 20 s |
| ThreadSanitizer | 310 + 26 passed, 0 reports, 396 + 408 s |
| ThreadSanitizer under load | 310 + 26 passed, 0 reports, 561 + 477 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release, `interpret` 1056 instructions, one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 310 + 26 passed |
| `just model-check` | 28 + 5 + 15 passed (relocation, save hold, young collection) |
| `just soak` | passed: 1000 seeds under every configuration, and in snapshot mode 762 to 985 of 1000 saved per mode, no failing seed |
| `just fuzz kasm 600` | libFuzzer build ok, 2.54 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 4.07 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 2.16 million runs, no crash |
| clean build | exit 0, 0 errors, 0 warnings |

(310 is `KajoVMTests`, 26 `KajoCompilerTests`, whose kernel-image suite
runs the kernel's 130 SUnit tests.) Two earlier full runs each found
something the gates exist for: on `ab180a6`, `just fuzz syntax` crashed
the assembler (a send of more than 255 arguments, as old as 8b) and `just
test-release` failed `backToBackStopsDoNotLetReleasedWorkersRun`'s "stops
>= 20", both fixed in `1a4bf66`; on `1a4bf66`, `just test-release` failed
`sharedYoungObjectsAreClaimedOnceByParallelScavengers`' "a scavenge with
four participants", fixed in `5fb848b` (Changes to earlier modules). Every
other gate passed on both.

## Commands

```zsh
just build-image                                   # kernel image without Processes
swift run kajo run k.kasm... --snapshot-at 3 --snapshot-to out.img
swift run kajo run out.img --workers 4             # resume
cd models && swift test --filter SaveHold
KAJO_MEASURE_SNAPSHOT=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter measureTheSave
S=<scratch>; git worktree add $S/start 5ddd8f4
A2=(-Xswiftc -enable-testing -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32)
(cd $S/start && swift build -c release --product kajo --scratch-path .build/bench-a2 $A2)
swift build -c release --product kajo --scratch-path .build/bench-a2 $A2
zsh bench.sh $S/start/.build/bench-a2/release/kajo .build/bench-a2/release/kajo bench.txt 5; python3 agg.py bench.txt
zsh gates.sh    # every gate, outputs and the commit each ran on in files
```

AOT 1 (2026-11-11, `docs/modules/aot.md`, open question 1): the saver writes a frame's native return marker as the empty context word and a Context's native marker field as 0 (patched around the snapshot), so `SavedProcessRules` still refuses every marker past 3 and a resumed Process finds its native code again at its first poll or return.
