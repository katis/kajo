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

## As built

Built 2026-11-11 on the Mac mini (M2 Pro), swift.org 6.4.2 and its
clang 21 first on PATH, from c93a7b1. Raw runs, tables and scripts of every
number below are in the hand-back's output directory (`baseline/`, `slice/`,
`steps/`, `speed/`, `compare/`, `sizes.txt`, `ab/`, `check/`).

### Where it lives

- `Sources/KajoVM/Native/` (core; `scripts/check-tier.sh` counts it and
  `Sources/KajoAOT/` as core): `NativeState.swift` (the worker's native
  state, appended to `Worker` after every field the interpreter reads),
  `NativeLayout.swift` (the layout constants and their hash, the content
  hash, the method facts the generator reads), `NativeBinding.swift` (the
  descriptor, the bind, the method-to-native table), `NativeInterface.swift`
  (the wrappers, the continuation, the driver, the two interpreter
  switches), `NativeInput.swift` (the image `kajo aot` reads, loaded as
  `kajo run` loads it).
- `Sources/KajoAOT/Generator.swift`: the generator, linked by `kajo` and the
  tests only. No `unsafe`.
- `kajo aot <file.kasm>...|<image> -o <dir>`, `kajo run --native <dylib>`,
  `kajo test --native <dylib>`; `Interpreter.bind(native:)`;
  `Headless.Options.native` (the host surface's field; `ShellVM` takes it).

### The starting positions, one by one

- **The driver: survived.** `drive(s, start)` replaces `interpret` at its
  two callers (`runSlice`, `Interpreter.runToReturn`); with no module bound
  it is `interpret` itself. Native code is entered through the module's
  C trampoline `kajo_enter`; the interpreter leaves by the leave code with
  `native.switchToNative` set, exactly as the brief described.
- **Continuing after a slow path: survived, with one correction.** Every
  wrapper answers through `nativeContinue`: nil (back to the driver,
  registers saved), `nativeCont` (same frame, the expected pc, the traced
  depth: go on inline) or a resume function with fp, hdr, the top value
  and the pc in `native.out`. The correction (found by `--stress stop`, part
  1): a poll at a send must not resolve its registers. They are the send's
  own (pc after the send, its operands still on the stack), which no resume
  point has, so the first version handed the interpreter the pc after the
  send with an operand too many ("doesNotUnderstand #+ (receiver Adder)").
  `nativePollSend` and `nativePollJump` answer `nativeCont` after a poll
  that kept the Process.
- **Native return to a native caller: the lookup, not the marker.** Both
  were built and measured on the slice (aligned, five interleaved runs, one
  worker): fib 18.4 cycles per send by lookup against 18.9 by marker, 113.7
  against 105.7 instructions; `sends` 39.6 against 39.0; `arith` equal.
  Equal within noise, so the simpler one: no marker on any native frame,
  nothing in the context word for native code to keep in step with
  `materialize`, `detach`, the Context primitives, stepping or the saver,
  and every frame the VM activates above a bound caller (closures, DNU,
  perform, primitive fallbacks) returns natively with no marking. The
  marker survives in one place: a slow path that activates an *interpreted*
  (unbound) frame directly above a native one marks it
  (`markCaller`, `nativeMarkerBase + resume index`), so its return in the
  interpreter leaves for the driver (`returnSlow`). `--return-marker` keeps
  the marker variant for measurement.
- **From a method to its native code: the side table, the parallel cache
  array not built.** A table of 16-byte lines indexed by the method's oop
  (its entry offset): `{activation, group}`, reserved at the entry table's
  capacity (zero pages untouched cost nothing). A native send reads the
  activation from the line of the method the cache answered; a miss's
  lookup answers 0 for no method, whose line is empty, so one test covers
  both. The parallel-array alternative was not measured (deviation).
- **The interface: survived.** No C target and no exported symbol in
  KajoVM; at bind the VM hands each worker a table of `@convention(c)`
  functions (`makeNativeInterface`), read by the generated code through
  `native.vt`. The same table serves a `dlopen`ed dylib and a linked module.
- **The generated code: survived.** The stack pointer is static per pc
  (`hdr + 4 + depth`); operands live in C locals `x0...` between calls into
  the VM and are flushed to their slots before each; temps stay in the
  frame. Literals: folded as constants (selectors, `push_lit` values,
  nil/true/false); the hash covers every folded oop, the binding roots the
  methods (so their literal frames), and literal frames are read-only and
  pinned for good, so no body address is ever cached. `preserve_none` with
  `musttail`: confirmed on the swift.org clang 21, Xcode 27.2's clang and
  for iOS arm64 (`native-cc`).
- **Fused opcodes: survived.** The generator reads plain instructions
  (`nativeMethodInfos`, the verifier's decode); `exec` reads a fused first
  byte as its base.
- **Where it lives: survived** (above).
- **In which images: survived.** Any image; a development image's
  runtime-made methods have no binding (`toInterpreterUnbound` 797 in the
  kernel tests, mostly `Compiler evaluate:` methods).

### Resume points

Every instruction start with a traced depth is a resume point of the
group's cold function `kn_C<k>` (a `switch` on the pc). Hot functions
`kn_R<k>_<pc>` are the entry (pc 0), the pc after each plain `send`, each
backward jump's target, and (part 3) the pc after each `value`, `value:`,
`value:value:`. Global resume indices (`kajo_resume`, the targets of
returns and of markers) are given to pc 0, backward-jump targets and the pc
after every instruction whose slow path can activate a frame: `send`,
`send_super`, every special send but `==`, `~~`, `isNil`, `notNil` and
`class`, and every extended instruction. A pc with no index resumes in the
cold function; a pc of no group, or a depth not the traced one, resumes in
the interpreter (rule 4).

Slow paths that can answer another frame or method (each goes through
`nativeContinue`): `send_slow` (doesNotUnderstand:, the VM's invoke:
primitives, activation primitives, interpreted activation), `special`
(LargeInteger and Float arithmetic, `at:`, `at:put:`, `size`, closure
activation, a real send), `exec` (`send_super`, `push_closure`,
`push_new_array`, the temp-vector slots and `store_ivar` refusals,
`push_this_context`, `nonlocal_return` with its unwinding and
`cannotReturn:`, `class`, `~=` and `~~` past their fast paths, every
extended instruction), `ret` (`returnSlow`: Context detach, markers,
stepping's `stepAfterReturn`, the bottom return), `overflow` (stack growth
by copying, then the VM's activation), `fail` (the errors), and the two
polls (preemption, a stop, a save, an interrupt, stepping).

### Readers of the context word and the markers

`returnSlow` (a native marker: the plain return, then
`interpreterReturnsToNative`); `materialize` (moves any SmallInteger marker
to the Context's marker field, unchanged); `detach`, `detachFrames`,
`terminateTo:` (drop SmallInteger markers, unchanged); primitive 158 (the
step marker replaces a native one, `isEmptyOrNativeMarker` for a Context's
field); primitive 156 (a native marker is neither discard nor cascade:
allowed, cleared with the frame); the saver (`saveInStop` saves a native
marker as the empty word and a Context's native marker field as 0, patched
and restored around the snapshot); `SavedProcessRules` (unchanged: refuses
any marker past 3, which the saver guarantees); the generated return (the
context word must be the empty one for the lookup; anything else is `ret`).

### Readers of the method-to-native table

The generated send (`activation` at offset 0 of the method's line), the
generated return (the caller's group at offset 8), `nativeResume` (every
continuation and the driver), `markCaller` (the caller's group and the
callee's absence), `interpreterLeavesForNative`, `bindNative` (writes),
`unbindNative` and `becomeForward` (clears a forwarded method's line).

### The interface

| Function | Takes | Leaves | Can park |
|---|---|---|---|
| `poll_send` | pc after the send, sp, fp, hdr, length | the send to go on (`nativeCont`), or nil (Process left; or stepping, pc rewound) | yes (`pollSlow`) |
| `poll_jump` | the target pc, sp, fp, hdr | as `poll_send` | yes |
| `lookup` | class index, selector | the method or 0, the cache line filled | no |
| `send_slow` | pc after the send, sp, fp, hdr, selector, argc and length, method (0: none) | the next frame's resume (doesNotUnderstand:, invoke) | yes (primitives, allocation) |
| `special` | pc after, sp, fp, hdr, selector index << 8 or argc | as the dispatch loop's `specialSend` | yes |
| `exec` | the instruction's pc, sp, fp, hdr | the VM's own code for that instruction | yes |
| `ret` | pc after, sp, fp, hdr, value | `doReturn` (`returnSlow`, the bottom return) | no |
| `fail` | pc after, sp, fp, hdr, kind << 8 or length, value | nil (the error recorded) | no |
| `overflow` | the caller's pc after its send, sp, fp, hdr, method, length | `stackOverflow` (growth, activation) | no |
| `store_barriers`, `store_conflict`, `remember` | the holder, slot, value (or the value's header), the barrier site | the store's barrier halves | no (spins on a relocation) |

Every wrapper with registers saves them before anything that can pause
(as each slow path does), turns the bytecode offset into the pointer the
slow path takes from the frame's method read then, and answers through
`nativeContinue`. None allocates a Swift object or retains one: `just
arc-check` lists them all (and `drive`, `nativeContinue`,
`interpreterLeavesForNative`, `interpreterReturnsToNative`) at ARC 0.

### The generated code

A group per content hash, sorted by hash in `kajo_groups`. Per group: the
activation `kn_A<k>` (frame setup, the stack check of `activate` exactly;
a primitive method's runs it through `send_slow`'s invoke path; a block
group's builds `activateClosure`'s frame), the hot resume functions, the
cold function, `RX<k>` (pc to resume index) and `DP<k>` (pc to depth). All
share one prototype `(KS *s, u64 *fp, u64 *hdr, u64 a, u64 b, u64 c, u64 d)`,
`preserve_none`, so every send and return is a `musttail` call and nothing
native stays on the C stack. `SmallInteger>>fib`'s activation and entry, as
generated (the send's slow paths are one call; the return is the lookup):

```c
KFN kn_A11(KS *s, u64 *fp, u64 *hdr, u64 a, u64 b, u64 c, u64 d) {
  u64 *h = fp + 1;
  if (UNLIKELY(h + 8 >= AT(s, W_STACKEND, u64 *))) {
    KF *f_ = VT(s)->overflow(s, c >> 8, fp + 0, (u64 *)a, hdr, b, c & 255);
    if (!f_ || f_ == KCONT) return;
    KOUT(f_);
  }
  u64 *base = AT(s, W_STACKBASE, u64 *);
  (void)d;
  h[0] = b; h[1] = TAG(c >> 8); h[2] = TAG((u64 *)a - base); h[3] = TAG(hdr - base); h[4] = EMPTY_CONTEXT;
  __attribute__((musttail)) return kn_R11_0(s, fp, h, 0, 0, 0, 0);
}
KFN kn_R11_0(KS *s, u64 *fp, u64 *hdr, u64 a, u64 b, u64 c, u64 d) {
  ...
L0:;
  x0 = fp[0];
  x1 = 0x0000000000000005ULL;
  { u64 a_ = x0, b_ = x1; if (LIKELY(a_ & b_ & 1)) x0 = ((i64)a_ < (i64)b_) ? TRUEV : FALSEV; else { hdr[5] = x0; hdr[6] = x1; KGO(VT(s)->special(s, 4, hdr + 6, fp, hdr, 769)); x0 = hdr[5]; } }
  { u64 c_ = x0;
  if (c_ == FALSEV) {
  goto L9;
  }
  if (UNLIKELY(c_ != TRUEV)) { hdr[5] = x0; KGO(VT(s)->fail(s, 7, hdr + 5, fp, hdr, 259, c_)); return; } }
  x0 = fp[0];
  { u64 v_ = x0;
    if (LIKELY(hdr[4] == EMPTY_CONTEXT)) {
      u64 *base_ = AT(s, W_STACKBASE, u64 *); u64 *ch_ = base_ + UNTAG(hdr[3]);
      const KGroup *g_ = *(const KGroup *const *)(AT(s, W_NTAB, const char *) + ch_[0] + 8);
      if (LIKELY(g_ != 0)) { i32 i_ = g_->rx[UNTAG(hdr[1])];
        if (LIKELY(i_ >= 0)) { u64 *cf_ = base_ + UNTAG(hdr[2]); fp[0] = v_; AT(s, W_NRETURNS, u64)++;
          const KResume *e_ = &kajo_resume[i_]; __attribute__((musttail)) return e_->fn(s, cf_, ch_, v_, e_->pc, 0, 0); } } }
    hdr[5] = x0; KF *f_ = VT(s)->ret(s, 9, hdr + 5, fp, hdr, v_); if (!f_ || f_ == KCONT) return; KOUT(f_); }
L9:;
  x0 = fp[0];
  x1 = 0x0000000000000003ULL;
  { u64 a_ = x0, b_ = x1; i64 r_; if (LIKELY(a_ & b_ & 1) && !__builtin_sub_overflow((i64)a_, (i64)b_ - 1, &r_)) x0 = (u64)r_; else { ... special(13, 257) ... } }
  hdr[5] = x0;
  if (UNLIKELY(k_due(s))) { KF *f_ = VT(s)->poll_send(s, 16, hdr + 5, fp, hdr, 3); if (f_ != KCONT) { if (!f_) return; KOUT(f_); } }
  AT(s, W_SENDS, u64)++;
  { u64 *rp_ = hdr + 5; u64 cls_ = k_classof(s, *rp_);
    const char *e_ = AT(s, W_CACHE, const char *) + ((((0x00000000000014e0ULL >> 4) ^ cls_) & (CACHE_ENTRIES - 1)) * CACHE_STRIDE);
    u64 m_;
    if (LIKELY(*(const u64 *)(e_ + CACHE_CLS) == cls_ && *(const u64 *)(e_ + CACHE_SEL) == 0x00000000000014e0ULL)) m_ = *(const u64 *)(e_ + CACHE_METHOD);
    else m_ = VT(s)->lookup(s, cls_, 0x00000000000014e0ULL);
    KF *act_ = *(KF *const *)(AT(s, W_NTAB, const char *) + m_);
    if (UNLIKELY(!act_)) { KF *f_ = VT(s)->send_slow(s, 16, hdr + 5, fp, hdr, 0x00000000000014e0ULL, 768, m_); if (!f_) return; KOUT(f_); }
    AT(s, W_NSENDS, u64)++;
    __attribute__((musttail)) return act_(s, rp_, hdr, (u64)fp, m_, 4099, 52); }
}
```

### The hashes

The content hash (`nativeContentHash`, SHA-256's first 128 bits): the
interface version, the plain bytecodes, argc, temps, maxStack, flags,
primitive, copied, the literal count, and each folded literal (`push_lit`
and `send` operands) as (index, raw oop). The layout hash: SHA-256 of every
`NativeLayout.constants` name and value: the worker offsets the C reads
(countdown, the flag line, the send counter, the cache, the stack base and
end, the object table and heap bases, the native table, the interface
table, the out registers, the native counters, the closure activation
counter), the cache geometry, the header and tag masks, the young bits and
the RELOCATING bit, the barrier sites of the inline stores, the well-known
class indices, the frame layout, the empty context word, the marker base,
the closure layout and the special selector count.

### Per part

- **Part 1.** Baseline (`baseline/table.md`, aligned c93a7b1): fib 58.1
  cycles and 212.3 instructions per send, `sends` 70.1 and 335.6, `st-sends`
  117.4 and 453.9, `alloc` 76.8 and 348.2; the send-free kernels per run:
  `arith` 6.13 G cycles, `ivars` 6.11 G, `storeheavy` 2.12 s, `st-closures`
  3.21 s (one worker; eight alike per worker). The slice (generator,
  interface, driver, binding, native send and return, polls): fib 18.4
  cycles per send (3.1 times), `sends` 39.6 (1.8), `arith` 9.9 times. The
  checkpoint (1.3 on fib) held by far. Where fib's cycles go now (17.0
  cycles and 113 instructions per send against the interpreter's 58.1 and
  212; `slice/`, the disassembly of `kn_A11` 43 instructions, `kn_R11_0`
  194, `kn_R11_16` 116, `kn_R11_23` 78, slow paths included): no dispatch
  remains (the interpreter's seven-instruction dispatch and indirect branch
  per bytecode, about 10 bytecodes per fib call), operands stay in
  registers between sends, and each send keeps the interpreter's own
  chain of dependent loads: the countdown and the flag, the receiver's
  header for its class, the cache line (three loads compared), the
  method's native line, then in the activation the stack end and base;
  each return the caller's method, its native line, the group's resume
  index and the resume entry, then an indirect `musttail`. Those loads and
  the two indirect branches per call are the floor of this design; the
  optimizer (module 3: guarded direct calls) is what removes them.
- **Part 2.** Every opcode has an emitter or runs through the VM's own code
  (`AOTGenerator.emitter(for:)`, checked by `theGeneratorHasNoGap`); none
  declined in the kernel image (3276 of 3276 methods bound in 2573 groups)
  or the development image (4053 of 4053 in 3194). The kernel tests 249 of
  249 and the tools' tests 292 of 292 with their images bound. The output is
  a header, one file per 150 groups and the tables: the kernel image as one
  47 MB file took 293 s and 7.9 GB at -O1; split, 16 s on ten cores at -O2.
- **Part 3.** Below.
- **Part 4.** The random programs in every configuration under the native
  engine (`randomProgramsAgreeWithTheirModelNatively`), saved under one
  engine and resumed under the other both ways
  (`randomProgramsResumeAcrossEngines`), the engine-switch, binding and
  broken-variant tests (`NativeEngineTests`), and the whole VM suite (421
  tests: the collectors' verifiers at every stop, the relocation, young and
  marking suites, stepping, interrupts, resends, saves) with every harness
  and runtime bound (`KAJO_NATIVE_HARNESS=1 KAJO_NATIVE_RUNTIME=1`), all
  passing. Under ThreadSanitizer with twelve busy loops and the generated
  code compiled `-fsanitize=thread`: 14 of 14 tests (the native suites), 0
  reports.
- **Part 5.** Below, "The shells and the devices".

### Part 3's steps

Each in aligned builds, five interleaved runs, 1 and 8 workers, native
with the step against native without it (`steps/`):

| Step | Kernel | Without | With | Kept |
|---|---|---|---|---|
| native send, return, mapping, inline arithmetic, comparison, `at:`, ivar loads (the slice and part 2) | fib | interpreter 58.1 cycles/send | 17.0 | yes |
| 1: `store_ivar` and temp-vector slots inline (`k_store` restating `storeWithBarrier`) | storeheavy | 2233 ms | 591 ms | yes |
| | ivars | 857 ms | 414 ms | |
| | st-closures | 3158 ms | 2122 ms | |
| 2: closure `value`s activated natively, the pc after each hot | st-closures | 2116 ms | 1271 ms | yes |
| | st-sends | 295 ms | 293 ms | (neutral) |

A first measurement of step 2 read no difference: the switch's Swift
`case .value, .value1, .value2 where` applied its condition to `.value2`
only, so "without" inlined two of three; fixed and measured again (the
table's numbers). Not built, each for the reason given: a per-site cache
(the global cache's line hit rate on every kernel is above 99.99 percent,
the interpreter-speed module bounded it at 2 percent), literals bound at
bind (they are folded constants already), inline allocation (`alloc` and
`push_closure` stay in the VM: 1.36 on `alloc`, see below).

### Engine switches and their counters

Per worker (`NativeCounters`, summed on the run line, `kajo test`'s
`native:` line and `VM.nativeCounters`):

| Switch | Where decided | Counter | Test that takes it |
|---|---|---|---|
| driver enters native code (slice start, after the interpreter left) | `drive` | `nativeEntries` | every native test |
| native to interpreter: an unbound method, a pc that is no resume point, a depth not the traced one | `nativeContinue` | `toInterpreterUnbound` | `anUnboundCalleeRunsInterpretedAndItsReturnSwitchesBack` |
| the interpreted callee's frame marked for its caller | `markCaller` | `nativeMarkersSet` | the same |
| interpreter to native at the callee's return | `returnSlow` | `toNativeAtReturn` | the same |
| interpreter to native at a budget check | `pollSlow` | `toNativeAtPoll` | the same (`spin:` activated by the interpreted `outer`) |
| a Process that steps leaves native code (rule 11) | `nativeContinue`, the polls | `toInterpreterStepping` | `aSteppedProcessRunsInterpreted` |
| a slow path's continuation into another frame or method | `nativeContinue` | `nativeResumes` | every native test |

`doesNotUnderstand:`, the marked sends (a refused store's
`modificationForbiddenAt:value:`, `cannotReturn:`, `aboutToReturn:through:`,
an interrupt's frame), non-local return through native frames, `ensure:`
blocks run by a terminate, Contexts materialized on native frames with
their temps changed, `restart` and `retry` (primitive 156), stack growth
inside a native method, a step and an interrupt of a Process with native
frames: each is a slow path the native code calls, counted by the VM's own
counter (`nonLocalReturns`, `unwindingReturns`, `resends`, `stackGrowths`,
`interrupts`, `stepStops`, ...), and each is exercised by the VM suite's
tests run natively (`KAJO_NATIVE_HARNESS=1 KAJO_NATIVE_RUNTIME=1`: 421 of
421) and by the kernel and tools tests bound (249 and 292 of 292); stack
growth and stepping also by tests of their own (`theStackGrowsUnderNativeFrames`,
`aSteppedProcessRunsInterpreted`).

### Tests

New, in `Tests/KajoVMTests/Native/` and `Workers/RandomPrograms.swift`;
none can run on c93a7b1 (the native engine does not exist there:
`failing-before.txt`), so each test's power is shown by its broken variant
where it has one:

- `NativeEngineTests`: `anUnboundCalleeRunsInterpretedAndItsReturnSwitchesBack`,
  `aMethodWhoseBytecodesChangedIsNotBoundAndAnswersRight`,
  `aModuleOfAnotherVersionOrLayoutIsRefusedWhole`,
  `methodsOfEqualContentShareOneGroupAndTheBindingRootsThem`,
  `sendCountsAreEqualInBothEngines`, `aSendNotCountedIsSeenByTheDriftDetector`,
  `anOperandIsInTheFrameAtEveryPoll`, `anOperandLeftInALocalAcrossAPollIsLost`,
  `theGeneratorHasNoGap`, `methodsAtTheEncodingLimitsRunNatively` (an
  extended literal index, 200 operands deep, `doesNotUnderstand:` at the top
  slot), `theStackGrowsUnderNativeFrames`, `aSteppedProcessRunsInterpreted`.
- `randomProgramsAgreeWithTheirModelNatively` (every `RandomConfig`, the
  seed count of the interpreted test) and `randomProgramsResumeAcrossEngines`
  (every `SnapshotMode`, saved natively and resumed interpreted and the
  other way, 40 seeds each).
- The suite's switches `KAJO_NATIVE_HARNESS=1` and `KAJO_NATIVE_RUNTIME=1`
  (every `Harness` and `Runtime` binds its image's generated C):
  `anUnknownOpcodeIsAnError` is skipped there, as it rewrites a bound
  method's bytecodes from the host after the binding (methods are read-only
  and pinned to every program).
- The gates `native-golden`, `native-kernel-test`, `native-cc`.

### Broken variants

As test switches: `AOTOptions.brokenNoSendCount` (the drift detector sees
fewer sends: `aSendNotCountedIsSeenByTheDriftDetector`) and
`AOTOptions.brokenNoFlushAtPoll` (an accumulator left in a C local across
a poll; preempted at every poll the Process resumes from the stale slot and
answers wrong: `anOperandLeftInALocalAcrossAPollIsLost`; the first gate
run's `swift-test-load` found this test's own fault: its slot could hold a
dead word from an earlier frame, which a debug build's assertion trapped on
under load (`ObjectMemory.classIndex(of:)`, SIGTRAP); the accumulator now
starts as a send's answer, so the stale slot is an old SmallInteger). By hand: fp kept
across a slow path that grew the stack (the activation's overflow branch
edited to go on with the old pointers into the freed segment): `kajo:
error: mustBeBoolean (receiver SmallInteger)` on `down: 20000`. Found as a
bug: the poll at a send resolved as a resume point ("doesNotUnderstand #+
(receiver Adder)" under `--stress stop`). Not built: "a marker not moved to
a materialized Context" (native frames carry no marker; `materialize` moves
every SmallInteger marker by the code that moves the other three, and the
saver's strip is checked by the loader in every cross-engine resume).

- **The Mac shell's matrix under the native engine: met but for the
  oracle row.** Both matrices in one session, interpreted then native
  (`mac-matrix/interp`, `mac-matrix/native`, 156 rows each, the warm-up 0 of
  1200 in both): golden 108 rows, drift, the scenarios, events and the hog
  with the budget on: 0 frames missed and 0 fallbacks in both engines, the
  hog on main preempted in both (the budget-off rows miss 1192 to 1193 by
  design in both). The ring under the stop-the-world young collector, the
  oracle row, missed 187 to 189 frames with 8 to 9 soft-limit fallbacks
  interpreted and 335 to 350 with 16 to 17 native: the faster mutator
  crosses the soft limit with no cycle running about twice as often
  (AGENTS.md: "a faster mutator is a heavier load on every provisioning
  rule"), every miss a counted fallback's compacting full collection of 197
  to 203 ms. Sweep stops appear natively (234, the longest 0.20 ms) where
  the interpreted rows had none.
- **The iPhone: kernel tests, the kernels' table and the matrix in both
  engines: done.** The shell built with `KAJO_SHELL_AOT=1` (the modules
  compiled with Xcode's clang and signed with the team's identity, no
  prompt) and launched with and without `native=1` (the console names the
  module loaded). Kernel tests 249 of 249 in both (7.96 s interpreted, 5.79
  s native, thermal serious). The matrix (`device/iphone-interp`,
  `device/iphone-native`, five workers): 0 frames missed and 0 fallbacks in
  every row of both but the hog with the budget off (by design) and the
  oracle ring row: interpreted 3 frames in all with no fallback, native 109
  frames with 2 fallbacks behind compacting full collections of 287 and 325
  ms. The matrix's kernels were not run back to back between the engines
  and drifted with the phone's clock (`device/iphone-kernels.md`); run back
  to back at thermal serious (`device/iphone-b2b.txt`, three each): fib
  1646 against 513 ms (3.27 times), `alloc` 3741 against 2824 (1.32),
  `floats` 3562 against 3362 (1.06), `walk` 3947 against 3778 (1.04).
- **The iPad (time allowed part of it):** kernel tests 249 of 249 in both
  engines (9.37 s and 7.23 s, nominal); kernels back to back at nominal
  (`device/ipad-kernels.md`): fib 2510 against 702 ms (3.57 times), `sends`
  3335 against 1676 (1.99), `arith` 2467 against 329 (7.50), `storeheavy`
  2838 against 1520 (1.87), `alloc` 5452 against 3585 (1.52). No matrix on
  the iPad.
- **`just check c93a7b1` on the final code commit, the core tier: below.**
- **ADR 0015 (proposed): written**
  (`docs/adr/0015-a-native-engine-beside-the-interpreter.md`).

The new `unsafe`: 245 added lines of `Sources/KajoVM` carry the keyword
(the native engine's wrappers, binding and layout; 3 changed lines lost
one), `Sources/KajoAOT` none, `fuzz-kasm` one (`getenv`), counted in the
diff; the clean build's 0 warnings are the `clean-build` gate's.

### Deviations

- Returns by lookup instead of the marker the brief preferred for native
  callers (measured equal; the marker is kept for interpreted callees of
  native frames only).
- The method-to-native mapping's parallel-array candidate was not built or
  measured; the side table was built.
- The shells load each bundled image's module as a signed dylib beside the
  image (`dlopen`), not linked into the binary: a shell bundles seven
  images, each needs its own module, and one descriptor symbol per module
  would need per-image symbol names. Linking a module into an app is module
  2's (a generated app has one sealed image).
- The generated code has a cold function per group (the whole method once,
  entered at any instruction start) besides the brief's per-resume-point
  functions, so every pc a slow path or the driver answers continues
  natively; hot functions are the entry, the pc after each send and each
  `value`, and backward-jump targets.
- `kajo aot` writes several C files and a header (the brief: "one C file");
  one file of the kernel image compiled in 293 s and 7.9 GB.
- The generated code reads no literal frame: every literal it uses is a
  constant (the brief's "bound once" became "folded", which the hash
  covers).
- `anUnknownOpcodeIsAnError` is skipped under `KAJO_NATIVE_HARNESS=1` (it
  corrupts a bound method from the host).

### Not done

- Inline allocation (`basicNew`, `push_closure`, `push_new_array`):
  `alloc` gains 1.36 times, `binarytrees` 1.36 to 1.41.
- Inline `at:put:`, `size`, `class`, the `perform:` family, Float
  arithmetic: they run through the VM's own code.
- A static link of a module into an app (module 2), Zig (module 2), the
  optimizer (module 3).
- The generated C is not deduplicated across hot regions beyond the region
  rule (code size 13.4 MB of text for the kernel image).

### Open questions, as built

1. Native markers in a saved image: **stripped at the save** (as
   recommended; no format change). With returns by lookup only interpreted
   frames above native callers carry one, and the saver writes it as the
   empty word.
2. The generator in the kasm fuzz target: **behind a switch** (as
   recommended): `KAJO_FUZZ_AOT=1` makes `fuzz-kasm` generate C for every
   image an input loads (`FuzzEntry.kasm(_:then:)`).
3. What the generator may decline: **nothing in the kernel and tools
   images** (as recommended): 0 declined in the kernel (3276 methods), the
   development (4053) and the 2000-class (24 118) images. The only reasons
   it has are a method with neither bytecodes nor a primitive and a stack
   deeper than 4096, which the verifier already refuses.
4. `-O2` or `-Os`: **`-O2`** (as recommended by the table): `-Os` is 7
   percent slower on fib and `arith` (18.2 against 17.0 cycles per send) and
   its text under 1 percent smaller (13.27 against 13.39 MB for the kernel
   image). Module 2 decides the product's flag.

### The bar, item by item

- **Kernel tests N of N with the kernel image bound, 0 declined, counts
  printed: met.** `just native-kernel-test`: 249 of 249, 3276 of 3276
  methods bound in 2573 groups, 0 declined, the `native:` line printed (797
  frames handed to the interpreter: methods made at run time); the tools'
  tests 292 of 292 in the development image with 4053 of 4053 bound.
- **Golden checksums and send counts equal in both engines: met.**
  `just native-golden`: every kasm and Smalltalk golden kernel at its
  published checksum with the interpreter's send count, e.g. fib 79 875 841
  sends in 1389.5 ms interpreted and 405.6 ms native, `walk` 96 473 107 in
  3600.8 and 3382.4, `floats` 2998.8 and 2683.1.
- **Random programs in every configuration, cross-engine save and resume
  both ways: met.** `randomProgramsAgreeWithTheirModelNatively` (22
  configurations) and `randomProgramsResumeAcrossEngines` (6 modes, both
  directions) pass; the whole VM suite under the native engine 421 of 421.
- **ThreadSanitizer 0 reports alone and under load with sanitized generated
  code: met for the native suites** (14 of 14 tests, twelve busy loops, 0
  reports); the gates' `tsan` and `tsan-load` run the whole suite with them.
- **`interpret` identical, the A/B within noise, `just arc-check` passing
  and extended: met.** `interpret` 1816 instructions on both sides,
  identical with addresses normalized (`interpret-diff.txt`); the aligned
  A/B against c93a7b1 (`ab/table.md`) 0.995 to 1.008 at one worker with
  instruction ratios 1.000, 0.936 to 1.039 at eight with instruction ratios
  0.996 to 1.000 (the usual eight-worker spread); `just arc-check` passes
  with the driver, the wrappers, `nativeContinue` and the two switches at
  ARC 0.
- **`just ios-check`; the kernel image's C for iOS arm64 and macOS with 0
  warnings under -Wall -Wextra: met.** `just native-cc`: 19 files each, 0
  warnings with `-Werror`; `ios-check` runs in the gates.
- **The speed table: met, with the expectation met on fib and `arith` and
  missed on `sends`.** Aligned release build at the same commit, five
  interleaved runs (`speed/`, plain bytecodes from the counting build in
  `counts/`):

  | workers | kernel | interpreter ms | native ms | × | cycles/bytecode | | instr/bytecode | | cycles/send | |
  |---|---|---|---|---|---|---|---|---|---|---|
  | | | median (min–max) | median (min–max) | | interp | native | interp | native | interp | native |
  | 1 | fib | 1384.5 (1375.9–1395.3) | 404.1 (396.1–409.7) | 3.43 | 5.81 | 1.70 | 21.23 | 11.32 | 58.1 | 17.0 |
  | 1 | sends | 1675.4 (1665.4–1678.7) | 936.5 (929.7–941.0) | 1.79 | 4.73 | 2.64 | 22.62 | 18.46 | 70.1 | 39.2 |
  | 1 | st-sends | 1398.5 (1390.1–1407.8) | 296.7 (285.7–299.1) | 4.71 | 3.95 | 0.82 | 15.30 | 5.81 | 117.3 | 24.5 |
  | 1 | arith | 1829.2 (1821.3–1839.0) | 187.4 (180.6–187.6) | 9.76 | 3.56 | 0.36 | 11.22 | 1.98 | - | - |
  | 1 | ivars | 1823.3 (1818.2–1829.1) | 411.3 (405.0–425.8) | 4.43 | 4.89 | 1.11 | 18.18 | 6.64 | - | - |
  | 1 | storeheavy | 2123.7 (2112.8–2126.0) | 593.2 (586.7–602.6) | 3.58 | 4.43 | 1.24 | 20.46 | 8.35 | - | - |
  | 1 | alloc | 2896.9 (2884.3–2914.5) | 2127.5 (2119.4–2168.9) | 1.36 | 11.01 | 8.10 | 49.70 | 46.82 | 77.1 | 56.7 |
  | 1 | st-closures | 3206.6 (3188.1–3209.8) | 1277.4 (1261.5–1285.1) | 2.51 | 5.86 | 2.33 | 29.54 | 16.75 | - | - |
  | 8 | fib | 185.9 (178.3–191.1) | 51.8 (51.7–57.5) | 3.59 | 5.85 | 1.69 | 21.23 | 11.32 | 58.5 | 16.9 |
  | 8 | sends | 220.9 (214.3–238.4) | 128.3 (119.2–135.6) | 1.72 | 4.72 | 2.68 | 22.62 | 18.47 | 70.0 | 39.7 |
  | 8 | st-sends | 191.1 (178.8–196.6) | 42.1 (37.4–45.0) | 4.54 | 3.99 | 0.84 | 15.32 | 5.81 | 118.3 | 25.1 |
  | 8 | arith | 246.8 (245.8–257.1) | 24.2 (24.2–27.5) | 10.20 | 3.56 | 0.36 | 11.23 | 1.98 | - | - |
  | 8 | ivars | 246.8 (232.8–259.3) | 57.0 (53.0–60.3) | 4.33 | 4.93 | 1.11 | 18.20 | 6.64 | - | - |
  | 8 | storeheavy | 282.6 (270.8–295.6) | 76.4 (76.3–80.5) | 3.70 | 4.45 | 1.24 | 20.47 | 8.34 | - | - |
  | 8 | alloc | 447.9 (437.9–455.8) | 357.4 (343.9–364.9) | 1.25 | 12.37 | 9.68 | 52.67 | 49.37 | 86.5 | 67.7 |
  | 8 | st-closures | 417.1 (410.4–437.7) | 169.0 (163.0–182.2) | 2.47 | 5.83 | 2.32 | 29.34 | 16.68 | - | - |

  (Per bytecode: the plain bytecodes a run executes, the same in both
  engines; eight workers do the same total work as one.) Where a kernel
  gains less: kasm `sends` sends `at:` as a plain send to `Object>>at:`, a
  primitive method, so every iteration's first send goes through the VM's
  invoke and `primitiveSend` (the Smalltalk twin compiles `at:` to the
  special send, inline natively: 4.7 times); `alloc` is the allocation
  primitive behind every `basicNew` and the collector's work, both the
  VM's in both engines; `st-closures` makes a closure per iteration in the
  VM (`push_closure`). The runtime comparison's five programs are in
  `docs/performance/README.md`, section 10 (3.2 to 3.6 times on fib, 1.8 and
  4.8 on dispatch, 1.4 on binarytrees, 1.8 on collections, 10.6 on arith).
- **Counters on the run line: met.** `nativeMethods`, `nativeBound`,
  `nativeGroups`, `nativeUnboundNoMatch`, `nativeUnboundUnreadable`,
  `nativeGenerated`, `nativeDeclined`, `nativeBindMs`, `nativeRefused`, the
  switches (`nativeEntries`, `toInterpreterUnbound`, `toInterpreterStepping`,
  `toNativeAtPoll`, `toNativeAtReturn`, `nativeMarkersSet`,
  `nativeResumes`), `nativeSends` against `vmSends`, `nativeReturns`,
  `nativeSlowCalls`. Declined by reason: the generator prints each
  (`declined: <method>: <reason>`), none in any image.
- **Bind, generation and compile times, code sizes, cold launch: measured**
  (`sizes.txt`, `mac-matrix/coldlaunch/`):

  | image | methods | groups | generation s | C MB | compile -O2 s (CPU s) | text -O2 MB | compile -Os s | text -Os MB | bind ms |
  |---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
  | kernel | 3276 | 2573 | 0.37 | 42.4 | 13.7 (103) | 13.39 | 13.2 | 13.27 | 5.1–5.4 |
  | development (tools) | 4053 | 3194 | 0.45 | 53.7 | 17.6 (134) | 16.94 | 17.5 | 16.81 | 6.1–7.4 |
  | 2000 classes | 24 118 | 15 994 | 0.76 | 90.2 | 27.8 (254) | 26.48 | 27.7 | 26.35 | 23.5–24.2 |

  (Compiles on ten cores, `xargs -P 10`.) The Mac shell's cold launch, five
  interleaved launches a side with `kajo-launch-report`: from the mode's
  start to the image opened 32.9 to 34.2 ms interpreted and 38.5 to 41.1
  native (the module's `dlopen` and the bind: about 6 ms), first frame
  1.21 to 1.31 s either way.
