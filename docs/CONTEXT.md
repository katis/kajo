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
- **Development protocol** (module 9b, ADR 0011): the one connection every
  developer tool (the developer UI, the `kajo` CLI, an agent through MCP)
  uses to reach a target: JSON lines of requests, replies and events over
  a transport the host opens, a session per connection opened with the
  token. Development images only.

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
- **Final collection**: the stop `VM.destroy` runs before releasing
  anything: the promote-all hook with every VM thread joined, after which
  nothing is young and every stash's entries go back to the pool, so the
  image the host holds is whole (docs/modules/vm-teardown.md).
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
  sends it `modificationForbiddenAt:value:` (index, value). Method literals
  are read-only.
- **Symbol table**: the Array of buckets of interned Symbols; a lookup
  compares bytes, a new Symbol is inserted with the world stopped. Weak
  (8b): the buckets are WeakArrays, a Symbol nothing else references is
  collected and its slot is a **tombstone** the next insertion reuses.
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

## Kernel and compiler (module 8b)

- **Tonel**: the kernel's source format, one file per class: a class
  definition in STON, then the methods, each with its protocol.
- **Bootstrap compiler**: `KajoCompiler`, the Swift compiler from Smalltalk
  method syntax to bytecode set v1. It builds the image and stays the
  oracle the compiler in Smalltalk is compared with.
- **Compiler in Smalltalk**: the kernel's Scanner, Parser, Compiler and
  BytecodeGenerator; it must produce exactly what the bootstrap compiler
  produced for every method (CompilerTest).
- **Captured variable**: a temp or argument a real block other than its
  own scope uses. Captured and assigned, it lives in a **temp vector**;
  otherwise it is **copied** into the closure.
- **Inlined block**: a literal block of `ifTrue:`, `whileTrue:`, `to:do:`
  and the other inlined selectors, compiled as jumps in the enclosing
  method or block; its temps are that scope's.
- **Image build**: Tonel files to an image: define, compile, install,
  initialize in a VM, save (`kajo build-image`).
- **Entry point**: special object 7 of an image, the object `kajo run` and
  `kajo test` start a fresh Process at (`run:of:`, `setup:`, `test:`): the
  class Smalltalk in the kernel.
- **Well-known class**: one of the 27 classes the VM knows by index
  (SmallInteger to WeakArray); the kernel's file for it must agree with the
  VM's format and may give it a superclass.
- **Event**: one JSON object of the core event protocol, versioned `"v":1`
  and stamped with the time it happened; the CLI writes them as NDJSON.
  Kinds in v1: `run.started`, `test.started`, `test.passed`, `test.failed`,
  `test.errored`, `transcript`, `gc`, `run.finished`.
- **Pragma index**: pragma selector to the Pragmas of every installed
  method, kept by installation, saved with the image; `Pragma allNamed:`.
- **Consumer** (of a pragma): a class that declares the pragma selectors
  it reads with a class-side `<consumesPragmas: #(...)>`; any other pragma
  is a compile warning.

## Live compilation (module 8d)

- **Loop body vector**: the temp vector an inlined loop body (`to:do:`,
  `whileTrue:`, `timesRepeat:` and the other inlined loops) owns for its
  captured and assigned temps, made afresh at the top of every pass, so a
  block made in one iteration keeps that iteration's values (Pharo's
  rule). The vector's **owner** is the nearest enclosing scope that is
  real or a loop body; inlined conditionals own none.
- **Class variable**: a capitalized name declared in a Tonel file's
  `#classVars`, shared by the class, its class side and every subclass.
- **Binding**: the kernel object (key Symbol, value) that is a class
  variable. The **class pool**, a read-only Array of a class's Bindings,
  sits in its metaclass; a method that names the variable holds the
  Binding itself in its literal frame and sends it `value` or `value:`.
- **Make** (a method): primitive 143, the kernel compiler's CompiledCode
  made into a CompiledMethod by the VM: read in a stop, built by the code
  the image build uses, verified by the one bytecode verifier, read-only
  and pinned before anything else sees it. The trust boundary for code
  from Smalltalk; a refusal is a String the kernel signals as a
  CompileError.
- **Doit**: source evaluated by `Compiler evaluate:`: compiled as a method
  `DoIt` of the receiver's class answering its last statement, made, run
  once by primitive 85 (`valueWithReceiver:arguments:`), never installed.
- **Release image**: an image whose header's flag (format 3, word 5 bit 0)
  forbids making, installing and removing methods from Smalltalk; set by
  `kajo build-image --release` or `kajo seal`, never cleared, read by
  `Smalltalk isReleaseImage`. The kernel signals **InstallForbidden**.
- **Development image**: an image without that flag.

## Live classes (module 8e)

- **Class definition** (in the image): a class's `ClassDefinition`, its
  own instance and class-side instance variable names, category, format
  kind and comment, which `Smalltalk` keeps per class; the class
  variables are its pool.
- **Define, redefine, remove**: primitives 145, 146 and 147, in the
  install stop, re-checking the image build's class rules (`ClassRules`);
  the kernel's `ClassBuilder` and the Smalltalk-80 `subclass:...`
  protocol over them. A refusal is a String the kernel signals as a
  **ClassDefinitionError**.
- **Reshape**: a class's instances given a new layout (module 1), all or
  nothing with its subclasses', every slot kept **by name**; in a
  redefinition, every method of the classes reshaped is made again from
  its recorded source against the new shape in the same stop, and the
  old ones are **forwarded** (become, one way) to their new selves, or to
  a **stub** that says the method was removed.
- **Running-frame rule**: no reshape or removal of a class while a frame
  of any Process runs one of its methods; the change is refused naming
  the Process and the method.
- **Undeclared** (Binding): the Binding of a class variable removed from
  its class: the methods that hold it read nil and a write is an error;
  adding the variable again declares the same Binding.
- **Obsolete class**: a removed class, kept in the class table renamed
  `AnObsolete<Name>`, outside the hierarchy and `Smalltalk allClasses`.
- **Category** (of a method): the protocol a method is filed under, kept
  per class and side by selector; `organization`.
- **Canonical form** (Tonel): the one text the image's Tonel writer
  writes for a class (definition keys in one order, `#type` only when not
  inherited, methods by side, category and selector, the recorded
  sources); `kernel/` is in it byte for byte, which a test checks by
  building the image and writing it out.
- **Sources directory**: the one directory the host opens a VM with
  (`--sources`); the file primitives read and write under it and nowhere
  else.

## Saved Processes (module 8c)

- **Saved Process**: a live Process in an image: its Process object (state
  ready or waiting, `record` -1) and its **saved stack**, the stack words
  `[0, sp]` copied into Arrays of at most one block. Frame links, saved pcs
  and Context frame numbers are indices and offsets, so they are saved as
  they are.
- **Scheduler state**: special object 8 of an image with saved Processes:
  the ready queues' heads and tails, the finalization Semaphore, the list
  of saved Processes with their stacks, the saver, the next id. nil once a
  VM has resumed them.
- **Saver**: the Process that sent `Smalltalk snapshot:`; it resumes after
  the send with true (false where the image was saved).
- **Hold** (on the scheduler): while a save is in progress no Process is
  dequeued and a running one leaves its worker at its next poll, as a
  preemption does, so every saved register is exact.
- **Resume**: a VM over an image with saved Processes installs them
  (records, stacks, queues) before any worker starts; `kajo run` runs them
  until nothing can happen without the host.
- **Saved-frame rules**: the loader's checks of every saved frame against
  its method and the bytecode verifier's **traced depth** at its pc (the
  operand depth the verifier computed for that instruction on every path).

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
- **Shell** (module 9a): a native application (`apps/KajoShell-macOS`,
  `apps/KajoShell-iOS`) that owns the run loop, the display link and the
  views and gives the VM its main thread in turns, through the **host
  surface** (`ShellVM`, `Sources/KajoVM/Shell/`). The shells share
  `KajoShellCore`; a platform is a `ShellPlatform`.
- **Event queue**: the shell's FIFO of native events (kind, the target
  view's handle, a value, the time the event happened), filled from any
  thread; one external signal per event wakes the **event loop**, the
  kernel's one main-affine Process (`UIEventLoop`) that takes events and
  dispatches them to wrappers.
- **View wrapper** (ADR 0010): a Smalltalk object (View, Window, Label,
  Button, TextView, Slider) holding the **handle** of a native view the
  shell keeps in its table; every view call is primitive 150, a hop
  primitive, answered by the shell's **view host** on the main thread. A
  dead wrapper's handle is released through its Ephemeron.
- **Frame account**: the share of each display frame the shell gives the
  VM (4 ms); past it a turn runs UI-priority Processes only, for 0.5 ms.
- **Probe view**: the plain View Smalltalk moves on every frame event, so
  the display (ProMotion) never idles and a missed frame is visible.
- **Stuck report**: a main-affine Process runnable for longer than the
  shell's limit (300 ms), reported once to the shell with its id and
  selector.

## The development protocol and the debugger (module 9b)

- **Target**: the running image a development session acts on (the iOS
  shell, the macOS shell, a headless `kajo run --protocol`).
- **Request**: a `<devProtocol>` method of `DevSession`; its kind is its
  selector's first keyword split before the first capital
  (`process.retrySend`), its arguments its argument names. A **reply**
  answers one request by its id; an **event** answers none.
- **Protocol Process**: the target's one Process at the highest priority
  that takes the transport's requests and runs each in a Process of its
  own.
- **Transport**: what carries the protocol's lines (a Unix-domain socket in
  9b; TCP in 9d), owned by the host; it checks every line before the image
  sees it.
- **Pairing token**: the short random string a target shows when it opens
  its transport; a session opens only with it. Never written to a file by
  the target.
- **Session**: one connection's dealings with a target: its client
  (`developer`, `agent:<name>`, the **author** of every change it makes),
  its **package**, and the objects it holds by **handle**.
- **Package**: the project a class or method belongs to (a directory of
  Tonel files, Kernel for `kernel/`); a method of another package than its
  class's is an **extension**, written to `<Class>.extension.st`.
- **Author mark**: which agent made a method, a pragma in its source
  (`<author: #'agent:claude'>`; until the development answers, Tonel
  metadata).
- **Stopped Process** (a **DebugStop**): a Process waiting for the
  debugger with its stack intact (an unhandled error where the host says
  a debugger can come, a step's end, a suspend); it runs the debugger's
  commands on its own stack. At most 32 error stops stand (the **stop
  cap**).
- **Cut-off**: a `terminate` that ended a Process where it stood after the
  unwind bound (1 s), its unwind blocks not run to their end; counted and
  reported.
- **Frame restart**: re-running the send a frame's sender made, with the
  frame's receiver and arguments, after unwinding the frames above; the
  method is looked up again. **Retry a send**: the same for the send that
  ended in doesNotUnderstand: (define the method, then retry).
- **Step**: into, over, out; decided at the poll for the stepped Process
  only, its returns caught by the **step marker** on the frame stepped.
- **Interrupt**: something a Process runs when it is next resumed, as a
  send from where it stands with the discard marker: `terminateUnwinding`,
  `stopForDebugger`.
- **pc-to-source map**: a method's last literal under flag 16, the source
  range of each send by pc.
- **Class-table hole**: an index whose removed class was freed; no object
  carries it, the next class defined takes it.
- **Sealed extension**: a method installed into a sealed class, allowed
  when it only sends messages.

- **Development image**: an image built from `kernel/` and `tools/` (and
  any other package, `kajo build-image --with <dir>`): the one the
  developer UI runs in. A release image never carries `tools/`.
- **Tools** (the package): the developer UI in Smalltalk (module 9c): the
  browser, workspace, inspector, debugger, test runner, transcript and
  target picker, each a **model** (what it shows and asks its target,
  tested with a fake client) and a **window** (the views over it).
- **DevClient**: the protocol's client in Smalltalk, one per connected
  target; requests are messages, replies and events arrive on the UI's
  event loop.
- **Local target**: the development image serving its own protocol, its
  tools connected to its own socket: Kajo develops Kajo.
- **Client transport**: the host's side of a DevClient's connection
  (primitive 164, `ClientHost`): it owns the socket and the token, checks
  every line and posts it as a `line` event (one String up to 16 MiB - 1
  since the large-bytes follow-up; a longer one in `linePart` pieces) and
  the end as a `lost` event.
- **Hand-over**: the event loop giving the events to a new loop Process
  when a tool's error stops the old one for the debugger.
- **Push and on-demand** (a data source's forms): the image gives a
  table or an outline all its rows or items at once, or a row count and
  the roots first and the rest as the view asks (an `expand` event).
- **LargeArray** (module 9c, removed by module 10): a sequence longer
  than one heap object could be, made of Arrays of 2048; the growable
  collections used it past 4095 slots until large objects made it
  unnecessary.

## The phone transport (module 9d)

- **Target address**: where a target listens, in one of three forms a
  person can type and a targets file can hold: a Unix socket's path,
  `tcp://host:port`, `bonjour:<name>`. A **target name** (a line of
  `~/.kajo/targets`, or a phone the network shows) stands for one.
- **Serve mode**: a shell serving the development protocol over TCP while
  a scenario runs (`mode=serve`, or `protocol=tcp[:port]`): the iOS
  shell's way of being a target, the macOS shell's stand-in for the phone.
  Only a development image serves, and only when asked.
- **Bonjour advertisement**: the `_kajo-dev._tcp` service a serving shell
  registers, named after the device; its **TXT record** carries the
  image's name, the protocol's version and the kernel's version, never the
  token.
- **Pairing screen**: what a serving phone shows: the token, large, its
  Bonjour name and addresses, what the listener does, and a **new token**
  button that ends every session.
- **Failed pairing**: a `session.open` with a wrong token, or a first
  request that is not `session.open`; three close a connection, ten within
  a minute make the listener **refuse** every connection for a minute.
- **Dropped link**: a connection that ended without its client closing
  it (the phone left the network, the socket died); the client
  **reconnects** with a growing wait (1, 2, 4 s, up to a minute) and opens
  a new session as the same client in the same package.
- **Retried request**: a request pending at a dropped link, sent again
  on the new session with its id; the **not-retried** kinds (`evaluate`,
  `process.evaluate`, `process.step`, `test.run`) fail instead, because
  running them twice is not running them once.
- **Outage**: from a dropped link to the new session's opening.
- **Pairing**: giving the host a target's token: the developer reads it
  off the phone's screen and types it into the host's own secure field
  (`ClientTransport pair:`); no token ever passes through the image.

## Large objects (module 10)

- **Large object**: an object whose body does not fit one 32 KiB block
  (more than 4095 slots or 32 760 bytes), up to the header's count field
  (16 777 215 slots or bytes). Old at birth, never young, never relocated
  or compacted. Recognised by its count (`Header.isLarge`), not by a
  header bit.
- **Run**: the contiguous blocks a large object's body owns alone: the
  **head**, where the body starts (its `used` is the body's bytes, past
  the block), and its **continuations** (`used` 0). No entry points into
  a continuation; no run block is ever in the block pool.
- **Block kind** (the **side table**): per block, ordinary, head or
  continuation (`BlockHeap.kind`); a free block is ordinary and not in
  use. Written under the pools lock or with the world stopped, and saved
  in the snapshot's block table (image format 5).
- **Run blind** (a test switch, `TestSwitches.runBlind`): one reader of a
  body treats runs as ordinary blocks, so that reader's test shows the run
  rule matters.
- **Mark chunk**: the 4096 slots of a large object the concurrent marker
  scans at a time; the rest goes back on its stack as the oop with the
  next chunk's number in bits 40..63, and counts 32 objects toward the
  marker's poll interval.
- **End growth**: blocks reserved past the promotion reserve that only
  the VM's final collection may take (`ObjectMemoryConfig.endGrowthBytes`,
  as large as the reserve unless set), so the promote-all at the VM's end
  grows old space instead of trapping.
- **Hard limit**: the blocks a promotion may hold, the soft limit plus
  the promotion reserve; past it lies the end growth.
