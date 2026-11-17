# Fused sends, measured first

## Status

Brief, 2026-11-17. The owner's answer of 2026-11-15 to interpreter speed's
third question (`docs/decisions/20-interpreter-speed.md`): "Measure first."
The owner on 2026-11-17, asked whether to brief and start it: "Yes, start
it".

## What it is

The interpreter fuses 17 pairs of bytecodes (opcodes 50 to 66). None ends
in a send. `push_temp send` and `push_self send` are the most common
static pairs in the image and were left out, because the send case is
where the dispatch loop's register budget is spent and a second copy of
the inline send is about a hundred instructions in the loop.

This module first bounds what fusing them could gain, with counts and a
cheating build, against a rule written and committed before any number is
read. If the ceiling is under the rule, the module stops there and records
the bound; nothing is built. If it is over, the module builds the fused
sends the bound justified, and only those.

Stopping after part 2 is a full result of this module, not a failure.

## What is known

Check these before building on them.

- `docs/modules/interpreter-speed.md` (ae1b0d6): `push_temp send` was 26.9
  million dispatches, 2.5 percent, of the kernel tests' and 2994 static
  sites; the static counts are led by `send pop`, `push_temp send` and
  `push_lit send`; the kernels' dynamic lists did not show a send pair in
  their top rows. `counts/summary.txt` of that module has the full lists.
- Fusing the 17 pairs cut dispatches to 0.62 to 0.84 and cycles per send
  to 0.61 to 0.82. A cheating build bounded a per-site inline cache at 2
  percent and the poll countdown at 1.1; neither was built.
- The rules a fused instruction keeps: only the first opcode byte is
  replaced; operands, offsets, jump targets, the pc-to-source map, saved
  pcs and stepping stay those of the plain code; a fast path that does not
  apply runs the first part alone and dispatches the intact second; the
  verifier's one rule (the second part follows, plain); every tool that
  compares bytecodes compares the plain form (primitive 166).
- The dispatch loop is one jump table and one indirect branch (`just
  arc-check`), one opcode per case. A bigger loop cost register allocation
  before it cost instructions (5 to 23 percent on every kernel, once).
- Since AOT 2 and native by default a Release app runs native code. The
  interpreter runs: every Debug app and the developer's live session, the
  methods a subset leaves out (`excluded.txt`), everything installed at
  run time, and a Release app built with `KAJO_NATIVE=NO`.
- A send is a poll point and a frame's saved pc is the pc after the send.
  The native engine's lesson: a poll at a send is not a resume point for
  another engine.

## Starting positions

To be measured. Say where one was wrong.

1. In the kernels and the kernel tests, sends preceded by `push_temp`,
   `push_self` or `push_lit` are under 10 percent of dispatches, so the
   ceiling from removed dispatches alone is a few percent of cycles.
2. The gain of a fused send is the removed dispatch (one indirect branch
   and its load) and nothing else; the send's own work does not shrink.
3. A fused send that jumps into the one existing send path after its push
   (no second copy of the inline send) keeps the loop's register
   allocation; a second inline copy does not.
4. The image's static counts overstate the dynamic share: most of the 2994
   sites are cold.
5. The Smalltalk workloads that matter for the interpreter now (the
   developer UI's session, the kernel tests in a Debug-like build) are
   send-bound, not bound by the dispatch between a push and a send.

## Parts

1. **Count, build nothing.** With the counting build
   (`-DKAJO_COUNT_OPCODES`, `KAJO_OPCODE_COUNTS`) on the head: for the
   golden kernels (kasm and Smalltalk), the kernel tests, the tools' tests
   and the collections program, every pair and triple that ends in a send,
   dynamic count and share of dispatches, and the static count in the
   image; cycles and instructions per dispatch from the run line. One
   table. From it, the arithmetic ceiling: if every counted pair cost one
   dispatch less, how many cycles is that, per workload.
2. **The rule, then the cheating build.** Before any cheating build is
   measured, write the rule that decides build or stop in
   `~/kajo-scratch/fused-sends/part2/rule.txt` and commit a copy in this
   doc in its own commit, so the commit's time is the proof. The
   recommended rule: build a fused send only if its cheating build gains 5
   percent of cycles or more on at least two of `sends`, `st-sends`, `fib`,
   `closures` and the kernel tests, in aligned builds with five interleaved
   runs and equal checksums, and no golden kernel is slower by more than 1
   percent. Then the cheating builds, never committed: the peephole fuses
   every candidate pair into an opcode that pushes and enters the send
   (a) through the existing send path and (b) as a second inline copy,
   ignoring the verifier, stepping and the source map as far as the
   kernels still give their checksums. Each build's table against the
   head, with the disassembly's answer to "did the loop keep one jump
   table and its registers" (`just arc-check`'s reading). Say which
   pairs, if any, pass the rule.
3. **Stop or build.** If nothing passes: write the bound in the doc, run
   the tier, hand back. If something passes: build exactly that as fused
   opcodes under every rule of "What is known" (verifier rule, plain
   bytecodes through primitive 166, stepping, the pc-to-source map, saved
   pcs, the fallback that runs the first part alone), and decide with the
   generator's own tests whether `Sources/KajoAOT` reads the plain form or
   must learn the opcodes.
4. **Only if built:** the aligned A/B, `just arc-check`, the matrices on
   the three machines in both engines with `--bar` over every row, and
   the runtime comparison's Kajo rows.

## Tests

Only if part 3 builds. Before the code where possible.

- The verifier refuses a fused send whose second part is not the plain
  send that follows; the seeded mutation test covers the new opcodes.
- The hand-run broken variant: a fused send whose operand is read as the
  other part's operand answers a named wrong value.
- A method with fused sends steps instruction by instruction as its plain
  form, shows the same pc-to-source map, and `plainBytecodes` answers the
  plain form; the compilers' comparison still compares plain forms.
- A preemption, a stack growth and a `doesNotUnderstand:` at a fused send
  resume at the right pc (the stress flags `--stress stop` and the random
  programs cover it; say which seed counts ran).
- The native engine's three gates pass in both configurations.

## The bar

- Part 1's table and part 2's rule and tables exist with their files, and
  the rule's commit precedes the first cheating measurement.
- If stopped: the doc states the ceiling per workload and which starting
  positions held; no code changed; the tier `just check` picks passes.
- If built: the rule's threshold is met in the committed build, not only
  the cheating one; no golden kernel slower by more than 1 percent
  aligned; `just arc-check` passes (one jump table, one indirect branch,
  no retain or release); every row of the matrices at 0 failed launches,
  0 wrong checksums, 0 unjustified fallbacks; the core tier passes on the
  final code commit in one log.

## Rules of the house that bind here

- Bound an optimization with a cheating build before building it.
- A fused instruction replaces only the first opcode byte.
- A bigger dispatch loop costs register allocation before instructions;
  read the disassembly, not the instruction count.
- For an A/B, both builds aligned; if the hot functions' disassembly is
  identical, the difference is the linker's.
- Swift's `case a, b where cond` applies the condition to the last
  pattern only; check that an A/B switch switches.
- A faster mutator is a heavier load on every provisioning rule; if
  built, the row that falls back first is read first.
- A rule written before the numbers is committed before the numbers.
- A cheating or broken build is never committed.

## Not in this module

- Triples, `store_ivar` pairs, inline `size` and `class`, the inline
  cache, the poll countdown.
- Any change to the native engine's generated code beyond what reading
  fused opcodes needs.
- Any collector or provisioning change, whatever the matrices show.

## Deliverables

Part 1's table and part 2's rule and tables under
`~/kajo-scratch/fused-sends/`, this doc as built, the tier's `gates.log`;
and if built, the opcodes, their tests and the A/B.

## Open questions

Build the recommended option; decisions only.

1. The rule's threshold. Recommended: 5 percent on two workloads, as
   above. A fused send adds opcodes to a loop that is hard to keep fast,
   and the interpreter is no longer the Release engine.
2. If one pair passes and another does not. Recommended: build only what
   passes.
3. If only the second inline copy passes and the shared path does not.
   Recommended: stop and hand back with the numbers; a second copy of the
   send in the loop is the owner's decision.

## Part 1: the counts (2026-11-17, 7934a55)

Mac mini M2 Pro, swift.org Swift 6.4.2 (swiftly, first on PATH;
`~/kajo-scratch/fused-sends/part1/env.txt`). The counting build
(`swift build -c release --product kajo -Xswiftc -DKAJO_COUNT_OPCODES`) ran
every workload at one worker (`scripts/part1-count.sh`, raw counts in
`part1/counts/<workload>.txt`, run lines in `part1/count-runs.txt`); the
cycles and instructions are the aligned `-enable-testing` release build's
(`ab.sh`'s flags), three runs, the median (`scripts/part1-cycles.sh`,
`part1/cycles.txt`): the workers' own counters for the kernels and the
collections program, the whole `kajo test` process from `/usr/bin/time -l`
for the tests (image load and harness included, so their cycles per
dispatch are high). Every path here is under `~/kajo-scratch/fused-sends/`;
the full table with every pair and triple ending in a send per workload is
`part1/table.md` (`scripts/part1-table.py`).

Dispatches are counted as the head dispatches them: a fused opcode is one
dispatch, and a pair is counted only when its second instruction began
where the first ended. A push that a fused opcode already took (`push_temp
push_temp send` runs as `fused_push_temp_push_temp` then `send`) is not in
a `push_temp send` row; those rows are exactly the dispatches a new pair
would remove, since the peephole fuses left to right and no fused pair
starts with a send.

| workload | dispatches | `push_temp send` | `push_self send` | `push_lit send` | `push_ivar send` | other pushes | all | cycles per dispatch | IPC | ceiling (i) | ceiling (ii) |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| arith | 1069 M | 0 | 0 | 0 | 0 | 0 | 0 | 5.73 | 3.15 | 0 | 0 |
| fib | 559 M | 0 | 0 | 0 | 0 | 0 | 0 | 8.30 | 3.65 | 0 | 0 |
| sends | 787 M | 80.0 M (10.17 %) | 0 | 0 | 0 | 0 | 10.17 % | 7.18 | 4.75 | 10.17 % | 2.09 % |
| alloc | 692 M | 0 | 0 | 42.0 M (6.06 %) | 42.0 M (6.06 %) | 0 | 12.12 % | 13.99 | 4.52 | 12.12 % | 1.34 % |
| ivars | 993 M | 0 | 0 | 32 k | 0 | 0 | 0.00 % | 6.13 | 3.73 | 0.00 % | 0.00 % |
| walk | 449 M | 21.0 M (4.67 %) | 0 | 33.6 M (7.48 %) | 0 | 0 | 12.15 % | 27.11 | 2.19 | 12.15 % | 1.43 % |
| storeheavy | 1346 M | 64 k | 0 | 64 k | 0 | 0 | 0.01 % | 5.28 | 4.62 | 0.01 % | 0.00 % |
| closures | 1173 M | 0 | 0 | 60 k | 0 | 60 k | 0.01 % | 8.97 | 5.43 | 0.01 % | 0.00 % |
| floats | 480 M | 0 | 0 | 0 | 0 | 0 | 0 | 22.55 | 5.40 | 0 | 0 |
| st-sends | 787 M | 40.0 M (5.08 %) | 0 | 0 | 0 | 0 | 5.08 % | 5.96 | 3.88 | 5.08 % | 1.54 % |
| st-ivars | 993 M | 0 | 0 | 32 k | 0 | 0 | 0.00 % | 6.15 | 3.72 | 0.00 % | 0.00 % |
| st-closures | 1173 M | 0 | 0 | 0 | 0 | 60 k | 0.01 % | 9.27 | 4.98 | 0.01 % | 0.00 % |
| collections | 1462 M | 10.8 M (0.74 %) | 2.4 M (0.16 %) | 0 | 0 | 0 | 0.90 % | 9.66 | 4.13 | 0.90 % | 0.16 % |
| kernel tests (249) | 984 M | 19.9 M (2.02 %) | 7.0 M (0.71 %) | 1.7 M (0.17 %) | 7.4 M (0.75 %) | 4.0 M (0.41 %) | 4.07 % | 15.18 | 3.68 | 4.07 % | 0.51 % |
| kernel and tools tests (295) | 1144 M | 23.4 M (2.04 %) | 8.3 M (0.73 %) | 2.0 M (0.17 %) | 8.6 M (0.76 %) | 4.7 M (0.41 %) | 4.11 % | 15.20 | 3.64 | 4.11 % | 0.52 % |

Counts under a thousand are shown as 0 (the exact ones are in
`part1/table.md`).

The arithmetic ceiling is the cycles saved if every counted pair cost one
dispatch less, as a share of the workload's cycles: (i) at the workload's
mean cycles per dispatch, which is the dispatch share itself and assumes
the removed dispatch costs as much as an average instruction with its work
(far more than it can); (ii) at the dispatch's own seven instructions
(`ldrb`, `cmp`, `b.hi`, `adr`, `ldrh`, `add`, `br`) at the workload's
measured instructions per cycle, which assumes no misprediction is
removed. The truth lies between; the cheating build measures it.

Other pairs ending in a send in the kernel tests: `push_closure send` 0.65
percent (not a push the loop does inline: `pushClosure` allocates out of
line), `push_int send` 0.39, `pop send` 0.13, `send send` 0.13, the rest
under 0.05 each; every pair ending in a send together 5.15 percent of the
tests' dispatches, with 74.3 M sends among 984 M dispatches (13.2 per send).
The top triples ending in a send are under 0.4 percent each (`push_lit
push_temp send` 0.39, `push_ivar push_ivar send` 0.30). `push_* send_super`
is 2 k dispatches. In `sends` the loop's `push_temp 5; send at:` and
`push_temp 3; send step:` are the 80 M (kasm sends `at:` as a plain send);
`st-sends` compiles `at:` to the special `at` opcode, so only `step:` is a
`push_temp send` (40 M). `alloc` and `walk` are `push_lit send` (`new`)
and `push_ivar send`.

Static, in the plain form the compilers emit (`part1/counts/static-*.txt`,
pairs not across a jump target): the kernel image's 56 386 instructions
have `push_temp send` at 2803 sites (4.97 percent), `push_lit send` 2201
(3.90), `send send` 1577, `push_self send` 879 (1.56), `push_closure send`
829, `push_int send` 530, `push_ivar send` 215 (0.38); the development
image (kernel and `tools/`, 73 268) 3506, 2949, 1999, 1010, 1151, 646 and
338.
