# Module 8c: Processes saved in the image

Status: brief, 2026-11-03. Decided by the owner the same day ("images hold
Processes", ADR 0009 Built (8a)); module 8b built the image without them
and reserved the entry point (special object 7) beside them. Module 9's
live development needs a running system that can be saved and resumed.

## What it hides

A Kajo image can be saved while Processes are ready, waiting or holding
locks, and a later `kajo run` of that image continues every one of them
where it stopped, with the same results as a run that was never saved.
Everything a Process needs to continue is in the image file, in a form
that is independent of addresses, worker count and the order the loader
rebuilds things in, and the loader trusts none of it: a saved frame is
untrusted input, verified against the methods in the image before any
Process is made runnable.

## Starting point (read these as built)

- `docs/modules/workers.md`: Process and Semaphore layouts (slots 6 to 9
  are the saved registers, SmallInteger word indices and a bytecode
  offset, never addresses), the record table, malloc'ed stacks, the ready
  queues (3 priorities x 2 affinities, head and tail oops, FIFO through
  `next`), the safepoint protocol and the saved-pc conventions, external
  signals and the pending-root table, `delay:signal:` as a one-shot GCD
  timer.
- `docs/modules/object-model.md`: the frame (`hdr[0..4]`, the block
  activation's `hdr[-1]`), closures and temp vectors, Contexts (a frame
  index while live, detached on return), return markers, the unwind and
  handler marks, frame pins (module 6), stack growth by copying, the image
  format and `verifyImage`'s rules (it refuses any Process and any live
  Context today).
- `docs/modules/kernel-image.md`: the image build, the entry point, the
  size lesson (an image's size follows the entry table's peak), `kajo run`
  and `kajo test`, the kernel's Process, Semaphore, Mutex, Monitor,
  SharedQueue, Delay and Ephemeron classes (`kernel/`).
- `docs/modules/object-memory.md`, `nursery.md`, `young-collection.md`,
  `relocation.md`: the snapshot (version 3) follows a promote-all and
  refuses young, deferred-free and frame-pinned entries; the loader is the
  trust boundary (AGENTS.md lessons).
- ADR 0009 section 3 says a Process resumed from a snapshot "rebuilds
  frames from Contexts". That sentence predates the as-built frame; this
  module decides the saved form (below) and amends the ADR in its Built
  (8c) note.

## What 8c builds

### 1. The saved form of a Process

Every live Process (state ready or waiting, and the one that asked for
the save) is saved as heap objects, so module 1's snapshot carries it and
its verifier covers every oop in it:

- The Process object as it is (priority, state, waitingOn, affinity,
  next, the four registers, result, exitSemaphore, id); `record` is
  meaningless in a file and is written as -1 and reassigned on load.
- The stack words `[0, sp]` as a traced heap object. Every word on a
  stack is already a valid oop or SmallInteger (receivers, arguments,
  temps, operands, methods, closures, caller pc/fp/hdr as word indices,
  context words), so the words can be copied into Arrays verbatim; an
  object is at most one block (4095 slots), a default stack is 8192 words
  and grows by doubling, so the saved stack is a chain of chunks (an
  Array of Arrays, or a dedicated sealed class; decide and document).
  Materialized Contexts keep their frame indices, which stay valid
  because indices are what is saved. This is the recommended form: it is
  what the frame design already is, and it needs no de-materialization.
  If you choose to rebuild frames from Contexts instead (the ADR's
  sentence), say why in the doc; either way the ADR is amended to what
  was built.
- Nothing by address, worker or time: `runningOn`, `runnableSince`,
  `hopStart`, the record index and the stuck report are not saved.

### 2. The scheduler's state

What lives outside the heap today and must be in the image: the ready
queues' heads and tails (6 queues), the finalization Semaphore the VM
signals (`FinalizationState`), and the list of live Processes (so the
loader knows which Process objects get a record and a stack; a terminated
Process is an ordinary object and may appear in an image from now on).
Put them in the special objects (extend `SpecialObjects`; the image
format's version becomes 2) or in one sealed scheduler-state object the
special objects name; the loader rebuilds the queues from the heads
through `next` and checks the chains (acyclic, each Process in exactly
one list, its state agreeing with the list it is in: ready in a ready
queue of its priority and affinity, waiting in `waitingOn`'s waiter list
and nowhere else). `excessSignals` and waiter lists are already heap
state and need no change.

Pending external work is not saved: the save drains the external signal
stack first (signals land before the stop), and outstanding `delay:signal:`
timers are dropped. The kernel re-arms them (4).

### 3. The save

A primitive the kernel sends (`Smalltalk snapshot: aString`, or your
name; document it) run from any Process at a bytecode boundary:

1. request a stop (module 8a's method-install stop is the model: every
   worker at a safepoint, every other Process parked with its registers
   saved; read the saved-pc conventions and make the parked Processes'
   registers exact);
2. drain external signals; promote all (the snapshot's precondition) and
   collect, so the entry table's peak does not bloat the file (the 8b
   lesson);
3. write the saving Process so that it resumes **after** the primitive
   with the answer `true`, and answer `false` in the running system
   (Smalltalk-80's `snapshot:andQuit:` convention), so one kernel method
   can do the post-resume work;
4. copy every live Process's stack into heap chunks, fill the scheduler
   state, snapshot in module 8a's image format (version 2), then free the
   chunks (or leave them to the next collection) and continue.

Frame pins: a snapshot refuses frame-pinned entries today. At the stop no
frame holds an address, so either clear them as part of the stop (say
where) or show they cannot be set at that point; the loader's refusal
stays.

Also `kajo save`? Not needed: the kernel's method is the API; the headless
CLI gets whatever a test needs (a `--snapshot-at` for the random programs,
below).

### 4. The load and the resume

`Image.load` accepts images of version 2 with saved Processes. For each
live Process, after `verifyImage` passes and before anything runs: a
record, a malloc'ed stack of at least the saved words (grown by the usual
doubling if the saved sp needs it), the words copied back, registers from
the Process, state as saved, and the ready queues relinked from the saved
heads. `kajo run image.img` with saved Processes resumes them instead of
sending the entry point; the entry point stays for images without (8b's
`kajo test` and the benchmark kernels). `kajo test` on an image with saved
Processes refuses with a clear message (provisional; question 2 below).
Main-affine Processes resume on the main worker; `--workers n` applies as
before.

The kernel's side (`kernel/`): the method that called the snapshot
primitive sees `true` and runs the resume hook: re-arm every pending
Delay (Delay keeps a class-side list of pending ones with their remaining
time, computed at save; a Delay's remaining time continues from the
resume, the time on disk is not counted: provisional, question 1), make
sure the finalization Process exists (it is saved waiting on its
Semaphore, so usually it does), and anything else that held host state.
The Transcript and the event stream reattach to the new host.

### 5. The loader as a trust boundary

A saved stack is the most powerful input an image can carry: a forged
frame could run a verified method on the wrong receiver, address the
wrong temp, or return into nothing. `verifyImage` gains a saved-Process
section, every rule refused by name and tested by a corrupt image:

- the Process's slots are of the right kinds; state ready or waiting
  (never running); priority and affinity in range; sp, fp, hdr, pc
  SmallIntegers with 0 <= fp < hdr < sp <= saved words (pc -1 only for a
  Process that has never run, whose stack is then the bottom frame's
  arguments alone, as `fork` lays it out);
- walking the frames from the top (hdr) through `hdr[3]` to the bottom
  (caller fp 0): each `hdr[0]` a CompiledMethod of the image's method
  table; each frame's `fp` equal to `hdr - 1 - argc - temps` of that
  method; the frames contiguous and non-overlapping, the operand stack of
  frame k ending where frame k+1's receiver begins; a block activation's
  `hdr[-1]` a BlockClosure whose block method is `hdr[0]`; a method
  activation's receiver an instance of a class that inherits from the
  method's class and has at least its instance variables (the kasm
  loader's rule, applied to a live receiver);
- the top frame's pc and every caller pc (`hdr[1]` of the callee) a
  bytecode boundary of its method that the bytecode verifier reached, and
  the operand depth there equal to the verifier's traced depth at that pc
  (the verifier already computes depths per path; expose the per-pc depth,
  which must be unique per reachable pc for this check to be sound, and
  make that uniqueness a verifier rule if it is not one yet). A caller's
  pc is the one after its send, so its traced depth already accounts for
  the popped arguments and the pushed answer;
- each context word nil, a return marker allowed at that frame (discard
  and cascade frames are VM-sent; check what the sender convention
  allows), or a Context whose `frame` is this header's index and whose
  `process` is this Process; no live Context anywhere else; a detached
  Context has frame nil as today;
- `waitingOn` a Semaphore whose waiter list contains the Process exactly
  once; a ready Process in exactly one ready queue; `next` chains acyclic
  and consistent; the saving Process's frame shaped so that resuming
  pushes `true` where the primitive's answer goes;
- the special objects' scheduler state well formed; the finalization
  Semaphore a Semaphore.

All or nothing, as today: any failure destroys the memory and throws.

### 6. Fuzzing and random programs

- `fuzz-snapshot` reaches images with saved Processes: add seeds (an image
  with one Process at each state and priority, one with a grown stack,
  one with live Contexts and a pending non-local return, one mid-`ensure:`)
  and make sure the fuzz entry exercises the resume path up to, but not
  including, running Smalltalk (loading and verifying; running a fuzzed
  image is the random programs' job).
- The seeded random programs (`Workers/RandomPrograms.swift`, `just soak`)
  gain a mode: snapshot at the n-th poll, load the bytes into a fresh VM,
  resume, and compare the result with the uninterrupted run and the model.
  This is the main oracle for the whole module; it must run in `just
  soak` and as a test with the stress flags (every poll, every
  allocation) over a seed range.
- `theImageLoaderRejects` gains one corrupt image per rule in section 5.

### 7. Tests (Swift and Smalltalk)

A round trip, each resumed run finishing with the same result as an
uninterrupted one:

- Processes ready at every priority and affinity, FIFO order kept;
- waiting on a Semaphore with and without excess signals; a Mutex held
  by one Process with others queued; a Monitor; a SharedQueue with
  producers and consumers mid-stream;
- a Delay pending at save, which fires after resume;
- live Contexts (`thisContext` held in a variable), a pending non-local
  return through two frames, an `ensure:` block pending, an active
  `on:do:` handler whose exception is signalled after resume, a frame
  carrying a return marker;
- a stack grown past 8192 words; a Process that has never run;
- the finalization Process with an Ephemeron whose key dies after resume;
- the saving Process answers `false` then `true`; saving twice; a saved
  image loaded on a VM with a different worker count;
- images without Processes still start at the entry point; `kajo test` on
  an image with Processes refuses;
- every loader rule refused; mutation of saved-Process images loads clean
  or is refused (300 copies, as today).

Kernel tests (SUnit) for the kernel's side: the Delay list, the resume
hook, `Smalltalk snapshot:` answering `false` in the saver.

## Rules

AGENTS.md binds, in particular: every verifier on in checked builds, the
stop-the-world collector as oracle, zero ARC and one jump table on the hot
paths (the save and load are not hot paths, but nothing they add may touch
the dispatch loop; if a check is added to a poll, measure it), tests
assert on CPU or on work, `.strictMemorySafety()` with every unsafe
construct marked and counted. No new cross-thread protocol without a model
in `models/`; if the save reuses the method-install stop, say so and add
no model.

Measure: the kasm and Smalltalk kernels within noise of the starting
commit (five interleaved runs, aligned `-enable-testing` builds, 1 and 8
workers); the save's stop time for the kernel image with a few hundred
Processes; the image's size with and without saved Processes; load time.

## Open questions for the owner (build to the provisional answers)

1. A Delay's remaining time continues from the resume (time on disk is
   not counted). Alternative: fire at once every Delay whose deadline
   passed in wall-clock time.
2. `kajo test` refuses an image with saved Processes. Alternative: a
   `--fresh` flag that discards them (terminating each as a terminate
   would, without running unwind blocks).
3. Terminated Processes may appear in an image as ordinary objects (their
   `record` -1, no stack). Alternative: the save fails on one.
4. The saved stack as Array chunks (position-independent by
   construction) rather than Contexts. The ADR is amended to the built
   form.

## Deliverables

Code under `Sources/KajoVM/` (where it belongs: `Loader/ImageFile.swift`,
`Processes/`, a new `Processes/SavedProcesses.swift` or similar) and
`kernel/`; the as-built doc replaces this brief's sections below the
title in the style of `docs/modules/kernel-image.md` (what it hides, each
part as built, the saved form with a table, the loader's rules, measurements,
changes to earlier modules, deviations with reasons, tests, broken variants
run by hand, unsafe surface, hot-path check, not done, gates, commands);
ADR 0009's Built (8c) note; terms in `docs/CONTEXT.md`; `kernel.md`'s
status line. AGENTS.md and PLAN.md are the main session's.
