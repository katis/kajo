# ADR 0009: Object model and bytecode set

Date: 2026-11-02
Status: proposed (accepted in principle by the project owner; each section
is revised as the module that implements it is built). Sections 2 to 11
built in module 8a; see "Built (8a)". The kernel's parts and section 12
built in module 8b; see "Built (8b)".

## Context

Modules 1 and 2 carry "object model v0" and "bytecode set v0": the
experiments' kernel of classes, a method made of a literal frame and a byte
object, SmallInteger as the only number, and no blocks, exceptions,
metaclasses, strings or weak references. `docs/PLAN.md` puts the kernel,
compiler and image build at module 8 and says this ADR precedes it. Three
of its decisions precede module 5 as well, because the collectors of ADRs
0005 to 0008 must know about weak slots, ephemerons and immediates from the
first line, and module 3 fixes what a frame records.

The constraints every section works under: the object table (ADR 0003,
oops never change and nothing outside the object memory computes a body
address); one jump table per dispatch loop and no ARC in hot paths (ADR
0001); concurrent marking with a snapshot-at-the-beginning barrier (ADR
0006) and concurrent relocation through the entry switch (ADR 0007); native
frames on Process-owned stacks with budgeted preemption (ADR 0004); and
Smalltalk Processes that truly run in parallel.

## Decisions

### 1. Weak references and ephemerons (before module 5)

- A class format may be **weak**: the object's indexed slots are not traced,
  and a slot whose referent is reclaimed becomes nil at the end of the
  collection that reclaimed it.
- An **Ephemeron** is an object whose first slot is a key traced only if the
  key is reachable from somewhere else. When the key is found unreachable
  except through ephemerons, the ephemeron is queued for finalization, its
  other slots are traced, and the key survives that one collection.
- A single **finalization queue** (a Semaphore the collector signals from
  outside, per module 3's external signal queue) is drained by one kernel
  Process that sends `mourn` to each ephemeron. Finalizers never run on a
  collector thread.
- Native resources (views, files, timers) are owned through ephemerons, so a
  Smalltalk wrapper dying releases the native object, and nothing native is
  kept alive by a cache.

Why: a live UI binds Smalltalk objects to native views for as long as either
side lives, and weak-only schemes leak the native side. Ephemerons are the
standard answer and cheapest when the marker is designed for them: modules
4 to 7 add weak slot treatment to the scavenge, the SATB marker and the
relocation pass as they are built, not afterwards.

**v0 (module 4, 2026-11-02).** A class's format word (below, section 6)
marks it weak or ephemeron; kasm's `class` directive takes `weak` or
`ephemeron`. Weak: the indexed slots (past the named ones) are not traced;
the scavenge nils those whose young referent died, module 1's mark-sweep
those whose referent is unmarked. Ephemeron: slot 0 is the key; module 1's
mark defers an ephemeron whose key is unmarked, traces those whose keys get
marked, then fires the rest at once: header bit 48 set (a fired ephemeron
is strong, so it is queued once), appended to the finalization queue (a
root) and traced, so key and value survive that collection. After the
stop the Semaphore registered with primitive 36 is signalled through the
external queue; a Process takes each ephemeron with primitive 37
`nextMourner` and sends `mourn`. The v0 rule: a scavenge treats ephemerons
as strong, so a young key's finalization waits for the first full
collection. Module 5 implements the key rule in the concurrent marker.

**The concurrent marker (module 5, 2026-11-03).** The marker does not
trace weak slots; it lists every weak object and every unresolved
ephemeron it marks. An ephemeron is unresolved when its key is an unmarked
snapshot entry (a key that is young or newer than the snapshot is live by
construction); one whose key is marked is traced at once. At the final mark
(world stopped): unresolved ephemerons whose key got marked are traced, to
a fixpoint; the rest are fired (bit 48, the finalization queue, the
Semaphore signalled after the stop) and traced, key included, so key and
value survive the cycle; then every listed weak object's weak slots naming
an unmarked snapshot entry become nil. Survivors (young at the snapshot)
are scanned as roots with their weak and ephemeron slots strong. Because
the marker runs while mutators do, `at:` on a weak slot records its
referent while a cycle marks (a keep-alive read barrier): otherwise a
referent read through a weak slot and stored elsewhere would be freed under
a live reference. Ephemeron keys need no such barrier: a marked
ephemeron's key is marked by the final mark either way. One consequence: an
ephemeron whose key was reachable only through it at the snapshot is fired
even if a mutator read the key through it during the cycle.

### 2. Immediates: SmallInteger, SmallFloat, Character (before module 4)

The tag scheme of module 1 reserved the low-nibble patterns with bit 0 clear.
They become:

| low bits | kind | payload |
|---|---|---|
| `...1` | SmallInteger | 63-bit two's complement (unchanged) |
| `..10` | SmallFloat | 62 bits: sign, 9-bit exponent, 52-bit mantissa |
| `0100` | Character | 60 bits, a Unicode scalar value |
| `0000` | object reference | entry offset (unchanged) |
| `1000`, `1100` | spare | rejected by the verifier and loader until assigned |

A SmallFloat holds every IEEE double whose exponent fits 9 bits (about
1e-77 to 1e77, including zero, and with the full 52-bit mantissa); other
doubles, NaN and infinities are boxed as `Float` byte objects. Encoding and
decoding are a rotate and a compare, inline in the arithmetic primitives,
with the boxed path out of line.

Why: UI geometry, animation and layout are floating point, at 120 Hz. Boxing
every float is allocation on the frame budget and churn in the nursery, and
the experiments showed the phone pays for every allocation. SmallFloat uses
four of the seven spare patterns to keep a 9-bit exponent; a 7-bit exponent
(one pattern) would box at 1e19 and surprise ordinary code.

### 3. Frames, contexts and the debugger (module 3 fixes the frame)

- **Frames stay native**, on the Process's stack, as module 2 laid them out.
- A frame can be **materialized** into a `Context` heap object on demand:
  for `thisContext`, for a block that can return non-locally, when a
  debugger opens, and when a Process is snapshotted. The frame header
  reserves one slot for its Context (nil until materialized); the Context
  names its Process and frame, and reads and writes go through the frame
  while it lives. When the frame returns, the Context is detached and keeps
  a copy of its state, so a debugger or an inspector can hold it.
- Nothing is ever de-materialized back into a frame. A Process saved in a
  snapshot keeps its frames as they are: its stack words are copied into
  heap Arrays (frame links are indices, so they need no fixing) and copied
  back into a fresh stack when the image resumes; materialized Contexts
  keep their frame indices (module 8c, Built (8c) below).

Why: Smalltalk-80's heap contexts made every send an allocation; Cog and
friends made frames native and reify lazily, and it is the only design in
which both the interpreter and the debugger are first class. ADR 0004 named
"freezing suspended Processes into contexts" as the same mechanism the
debugger needs, and this is it.

### 4. Blocks and non-local return

- A block is a **closure object**: its compiled block method, the receiver,
  and copied values. A temporary that is written after capture by any
  closure is allocated in a **temp vector** (a heap Array) shared by the
  method and its closures; others are copied by value.
- A block containing `^` also captures its **home Context**, which
  materializes the home frame when the closure is created. Non-local return
  unwinds the Process's stack to the home frame, running `ensure:` blocks on
  the way; if the home frame has returned, the block is sent
  `cannotReturn:`.
- Blocks are reentrant and may run on any worker; a closure holds no frame
  address, only oops.

Why: this is the compiled-closure design the fast Smalltalks converged on.
The temp-vector rule keeps the common case (a loop body reading an outer
temp) allocation free apart from the closure itself.

### 5. Exceptions and unwinding

- `ensure:` and `ifCurtailed:` are ordinary methods whose frames carry an
  **unwind mark** in the method header; the unwinder finds them by walking
  frames, not by a separate handler stack.
- `on:do:` is a method with a **handler mark**; signaling walks the
  signaling Process's own frames from the top, materializing as it goes,
  and runs the handler on top of the signaling stack so exceptions are
  resumable, retryable and returnable as in ANSI Smalltalk.
- Walks and unwinds are primitives that operate on one Process's stack and
  are bounded by its depth; they never block.

### 6. Classes, metaclasses and class format

- **Classic metaclasses**: every class is the sole instance of its
  metaclass, class-side methods and class instance variables work as in
  Smalltalk-80, `Metaclass` and `Class` meet at `Class class`.
- A class's **format** says: the number of named slots, and one of pointers
  (fixed or variable), bytes, 16-bit, 32-bit, 64-bit words, weak, or
  ephemeron. The object memory keeps only "pointers or bytes" in the header
  (bit 47) and the count; the finer kind is the class's, read by primitives
  and the collectors through the class table.
- Changing a class's format while instances exist is module 1's `reshape`
  applied to `allInstances`, done at a stop.
- **Sealed classes** of module 2 (Class, Metaclass, Method, MethodDict, and
  Process and Semaphore from module 3) stay sealed from `instVarAt:put:`,
  `become:` and `basicNew`; the kernel changes them through primitives
  that keep the VM's invariants.

**v0 (module 4, 2026-11-02).** The format word lives beside the class
table (`ClassFormat`: bits 0..15 named slots, 16 weak, 17 ephemeron), is
set by the loader from kasm and saved in the snapshot (version 2). Only the
collectors read it yet; no metaclasses, no 16/32/64-bit word formats.

### 7. Integers

- SmallInteger overflow in `+ - *`, bit shifts and `//` produces a
  **LargePositiveInteger** or **LargeNegativeInteger**, byte objects holding
  the magnitude little-endian. Primitives implement the arithmetic,
  comparison and bit operations on them and normalize results back to
  SmallInteger when they fit. Printing, parsing, `gcd:` and friends are
  Smalltalk.
- There is no 32-bit integer class; the phone and the Mac are 64-bit.

### 8. Strings, Symbols and Characters

- There is **one `String` class**, a byte object holding **UTF-8**, with
  Swift's and Rust's string design as the inspiration rather than
  Smalltalk-80's: a String is an immutable sequence of Unicode scalars
  stored as bytes, not an integer-indexed array of characters. Positions
  are byte offsets valid only at scalar boundaries (Rust), iteration is by
  scalar (`do:` yields Characters), the bytes are reachable as a read-only
  view (`utf8`, constant-time `at:` and `size`), and strings are built with
  streams and concatenation, never with `at:put:`. Grapheme clusters and
  normalization are later kernel libraries (Swift's `Character` is a
  grapheme; Kajo's is a scalar, section 2, until the Unicode tables exist).
- `Symbol` is an interned `String` subclass with identity `==`; it is the
  representation of selectors and literal `#foo`, with the same bytes and
  the same protocol, not a second text representation. Interning is a
  kernel table with a weak set.
- `Character` is immediate (section 2); there is no Character table.

Why: every native API on the two targets takes UTF-8 or converts to it;
Swift `String` is UTF-8; a 32-bit-per-character string crosses the shell
boundary four times as large. The owner asked for a single String type
(2026-11-03), which rules out the earlier `AsciiString` fast path: an
integer-indexed protocol over UTF-8 is either O(n) or a lie, so the
protocol is index-free in Swift's and Rust's way instead. Constant-time
positional access is on the byte view, for code that knows what it holds.

### 9. Read-only objects

- Header bit 50 marks an object **read-only** (bit 48 is the fired
  ephemeron of section 1 and module 4, bit 49 module 7's deferred free;
  the first draft of this section said 48). `at:put:`, `instVarAt:put:`,
  `become:`, `reshape` and every store bytecode check it; a store into a
  read-only object fails the primitive or the bytecode's slow path, which
  sends `attemptToModify:at:value:` to the object. The kernel decides what
  that does (raise, log, or copy-on-write).
- Method literals are read-only. The kernel may mark objects a view is
  displaying so a background Process cannot mutate them unnoticed.
- The bit is set and cleared by a primitive at a bytecode boundary, with
  one relaxed store; a concurrent store check that sees the old value is a
  race in the program, not in the VM. The collectors never read bit 50.

### 10. Bytecode set v1

- One-byte opcodes, one opcode per dispatch case; one-byte operands with
  an **extension prefix** opcode for larger indices. Opcode numbering,
  operand formats and stack effects stay in one table (module 2's
  `Opcodes.swift`); the loader's stack-depth tracer and the assembler read
  it.
- **Inlined control flow**: `ifTrue:`, `ifFalse:`, `ifTrue:ifFalse:`,
  `and:`, `or:`, `whileTrue:`, `whileFalse:`, `repeat`, `to:do:` and
  `timesRepeat:` compile to conditional and unconditional jumps when their
  arguments are literal blocks. `mustBeBoolean` is a send, as in module 2.
- **Special sends** with a fast path and a full send fallback: `+ - * / //
  \\ < > <= >= = ~= == ~~`, `at: at:put: size class value value: value:value:
  isNil notNil`. The fallback must leave the stack as a plain send would.
- New opcodes: `push_closure` (block method literal, copied-value count),
  `push_temp_vector_slot` and `store_temp_vector_slot`, `push_this_context`,
  `send_super`, `block_return`, `nonlocal_return`.
- A compiled method is two objects, as in module 2: a `Method` with the
  literal frame, header slots (argument and temp counts, primitive number,
  unwind and handler marks, the class it was compiled in for `super`) and a
  reference to its bytecodes; the bytecodes a byte object. Block methods are
  `Method` instances held in the literal frame of their outer method.

Why: these are the parts of a bytecode set that have stopped changing
across implementations, and the parts that haven't (operand widths,
exactly which sends are special) are hidden behind the opcode table at a
cost module 2 measured as nil.

### 11. Message sends

- `doesNotUnderstand:` with a `Message` (module 2), `perform:` and its
  arities as primitives that enter the send path, `respondsTo:` as a lookup
  primitive. `super` looks up from the superclass of the method's defining
  class, carried in the method header.
- The lookup cache is per worker (module 2); a method dictionary change
  flushes every worker's cache at the next safepoint, and installs are
  therefore ordered after the flush.

### 12. Shared mutable state across Processes (kernel design)

- Processes run in parallel; the VM provides atomic reads and writes of
  single slots and `become:`, nothing more. **Kernel collections are not
  synchronized.** Sharing between Processes goes through Semaphores,
  Mutexes, Monitors and queues written in Smalltalk over the VM's Semaphore.
- UI state is **main-affine by construction** (ADR 0004): objects a view
  displays are mutated from main-affine Processes, and a background Process
  that must touch them hops to main. Read-only marks (section 9) catch the
  violations the convention misses.
- No global interpreter lock, now or later.

## Built (8a, 2026-11-03)

Module 8a (`docs/modules/object-model.md`) built sections 2 to 11 in the
VM; section 12 is the kernel's (8b). What each became:

- **1** (module 4 to 7, unchanged): the format word gained the kind,
  sealed and behaviors bits around the weak and ephemeron ones.
- **2**: SmallFloat `..10` (the double rotated, the exponent offset by 768
  into nine bits: 2^-255 to 2^257 and both zeros; plus or minus 2^-255
  boxed, since zero takes its pattern) and Character `0100`; `1000` and
  `1100` spare. The open question is closed: the encoding is a bijection
  on its range, and a property test against Swift's `Double` (200 000
  values) round-trips every one bit for bit. Every "is it a reference"
  site tests `raw & 0xF`; the six that tested `raw & 1` were insertion
  barriers.
- **3**: Contexts are materialized into `hdr[4]` on demand and detached
  (temps copied, frame nil) by return, by being cut, and when their
  Process ends; liveness is checked against the frame's context word,
  never trusted from the index. Contexts of other Processes answer as dead
  (walking a running Process's stack from another is not built). Snapshots
  of Processes are not (the image loader refuses a Process).
- **4**: closures with copied values and temp vectors; a block's frame
  keeps its closure in the word before the header; a block that returns
  non-locally carries its home Context (materialized when the closure is
  made). `cannotReturn:` is sent to the closure.
- **5**: unwind and handler marks are method flags; non-local return with
  no mark between cuts in the VM, with one sends `aboutToReturn:through:`
  and the kernel unwinds over `terminateTo:` and
  `findNextUnwindContextUpTo:` (Smalltalk-80's protocol, shown in kasm in
  the test kernel), as do `on:do:`, `signal`, `resume:` and `return:`.
- **6**: classic metaclasses (Object class's superclass is Class); the
  format word's kinds; sealed classes generalise module 2's structural
  ones and include every metaclass.
- **7**: LargeIntegers normalized; overflow in the special sends makes one
  without a send; arithmetic, comparison, bit operations and shifts as
  primitives; checked against `Int128`.
- **8**: one UTF-8 String, interned Symbols in a heap table (strong in 8a),
  no `at:put:` on either, byte-offset positions checked at scalar
  boundaries; Symbols are no longer host-side names.
- **9**: bit 50, checked in every store path with no extra instruction on
  `store_ivar`; set with an atomic or rather than a store, because module
  7's young collector compare-and-swaps young headers concurrently (it now
  keeps the bit when its swap fails).
- **10**: as written, plus `push_new_array` (making a temp vector) and the
  rule that `==`, `~~`, `class`, `isNil`, `notNil` are answered inline and
  never sent (no fallback for those three, a deviation). The opcode table,
  the assembler and the one bytecode verifier (kasm and image) read it.
- **11**: super through the method class, `perform:` family and
  `respondsTo:` as primitives, installation in a stop with every worker's
  cache flushed before it runs again.

Open questions for the owner, answered 2026-11-03:

- `class`, `isNil` and `notNil` stay inline and can never be overridden
  (no proxies that answer `isNil` true). Pharo inlines `==` and `class`
  only; Kajo adds the two nil tests. Accepted.
- The read-only failure is sent as a two-argument
  `modificationForbiddenAt:value:` to the object (the ADR's first draft
  said `attemptToModify:at:value:`, which 8a sent with the object as its
  own first argument). The kernel's Object signals ModificationForbidden.
  Built in 8b.
- The symbol table is **weak**, as this ADR says; 8a's strong table is
  replaced in 8b (weak slots, tombstoned buckets reused by interning).
- The read-only check's cost on `storeheavy` (1.07 on one worker, 1.10 on
  eight; parity with the bit out of the store mask; the kernels that load
  as well do not see it) is accepted.
- **Images hold Processes** (the third open question below is decided):
  saved Process stacks, their waits and the ready queues are part of the
  image format. Not in 8a or 8b; module 8c builds it before module 9's
  live development needs it.

## Built (8b, 2026-11-03)

Module 8b (`docs/modules/kernel-image.md`) built the kernel the sections
above ask of it, the owner's two answers that were 8b's, and section 12:

- **1**: WeakArray (well-known class 27) and Ephemeron in the kernel; the
  finalization Process mourns, starting with the first registered
  ephemeron in each run.
- **4, 5**: the compilers allocate temp vectors by one rule (captured and
  assigned; an inlined loop's counter is copied per iteration); ANSI
  exceptions in Smalltalk over the frame walks: resume, return, retry (a
  loop in `on:do:`), pass, outer, `ensure:`, `ifCurtailed:`.
- **7**: Fraction completes the tower; Integer `/` answers one when not
  exact.
- **8**: the String protocol as kernel.md decided, written index-free;
  the symbol table is **weak**: buckets are WeakArrays, collected Symbols
  leave tombstones that interning reuses, lookups take the weak read
  barrier.
- **9**: a refused store sends `modificationForbiddenAt:value:`; Object
  signals ModificationForbidden (resumable).
- **10**: the bootstrap compiler and the compiler in Smalltalk inline the
  selectors listed above and the `ifNil:` family, and agree on every method
  of the kernel.
- **12**: kernel collections are unsynchronized; Semaphore, a reentrant
  Mutex, Monitor and SharedQueue in Smalltalk over the VM's Semaphore; the
  kernel's process tests share state only through them. Main-thread
  affinity is a pragma the kernel declares; nothing checks it yet.

## Built (8c, 2026-11-04)

Module 8c (`docs/modules/image-processes.md`) built the owner's answer
"images hold Processes" (Built (8a)):

- **3**: a Process is saved as its Process object and its stack words
  `[0, sp]` copied verbatim into Arrays of at most one block (every word is
  already an oop or a SmallInteger index), under special object 8 with the
  ready queues, the finalization Semaphore and the next id. Frames are not
  rebuilt from Contexts: the frame needs no de-materialization, Contexts
  keep their indices. The sentence of section 3 that said otherwise is
  amended above.
- The loader checks every saved frame against its method: the method in
  the method table, fp from its argument and temp counts, the receiver of
  a class that inherits the method, a block's closure, the context word
  (empty, a return marker, or this frame's Context), and the pc and operand
  depth against the bytecode verifier's traced depth there (now exposed per
  instruction; it was already unique per instruction). Every list the
  scheduler walks is checked acyclic and consistent with its Processes'
  states, all or nothing.
- The save holds the scheduler until every other Process has left its
  worker at a poll (a new protocol, model-checked in
  `docs/models/save-hold.md`), then saves in a stop as the method install
  does. `Smalltalk snapshot:` answers false where it saved and true where
  the image resumes; Delays are re-armed by the kernel for the time they
  had left.

## Consequences

- Modules 4 to 7 implement weak slots and ephemerons as they are built, and
  their briefs say how (nil-ing at the scavenge, ephemeron queue after the
  SATB marker's transitive closure, weak slots not retained through
  relocation). Module 3's frame header reserves the Context slot.
- Module 1's verifier and loader stop rejecting the SmallFloat and
  Character patterns when module 8 introduces them; until then they stay
  rejected.
- Module 8's compiler targets bytecode set v1 and the kernel is written to
  sections 4 to 12. The kasm assembler gains the new opcodes so the
  randomized-program generator and the fuzzers cover them.
- `docs/CONTEXT.md` gains Closure, Temp vector, Context, Ephemeron,
  SmallFloat, Read-only, Unwind mark, Handler mark, Special send.

## Open

- Whether `Float` arithmetic on SmallFloats is exact to IEEE in every
  rounding case after re-encoding (it should be, the mantissa is intact;
  a property test against Swift `Double` decides).
- 16-bit `String` variants for Core Text and UIKit attributed strings, if
  conversion at the boundary ever shows in a profile.
- ~~Whether a Process snapshot (section 3) is part of the image format or
  a separate developer-tool format.~~ Decided 2026-11-03: part of the image
  format (module 8c).
