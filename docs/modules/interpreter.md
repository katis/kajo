# Module 2: interpreter and loader

Status: brief, 2026-11-02. Becomes the module's description as it lands.

## What it hides

How a method runs: the bytecode encoding, the frame layout on a stack, how a
send finds a method and how a primitive is entered and fails. Nothing
outside this module reads a bytecode or a frame word. The object memory
(module 1) stays the only module that computes a body address; the
interpreter reaches slots through its `load`/`store` path and reaches a
method's bytecodes and literals through two cached base pointers it
re-derives after every pause.

## What is and is not decided

**Bytecode set v0** is the experiments' set (`experiments/vm-language-bench/SPEC-SHARED.md`
"Bytecodes", "Frames", "Lookup cache"; the primitive numbering of
`experiments/concurrent-young/SPEC.md` where it extends it). It is carried
in as the encoding the first loader reads, **not** as Kajo's bytecode set:
it has no blocks, no non-local return, no super sends, no metaclasses, no
LargeInteger, Float or String, and no `doesNotUnderstand:`. Those are the
scope of a bytecode-and-object-model ADR that precedes module 8 (the
compiler), and the user decides them. Build so that the ADR changes one
file: the opcode table and its operand decoding live in one place, the
dispatch loop is generated or written one opcode per case from that table,
and frame layout, send, primitive entry and the lookup cache do not depend
on opcode numbering.

**Decided now and carried forward:**

- **Stack**: a per-stack region of tagged words, grows up, `stack[0]` nil,
  every word in `[0, sp]` a valid oop, so the collector scans it uniformly
  (SPEC-SHARED "Frames"). Module 2 has exactly one stack; module 3 makes
  stacks Process-owned (ADR 0004), so the interpreter takes a stack as an
  argument and never assumes there is one.
- **Frame**: receiver, arguments, temps, then a header of method, caller pc,
  caller fp, caller hdr as tagged addresses, then the operand stack
  (SPEC-SHARED "Frames"). Caller addresses tagged as SmallIntegers are
  stack-internal; nothing else may tag an address.
- **Registers are roots.** pc, sp, fp, hdr, the receiver, the current method
  and the `result` register are declared in one struct and every one of them
  is handed to the collector at a pause (AGENTS.md: the `result` register
  kept dead objects alive and only a test that must fail without the rule
  found it; port that test).
- **Cached raw pointers**: the interpreter may cache the current method's
  bytecode base and literal base and nothing else. Both are re-derived from
  the oop after any call that can pause (send slow path, primitive,
  allocation slow path). The compaction-under-live-frames test proves it.
- **Send**: lookup through the class's method dictionary chain, a per-stack
  (later per-worker) direct-mapped lookup cache of 1024 entries, flushed at
  every collection (its entries are oops; a test that collects with a
  populated cache and then sends through it must pass). Misses are a
  counter.
- **Special sends** `+ - * < > <= >= =` with the SmallInteger fast path and a
  real send on failure; `==` inline. Overflow is a real send, never a trap.
- **Primitives** are a table indexed by number, each a function taking the
  interpreter state and argument count. A primitive checks every type and
  bound itself and returns success or failure; on failure the interpreter
  runs the method's bytecode body if it has one, else signals an error (see
  errors). No primitive may trust an oop it did not check. v0 primitives:
  `at:`, `at:put:`, `basicNew`, `basicNew:`, `class`, `//`, `\\`,
  `globalAt:`, `globalAt:put:`, `==`, `collect` and `compact` (test
  switches that stop the world through module 1), `identityHash`.
- **Errors never abort the process.** The experiments called `exit(2)` on
  doesNotUnderstand, a non-boolean jump, a primitive failure or stack
  overflow. The production interpreter reports a `VMError` (kind, selector,
  receiver class, pc) to its caller and leaves the stack intact for
  inspection; `doesNotUnderstand:` is looked up first and sent with a
  Message if the class provides it. A test per error kind.
- **Safepoint polls** at every send and backward jump remain one relaxed
  load of a flag the interpreter is given; module 3 wires the flag. For now
  the flag is a test switch that makes the poll call `collect`.
- **Loader**: the kasm loader (`experiments/concurrent-young/swift/Sources/Kasm/`
  is the lineage; `SPEC-SHARED.md` ".kasm text format" and "Boot /
  allocation order" the spec) builds an image: well-known classes, symbols,
  methods, method dictionaries, globals. It reads untrusted text: every
  limit is checked (operand ranges, label resolution, literal counts, method
  sizes, class count) and failure is an error value, never a trap or a
  crash. Both loaders (kasm text, module 1's snapshot bytes) get a
  libFuzzer entry point (`LLVMFuzzerTestOneInput`) in an executable target
  built with `-sanitize=fuzzer`; `just fuzz <target> <seconds>` runs them.
  Add a seed corpus under `Tests/KajoVMTests/Fixtures/`.
- **Headless CLI**: `kajo run <file.kasm>... [--workers 1]` loads the files
  and sends `run:of:` to nil; prints the checksum and the counters. One
  worker only until module 3.
- **Counters**: sends, cache misses, primitive calls and failures, special
  send fallbacks, errors, safepoint polls taken, collections triggered from
  the interpreter.

## Hot path

AGENTS.md rules verbatim: one opcode per `case`, one jump table (check the
arm64 assembly and record the method in this file beside module 1's
`just arc-check`, which must be extended to the dispatch loop and the send
path); registers passed as scalars into slow paths; `@_transparent` where
inlining is required; `&+ &- &* &>>` and `truncatingIfNeeded` only inside
the interpreter loop and send path; zero `swift_retain`/`swift_release` in
the loop, the send path and the primitives that allocate. Raw body
pointers stay out of primitives except the two cached bases.

## Tests to port

From object-representation and the lineage: `smallProgramRuns`,
`kernelsAssemble`, `interpreterSeesBecome`, the live-frames half of
`compactionMovesMethodsUnderLiveFrames` (now portable: a primitive triggers
compaction while a method is executing), the `result`-register root test
from concurrent-young, the lookup-cache-across-collection behaviour.

Golden checksums: the vm-language-bench kernels (`fib`, `sends`, `ivars`,
`arith`, `alloc`, `walk`) copied as fixtures with their published
single-worker checksums from `experiments/vm-language-bench/RESULTS.md`.
Experiments are deletable, so the fixtures live in `Tests/KajoVMTests/Fixtures/`.

New: a test per `VMError` kind; primitive failure falls into the method
body; the loader rejects each malformed input class (bad operand, unknown
label, unknown class, duplicate method, oversize method, too many classes);
3,000 seeded random mutations of a valid kasm file either load or are
rejected without a crash (as module 1 did for snapshots); stress flags from
module 1 under the kernels (collect at every allocation makes `alloc` and
`walk` run thousands of collections with correct checksums).

## Tests that wait

Everything with more than one worker, Processes, Semaphores, budgets and
events (module 3); everything generational and concurrent (modules 4 to 7).

## Done when

Tests green, under load and under ThreadSanitizer; `just ios-check`;
`just arc-check` extended and clean; the jump-table check recorded; `kajo
run` runs the fixture kernels with their checksums; `fib` on one worker
within 10 percent of `experiments/concurrent-young`'s `cy-bench` on the same
machine back to back (record both numbers and the load state of the
machine; the Mac may be busy, so take medians of 5 interleaved); this file
describes the module as built; CONTEXT.md gains Frame, Stack, Send,
Primitive failure, VMError.
