# ADR 0015: A native engine beside the interpreter, generated as C from an image's methods

Date: 2026-11-11
Status: proposed (module AOT 1, `docs/modules/aot.md`)

## Context

iOS forbids generating code at run time but not code compiled at build
time and signed with the app. A sealed Release image is a closed world (the
make, install and class primitives refuse there), and the object table
(ADR 0003) means an oop held in compiled code needs no fix-up when its
object moves. The interpreter after the interpreter-speed module runs fib
at 58 cycles per send and arith at 107 cycles per iteration on the M2 Pro;
LuaJIT's interpreter is 1.5 to 2.1 times faster. The owner decided on
2026-11-11 to compile images ahead of time, generating C.

## Decision

- **A second engine, not a replacement.** `kajo aot <image>` (the target
  `KajoAOT`, which only the `kajo` tool and the tests link) writes one C
  module for an image's methods: a header, one file per 150 groups, the
  tables and a descriptor `kajo_native_module`. The VM binds it at start
  (`VMConfig.native`, `Headless.Options.native`, `Interpreter.bind(native:)`)
  and runs it beside `interpret`; the interpreter stays whole and runs
  everything the module does not bind, a development image's runtime-made
  methods among them.
- **One frame layout, bytecode pcs only** (the module's rules 1 to 4): native
  frames are the VM's frames; a resume point is a bytecode pc with the
  traced operand depth, so either engine continues any frame there and the
  interpreter continues any frame at all. Collectors, Contexts, unwinding,
  stack growth, the saver and the loader see one kind of frame.
- **A flat C stack**: sends and returns are `musttail` calls with
  `preserve_none`; slow paths are ordinary calls of C-callable wrappers over
  the VM's own slow paths, each answering "go on", "tail-call this resume
  function" or "back to the driver". Neither engine calls the other; a
  driver above both chooses (`drive`), and the interpreter leaves for native
  code only in `pollSlow` and `returnSlow`. `interpret` is unchanged
  instruction for instruction.
- **Returns find their caller by lookup**: the caller's method, its group,
  the group's resume index at the caller pc. A marker in the context word
  measured equal (fib 18.9 against 18.4 cycles per send, sends 39.0 against
  39.6) and was kept only for an interpreted frame a slow path activates
  above a native one, so the interpreter's return leaves for the driver.
- **Binding by content**: a SHA-256 of what the generator folded (plain
  bytecodes, the header counts, the primitive, the literal count, every
  folded literal's oop) per method, and a layout hash of every offset and
  constant the C reads; a mismatch runs the method interpreted, a wrong
  layout or version refuses the module whole.
- **The collectors' rules bind the generated code**: relaxed atomic loads of
  state words, headers and slots, the body from the state word just loaded,
  stores restating `storeWithBarrier` (the post-store check seq_cst on both
  halves, the barrier word, the young barrier), operands flushed to the frame
  before every call into the VM.

## Evidence

Aligned release builds on the Mac mini, five interleaved runs, one worker,
native against interpreter at the same commit: fib 3.4 times (17.0 against
58.1 cycles per send), `sends` 1.8, `st-sends` 4.7, `arith` 9.8, `ivars` 4.4,
`storeheavy` 3.6, `alloc` 1.36, `st-closures` 2.5; eight workers alike. The
kernel image's 3276 methods bind with none declined; 249 of 249 kernel
tests and 292 of 292 tools tests pass bound; the whole VM suite (421 tests,
the random programs in every configuration, saves resumed across engines)
passes under the native engine; ThreadSanitizer reports nothing with the
generated code sanitized, alone and under load. `docs/modules/aot.md`'s
"As built" has the rest, with the runtime comparison's rows in
`docs/performance/README.md`.

## Costs

- A second engine to verify: every protocol rule and every verification
  layer now holds for generated code too, and each future change to a slow
  path, a frame word, the bytecode set or a barrier must keep the
  generator's restatement in step (the layout hash catches offsets, not
  semantics). The gates gain three (`native-golden`, `native-kernel-test`,
  `native-cc`) and the suites run in both engines.
- Debug and Release diverge: a development image runs mostly interpreted
  (its methods change), a sealed Release image mostly native. A bug of one
  engine shows only where that engine runs; the cross-engine tests and the
  KAJO_NATIVE_* switches exist for that.
- Size: the kernel image's module is 16 MB of arm64 objects (42 MB of C)
  for 2573 groups; compiling it takes about 16 s on ten cores at -O2.
  Module 2 decides the product's flag and whether to compile only reached
  methods.
