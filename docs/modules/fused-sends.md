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
