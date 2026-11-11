# AOT 1: the native engine

Briefed 2026-11-11. The owner's decision of the same day, after a design
discussion: start the ahead-of-time compilation of the sealed Release
image (`docs/PLAN.md`'s row, set aside on 2026-11-08), generating C, with
Zig as the bundled C compiler for future non-Apple targets, and without a
separate experiment first ("we already know we can get a lot of
performance wins because of prior art"). This is the first of three
modules:

1. **The native engine** (this brief): a generator from an image's methods
   to C, the VM's runtime half that binds and runs the result beside the
   interpreter, every verification layer run in both engines, measured on
   the Mac, in the Mac shell and on the iPhone.
2. **The product** (later): a generated app's Release build compiles its
   sealed image, `dist.sh` and the prebuilt frameworks, `new-check`'s
   assertions, sizes, opt-in or default, and Zig bundled when the first
   non-Apple target exists.
3. **The optimizer** (later): guarded direct calls and inlining from the
   class hierarchy and a development-time profile of receiver classes.

It changes the core directories, so the core tier's gates are owed.

## Why it is feasible here

A sealed image is a closed world: a release image refuses the make and
install primitives and the class primitives, so the set of methods is
fixed when the app is built. iOS forbids generating code at run time, not
code compiled at build time and signed with the app. And the object table
means a reference held in native code needs no fix-up when its object
moves.

`doesNotUnderstand:`, `perform:`, `become:`, Contexts, non-local return
and unwinding stay exactly as they are: they are slow paths of the VM,
and native code calls the same ones. There is no tree shaking by
reachability; every method of the image exists in the app, native or
interpreted.

## The shape

`kajo aot <image> -o <dir>` reads an image and writes C: a prelude and one
function group per method. A method's bytecodes become straight-line code
with operands folded, the operand stack mostly in C locals, the fast paths
the interpreter has inline (SmallInteger arithmetic and comparison,
`at:`, `isNil`, jumps on Booleans) inline in C, and everything else a call
of the VM's own slow path, primitive or poll through a small interface.
The C is compiled by the platform's compiler (Xcode's clang on Apple
platforms; `zig cc` where no compiler can be assumed, in module 2) and
linked into the app, or into a dylib for tests on the Mac.

At launch the VM binds each method of the image to its function group
through a table keyed by a hash of what the generator read. A method with
no match runs in the interpreter. The interpreter stays whole: it runs
development images, methods the generator declined, and any frame the
native engine hands back.

## The rules

These are the module's invariants. Where the code shows one of them
cannot hold as written, say so in the doc with the trace and build what
keeps its intent.

1. **One frame layout.** Native code keeps its frames on the Process's
   stack in the VM's own layout (`fp[0]` receiver, arguments, temps, the
   five header words, the operand stack; links as indices and offsets).
   The interpreter, the collectors, Contexts, the unwind and handler
   walks, stack growth, the saver and the loader see the same frames
   whichever engine made them.
2. **The saved pc is the bytecode pc.** A frame's caller pc, a Process's
   saved pc, a Context's pc and the pc-to-source map never name a native
   address.
3. **Resume points.** A method's native code is a set of functions, one
   per place the method can be entered or continued: its entry, each send
   (a poll rewinds to the send), the instruction after each send, each
   backward jump's target, and the instruction after every instruction
   whose slow path can run other code or activate a frame (the special
   sends that fall to a real send, a refused store, a non-Boolean jump,
   and whatever else the reading finds; list them all in the doc). At a
   resume point everything live is in the frame's slots, and the operand
   depth is the verifier's depth at that pc.
4. **The engines are interchangeable at resume points.** Any frame whose
   pc is a resume point of a bound method may be continued by either
   engine, and any frame at all may be continued by the interpreter. So
   every fallback is sound by construction: when in doubt, the
   interpreter runs it.
5. **A flat C stack.** A native send or return is a guaranteed tail call
   (`musttail`). A slow path is an ordinary call that returns. Native
   code never calls `interpret` and `interpret` never calls native code;
   a driver loop above both chooses. Nothing native is on the C stack
   when a Process leaves its worker.
6. **Nothing of the heap or the frame is kept across a call into the
   VM.** Every slow path can answer registers for another frame or
   another method (a `doesNotUnderstand:` activation, a marked send, a
   non-local return, `returnSlow`'s cascade and step, an activation
   primitive, a closure's activation, stack growth by copying,
   `terminateTo:`'s move of the running frame), and any poll can move
   bodies. After every call native code takes fp, hdr and sp from what
   the VM answered and decides again where to continue.
7. **The same observable behaviour.** The same slow paths, primitives and
   polls in the same order; the countdown poll at every send and backward
   jump with the same rewind; `counters.sends` and the other counters the
   run line reports; the `freshSlice` rule; the stack check at
   activation; the spare word for a `doesNotUnderstand:` at the deepest
   operand slot; the context-word test at every return. Equal send
   counts between the engines on the same program are the drift detector.
8. **`interpret` unchanged.** Identical instruction for instruction (page
   offsets apart), one jump table and one indirect branch, `just
   arc-check` passing. An engine switch out of the interpreter is decided
   only where a slow path already runs (`pollSlow`, `returnSlow`), as
   stepping is.
9. **The collectors' protocol rules bind the generated code** as they
   bind a primitive: relaxed atomic loads of state words, both halves of
   the post-store check seq_cst, the body address computed from the
   offset just loaded, the read-only bit, the barriers, `hasSlot` on
   instance-variable access, the full low-nibble reference test. A store
   the generated code makes inline restates the rule beside it; the first
   version makes every heap store through the VM's out-of-line store.
10. **Binding is by content.** A function group runs a method only when a
    strong hash of everything the generator folded in agrees (the plain
    bytecodes, since fusion replaces only an opcode byte; argument and
    temp counts, the stack maximum, flags, the primitive, the literal
    count, and any literal the code folds), and the module's layout hash
    agrees with the VM's build. A mismatch is not an error: the method
    runs interpreted, counted and reported. The binding holds its methods
    as roots, so an entry is never freed and reused under a binding.
11. **A process being stepped, or with an interrupt pending, runs
    interpreted.**

## Starting positions

What follows is the design the main session reached by reading the
interpreter. Part 1 confirms or corrects each by reading and by
measurement; the doc's "As built" says which survived.

**The driver.** `interpret` has two callers (`Workers/Run.swift`,
`Interpreter/Interpreter.swift`). With a binding present they call a
driver instead: while the state is running, if the current registers'
method is bound and their pc is one of its resume points, enter native
code through a plain-C trampoline in the generated file; otherwise
`interpret`. Native code returns to the driver when the next frame is not
native or the state stopped running; the interpreter returns to it by the
mechanism a suspension uses, with a leave reason of its own.

**Continuing after a slow path.** One step, used after every call into
the VM: read the answered registers; if the state is not running, return
to the driver; if the frame and pc are the ones expected, go on; else
look the frame's method and pc up and tail-call its resume function, or
return to the driver.

**Native return to a native caller.** A return has to reach the caller's
resume function without a C return. Two candidates, measured on fib:

- *A marker.* A native caller writes a SmallInteger marker carrying its
  global resume index into the callee frame's context word, beside
  `FrameMarker.discard`, `cascade` and `step`. A native return already
  tests the context word; it masks, loads `resume[index]` and tail-calls.
  An interpreted callee returning from such a frame goes through
  `returnSlow`, which makes the plain return and leaves to the driver.
  When a Context is materialized the marker moves to the Context's marker
  field as the others do. Every reader of the context word and of the
  markers is listed and changed in the same commit (`returnSlow`,
  `materialize`, `detach`, the Context primitives, `stepAfterReturn`, the
  saver and `SavedProcessRules`, the verifiers). Resume indices mean
  something only to the binary that made them, so a saved image either
  never holds one (stripped at the save, recommended) or the loader
  validates each.
- *A lookup.* The return reads the caller's method from its frame, the
  method's binding from the side table and the resume function from the
  binding's table by pc. No marker, nothing in images, about two more
  dependent loads per return.

The interpreter never enters native code at a call. A frame the
interpreter activated runs interpreted until it returns into a marked
frame or reaches a `pollSlow` (every `VMConfig.pollEvery` polls), where,
if its method is bound and the rewound pc is a resume point, the
interpreter leaves to the driver. That is the bound on how long a bound
method stays interpreted after a switch.

**From a method to its native code.** A side table indexed by the
method's object-table entry (an index into the module's records, 0 for
none), or a native word beside each method-cache line in a parallel array
so the interpreter's probe is untouched, filled at the miss. Measure on
`sends` and `st-closures`.

**The interface.** No C target in `KajoVM` and no exported symbols: at
bind the VM hands the module a versioned table of `@convention(c)`
function pointers (the send and its slow paths, primitives, polls, the
store, allocation, closures, Contexts, the returns). The wrappers take
scalars and leave the answered registers where the generated code reads
them, placed so no hot offset of `interpret` moves. The generated C is
self-contained: its prelude holds the layout constants the generator
computed from the Swift structs and a hash of them that the VM checks at
bind. The same table serves a `dlopen`ed dylib and a statically linked
module.

**The generated code.** The stack pointer is static per pc. Operand
values live in C locals between resume points and are written to their
slots before a send, a poll or any call that can look at the frame; temps
stay in frame memory (a Context's `tempAt:put:` and `terminateTo:` can
change them). Literals are read through the method unless the reading
shows a cheaper form that is sound: with the object table an oop is
stable for its object's life, so a selector or a literal may be bound
once, as a root, if the hash covers it. Whether a literal frame's body
address may be cached depends on whether any collection (a compacting
full collection included), `become:` or a forward can move or replace a
body pinned for good: find out before caching any address. `preserve_none`
with `musttail` is the calling convention to try first; confirm both on
the swift.org toolchain's clang, Xcode's clang, and for iOS arm64.

**Fused opcodes.** The generator reads the plain form of every method
(the fused opcodes map back to their pairs); the C compiler does its own
fusion.

**Where it lives.** The runtime half (driver, binding, interface) in the
core, as `Sources/KajoVM/Native/` or where the reading puts it; the
generator in a target of its own that only the `kajo` tool links
(`Sources/KajoAOT/`), so no app carries it. `scripts/check-tier.sh`
counts both as core.

**In which images it binds.** The engine binds whatever matches, in any
image; in a development image a method compiled at run time simply has no
binding, which exercises the mixed mode. That an app ships native code
only for a sealed image is module 2's rule.

## Parts

Build in order; commit each coherent step.

**Part 1: measure, then the slice.** Record the baseline (cycles and
instructions per send and per bytecode on fib, `sends`, `st-sends`,
`arith`, `ivars`, `storeheavy`, `alloc`, `st-closures` at 1 and 8
workers, from `kajo run`). Then the smallest slice that runs fib, `sends`
and `arith` natively end to end (generator, interface, driver, binding,
native send and return, polls), with both return candidates, and its
cycles per send broken down by where they go. Checkpoint: if the slice is
under 1.3 times the interpreter on fib with no explanation that the later
parts remove, stop and report with the breakdown.

**Part 2: every opcode, correct.** Every opcode of bytecode set v1 has an
emitter or a stated reason the generator declines its method (declined
methods run interpreted; the bar wants none declined in the kernel
image). Closures, temp vectors, `thisContext`, non-local return, super
sends, the special sends, the `perform:` family, primitives with their
fallback bodies, `doesNotUnderstand:`, stack growth, preemption at every
poll, saves and resumes. The whole kernel test suite passes with the
kernel image bound.

**Part 3: the fast paths.** Native send and return, the method-to-native
mapping, inline arithmetic and comparison, inline `at:`, instance
variable loads, and then, each only if its kernel shows the gain: inline
stores, a per-site cache (invalidated with the method cache), literals
bound at bind time. One step at a time, each measured in aligned builds
and kept or discarded with its number, as the interpreter-speed module
did.

**Part 4: verification in both engines.** See Tests. This part is not
optional and is not last by importance: start the random programs under
the native engine as soon as part 2 can run them.

**Part 5: the shells and the iPhone.** The Mac shell and the iOS shell
build with their bundled images compiled in when asked (an environment
switch such as `KAJO_SHELL_AOT=1`; the default build is unchanged), the
module handed to the VM through the host surface. The scenario matrix on
the Mac in both engines; on the iPhone the kernel tests, the kernels and
the matrix in both engines with the thermal state on every line. The
iPad if time allows, else listed as not done.

## Tests

On the Mac the tests compile generated C with the clang first on PATH
into a dylib in a temporary directory and `dlopen` it; under the
sanitizer the generated C is compiled with `-fsanitize=thread` too.

- The kernel tests, the golden kernels and every Smalltalk kernel under
  the native engine: equal answers, equal checksums, equal send counts.
- The random programs with the native engine in every configuration they
  have (one and eight workers, `collectEveryAllocation`,
  `stopEveryPoll`, `preemptEveryPoll`, perturbed, the marking, relocation
  and young-collection modes, the exhausted reserve, `plainBytecodes`),
  agreeing with their model; saved mid-run under one engine and resumed
  under the other, both ways.
- Every opcode, plain and fused, has a test that runs it natively and a
  check that the generator's table has no gap; a method at each encoding
  limit (an extended operand, the largest literal index, the deepest
  stack with a `doesNotUnderstand:` at the top slot).
- Each engine switch has a test that takes it and a counter that shows it
  was taken: native to interpreter at an unbound callee, back at its
  return; interpreter to native at a `pollSlow`; a `doesNotUnderstand:`,
  a marked send, a non-local return through native frames, an `ensure:`
  block run by a terminate, a Context materialized on a native frame and
  its temps changed, `restart` and `retry` of a native frame, stack
  growth inside a native method, a step and an interrupt of a Process
  whose frames are native.
- Binding: a method whose bytecodes changed after generation is not
  bound and runs interpreted with the right answer; a module with the
  wrong layout hash or version is refused whole; two methods with equal
  content share one group; a removed class's methods in a development
  image; the binding's roots keep a bound method across a collection.
- Broken variants as test switches where they fail a verifier or a check
  (a value left in a local across a poll, fp kept across a slow path that
  grew the stack, a marker not moved to a materialized Context, the send
  count not bumped), run by hand and recorded in the doc where they trap.
- The collectors' verifiers at every stop with native frames on the
  stacks; the relocation, young and marking suites' kernels natively.
- The generator alone over every method the kasm and syntax fuzz seeds
  make: it emits or declines, never traps. Whether the kasm fuzz target
  should run the generator on every input is an open question; build it
  behind an environment switch if it is cheap.
- Each new test is run on the starting commit where it can run there, and
  the doc quotes its failure or says why it cannot.

## The bar

- Kernel tests N of N headless with the kernel image bound, with 0
  methods declined and the bound and interpreted counts printed; the
  tools' tests in the development image with it bound.
- Golden checksums and send counts equal in both engines.
- Random programs agree with their model under the native engine in every
  configuration; cross-engine save and resume both ways.
- ThreadSanitizer 0 reports alone and under load with sanitized generated
  code.
- `interpret` identical (page offsets apart); the aligned A/B of the
  interpreter against the starting commit within noise at 1 and 8
  workers; `just arc-check` passing, extended to the driver and the
  interface's wrappers.
- `just ios-check` passing; the generated C for the kernel image compiles
  for iOS arm64 and for macOS with 0 warnings under `-Wall -Wextra`.
- The speed table, native against interpreter at the same commit, aligned
  builds, five interleaved runs, 1 and 8 workers, cycles and instructions
  per send and per bytecode: fib, `sends`, `st-sends`, `arith`, `ivars`,
  `storeheavy`, `alloc`, `st-closures`, and the runtime comparison's five
  programs with their rows in `docs/performance/README.md` (a new
  section; the other runtimes are not re-run). Expected, not promised:
  1.5 times or better on fib and `sends`, 3 times or better on `arith`.
  Where a kernel does not gain, the breakdown says why.
- Counters on the run line: methods bound, declined by reason, unbound by
  reason, engine switches by kind, native sends against sends through the
  VM.
- Bind time at launch for the kernel image, the development image and the
  2000-class image; generation time, C compile time at `-O2` and `-Os`,
  and the code size for each; the cold-launch cost in the Mac shell.
- The Mac shell's matrix under the native engine: frames missed,
  fallbacks, stops and time to safepoint no worse than the interpreter's
  rows run in the same session; the hog on main still preempted.
- The iPhone: kernel tests N of N, the kernels' table and the matrix in
  both engines.
- `just check <starting commit>` on the final code commit, the core tier,
  every gate, with the new gates in it (below).
- ADR 0015 (proposed): the native engine, its rules and what it costs.

## Gates

The core tier's set, plus, added to `scripts/check-tier.sh` through
`gates-lib.sh` and run once on their own before the gate run: the kernel
tests under the native engine, `just golden` under the native engine, and
the generated C's warning-free compile for both platforms. `swift test`
and the sanitizer gates carry the native tests themselves. The device
rows of the tier run as they do; this module's own device runs are part 5
and never run while a gate does.

## Not in this module

A generated app's build, `dist.sh`, the prebuilt frameworks and
`new-check` (module 2). Zig. Guarded direct calls, inlining across sends,
a receiver-class profile, type feedback of any kind (module 3). Any
change to the bytecode set or the image format beyond what the marker, if
kept, needs; if the format must change, say why before changing it.

## Open questions

Build the recommended option of each and list it; decisions only.

1. A saved image and native markers: stripped at the save (recommended,
   no format change, a resumed Process finds its native code again at its
   first poll or return) or kept and validated by the loader.
2. The generator in the kasm fuzz target: behind a switch (recommended)
   or not at all.
3. What the generator may decline: nothing in the kernel and tools images
   (recommended bar); a method past a size the C compiler handles badly
   may be declined with its reason counted.
4. `-O2` or `-Os` for the generated code: recommended by the measured
   table, the faster unless the size difference is large; module 2
   decides the product's flag.
