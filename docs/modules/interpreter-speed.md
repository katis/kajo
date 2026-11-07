# Interpreter speed: the send path, superinstructions, the special sends

Status: briefed, 2026-11-07 (the owner: "I think the 1-3 sound good, you can
work on them before we finish with the VM"). The last VM module before the
core is declared done; module 2 (`docs/modules/interpreter.md`) and 8a
(`docs/modules/object-model.md`) built what it changes, 8d's shared
`Loader/MethodBuilding.swift` is where its peephole goes. It changes
`interpret` on purpose. Everything the loop was built to keep (one jump
table, zero ARC, the register budget of module 8a, every slow path one
out-of-line call) binds; `just arc-check` and the disassembly diff are the
proof, not the bench.

## What it hides

How a send finds its method and pushes its frame, how many dispatches a
compiled expression costs, and how the special sends reach their fast
paths. The bytecode set's meaning does not change: every method that
runs today runs the same afterwards, the compilers' output changes only
by a peephole both compilers pass through, and the debugger steps the
same source ranges.

## Where the time goes today (measured before anything changes)

Take these on the mini in the aligned `-enable-testing` release build
with five interleaved runs, as every A/B has, and on the iPhone for the
one-thread kernels (`scripts/device.sh`, one kernel per launch, thermal
state on every line):

- `fib`: 79.9 M sends in 1.69 s on one worker, about 21 ns a send with
  its arithmetic, about 70 cycles.
- `sends`: 80 M sends (40 M polymorphic over three classes, 40 M real
  sends of `at:` that reach primitive 60) in 2.61 s.
- `arith`: 80 M iterations of about 20 bytecodes in 2.55 s, 1.6 ns a
  bytecode.
- `st-sends`, `st-closures`, `st-ivars`: the Smalltalk-compiled twins.

Add to the bench harness, per kernel and worker, cycles and
instructions from the per-thread counters the shells already read
(`proc_pidinfo(PROC_PIDTHREADCOUNTS)`; the telemetry in
`Sources/KajoShellCore/`), so every number below is cycles per send and
cycles per bytecode, not only wall time. If `kpc` branch-misprediction
counters are reachable without changing the machine (they need root; do
not escalate), add them; if not, say so and use the instruction counts
and the disassembly.

Then count, statically over the kernel image and `tools/`, and
dynamically over the kernels, the Mac shell's `demo` and `devsession`
modes and the kernel tests, which opcode pairs and triples are the most
frequent (a counting build behind a test switch; off in the product).
The counts decide part 2.

## Part 1: the send path

Today (`Interpreter/Send.swift`): a send polls, computes the receiver's
class index, probes a per-worker direct-mapped cache of 1024 lines keyed
by class and selector, and on a hit reads the method's state word, its
primitive, temps and maxStack, nils the temps, writes five header words
and derives the code and literal bases from the method through the
entry table. The cache is `memset` at every pause
(`InterpreterState.flushCache`): under the storm that is thousands of
times a second, and every send after a pause misses.

Build and measure, in this order, keeping each step only if its A/B
shows it:

1. **A per-site inline cache.** One word per send site: the receiver's
   class index and the method's entry index packed in one 64-bit word,
   written and read as one relaxed atomic so two workers running the
   same method can never see a torn pair. On a hit the send skips the
   hash, the index and two compares; on a miss it falls to the global
   cache, then to the lookup. Where the words live is the design
   question: in the method's literal frame as hidden literals (the
   method is a root, so a cached method is never freed under the cache;
   but a store into an old object while a cycle marks is a store the
   SATB barrier must see, and the literal frame is read-only to
   Smalltalk, which the VM's own store does not violate but the
   verifiers' rules must say so), or in a side object the method owns.
   The invariant either way, stated in the doc and checked by a stop
   verifier: **a cache word never names a freed or replaced method.**
   Method install, redefinition and `Smalltalk garbageCollect` already
   stop the world; the cache words of every method whose class or
   selector is affected are cleared in that stop (or all of them, if
   that is cheaper and measured). The global cache's flush at every
   pause may then go away for the per-site hits; say what still needs
   it.
2. **A leaner activation.** The method's temps, maxStack, primitive and
   argc are four separate words read through the state word; the code
   and literal bases are two entry-table hops each on every activation
   and every return. Measure a packed activation word (temps, maxStack,
   prim, argc in one SmallInteger-tagged word written by the make
   primitive) and whether the return can keep the caller's bases rather
   than re-deriving them (the frame has five header words; a sixth and
   seventh holding the caller's code and literal bases are raw pointers
   into pinned, never-moving method bodies, which ADR 0003's rule makes
   a pin or a hazard: argue it from the pin for good or do not do it).
   The temps nil fill and the stack-overflow check stay.
3. **The poll.** The countdown and the flag load at every send are two
   memory operations; measure the countdown in a register of the loop
   against today's, and keep today's if the register budget says so.

## Part 2: superinstructions

The arith loop's `push_temp; push_temp; lt; jump_if_false` is four
dispatches for one compare-and-branch, and `push_temp; push_int; add;
store_temp` four for one add. From the counts above, fuse the pairs and
triples that cover the most dynamic dispatches, as new opcodes in the
free space of the one-byte set (50 of 256 used, `ext` for operands),
one case each in `interpret`, no case sharing a body. Candidates to
check against the counts, not to assume: compare-and-jump for each
comparison on two temps or a temp and an int; temp-op-int and
temp-op-temp arithmetic with the result pushed or stored; `push_temp;
send` for argc 0 and 1; `push_self; push_ivar`; `return` of a temp or
an ivar; `dup; store_temp`.

The fusion is a peephole in `Loader/MethodBuilding.swift`, which the
image build, the bootstrap compiler and the make primitive all pass
through, so both compilers emit the same unfused bytecodes and agree as
before (`CompilerTest`), and every installed method is fused the same
way. The verifier verifies the fused form (its stack effect is the sum
of its parts), the pc-to-source map is rewritten with it so the
debugger's ranges and stepping hold, the disassembler and `kasm` read
and write the new opcodes, and the kasm fuzz corpus gains them. A step
over a fused instruction is one step; say so in the doc.

Stop fusing when the loop's disassembly shows a spill (the 8a lesson: a
bigger switch costs register allocation before instructions; count the
loads of `fp`, `hdr`, the heap base and the table base per dispatch
before and after) or when `arc-check` finds a second table.

## Part 3: the special sends

`at:`, `at:put:`, `size`, `class`, `isNil` and `notNil` are special
bytecodes already, but every one runs out of line through
`v1Instruction` (`Interpreter/Special.swift`), which first re-derives
the code and literal bases from the method (`regsAt`: four dependent
loads) and then switches on the opcode a second time. Measure: the
bases passed in rather than re-derived; the second switch replaced by
one entry per opcode; and for `isNil`, `notNil`, `class` and `at:` on
a plain Array with a SmallInteger index, whether an inline fast path
fits the register budget (it did not for every v1 fast path in 8a; the
disassembly decides, per opcode). `at:` and `at:put:` keep the weak
keep-alive barrier and the read-only check the collectors review put
there.

## The bar

- `fib`, `sends`, `st-sends`: at least 15 percent fewer cycles per send
  on the mini, with the device's one-thread rows moving the same way.
- `arith`: at least 20 percent fewer cycles per iteration.
- No kernel slower than 1.02 in the aligned A/B at 1 and 8 workers.
- `interpret` is one jump table and one indirect branch (`just
  arc-check`), with no new spill of a hot register (the disassembly
  diff, loads per dispatch counted in the doc).
- The random programs, the kernel tests, the golden checksums, the
  save-and-resume tests, the debugger's step tests and `CompilerTest`
  pass unchanged in meaning; where a test reads a pc or a bytecode
  count, it is updated with the reason beside it.
- The models' rules bind: a store into an old object while marking goes
  through the barrier, a stale cache word is impossible after an
  install stop, and the doc has the argument.
- The 18 gates on the final code commit, the four fuzz targets one
  after another, broken variants as test switches where they fail a
  verifier (a cache word surviving an install stop; a fused
  instruction's source map off by one) and by hand where they trap.
- The shells' scenario matrix on the Mac and the iPhone misses no more
  frames than before (the loop changed; the frame bar is the product's).

## Not in scope

A register bytecode (same gain band on dispatch-bound code, nothing on
sends, every compiler and the debugger rewritten), a hand-written
assembly loop (Swift lands within 1 to 8 percent of Rust; revisit only
if the misprediction counters say dispatch dominates), ahead-of-time
compilation of release images (a later module), polymorphic inline
caches past one entry (measure the monomorphic hit rate first and
report it), changes to the kernel's collections.

## Deliverables

`docs/modules/interpreter-speed.md` as built in the style of
`large-bytes.md` (measurements first, each step's A/B kept or
discarded with its number, the design of the cache word and its
invariant, the opcode pairs chosen with their counts, the loads per
dispatch before and after, deviations, tests, broken variants, unsafe
surface, hot-path check, not done, open questions, gates, commands);
ADR 0009's Built note for the new opcodes; `docs/modules/interpreter.md`
and `object-model.md` updated where they describe the send and the
set; the bench harness's cycle columns kept for the weekly run.
