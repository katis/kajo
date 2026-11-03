# Kajo context

Shared vocabulary for the project. When a word here is used in code, docs or
conversation it means exactly this. Add words as they are coined; sharpen them
as they are understood.

## System

- **VM** or **VM core**: the Swift library `KajoVM`. Object memory, garbage
  collector, interpreter, scheduler and primitives. The trusted computing
  base: the only code that can corrupt memory.
- **Shell**: a native macOS or iOS application that hosts a VM and renders its
  UI with SwiftUI, UIKit or AppKit. Owns the main thread. Never runs
  Smalltalk code on it.
- **Image**: a snapshot of the whole object memory. Loaded at startup, saved
  at will. A build artifact, never committed.
- **Kernel**: the Smalltalk class library that boots the system, kept as text
  under `kernel/`.
- **Development protocol**: the connection between a shell or VM being
  developed and the developer's tools on another machine. Not designed yet.

## Execution

- **Worker**: an OS thread that executes Smalltalk Processes, with its own
  interpreter state, lookup cache and allocation context. Many workers share
  one heap. Worker 0 is the **main worker**: the shell's main thread, inside
  the VM only during a Turn. Background workers are threads of the VM at
  user-initiated QoS; the host worker serves host calls. Idle workers wait
  untimed.
- **Process**: a Smalltalk-level thread of control, scheduled onto workers:
  a heap object (class 13: priority, state, affinity, saved registers as
  integers, result, exit Semaphore), a native record and its own stack. It
  can leave one worker mid-method and resume on another. A **main-affine**
  Process runs only on the main worker.
- **Semaphore**: a heap object (class 14): excess signals and a FIFO list of
  waiting Processes. The only way a Process waits; primitives never block.
- **Safepoint**: a point where a worker checks whether it must pause for a
  stop, and every `pollEvery` polls its budget. Reached at sends and
  backward jumps. A **stop** brings every worker inside the VM to a
  safepoint (parked) so one of them can collect, compact or become.
- **Turn**: one call of the shell into the VM on the main thread
  (`runMain`): main-affine Processes run until none is ready or the turn's
  budget is spent; a Process that overruns is preempted at its next budget
  check.
- **Hop**: a primitive that must run on the main thread, called on another
  worker, suspends its Process with the send rewound, makes it main-affine
  and wakes the main worker, which retries the send.
- **External signal**: a Semaphore signal from a thread outside the VM (a
  completion handler, the shell), pushed onto a lock-free queue that workers
  drain at budget checks, turns and when they wake. A **pending root** keeps
  the Semaphore alive until it is drained.
- **Primitive**: VM-implemented behaviour reachable from Smalltalk by send.
  The boundary where the VM checks bounds and types so Smalltalk code can
  never corrupt memory.

- **Stack**: a region of tagged words, outside the heap, that frames live
  on. Word 0 is nil and every word up to sp is a valid oop, so the collector
  scans it uniformly. Module 3 gives one to each Process.
- **Frame**: one activation on a stack: receiver, arguments, temps, then a
  five-word header (method, caller pc, caller fp, caller hdr, and the
  frame's Context, nil until materialized: ADR 0009) and the operand stack. The caller links are SmallIntegers holding a bytecode
  offset and word indices, never addresses, so neither moving bytecodes
  nor a moving stack needs them fixed.
- **Send**: finding and running the method for a receiver's class and a
  selector: the lookup cache, else the superclass chain's method
  dictionaries; then the method's primitive, or a new frame. With no
  method, `doesNotUnderstand:` is sent with a Message if the class has it.
  A **super send** looks up from the superclass of the class the running
  method was compiled in.
- **Special send**: a bytecode for a common selector (`+`, `<`, `at:`,
  `value`, ...) with a fast path inline, an out-of-line tier (overflow,
  floats, Arrays, closures) and a full send of the selector otherwise.
- **Bytecode set v1**: ADR 0009's encoding: module 2's 27 opcodes, the
  special sends, closures, temp vectors, thisContext, super, block and
  non-local returns, and the **extension prefix** `ext` that widens the
  next instruction's first operand.
- **Closure**: a BlockClosure: a block method (a CompiledMethod flagged as
  a block, held in its outer method's literals), the receiver of its home,
  its home Context if it can return non-locally, and copied values.
- **Temp vector**: an Array holding the temps a method and its closures
  both write after capture, reached with `push_tv_slot` and
  `store_tv_slot`.
- **Context**: a frame made into a heap object on demand (thisContext, a
  closure's home, the Context primitives). **Live** while its frame index
  names a frame on the current Process's stack whose context word is it;
  **detached** (dead) once the frame returned or was cut: its temps copied,
  its frame and sender nil.
- **Non-local return**: `^` in a block: return from the block's home
  method. Straight to the home when no unwind mark lies between, else
  through the kernel (`aboutToReturn:through:`); a home that returned
  sends `cannotReturn:`.
- **Unwind mark**: a method flag on `ensure:` and `ifCurtailed:`: frames a
  non-local return or an exception's return must not cut without running
  their block. **Handler mark**: the flag on `on:do:` that a signal's walk
  looks for.
- **Return marker**: a SmallInteger in a frame's context word for a frame
  the VM sent itself: drop the answer (after a refused store) or return it
  from the caller too (after a failed non-local return).
- **Primitive failure**: a primitive refusing its receiver or arguments
  (wrong type, bound or argument count). The method's bytecodes then run
  as an ordinary activation; a method with none stops with a VMError.
  Running out of heap is not a primitive failure.
- **VMError**: what a program that cannot go on hands its caller: kind,
  selector, receiver class, method and pc. The interpreter never exits or
  traps on one and leaves the stack as it was for inspection.
- **Structural class**: Class, Method and MethodDict, the objects whose
  shape the interpreter trusts. No primitive reads, writes, creates or
  exchanges their instances. Module 8 generalises it as **sealed**: a
  bit of the class format, set for CompiledMethod, MethodDictionary,
  Process, Semaphore, BlockClosure, Context, Metaclass, Behavior,
  ClassDescription, Class and every metaclass.

## Memory

- **Oop**: a 64-bit tagged word. Low bit 1: a SmallInteger, 63-bit two's
  complement. Low bits `10`: a SmallFloat; `0100`: a Character. Low four
  bits 0 and nonzero: an object reference, the byte offset of the object's
  entry in the entry table (ADR 0003). `1000` and `1100` are spare. 0 is no
  object. Oops never change when objects move. A word is a reference
  exactly when its low four bits are 0 (never test `raw & 1` for it).
- **Immediate**: an oop that is its own value: SmallInteger, SmallFloat,
  Character. Never a reference, never young, always read-only.
- **SmallFloat**: an immediate double whose exponent fits nine bits (about
  1e-77 to 1e77, and zero), with its full mantissa; other doubles are a
  boxed **Float** (an 8-byte object).
- **Character**: an immediate Unicode scalar (not a grapheme).
- **LargeInteger**: a LargePositiveInteger or LargeNegativeInteger, a byte
  object holding the magnitude little-endian. **Normalized**: no leading
  zero byte, and never a value a SmallInteger can hold.
- **Entry**: 16 bytes in the entry table: the state word (the body's offset
  in the heap, offset + 2^32 while RELOCATING, or a free-list link with bit
  63 set) and the header word. Entry 0 is never used.
- **Header**: the object's header word, kept in its entry, not in the body.
  Bits 0..21 class index, 22..45 slot or byte count, 46 mark (reserved;
  marks live in a side byte map), 47 byte object, 48 fired ephemeron,
  49 deferred free, 50 read-only, 52..55 nursery index, 56 young, 57..59
  age, 60 pinned for good, 61 frame pin, 62..63 scavenge claim tag. Written only with the world stopped, or
  by the allocating worker before the oop escapes.
  docs/modules/object-memory.md has the full layout and which bits each
  module uses.
- **Body**: an object's storage in the heap: a back reference (entry index
  and body size) then the slots or bytes. Never spans a block.
- **Block**: 32 KiB unit of the heap; bodies are bump-allocated in blocks.
- **Allocation context**: a caller's private block and private free-entry
  list; one per worker.
- **Pin**: a header bit that keeps a body from moving. **Pinned for good**
  (bit 60): set when the image is built on every method, its bytecodes and
  literal Array (the interpreter's two cached raw pointers point into
  these), every class, every symbol, nil, true and false. **Frame pin**
  (bit 61): set at a final mark on every old object the running frames
  name, cleared by the pause that applies or aborts the cycle. Neither the
  relocator nor a compaction moves a pinned body.
- **Nursery**: a worker's region for young objects (module 4): an eden
  and two survivor halves, beyond the block range. Every worker has one;
  all are collected together by a scavenge.
- **Eden**: the part of a nursery new objects are bump-allocated in; empty
  after every scavenge.
- **Survivor**: a young object that lived through a scavenge, copied into
  the copying participant's survivor-to half; survivor-from holds the
  previous scavenge's survivors. The halves swap roles at every scavenge.
- **Young / old**: young objects live in a nursery (header bit 56); old ones
  in blocks. Promotion copies a young object into old space; its oop stays.
- **Age**: the scavenges a young object survived (header bits 57..59). At
  N (default 2) it is promoted; earlier when survivor-to is full (an
  overflow promotion).
- **Scavenge**: a stop-the-world young collection: every participant
  copies the young objects reachable from the roots and the remembered
  holders, then the dead young entries are freed.
- **Claim tag**: header bits 62..63; scavenge s claims a young object by
  setting bit 62 + (s & 1) in one compare-and-swap that also writes the
  decision (survive or promote). A loser reads the decision.
- **Remembered set**: the old objects that may name a young one: a 16-bit
  marker per entry beside the table (one bit per nursery) and per-worker
  buffers of holders. Never a header bit; never a young holder.
- **Barrier**: the check after every store of an oop into a heap object:
  a young value stored into an object not young in the same nursery calls
  the slow path, which remembers an old holder.
- **Promotion reserve**: blocks beyond old space's soft limit that only
  promotion may take, so a scavenge never fails for lack of space.
- **Entry stash**: an array of free entries owned by one nursery; young
  objects take entries from it in order, and the entry sweep returns the
  dead ones to it.
- **Weak slot**: an indexed slot of an object whose class format is weak:
  not traced; nil once its referent is reclaimed.
- **Ephemeron**: an object whose slot 0 (the key) is traced only if the key
  is reachable some other way; when it is not, a full collection fires the
  ephemeron once: queues it for finalization and keeps key and value alive
  for that collection.
- **Metaclass**: the class of a class. Every class is the sole instance
  of its metaclass; a metaclass is an instance of Metaclass.
  `Foo class superclass` is `Foo superclass class`.
- **Read-only**: header bit 50: every store path refuses the object and
  sends it `attemptToModify:at:value:`. Method literals are read-only.
- **Symbol table**: the Array of buckets of interned Symbols; a lookup
  compares bytes, a new Symbol is inserted with the world stopped.
- **Image file**: module 1's snapshot with a method table and the special
  objects, loaded only after every object-model rule and every method has
  been verified.
- **Format**: a class's format word beside the class table: named slots,
  weak or ephemeron, the kind (pointers fixed or variable, bytes, 16-,
  32-, 64-bit words), sealed, and whether the instances are behaviors (ADR
  0009 section 6). The header keeps only pointers or bytes.
- **Finalization queue**: the fired ephemerons, a root, taken one at a
  time by a Process that a Semaphore wakes; finalizers never run on a
  collector thread.

## Concurrent marking (module 5)

- **Cycle**: one concurrent collection of old space: an initial mark, the
  marker's tracing, a final mark, the lazy sweep and the apply. Started at
  the end of a scavenge by occupancy (the floor), by the predictor or by a
  stress flag; abandoned (an **abort**) by any module 1 operation that
  moves, frees or exchanges objects, or by a failed verifier.
- **Snapshot**: the old objects at the initial mark, as a bitmap of entries
  copied from the **old map** (one bit per entry, set exactly while it holds
  an old object). The marker and the barrier test membership with one bit;
  nothing young is ever in it; no snapshot entry is freed or reused before
  the sweep. Objects promoted or allocated old later are black by not being
  in it.
- **SATB record**: snapshot at the beginning: the value a store is about to
  overwrite, pushed on the storing worker's 512-oop buffer while a cycle
  marks, when the holder is old and the value an unmarked snapshot entry.
  Full buffers go to the marker's queue.
- **Flag word**: the VM-wide barrier word beside the safepoint flag; every
  pointer store loads it once before storing. Bit 0: marking. Nonzero sends
  the store to one out-of-line call with every barrier.
- **Grey**: a marked snapshot entry whose slots are still to be scanned:
  on the marker's stack or in a grey packet in its queue. Black: marked
  and scanned. Marks live in the side byte map.
- **Marker**: the one thread that traces a cycle and sweeps it; a VM
  participant (it parks at stops, never joins a scavenge), at utility QoS
  unless headroom is low. Waits untimed when it has nothing to do.
- **Initial mark**: the snapshot taken at the end of a stop-the-world
  scavenge: the snapshot copy, the roots marked grey, and the survivor
  spaces scanned as roots.
- **Final mark**: a stop the marker requests when it has nothing left:
  every partial SATB buffer and queued item drained, dead holders filtered
  out of the remembered set, ephemerons resolved, weak slots naming dead
  snapshot entries nil'ed, the verifier run.
- **Lazy sweep**: the marker freeing the unmarked snapshot entries after the
  final mark, while the world runs, into **pending runs** owned by a list of
  their own; the snapshot map is cleared word by word. A used entry the
  sweep has not reached yet and will free is **pending dead**: the
  verifiers skip its slots.
- **Apply**: publishing a finished sweep at the next scavenge or full
  collection, or in a short stop the sweeper requests: pending runs to the
  allocators, blocks without a live body (and not taken since the
  snapshot) freed.
- **Fallback**: a full stop-the-world collection forced by space while
  concurrent marking is configured (old space past its soft limit after a
  scavenge, or the table full). A provisioning failure, counted by the
  phase it found, never hidden.
- **Headroom**: the free fraction of old space's soft limit. The marker is
  raised to user-initiated QoS while it is below a threshold, and the
  predictor compares the time the promotion rate takes to fill it with a
  cycle's duration.
- **Floating garbage**: objects that died during a cycle but were marked
  (reachable at the snapshot): freed by the next cycle. Counted in bytes by
  the verifier.
- **Weak keep-alive**: the read barrier on `at:` of a weak slot while a
  cycle marks: the referent is recorded like an overwritten value, since
  the marker never traces weak slots.
- **Relocation**: moving live old objects out of sparse blocks while the
  world runs (module 6), by the marker thread between the final mark and
  the sweep. The **relocation set** is the blocks chosen at the final mark:
  snapshot blocks whose live bytes (counted by the marker) are under a
  threshold, up to a cap on the free blocks under the soft limit. An
  **evacuated block** is one all of whose live objects moved.
- **RELOCATING**: the state of an entry whose body is being copied: its
  state word is the old offset + 2^32, which leads to the intact old body
  through the heap's second mapping, so reads and stores need no check.
  Entered by a CAS, left by the **switch** (one release store of the new
  offset) or a revert. Never seen at a pause.
- **Post-store check**: after every mutator store into a heap object, the
  state word reloaded (the store and the reload both seq_cst); if it
  changed or was RELOCATING, one out-of-line call waits out the copy and
  stores again into the body the entry now leads to.
- **Hazard slot**: one of two words per worker in which a primitive that
  keeps a body pointer across a loop (the array copy) publishes the object;
  the relocator reverts and skips a hazarded object.
- **Epoch**: a global counter the relocator increments when it evacuates a
  block, and each worker's epoch word: the epoch it last saw where it held
  no body pointer (a poll slow path, a park), 0 while entering the VM,
  quiescent outside it.
- **Pending block**: an evacuated block waiting until every worker's epoch
  word is past the epoch recorded with it, or the next pause, whichever is
  first; then it is freed and handed to the allocators. Every pause frees
  every pending block first.
- **Apply** (module 6): the pause that publishes a sweep also ends the
  cycle's relocation: frame pins cleared, blocks left in the relocation
  set returned to the pool.
- **Local collection** (module 7): a nursery collected by its owning worker
  while every other worker runs: a concurrent mark of the nursery's young
  objects (Y) whose action on a marked object is the copy (module 6's
  protocol through the entry's state word). The owner's pause is the whole
  collection.
- **Offloaded collection**: the main worker's nursery collected by the
  young collector thread while the main worker allocates in the other half
  of its eden. The owner's pause is the **flip**: handing the full half and
  its stash to the collection and switching to the other half.
- **Round**: one step of a young collection's handshake: every participant
  inside the VM does a piece of work for it at its next safepoint and
  acknowledges. H0 turns the barrier on (clears the participant's stale
  deletion records), H1 hands over roots (its stack) and buffers, a drain
  round hands over buffers again; collection stops after the first drain
  round that copied nothing.
- **Acknowledgement**: a participant's part of a round, done at a poll or
  in a wait; or **by proxy**: done by the collector under the safepoint
  mutex for a participant outside the VM, or in a blocking region (whose
  flushed stack it scans).
- **Blocking region**: a primitive that may block long without touching the
  heap (the shell call, a test primitive) brackets itself; inside, rounds
  are acknowledged by proxy and the worker's epoch word is kept.
- **Deferred free**: a dead young entry that a remembered list may still
  name (its remembered word was nonzero at the sweep): it gets slot count 0
  and the deferred header bit, and its nursery frees it after the epoch, or
  at its next collection if another collection re-armed it, or at a
  stop-the-world scavenge's pause. Neither young nor old: no snapshot holds
  it, every verifier skips it.
- **Young-root scan**: the initial mark without a scavenge: every
  nursery's eden (or current half) and survivor-from bodies are walked and
  their slots greyed, since young objects are not snapshot entries.
