# Interpreter speed: the send path, superinstructions, the special sends

Status: built, 2026-11-07, from the brief of the same day (the owner: "I
think the 1-3 sound good, you can work on them before we finish with the
VM"). Code in `Sources/KajoVM/Interpreter/Dispatch.swift` (the fused
cases, `compareAndJump`, the inline `at:`, `isNil`, `notNil`),
`Opcodes.swift` (the 17 fused opcodes, `fusedParts`, `base`,
`DecodedInstruction.fused`), `Loader/MethodBuilding.swift`
(`fuseBytecodes`, the peephole), `Loader/BytecodeVerifier.swift` (the
second part's check), `Loader/Assembler.swift` (kasm's fused mnemonics),
`ObjectModel/LiveMethods.swift` (primitive 166), `ObjectMemory/Config.swift`
(the `noFusion` switch); the measuring in `Headless.swift`,
`Workers/VM.swift` (`workerInstructionsAndCycles`) and the counting build
`Interpreter/OpcodeCounts.swift`. Kernel: `CompiledMethod>>plainBytecodes`,
`CompiledCode>>matches:`. Tests in
`Tests/KajoVMTests/Interpreter/FusionTests.swift`, `KasmTests`,
`SeedTests` (a fused kasm seed), the random programs (`plainBytecodes`).

The result in one line: **part 2 did it.** Fused instructions cut the
dispatches of the kernels by 16 to 38 percent and of the kernel tests by
24 percent, and with them the cycles of `fib` by 18 percent per send,
`sends` 36, `st-sends` 40 (with part 3's inline `at:`) and `arith` 28 per
iteration on the mini; the iPhone's one-thread rows moved the same way
(19, 17, 40 and 28). Every step of part 1 was measured and none was
kept: the per-site cache's ceiling was 2 percent, the leaner activation's
7 percent on `fib` cost 6 to 8 percent elsewhere through the register
allocation and added nothing once the instructions were fused, and a poll
without its countdown was worth 1 percent at most.

## What it hides

How a send finds its method and pushes its frame (unchanged), how many
dispatches a compiled expression costs (fewer: a fused opcode runs two
instructions), and how `at:`, `isNil` and `notNil` reach their fast paths
(inline). The bytecode set's meaning does not change: every method runs
as before, both compilers emit the same plain bytecodes as before and
still agree (`CompilerTest`), and the debugger steps the same source
ranges at the same pcs, because a fused method has every offset of the
plain one.

## Where the time went (measured first)

### The counters

`kajo run` now reports `workerInstructions` and `workerCycles`: the
background workers' own retired instructions and cycles over the timed
run (from setup's end to the last Process's end), summed over the workers
and both core types, from the per-thread counters the shells already read
(`proc_pidinfo(PROC_PIDTHREADCOUNTS = 34)`, declared by its symbol since
libproc.h is not in the iOS SDK; `workerCountersOk` says whether every
worker's record read). The A/B script and the weekly run keep them, so
every number below is cycles per send or per bytecode, not only wall time.
An A/A run of the same binary twice (three runs interleaved) put the noise
at 1 percent of cycles at 1 worker and 2.6 at 8 (wall time at 8 workers:
up to 9 percent). **The `kpc` branch-misprediction counters need root**;
they were not used (no escalation), so mispredictions are inferred from
instructions against cycles and from the disassembly.

### The starting point (b04acba, aligned `-enable-testing` release, 1 worker, M2 Pro)

| kernel | sends | bytecodes | cycles per send | cycles per bytecode | instructions per bytecode |
|---|--:|--:|--:|--:|--:|
| `fib` | 79.9 M | 799 M | 71.3 | 7.13 | 25.4 |
| `sends` | 80.0 M | 1187 M | 109.6 | 7.39 | 26.8 |
| `st-sends` | 40.0 M | 1187 M | 193.7 | 6.53 | 21.5 |
| `arith` | 1 | 1718 M (21.5 per iteration) | - | 4.97 (106.8 per iteration) | 16.1 |
| `ivars` | 64 k | 1249 M | - | 5.29 | 21.6 |
| `st-closures` | 240 k | 1833 M | - | 6.95 | 34.1 |

`fib` runs 10 bytecodes per send; at 4 instructions per cycle the core is
not starved, it is doing work: 254 instructions per call, of which the
send and the return are about a hundred and the dispatches 7
instructions each (`ldrb`, `cmp`, `b.hi`, `adr`, `ldrh`, `add`, `br`).

### The counts (`counts/`)

A counting build (`swift build -c release -Xswiftc -DKAJO_COUNT_OPCODES`;
the product has none of it, `interpret`'s disassembly is unchanged without
the flag) counts every dispatch and every pair and triple that ran by
fall-through (each instruction beginning where the one before ended: the
sequences a fusion can stand for), and, statically, every method made
through `makeMethodObjects`, pairs not crossing a jump target. Dynamic
counts over the twelve kernels (9 kasm, 3 Smalltalk) and over the kernel
and `tools/` tests (235 tests, one worker), static over the development
image (kernel and `tools/`, 62 222 instructions):

| pair | kernels | kernel tests | static |
|---|--:|--:|--:|
| `push_temp push_int` | 1141 M (7.7 %) | 35.1 M (3.3 %) | 934 |
| `push_temp push_temp` | 827 M (5.6 %) | 67.4 M (6.3 %) | 1202 |
| `push_int add` | 672 M (4.6 %) | 30.9 M (2.9 %) | |
| `store_temp jump` | 515 M (3.5 %) | 25.1 M (2.4 %) | |
| `add store_temp` | 395 M (2.7 %) | 24.4 M (2.3 %) | |
| `push_int sub` | 357 M (2.4 %) | | |
| `gt jump_if_false` | 330 M (2.2 %) | | |
| `ge jump_if_false` | 208 M (1.4 %) | | |
| `lt jump_if_false` | 198 M (1.3 %) | | |
| `dup store_temp` | 190 M (1.3 %) | | |
| `le jump_if_false` | 189 M (1.3 %) | 28.1 M (2.6 %) | |
| `pop push_temp` | 188 M (1.3 %) | 20.6 M (1.9 %) | 574 |
| `push_self push_temp` | | 42.7 M (4.0 %) | 1285 |
| `push_self push_int` | 160 M (1.1 %) | | |
| `identical jump_if_false` | | 7.9 M (0.7 %) | |
| `push_temp send` | | 26.9 M (2.5 %) | 2994 |
| `store_ivar push_temp`, `push_temp store_ivar` | 580 M, 520 M | (1 %) | |

The full lists, triples included, are in `counts/summary.txt`; the
static counts are dominated by sends (`send pop`, `push_temp send`,
`push_lit send`), which no fusion here takes. The Mac shell's `demo` and
`devsession` modes were not counted: the counting flag does not reach a
package built by Xcode (the 11a lesson), and a shell built with it was
not worth its build; the kernel tests run `tools/`'s tests, which are what
`devsession` drives.

## Part 1: the send path

Every step was built, measured in the aligned A/B, and discarded.

### 1. The per-site inline cache: discarded on its ceiling

The question was where the cache words live. Before designing it, its
ceiling: a build whose send trusts the global cache line without
comparing class and selector (correct only for a monomorphic kernel, so
`fib` alone) is everything a per-site cache could save, and more, since an
inline cache still loads and compares its word. Against the starting
build, five runs: **`fib` 0.979 cycles, 0.976 instructions**. A real
inline cache would save under 2 percent of `fib`'s cycles and less on
`sends` (15 bytecodes per send), against a new hidden literal or side
object in every method, both compilers, the source map's last-literal
rule, the snapshot and the verifier. Not built. The global cache's flush
at every pause stays (it is also what makes the activation's cached
fields below safe); see "Not done" for the storm's misses.

### 2. A leaner activation: discarded

Built as two pieces and in three register layouts (`ab/var-proto*`,
`protoAB.patch`, `protoD.patch`):

- **The activation from the cache line**: a line of 64 bytes holding the
  method's packed activation word (temps, the frame's words, the
  primitive) and its bytecodes' and literal frame's bases, filled by
  `lookupMiss`, so a hit reads nothing of the method. (The brief's packed
  word in the method would have changed `MethodLayout` and the kernel's
  CompiledMethod; the line holds it at no format cost.)
- **The return from the frame**: two more header words holding the
  frame's own code and literal bases, tagged as SmallIntegers, so a return
  reads the caller's bases from its header (one load after the caller's
  hdr) instead of four dependent loads through the method. The argument
  for the raw pointers is the pin for good: a method's bytecodes and
  literal Array are pinned for good (the loader refuses a method whose
  are not), compaction keeps pinned blocks, relocation selects none, and
  a frame's method word keeps them alive; the saved Processes' loader
  would have rewritten the words from each frame's method.

Measured against the starting build (1 worker, cycles):

| variant | `fib` | `sends` | `st-sends` | `arith` | `ivars` |
|---|--:|--:|--:|--:|--:|
| both pieces | 0.924 | 0.976 | 0.989 | **1.063** | **1.083** |
| both, `code` dropped from the registers (caller pc from the frame word) | 1.019 | 0.946 | 0.952 | 0.998 | 0.999 |
| the same, `Regs` reordered | 1.002 | 0.951 | 0.950 | 1.024 | **1.082** |
| both, true and false loaded where used | 0.931 | 0.989 | 0.993 | 1.085 | 1.112 |

The first row is the step's real gain on `fib` (7.6 percent) and its real
cost: the larger inline activation moved `true` and `false` out of their
registers into the frame of `interpret` (`ldp x11, x10, [x0]; stp x10,
x11, [sp]` in the prologue), so every compare and conditional jump of
`arith` loaded them, and `ivars` lost a register its store path used. No
layout of the four tried kept `fib`'s gain without a loss of 2 to 8
percent elsewhere. **With part 2 in, the whole step added nothing**:
fused and lean against fused alone, `fib` 0.825 against 0.819, `sends`
0.648 against 0.639, `st-sends` 0.663 against 0.687, `arith` 0.730
against 0.716, `ivars` 0.927 against 0.929 (`multi-fuse.txt`). Kept out,
with the frame layout, the saved-Process rules and the cache line as they
were.

### 3. The poll's countdown: discarded on its ceiling

The countdown in a register needs a register the loop does not have (the
step above showed what one more live value costs). Its ceiling: a build
with no countdown at all at sends (the flag alone; wrong, the budget
check never comes) against part 3: `fib` 0.989, `sends` 0.991, the others
within 0.6 percent. Not built.

## Part 2: superinstructions

### The design: a fused opcode is a first byte

A fused opcode replaces **only the opcode byte of the first of two plain
instructions**; the first's operands and the whole second instruction
stay where they were. The dispatch loop runs both at once and continues
after the second; when a fast path does not apply it runs the first part
alone, exactly as its plain case would, and continues at the second, which
is intact. So a fused method has every offset of the plain one:

- jump targets need no care: a jump to the second part runs it alone,
  and control reaches the first part only by falling into the second;
- the pc-to-source map, the saved pcs of an image's Processes, the
  verifier's traced depths at each pc, `sendEnding`, `primResend:` and
  the debugger's stepping are unchanged (no map is rewritten, and the
  brief's broken variant, a map off by one, cannot arise);
- a poll inside a fused instruction is the first part's (a special
  send's real send, rewound by one byte to the fused opcode, which then
  runs again from its start with nothing done) or the backward jump's at
  its end;
- **a step over a fused instruction is a step over its parts**: stepping
  stops at sends, and neither part of any fused instruction here is a
  send on its fast path.

The brief's form (a new instruction with all operands packed, the map
rewritten) would have saved the second part's operand bytes and nothing
else; this one costs no format change at all beyond the opcodes.

### The opcodes chosen (50 to 66)

From the counts, pairs, one case each, no case sharing a body:

| # | mnemonic | parts | fast path | fallback |
|--:|---|---|---|---|
| 50 | `fused_push_temp_push_temp` | `push_temp a; push_temp b` | always | - |
| 51 | `fused_push_temp_push_int` | `push_temp a; push_int k` | always | - |
| 52 | `fused_push_self_push_temp` | `push_self; push_temp b` | always | - |
| 53 | `fused_push_self_push_int` | `push_self; push_int k` | always | - |
| 54 | `fused_push_int_add` | `push_int k; add` | top a SmallInteger, no overflow | the push |
| 55 | `fused_push_int_sub` | `push_int k; sub` | same | the push |
| 56 | `fused_add_store_temp` | `add; store_temp n` | two SmallIntegers, no overflow | `add` (its tier, or the send) |
| 57 | `fused_sub_store_temp` | `sub; store_temp n` | same | `sub` |
| 58 | `fused_store_temp_jump` | `store_temp n; jump off` | always (the backward jump polls) | - |
| 59 | `fused_dup_store_temp` | `dup; store_temp n` | always | - |
| 60 | `fused_pop_push_temp` | `pop; push_temp n` | always | - |
| 61 to 65 | `fused_lt_`, `gt_`, `le_`, `ge_`, `eq_jump_if_false` | compare; `jump_if_false off` | two SmallIntegers: compare and branch, no Boolean made | the compare |
| 66 | `fused_identical_jump_if_false` | `identical; jump_if_false off` | always | - |

Not fused, against the counts: `push_temp send` (2.5 percent of the
tests' dispatches, 2994 static sites) and every pair ending in a send,
because each copy of the inline send is a hundred instructions in the
loop and the send case is where the register budget is spent; `store_ivar`
pairs (`storeheavy` and `ivars` only: the store path with its barriers is
the 8a lesson's cost); triples (`push_temp push_int add` is two fused
dispatches as it is). The compare-and-jump opcodes cover the conditional
jumps that matter; `jump_if_false push_temp` (3 percent of the kernels)
was left out because its fall-through half would have to run a push only
on one outcome.

### The peephole (`fuseBytecodes`, `Loader/MethodBuilding.swift`)

`makeMethodObjects` passes every method's and block method's bytecodes
through it before making the ByteArray: the image build, the kasm loader,
the make primitive (143) and a reshape's remade methods, so both compilers
emit plain bytecodes and every installed method is fused the same way.
Left to right, each pair of plain, unextended instructions with a fused
opcode gets it in its first byte, and the scan goes on after the pair;
already fused instructions are kept with their second part (so remaking
a method is idempotent); bytes that do not decode are left for the
verifier. An extended instruction (`ext`) is never fused, so a fused
instruction's operands are each one byte. The test switch `noFusion`
makes methods plain.

### The verifier, kasm, the tools

- `decodeInstruction` answers a fused instruction as its first part
  (`op`), with the fused opcode in a new field (`fused`): every reader of
  instructions (the verifier's checks and tracer, the saved-Process rules,
  `sendEnding`, the counts) sees the plain instruction. The verifier adds
  one rule: a fused instruction is followed by its second part as a
  plain, unextended instruction (`theVerifierRefusesAFusedOpcodeWithoutItsSecondPart`).
  Its stack effect is its first part's, the second is traced as itself.
- kasm takes the fused mnemonics in place of the first part, the second
  part on the next line (`kasmTakesFusedMnemonics`); a fused mnemonic's
  operand must fit a byte. The kasm fuzz corpus gains `fused.kasm`, every
  fused mnemonic.
- **Primitive 166, `CompiledMethod>>plainBytecodes`**: the bytecodes with
  every fused opcode back as its first part. `CompiledCode>>matches:`
  compares the Smalltalk compiler's output with it, so `CompilerTest`,
  `LiveCompileTest`, `MakeFuzzTest` and `ClassVariableTest` compare what
  the compilers emit, as before (four kernel tests failed on the fused
  bytes before it).
- Images: a new image has fused methods; an older image (version 6) loads
  and runs its methods plain, and an older VM refuses a new image's
  methods at the verifier (unknown opcode). The image version is
  unchanged (an open question below).

### Loads per dispatch and the registers

The disassembly of the starting and final aligned builds
(`ab/disasm/start`, `ab/disasm/head`): `interpret` 1320 to 1816
instructions; **one jump table, one indirect branch** (`just arc-check`);
the dispatch is the same seven instructions, **two loads per dispatch
before and after** (the opcode byte and the table entry; the table's base
stays in `x26`); the register map is identical (`pc` x1, `sp` x2, `fp`
x3, `hdr` x4, `code` x27, `lits` x20, `true` x28, `false` x23, the flag
x24, the table and heap bases at +8 in x21 and x25, the bases themselves
on the stack as before). `fp`, `hdr` and the bases are loaded per
dispatch in neither build. Stack-relative accesses away from any call:
7 before, 10 after, the three new ones the activation's nil fill
reloading the heap base on its three paths (the starting build's send
loaded both bases with one `ldp` instead). No new spill of a hot
register.

## Part 3: the special sends

`at:` on an Array with a SmallInteger index in bounds, `isNil` and
`notNil` run inline (`at:`: one header load, the class and bounds test,
the slot load, as `push_ivar` does; `isNil`, `notNil`: a compare with nil
loaded where used, as `push_nil` does). Everything else of them goes to
`v1Instruction` as before. Against part 2: **`st-sends` 0.888 cycles**,
every other kernel within 0.6 percent, the registers unchanged. `at:`'s
inline path is the plain Array's, which has no weak slot and no barrier
on a read; the weak keep-alive and the read-only check stay in the tier
and `at:put:` is unchanged.

Not done of part 3: `size` and `class` still go through `v1Instruction`
(with its `regsAt` and its second switch), and `ne`, `not_identical`, the
temp-vector instructions too; none is in a kernel's hot loop, and the
kernel tests run `size` at 0.7 percent of their dispatches.

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2.

### The kernels against the starting commit

The measuring commit b04acba (`kajo` from a worktree) against the final
code (e417519 with the tests commit 1105916; `interpret` and the send path as at the final commit ae1b0d6),
both `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`, 2026-11-07; median (min to max) ms and the workers'
cycles; every checksum equal on both sides and the published one
(`ab/bench-final.txt`).

| kernel | workers | start ms | final ms | ratio | start cycles per send | final | cycles ratio | instructions ratio |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| alloc | 1 | 2949.5 (2946 to 2955) | 2898.7 (2885 to 2928) | 0.983 | 78.6 | 77.2 | 0.983 | 0.940 |
| alloc | 8 | 471.7 (456 to 486) | 475.3 (472 to 479) | 1.008 | 88.7 | 86.8 | 0.979 | 0.948 |
| arith | 1 | 2545.7 (2540 to 2556) | 1825.7 (1821 to 1832) | **0.717** | - | - | **0.717** | 0.697 |
| arith | 8 | 345.4 (340 to 360) | 247.0 (246 to 256) | 0.715 | - | - | 0.712 | 0.696 |
| fib | 1 | 1698.3 (1691 to 1701) | 1388.5 (1376 to 1393) | **0.818** | 71.3 | 58.1 | **0.815** | 0.836 |
| fib | 8 | 233.5 (217 to 239) | 187.1 (177 to 192) | 0.801 | 71.9 | 58.6 | 0.815 | 0.836 |
| ivars | 1 | 1971.6 (1965 to 1974) | 1822.4 (1818 to 1824) | 0.924 | | | 0.924 | 0.843 |
| ivars | 8 | 254.8 (252 to 277) | 240.3 (233 to 251) | 0.943 | | | 0.931 | 0.844 |
| sends | 1 | 2618.8 (2608 to 2621) | 1665.7 (1662 to 1675) | **0.636** | 109.6 | 69.9 | **0.638** | 0.845 |
| sends | 8 | 349.5 (336 to 361) | 215.9 (214 to 239) | 0.618 | 110.8 | 69.7 | 0.629 | 0.845 |
| st-closures | 1 | 3794.1 (3779 to 3810) | 3211.4 (3200 to 3215) | 0.846 | | | 0.845 | 0.865 |
| st-closures | 8 | 500.3 (485 to 522) | 429.4 (411 to 432) | 0.858 | | | 0.852 | 0.866 |
| st-ivars | 1 | 1969.8 (1968 to 1974) | 1817.7 (1814 to 1822) | 0.923 | | | 0.923 | 0.844 |
| st-ivars | 8 | 252.9 (252 to 271) | 249.9 (232 to 256) | 0.988 | | | 0.940 | 0.845 |
| st-sends | 1 | 2315.5 (2308 to 2317) | 1397.0 (1390 to 1402) | **0.603** | 193.7 | 117.2 | **0.605** | 0.713 |
| st-sends | 8 | 313.9 (302 to 322) | 179.4 (179 to 195) | 0.572 | 195.1 | 116.5 | 0.597 | 0.712 |
| storeheavy | 1 | 2406.4 (2396 to 2416) | 2118.2 (2108 to 2126) | 0.880 | | | 0.878 | 0.909 |
| storeheavy | 8 | 321.4 (312 to 334) | 280.0 (271 to 290) | 0.871 | | | 0.883 | 0.909 |

The bar: `fib`, `sends`, `st-sends` at least 15 percent fewer cycles per
send (18.5, 36.2, 39.5); `arith` at least 20 percent fewer per iteration
(106.8 to 76.5 cycles, 28.3); no kernel slower than 1.02 (the slowest
ratio is `alloc` at 8 workers, 1.008 in wall time and 0.979 in cycles).

Per bytecode (the plain count) and per dispatch (the fused count), 1
worker:

| kernel | bytecodes | dispatches after | cycles per bytecode before / after | cycles per dispatch after | instructions per bytecode before / after |
|---|--:|--:|--:|--:|--:|
| arith | 1718 M | 1069 M (0.62) | 4.97 / 3.56 | 5.73 | 16.1 / 11.2 |
| fib | 799 M | 559 M (0.70) | 7.13 / 5.81 | 8.30 | 25.4 / 21.2 |
| sends | 1187 M | 787 M (0.66) | 7.39 / 4.71 | 7.11 | 26.8 / 22.6 |
| st-sends | 1187 M | 787 M (0.66) | 6.53 / 3.95 | 5.96 | 21.5 / 15.3 |
| ivars | 1249 M | 993 M (0.80) | 5.29 / 4.89 | 6.16 | 21.6 / 18.2 |
| storeheavy | 1603 M | 1346 M (0.84) | 5.04 / 4.42 | 5.26 | 22.5 / 20.5 |
| st-closures | 1833 M | 1173 M (0.64) | 6.95 / 5.87 | 9.17 | 34.1 / 29.5 |
| kernel tests | 1064 M | 814 M (0.76) | | | |

Cycles fall faster than instructions where the fused pairs end in a
conditional jump (`sends` 0.64 cycles for 0.85 instructions): a compare
and branch with no Boolean in between removes a store, a load and a
dependent compare from the critical path, and one indirect branch.

### The iPhone

The iOS shell's `mode=golden`, one kernel per launch, one worker, the
starting commit's build and the final one each installed in turn (`dev/`,
2026-11-07, thermal nominal on every line); the process's cycles
(`ru_cycles`), two launches each (the two agree within 0.3 percent):

| kernel | start ms | final ms | start cycles | final cycles | cycles ratio |
|---|--:|--:|--:|--:|--:|
| fib | 1768 | 1437 | 5.74 G | 4.66 G | **0.811** |
| sends | 2730 | 2271 | 8.85 G | 7.36 G | **0.832** |
| arith | 2667 | 1919 | 8.65 G | 6.23 G | **0.720** |
| st-sends | 2406 | 1441 | 7.90 G | 4.78 G | **0.605** |

The device moves the same way; `sends` less than on the Mac (0.83
against 0.64), its `at:` send and polymorphic `step:` costing the A15
more of the remaining time.

### The shells' scenario matrix (the frame bar)

The final code's shells, `scripts/shell-matrix.sh` (drift, scenarios,
events, hog, three runs each; the iPhone at 5 workers, the Mac at 7),
2026-11-07 (`dev/iphone/`, `mac/`; every raw row tabulated in
`dev/iphone-rows.md` and `mac-rows.md`). Frames missed per launch,
counted fallbacks and full collections, and the longest stop of each
kind over the launches:

| device, row | launches | frames missed per launch | fallbacks | longest stops ms |
|---|--:|---|--:|---|
| iPhone idle | 3 | 0, 0, 0 | 0 | - |
| iPhone storm stw / local / offload | 3 each | 0 in all 9 | 0 | scavenge 10.8; initial mark 0.62, final mark 0.36, apply 0.35 |
| iPhone ring stw | 3 | 0, 1, 5 | 0 | scavenge 17.3, final mark 0.66 |
| iPhone ring local / offload | 3 each | 0 in all 6 | 0 | final mark 0.86, apply 0.45 |
| iPhone share stw / local / offload | 3 each | 0 in all 9 | 0 | scavenge 1.47 |
| iPhone events idle / storm | 3 each | 0 in all 6 | 0 | initial mark 0.46 |
| iPhone hog (budget on) | 3 | 0, 0, 0 | 0 | - |
| iPhone hog (budget off, the control) | 3 | 1192 each | 0 | - |
| Mac idle | 3 | 595, 0, 0 | 0 | - |
| Mac storm stw / local / offload | 3 each | 0 in all 9 | 0 | scavenge 6.2; initial mark 0.33 |
| Mac ring stw | 3 | 309, 289, 316 | 88 | full 200.4, scavenge 11.1 |
| Mac ring local / offload | 3 each | 0 in all 6 | 0 | final mark 0.82 |
| Mac share stw / local / offload | 3 each | 0 in all 9 | 0 | scavenge 1.16 |
| Mac events idle / storm | 3 each | 0 in all 6 | 0 | initial mark 0.31 |
| Mac hog (budget on) | 3 | 0, 0, 0 | 0 | - |
| Mac hog (budget off, the control) | 3 | 1193 each | 0 | - |

The iPhone (thermal nominal to serious) misses what module 9a's matrix
missed: nothing but the ring under the stop-the-world oracle (1 [0 to 5]
against 9a's 2 [1 to 4]), the main thread stopped for others 32 to 37 ms
per 10 s under the storm with young collection on (9a: 43 and 48), the
event latency p99 2.4 ms under the storm, the hog preempted 2413 times
with no frame missed.

The Mac's idle row has one launch, the first of the matrix, missing 595
frames behind a single gap of 4.97 s with no stop and no collection in it;
six more idle launches (three of each build, below) missed none. **The
ring under the oracle misses more than before**, measured against the
starting commit's own Mac shell, seven launches each interleaved
(`mac-ab/`):

| build | frames missed per launch | median | counted full collections (median) |
|---|---|--:|--:|
| b04acba | 232, 232, 257, 280, 193, 274, 282 | 257 | 23 (20 to 28) |
| final | 296, 346, 268, 255, 310, 320, 340 | 310 | 27 (26 to 32) |

Every missed frame there is a module 5 fallback's compacting full
collection (185 to 200 ms each, 11 frames per collection on both builds);
the faster mutators reach the soft limit with no cycle running more often
(`fallbacksIdle` 15 against 18 at the median) and so fall back more often.
The concurrent modes miss nothing with either build. The bar's frame
condition holds in every row but this one, the oracle's (an open question
below). (The 9a figure of 143 for this row was before modules 10 and the
large-bytes follow-up; the starting commit misses 257.)

## Deviations from the brief

- **No part 1 step is in the code**: each was built (or bounded) and
  measured; the numbers are above. With it the brief's invariant ("a cache
  word never names a freed or replaced method"), its stop verifier and its
  broken variant have nothing to check, and the global cache's flush at
  every pause stays as it was.
- **Fusion rewrites first bytes only**; the brief expected packed fused
  instructions and a rewritten pc-to-source map. Nothing about offsets
  changes, so the map, the saved pcs and stepping need no rewrite and the
  "map off by one" broken variant does not exist; the verifier's
  second-part rule is the one new check, with its broken variant in the
  suite.
- **Pairs only** (no triples), and no pair ending in a send: the counts
  and the register budget, above.
- **Part 3 kept `size` and `class` out of line**; only `at:`, `isNil`,
  `notNil` were measured inline.
- The shells' `demo` and `devsession` modes were not counted (above).

## Tests

- `FusionTests` (new): each of the 17 fused opcodes in a program that runs
  its fast path and, where it has one, its fallback (a LargeInteger from
  an overflow, a Float compare, a backward jump's poll), fused and plain
  (`noFusion`), the same answer, the fused opcode present and only first
  bytes differing; the peephole on hand-made bytes (left to right,
  idempotent, an extended instruction not fused, junk left alone); the
  verifier refusing a fused opcode followed by another instruction, an
  extended one, a fused one, or nothing; kasm's fused mnemonics.
- `theOpcodeTableIsContiguous`: 67 opcodes, the fused ones 50 to 66 (it
  counted 50 before; the reason is beside it).
- `kasmFuzzSeedsLoad`: the new `fused.kasm` seed.
- The random programs: a `plainBytecodes` configuration (eight workers,
  methods made without the peephole); every other configuration runs the
  programs fused.
- Kernel: `CompiledCode>>matches:` compares with `plainBytecodes`, which
  fixed `CompilerTest`, `LiveCompileTest`, `MakeFuzzTest` and
  `ClassVariableTest` (929 methods differed at the fused bytes, nothing
  else). 205 kernel tests and 235 with `tools/`.
- No test reads a pc or a bytecode count that fusion changes (offsets do
  not change); the debugger's step tests, the save-and-resume tests and
  the golden checksums pass unchanged.

## Broken variants

- In the suite: a fused opcode without its second part
  (`theVerifierRefusesAFusedOpcodeWithoutItsSecondPart`, four forms); the
  plain bytecodes as a configuration of the random programs and of every
  `FusionTests` program.
- By hand: with the verifier's second-part rule removed, the test above
  fails on three of its four forms (a fused opcode at the end still falls
  off the end) and a method with `fused_push_temp_push_temp 0` followed by
  `push_int 2` loads and runs: the loop reads the `push_int`'s operand as
  the second temp's index, pushes temp 2 (40) instead of 2, and the method
  answers 47 where the plain code answers 9. The rule is what makes the
  loop's fixed-offset reads right and safe: without it a byte checked as
  an integer or a jump offset is read as a temp index, unchecked, up to 255
  words past `fp`.

## Unsafe surface

120 added lines with `unsafe` in `Sources/KajoVM`: `Dispatch.swift` 77
(the fused cases and `compareAndJump`, register and stack-word reads and
writes as the plain cases make), `OpcodeCounts.swift` 34 (the counting
build only, compiled out of the product), `Workers/VM.swift` 9 (the
thread counters). Nothing outside the core.

## Hot-path check

`just arc-check` on the final commit: no retain or release on the checked
paths, `interpret` one indirect branch and one jump table (1403
instructions in its plain `-enable-testing` build; 1816 in the aligned
one). The disassembly diff is in `ab/disasm/diff-interpret.txt`; the new
cases call only `specialSend` and `pollAtJump`, as the plain compare and
jump cases did.

## Not done

- **The global cache's misses after a pause.** Every pause still
  flushes every worker's 1024 lines, so the first send of each site after
  a stop misses. Not measured under the storm in this module; the inline
  cache that would answer it was bounded at 2 percent of a monomorphic
  kernel's cycles without pauses.
- **Fused sends and triples**, beyond the measured set; `size`, `class`
  and the rest of `v1Instruction` inline; the branch-misprediction
  counters (root).
- The iPad's rows (the iPhone's only).

## Open questions for the owner

1. **The image version.** A new image carries fused opcodes an older VM
   refuses at its verifier; an older image runs plain on this VM. Bump the
   image version (7) so the refusal names the version, or leave it at 6
   since images are rebuilt from sources? Built: unchanged.
2. **The ring under the stop-the-world oracle on the Mac** misses more
   frames than before (310 against 257 at the median of seven launches),
   all of them behind counted compacting full collections that come more
   often with faster mutators. The owner accepted the oracle's misses
   (reserve-and-depth); is a worse oracle row acceptable for a faster
   interpreter, or should the oracle's trigger (its soft limit with no
   cycle running) follow? Built: nothing changed in the collector.
3. **Fused sends.** `push_temp send` and `push_self send` are the most
   common static pairs; fusing them needs either another copy of the
   inline send in the loop (the register budget) or an out-of-line send
   for the fused form. Worth a measured follow-up? Built: not fused.

## Gates

Every gate ran on **ae1b0d6** (the last commit that changes code; the
commits after it are this doc), Mac mini (M2 Pro), swift.org 6.4.2 (the
toolchain first on PATH), 2026-11-07 16:22 to 19:19, no device run
meanwhile, one after another, every output in a file under the session's
`interp/gates/`, each step logged with its commit in `interp/gates.log`.
The first run (31aeb7b, 16:14 to 16:22, `gates/run1-31aeb7b/`) passed the
clean build and failed `swift test` in the two Tonel round-trip tests
(the kernel's and `tools/`'s written out byte for byte): the new
`CompiledMethod>>plainBytecodes` had been appended, not written where the
image's canonical writer puts it; ae1b0d6 moved it
(`scripts/canonical-tonel.sh`) and the whole sequence ran again.

| gate | result |
|---|---|
| clean build (`--scratch-path .build/clean-check`) | exit 0, 0 errors, 0 warnings, 22 s |
| `swift test` | 385 + 115 passed, 310 + 91 s |
| under load (12 busy loops) | 385 + 115 passed, 363 + 111 s |
| ThreadSanitizer | 385 + 115 passed, 0 reports, 464 + 2283 s |
| ThreadSanitizer under load | 385 + 115 passed, 0 reports, 761 + 2912 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 139 functions, `interpret` 1403 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 385 + 115 passed |
| `just model-check` | 29 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration (28 lines, `plainBytecodes` among them, no failing seed); the resumed modes saving 908 to 995 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.20 million runs, no crash (the corpus with `fused.kasm`) |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.33 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.90 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.69 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| `just kernel-test` | 205 tests, 205 passed |
| `just new-check` | ok: both targets in both configurations, 0 errors, 0 warnings; the Release products without the protocol |

(385 is `KajoVMTests`, 4 of them new: `FusionTests`' functions, its 17 programs being cases of one; 115 `KajoCompilerTests`, as before.)
The bench A/B and the disassembly are of e417519 plus the test commit;
31aeb7b and ae1b0d6 change the thread counters' declaration and a
Smalltalk method's position, out of every path the check covers, and
`just arc-check` passes on ae1b0d6. The device and Mac matrix rows ran on
31aeb7b's shells (the same VM and kernel but for the method's position).

## Commands

```zsh
just arc-check
swift test --filter 'Fusion|kasmFuzzSeedsLoad|theOpcodeTableIsContiguous'
swift build -c release --product kajo -Xswiftc -DKAJO_COUNT_OPCODES --scratch-path /tmp/count   # the counting build
KAJO_OPCODE_COUNTS=counts.txt /tmp/count/release/kajo run kernels/prelude.kasm kernels/lib.kasm kernels/fib.kasm --workers 1
kajo run ... | tr ' ' '\n' | grep -E 'workerCycles|workerInstructions'   # cycles and instructions of the workers
DEVICE=<udid> scripts/device.sh run out.txt mode=golden kind=kasm kernel=fib workers=1
```
