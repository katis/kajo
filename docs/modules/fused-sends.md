# Fused sends, measured first

## Status

Brief, 2026-11-17. The owner's answer of 2026-11-15 to interpreter speed's
third question (`docs/decisions/20-interpreter-speed.md`): "Measure first."
The owner on 2026-11-17, asked whether to brief and start it: "Yes, start
it".

**Stopped after part 2, 2026-11-17: nothing passes the rule.** The best
cheating build gains 4.4 percent of cycles on `sends`, 2.9 on `st-sends`
and 0.6 on the kernel tests; nothing is built (sections "Part 2" and "The
bound" at the end).

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

## Part 2: the rule (committed before any cheating build)

A copy of `~/kajo-scratch/fused-sends/part2/rule.txt`, committed on its
own so that this commit's time precedes every cheating measurement.

```text
The rule that decides build or stop (fused sends, part 2). Written
2026-11-17 after part 1's counts (c434e23) and before any cheating build
is made or measured. The brief's recommended rule, open question 1's
recommended answer, made exact.

Candidates. The four push-then-send pairs at 0.5 percent of dispatches or
more in at least one workload of part 1: `push_temp send`, `push_self
send`, `push_lit send`, `push_ivar send`. (`push_closure send`, 0.65
percent of the kernel tests, is out: its push is an out-of-line
allocation, not a push the loop does inline. Every other push before a
send is under 0.4 percent everywhere.)

Builds. Two cheating builds from the rule's commit, never committed, each
fusing all four candidates through the existing peephole (four opcodes
appended after 66, each the push's first byte, the send intact after it):
 (a) shared send path: the fused case does the push and continues into the
     one inline send that the plain `send` case also uses; the send's
     inline body exists once in `interpret`;
 (b) second inline copy: each fused case does the push and has its own
     inline send.
The verifier, stepping and the source map are not touched beyond what the
peephole and the fused-opcode table already give; the build counts only
if every checksum is equal.

Measurement. Each cheating build against the rule commit's own build
(docs only since 7934a55, so the code is 7934a55's), both `-c release
-Xswiftc -enable-testing` with `-align-all-nofallthru-blocks=5
-align-loops=32` (scripts/ab.sh's flags), five runs interleaved
(base, variant alternating), `--slice-ms 0`:
 - the twelve golden kernels (kasm: alloc, arith, fib, ivars, sends,
   storeheavy, walk, closures, floats; Smalltalk: st-sends, st-ivars,
   st-closures) at 1 and 8 workers, the workers' cycles from the run line;
 - the kernel tests (kernel image built by each side's own binary, `kajo
   test <img> --workers 1`), the process's cycles from `/usr/bin/time -l`,
   every test passing on both sides.
Gain of a workload = 1 - (median cycles of the variant / median cycles of
the base), at 1 worker. Checksums equal on both sides in every run.

Decision.
 1. A cheating build passes if its gain is 5.0 percent or more on at least
    two of: sends, st-sends, fib, closures (the kasm kernel), the kernel
    tests; every checksum is equal; and no golden kernel's median cycles
    ratio is above 1.010 at 1 or at 8 workers.
 2. The all-four build of (a) is measured first. If it does not pass, no
    pair alone is measured for building (a pair alone removes a subset of
    the same dispatches) and the module stops: the bound is written in the
    doc. If it passes, each pair is measured alone in an (a) build, and
    only the pairs that pass alone are built (open question 2).
 3. (b) is measured either way, for the bound. If (b) passes and (a) does
    not, the module stops and hands back with the numbers: a second inline
    copy of the send is the owner's decision (open question 3).
 4. A build that passes here is built for real and must meet the same
    threshold in the committed build, not only in the cheating one.
```

## Part 2: the cheating builds (measured after the rule's commit)

The rule's commit is 78e8ff0 at 15:06:04; the cheating builds were made
from `git archive 78e8ff0` in `~/kajo-scratch/fused-sends/part2/src-{a,b}`
by `scripts/cheat-patch.py` (the patches as diffs:
`part2/cheat-{a,b}.diff`) and first measured at 15:09:59 (the first line
of `part2/ab-all4.txt`). Nothing of them was committed or put in the
working tree.

Both fuse the four candidates through the existing peephole: four opcodes
after 66 in `Opcode`, with `fusedParts` (`push_temp`, `push_self`,
`push_lit`, `push_ivar` with `send`) and a mnemonic, so `fuseBytecodes`
and the verifier's second-part rule took them as they are; every checksum
and all 249 kernel tests agreed on every side and run.

- **(a) the shared send path**: the plain `send` case and each fused case
  set a flag and leave the `switch`; after it one inline send reads the
  send's operands at `pc`. The compiler threaded the flag: `interpret` has
  one inline send (one call site each of `pollAndSend`, `lookupMiss`,
  `doesNotUnderstand`, `primitiveSend` and `stackOverflow`, as the base).
- **(b) a second inline copy**: each fused case pushes and runs its own
  inline send (`send(..., 3, poll: true)`, so a poll or an error rewinds to
  the intact plain send after the push, as the plain code would).

The disassembly of `interpret` in each aligned build
(`scripts/disasm.sh`, arc-check's reading; `part2/disasm/{base,a,b}.s`):

| build | instructions | indirect branches | jump tables | inline sends | ARC | stack-relative accesses | registers |
|---|--:|--:|--:|--:|--:|--:|---|
| base (78e8ff0) | 1816 | 1 | 1 | 1 | 0 | 349 | `true` x28, `false` x23, both +8 bases in registers |
| (a) shared | 1840 | 1 | 1 | 1 | 0 | 362 | `true` spilled (7 reloads from the stack), one +8 base spilled (2 reloads), the other base word reloaded 5 times |
| (b) second copy | 2680 | 1 | 1 | 5 | 0 | 488 | `true` and `false` both spilled (3 reloads each) |

So the loop kept one jump table and one indirect branch in both builds,
and lost registers in both: the shared path is not free of the register
cost either (starting position 3 was wrong), the copies cost more.

The aligned A/B (`scripts/part2-ab.sh`, raw lines `part2/ab-all4.txt`,
table `part2/table-all4.md` by `scripts/part2-table.py`): base, (a) and (b)
from the same source tree, `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`, five runs, the three
sides interleaved with their order rotated each run, `--slice-ms 0`,
2026-11-17 15:10 to 15:20, no thermal or performance warning recorded at
either end (`pmset -g therm`). Kernels: the workers' cycles; the kernel
tests: the `kajo test` process's cycles (`/usr/bin/time -l`). Ratios are
medians against the base's median; the cycles ratio's range is the
variant's five runs.

| workload | workers | base ms | base cycles | (a) cycles ratio | (a) instructions | (b) cycles ratio | (b) instructions |
|---|--:|--:|--:|--:|--:|--:|--:|
| alloc | 1 | 2893 | 9.69 G | **0.976** (0.972-0.978) | 0.987 | **0.960** (0.959-0.968) | 0.983 |
| arith | 1 | 1823 | 6.12 G | 1.004 (1.002-1.005) | 1.000 | 1.000 (1.000-1.001) | 1.000 |
| closures | 1 | 3147 | 10.57 G | 0.998 (0.996-1.004) | 1.000 | **1.041** (1.038-1.042) | 1.000 |
| fib | 1 | 1380 | 4.63 G | 0.998 (0.997-1.000) | 0.996 | 0.997 (0.996-1.001) | 0.995 |
| floats | 1 | 3228 | 10.83 G | 0.985 (0.984-0.987) | 1.000 | 1.006 (1.003-1.016) | 1.035 |
| ivars | 1 | 1819 | 6.10 G | 0.997 (0.997-0.999) | 1.003 | 0.997 (0.996-0.999) | 1.003 |
| sends | 1 | 1684 | 5.65 G | **0.956** (0.948-0.958) | 0.978 | **0.968** (0.968-0.972) | 0.975 |
| storeheavy | 1 | 2117 | 7.09 G | 0.997 (0.993-0.998) | 1.000 | 0.996 (0.993-0.997) | 1.000 |
| walk | 1 | 3589 | 12.04 G | 0.996 (0.992-0.999) | 0.985 | 1.008 (0.999-1.049) | 0.985 |
| st-closures | 1 | 3229 | 10.84 G | 0.998 (0.995-1.000) | 1.000 | 0.994 (0.993-0.995) | 1.000 |
| st-ivars | 1 | 1816 | 6.09 G | 0.995 (0.992-0.997) | 1.003 | 0.997 (0.995-0.999) | 1.003 |
| st-sends | 1 | 1400 | 4.69 G | **0.971** (0.970-0.978) | 0.982 | **0.968** (0.967-0.970) | 0.973 |
| kernel tests | 1 | 6540 | 14.92 G | 0.994 (0.991-0.994) | 0.996 | 0.997 (0.994-0.999) | 0.995 |
| alloc | 8 | 454 | 10.95 G | 0.966 (0.957-0.987) | 0.983 | 0.960 (0.951-0.966) | 0.985 |
| arith | 8 | 246 | 6.09 G | 1.010 (1.003-1.018) | 1.001 | 1.006 (1.000-1.018) | 1.001 |
| closures | 8 | 426 | 10.63 G | 0.992 (0.979-1.003) | 1.000 | 1.040 (1.026-1.053) | 1.000 |
| fib | 8 | 185 | 4.66 G | 0.986 (0.985-1.016) | 0.995 | 0.992 (0.986-1.014) | 0.995 |
| floats | 8 | 438 | 11.12 G | 1.046 (0.969-1.175) | 1.001 | 1.052 (0.980-1.526) | 1.001 |
| ivars | 8 | 253 | 6.17 G | 0.988 (0.980-1.015) | 1.001 | 0.984 (0.980-1.002) | 1.001 |
| sends | 8 | 232 | 5.71 G | 0.960 (0.937-0.971) | 0.978 | 0.957 (0.954-0.987) | 0.974 |
| storeheavy | 8 | 271 | 7.05 G | 1.010 (0.996-1.024) | 1.001 | 1.003 (0.996-1.016) | 1.000 |
| walk | 8 | 471 | 11.81 G | 0.993 (0.981-1.007) | 0.988 | 1.015 (0.991-1.018) | 0.987 |
| st-closures | 8 | 438 | 10.94 G | 0.995 (0.983-0.997) | 1.000 | 0.985 (0.972-0.996) | 0.999 |
| st-ivars | 8 | 233 | 6.06 G | 1.015 (0.998-1.024) | 1.004 | 1.016 (0.997-1.019) | 1.004 |
| st-sends | 8 | 181 | 4.67 G | 0.990 (0.976-1.003) | 0.984 | 0.971 (0.967-0.977) | 0.974 |

The rule applied (`part2-table.py`'s last lines):

- **(a)**: gains at one worker `sends` 4.39 percent, `st-sends` 2.85,
  `fib` 0.20, `closures` 0.23, the kernel tests 0.64; none at 5 percent.
  Its worst golden ratio is `floats` at 8 workers, 1.046, whose five runs
  span 0.969 to 1.175 (the 8-worker rows are noisy; at one worker nothing
  is above 1.004). **Does not pass.**
- **(b)**: `sends` 3.18, `st-sends` 3.22, `fib` 0.33, `closures` -4.12
  (the spilled `true` and `false`: `closures` is compares and conditional
  jumps), the kernel tests 0.25; none at 5 percent, `closures` 1.041 at
  one worker. **Does not pass.**

By the rule's step 2, with the all-four (a) build failing no pair was
measured alone: a pair alone removes a subset of the same dispatches, and
the two workloads that came closest owe all of theirs to `push_temp send`.
Step 3 does not arise: (b) does not pass either.

Per removed dispatch: in `sends` (a) saved 0.022 of 26.8 G instructions,
7.4 instructions for each of the 80 M fused pairs, which is the
dispatch's seven; and 3.1 cycles each (4.39 percent of 5.65 G over 80 M);
`st-sends` 3.3 cycles, the kernel tests 2.7 (0.64 percent of 14.9 G
process cycles over the 36.0 M dispatches the four pairs remove) per
removed dispatch. That is above part 1's ceiling (ii) (1.5 to 1.9 cycles,
seven instructions at the mean IPC) and well under ceiling (i).

## The bound (the module's result)

Fusing a push with the send after it, for every pair that matters
(`push_temp`, `push_self`, `push_lit`, `push_ivar`), removes 3.7 percent
of the kernel tests' dispatches and 10 percent of `sends`', and gains at
most **4.4 percent of cycles on `sends`, 2.9 on `st-sends`, 2.4 to 4.0 on
`alloc`, 0.6 on the kernel tests and nothing on `fib` or `closures`**, in a
build that ignores everything a real fused send must keep. The shared send
path is the better of the two shapes and still moves `true` and a base
register to the stack. The rule needed 5 percent on two of the five
workloads; the best build reaches it on none. Nothing is built.

Where the time goes instead: a send in the kernel tests is 13.2
dispatches apart from the next, and the pair before it is one of them; the
workloads are send-bound (their sends' lookups, activations and returns),
not bound by the dispatch between a push and a send.

## Starting positions

1. "Sends after `push_temp`, `push_self` or `push_lit` are under 10
   percent of dispatches; the ceiling from removed dispatches is a few
   percent of cycles." **Held for the kernel tests (4.07 percent with
   `push_ivar`) and most kernels; wrong for `sends` (10.17), `alloc`
   (12.12, `push_lit` and `push_ivar`) and `walk` (12.15).** The ceiling
   held: 4.4 percent at most measured.
2. "The gain is the removed dispatch and nothing else." **Held for
   instructions** (7.4 removed per pair in `sends`, the dispatch's
   seven); **in cycles a removed dispatch was worth 2.7 to 3.3**, more
   than its seven instructions at the mean IPC (1.5 to 1.9), so the
   indirect branch's prediction is part of it. The send's own work did not
   shrink.
3. "A fused send through the one send path keeps the loop's register
   allocation; a second inline copy does not." **Wrong in its first half**:
   (a) kept one send, one jump table and one indirect branch but spilled
   `true` and one base register; (b) spilled `true` and `false` and cost
   `closures` 4 percent. Neither shape is free.
4. "The static counts overstate the dynamic share." **Held**: `push_temp
   send` is 4.97 percent of the kernel image's instructions and 2.02 of
   the kernel tests' dispatches, `push_lit send` 3.90 against 0.17;
   `push_ivar send` is the exception (0.38 against 0.75).
5. "The workloads that matter are send-bound, not bound by the dispatch
   between a push and a send." **Held**: 0.6 percent on the kernel tests
   at best.

## Deviations from the brief

- The kernel tests' cycles are the whole `kajo test` process's
  (`/usr/bin/time -l`; `kajo test` has no workers' counters line), image
  load and harness included, on both sides alike. Their gain is therefore
  diluted by the harness; at 4.07 percent of dispatches fused their
  ceiling (i) was already under 5 percent.
- The tools' tests were counted (the kernel and tools tests row of part
  1) but not in part 2's A/B: the rule names the kernel tests, and the
  two rows of part 1 agree within 0.05 percent.
- The disassembly reading is `scripts/disasm.sh`, which applies `just
  arc-check`'s counts (indirect branches, jump-table loads, ARC calls) to
  `interpret` of each build; `just arc-check` itself builds the working
  tree and was not run on the cheating trees.
- The runtime comparison's Kajo rows and the matrices (part 4) were not
  run: nothing was built.

## Not done

- Each pair alone was not measured: the rule's step 2 says not to after
  the all-four build failed.
- Triples ending in a send (none above 0.4 percent of the tests'
  dispatches) and `push_closure send` (0.65 percent, an out-of-line push)
  were not tried; the brief keeps triples out.
- No device run: there is nothing to compare on a device.

## Open questions

None of the brief's three arises as a decision: the threshold was not met
by either shape, so open questions 2 and 3 have nothing to choose between.
One for the owner, with a recommendation:

1. **Close fused sends as measured?** The bound above (4.4 percent on the
   kernel that is nothing but these sends, 0.6 on the kernel tests) is
   below the rule, and the native engine runs Release apps. Recommended:
   close it; reopen only if a workload where the interpreter matters
   (the developer's session, a Debug app) is measured to be dispatch-bound
   between pushes and sends.
